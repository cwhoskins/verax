## Power-distribution-network impedance: how much the rail moves as load
## current changes, vs frequency (dV = Z(f)*dI, so targets are impedances).
##
## What matters is what an ideal-capacitor model can't show: the **ESR
## floor**, **self-resonance**, and **anti-resonance** -- the peak where one
## capacitor's inductance rings against another's capacitance, created by
## adding decoupling. So `expandCapacitorParasitics` is essential here.
##
## The design is never mutated; `isolate` clones first.

import std/[math, strutils, tables]
import ../../netlist/types
import ../../netlist/graph
import ../../netlist/formats/spice as spiceFormat
import ../../spice/isolate
import ../../spice/bench
import ../../spice/transform
import ../../spice/models
import ../../spice/probes
import ../../spice/ngspice
import ../measure
import ../report

export report

const
  KindNoDecoupling* = "pdn_no_decoupling"
  KindImpedanceExceedsTarget* = "pdn_impedance_exceeds_target"
  KindAntiresonance* = "pdn_antiresonance"
  KindSimulationFailed* = "pdn_simulation_failed"

type
  PdnSpec* = object
    fStart*, fStop*: float
    ptsPerDecade*: int
    targetZ*: float
      ## Design target in ohms, enforced only from `targetFrom` upward.
    targetFrom*: float
      ## Lowest frequency `targetZ` applies at, Hz. Below the regulator's
      ## crossover the regulator holds the rail (cut away here), so a bare
      ## bank would always fail. 100 kHz suits a typical switcher; lower it
      ## for a slower loop.
    targetTo*: float
      ## Highest frequency `targetZ` applies at, Hz. Above ~100 MHz plane,
      ## package and via inductance dominate -- not in a netlist and not
      ## fixable by capacitor choice. The sweep runs past it so the rise is
      ## visible.
    reportAt*: seq[float]
      ## Frequencies to report Z at explicitly, in Hz.
    maxHops*: int
    parasitics*: ParasiticDefaults
    sourceZ*: SourceDefaults
      ## Output impedance for a supply that states none. `modelSources =
      ## false` leaves sources ideal (the rail then reads as a dead short).
    pinModels*: PinModelDefaults
      ## Per-pin-kind impedance substituted for a part carrying no model.
    modelSources*: bool
    flattenHierarchy*: bool
      ## Flatten subcircuit instances first (default on); otherwise
      ## `spice/isolate` cuts each instance at its boundary.
    keepInstances*: seq[string]
      ## Instance paths `flatten` keeps intact, beyond the analysed part
      ## (added automatically) -- for a design's own subcircuit macromodel.
    bias*: OrderedTable[string, float]
      ## A solved operating point (node -> volts) for capacitor bias
      ## derating. Empty falls back to stated rail voltages, missing
      ## unannotated nodes. See `analysis/operating`.
    modelUnmodelledParts*: bool
      ## When false, undescribed parts are cut away instead of stood in for
      ## (the rail then sees no load).

proc defaultPdnSpec*(): PdnSpec =
  PdnSpec(fStart: 1.0e3, fStop: 1.0e9, ptsPerDecade: 20,
          targetZ: 0.1, targetFrom: 1.0e5, targetTo: 1.0e8,
          reportAt: @[1.0e5, 1.0e6, 1.0e7, 1.0e8], maxHops: 3,
          parasitics: defaultParasitics(),
          sourceZ: defaultSourceImpedance(),
          pinModels: defaultPinModels(),
          modelSources: true,flattenHierarchy: true,
 modelUnmodelledParts: true)

proc analyzePdn*(nl: Netlist, powerNet: string, groundNet = "",
                 spec = defaultPdnSpec()): AnalysisReport =
  ## Isolates everything on `powerNet`, expands capacitor parasitics,
  ## injects 1 A AC into the rail and sweeps. `groundNet` may be empty if
  ## ground is `"0"` or tagged `ntGround`.
  result.name = "PDN impedance on '" & powerNet & "'"

  if not nl.nets.hasKey(powerNet):
    raise newException(NetlistError, "no such net: " & powerNet)

  var isoSpec = defaultIsolationSpec("pdn_" & powerNet)
  isoSpec.maxHops = spec.maxHops
  isoSpec.groundNet = groundNet
  # The rail under test stays undriven (an ideal source would short it).
  isoSpec.excludeRails = @[powerNet]
  # Other rails reached (e.g. through a ferrite) float, as an assumption.
  isoSpec.requireKnownRails = false

  # Stand in for undescribed parts *before* isolating; `isolate` won't
  # traverse them afterwards.
  var b = openBench(nl, "pdn:" & powerNet, spSmallSignal,
                    spec.flattenHierarchy, spec.keepInstances)
  if spec.modelUnmodelledParts: b.modelUnmodelled(spec.pinModels)
  b.scopeBench ScopeRequest(strategy: "terminated", seedNets: @[powerNet],
                            isolation: isoSpec)
  result.assumptions.add b.assumptions
  let iso = (dropped: b.scoped.region.dropped)
  let frag = b.netlist

  var caps: seq[Component]
  for _, c in frag.components:
    if c.kind == "capacitor": caps.add c
  result.add "cap_count", float(caps.len)

  if caps.len == 0:
    result.issues.add newIssue(KindNoDecoupling, sevError,
      "net '" & powerNet & "' has no decoupling capacitor to ground: its impedance " &
      "is set entirely by the supply and the plane, and nothing here can bound it",
      net = nl.nets[powerNet])
    return

  result.assumptions.add expandCapacitorParasitics(
    frag, spec.parasitics, defaultDerating(), spec.bias)
  # An ideal supply in the design would short the rail at AC; give it
  # impedance.
  if spec.modelSources:
    result.assumptions.add expandSourceImpedance(frag, spec.sourceZ)
  if iso.dropped.len > 0:
    result.assumptions.add note("components " & iso.dropped.join(", ") &
      " were cut at the boundary: their actual current draw and input impedance " &
      "are not represented")

  let probe = addImpedanceProbe(frag, frag.nets[powerNet], frag.nets["0"])
  b.stimulus(probe.source, "1 A AC injected into '" & powerNet & "'")
  b.probe(powerNet, "V(" & powerNet & ") is the rail's impedance in ohms")

  let card = ".ac dec " & $spec.ptsPerDecade & " " &
             spiceFormat.spiceValue(spec.fStart) & " " & spiceFormat.spiceValue(spec.fStop)
  try:
    result.raw = b.run(@[card], label = "pdn:" & powerNet)
  except SpiceSimError as e:
    result.issues.add newIssue(KindSimulationFailed, sevWarning,
      "ngspice could not sweep the isolated PDN fragment: " & e.msg)
    return

  let f = result.raw.freq()
  # A 1 A drive means the node voltage is numerically the impedance.
  let z = result.raw.mag(probe.label)
  # Composite self-resonance: where the scheme works best, and its ESR
  # floor.
  var minI = 0
  for i in 1 ..< z.len:
    if z[i] < z[minI]: minI = i
  result.add "z_min", z[minI], "ohm"
  result.add "f_z_min", f[minI], "Hz"

  # Worst impedance inside the target band, not globally: a sweep starting
  # below the bulk cap's resonance always peaks at its first point.
  var maxI = -1
  for i in 0 ..< z.len:
    if f[i] >= spec.targetFrom and f[i] <= spec.targetTo and
       (maxI < 0 or z[i] > z[maxI]): maxI = i
  if maxI >= 0:
    result.add "z_max_in_band", z[maxI], "ohm"
    result.add "f_z_max_in_band", f[maxI], "Hz"

  # The worst anti-resonance: an interior maximum where two capacitor
  # families ring, made worse by adding more of the same capacitor.
  let peaks = localMaxima(f, z)
  var worst = -1
  for i, pk in peaks:
    if worst < 0 or pk.y > peaks[worst].y: worst = i
  if worst >= 0:
    result.add "z_antiresonance", peaks[worst].y, "ohm"
    result.add "f_antiresonance", peaks[worst].x, "Hz"
  else:
    result.add "z_antiresonance", NaN, "ohm"
    result.add "f_antiresonance", NaN, "Hz"

  for target in spec.reportAt:
    let v = valueAt(f, z, target, logX = true)
    if not v.isNaN:
      result.add "z_at_" & eng(target, "Hz").replace(" ", ""), v, "ohm"

  if maxI >= 0 and z[maxI] > spec.targetZ:
    result.issues.add newIssue(KindImpedanceExceedsTarget, sevWarning,
      "PDN impedance on '" & powerNet & "' reaches " & eng(z[maxI], "ohm") &
      " at " & eng(f[maxI], "Hz") & ", above the " & eng(spec.targetZ, "ohm") &
      " target, over the " & eng(spec.targetFrom, "Hz") & " to " &
      eng(spec.targetTo, "Hz") & " band",
      net = nl.nets[powerNet])

  for pk in peaks:
    if pk.y > spec.targetZ and pk.x >= spec.targetFrom and pk.x <= spec.targetTo:
      result.issues.add newIssue(KindAntiresonance, sevWarning,
        "anti-resonant peak of " & eng(pk.y, "ohm") & " at " & eng(pk.x, "Hz") &
        " on '" & powerNet & "' -- an impedance peak between two capacitors' " &
        "self-resonances; adding more of either capacitor will not remove it, " &
        "damping or an intermediate value will", net = nl.nets[powerNet])
