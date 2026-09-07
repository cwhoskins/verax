## Power-distribution-network impedance: how much the rail voltage moves when
## the load's current draw changes, as a function of frequency.
##
## This is the question a decoupling scheme exists to answer. A digital load
## drawing a step of dI develops dV = Z(f)*dI on its own supply pin, so the
## design target is stated as an impedance: "keep Z below 100 mohm out to
## 100 MHz". The three things that make or break that are exactly the three
## things an ideal-capacitor model cannot show:
##
## * the **ESR floor** -- below it no amount of capacitance helps;
## * **self-resonance**, above which a capacitor is an inductor; and
## * **anti-resonance**, the impedance *peak* where a bulk capacitor's
##   inductance rings against a ceramic's capacitance. This is the failure
##   mode. It is created by adding decoupling, it sits between the two
##   capacitors' own resonances, and it is invisible to any analysis that
##   models capacitors as ideal.
##
## So `verax/spice/models.expandCapacitorParasitics` is not an optional
## refinement here; without it this analysis has nothing to report.
##
## Like every simulation-backed check in this submodule, the design netlist
## passed in is never mutated or simulated directly -- `isolate` clones first.

import std/[math, strutils, tables]
import ../../netlist/types
import ../../netlist/graph
import ../../netlist/formats/spice as spiceFormat
import ../../spice/isolate
import ../../spice/transform
import ../../spice/models
import ../../spice/flatten
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
      ## Lowest frequency at which `targetZ` is meaningful, in Hz.
      ##
      ## Below the supply's regulation bandwidth it is the *regulator*, not
      ## the decoupling network, that holds the rail up -- and this analysis
      ## does not model the regulator at all, having cut it away at the
      ## boundary. A bare capacitor bank is necessarily high-impedance down
      ## there, so checking a decoupling target against the low-frequency end
      ## would flag every well-designed board for a problem it does not have.
      ## The 100 kHz default is a typical crossover for a switching
      ## regulator; lower it for a design whose loop is slower.
    targetTo*: float
      ## Highest frequency at which `targetZ` is meaningful, in Hz.
      ##
      ## The mirror of `targetFrom` at the other end. Above roughly 100 MHz
      ## the rail impedance is set by plane capacitance, package and via
      ## inductance and die-level decoupling -- none of which is in a netlist,
      ## and none of which discrete capacitors control. The sweep deliberately
      ## runs past this so the rise is visible, but checking a discrete-
      ## decoupling target up there would flag every board for something no
      ## change to the capacitor selection can fix.
    reportAt*: seq[float]
      ## Frequencies to report Z at explicitly, in Hz.
    maxHops*: int
    parasitics*: ParasiticDefaults
    sourceZ*: SourceDefaults
      ## Output impedance substituted for a supply that states none. Set
      ## `modelSources = false` to leave sources ideal, which reports the
      ## rail as a dead short whenever one is present.
    pinModels*: PinModelDefaults
      ## Per-pin-kind impedance substituted for a part carrying no model.
    modelSources*: bool
    flattenHierarchy*: bool
      ## Dissolve subcircuit instances into the top level before anything
      ## else touches the netlist. On by default: left un-flattened, every
      ## instance is cut at its boundary by `spice/isolate` and no model pass
      ## reaches inside one. Off restores the older behaviour.
    keepInstances*: seq[string]
      ## Instance paths `flatten` must leave intact, beyond the part this
      ## analysis was named for (which is added automatically). For a design
      ## that brings its own subcircuit macromodel and expects it honoured.
    bias*: OrderedTable[string, float]
      ## A solved operating point, node name -> volts, used to work out the DC
      ## across each capacitor for bias derating. Empty falls back to reading
      ## a stated rail voltage off the net, which misses every capacitor on an
      ## unannotated node. See `analysis/operating`.
    modelUnmodelledParts*: bool
      ## When false, a part nothing describes is cut away at the boundary
      ## instead of being stood in for -- the older behaviour, which reports
      ## a rail loaded by nothing at all.

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
  ## Isolates everything hanging off `powerNet`, expands capacitor
  ## parasitics, injects 1 A of AC current into the rail and sweeps.
  ##
  ## `groundNet` may be left empty when the design already names its ground
  ## `"0"` or tags it `ntGround`.
  result.name = "PDN impedance on '" & powerNet & "'"

  if not nl.nets.hasKey(powerNet):
    raise newException(NetlistError, "no such net: " & powerNet)

  var isoSpec = defaultIsolationSpec("pdn_" & powerNet)
  isoSpec.maxHops = spec.maxHops
  isoSpec.groundNet = groundNet
  # The rail under test must stay undriven: an ideal source is an AC short,
  # and terminating it would report zero impedance at every frequency.
  isoSpec.excludeRails = @[powerNet]
  # Any *other* rail reached (e.g. through a ferrite bead) is left floating
  # rather than blocking the run; it is reported as an assumption instead.
  isoSpec.requireKnownRails = false

  # Stand in for the parts nothing describes *before* isolating, not after:
  # `isolate` refuses to traverse an unmodellable component and records it in
  # `dropped`, so by the time it has run there is nothing left to model. Once
  # each becomes a per-pin impedance it is passive, and the rail sees what it
  # actually hangs off instead of an open circuit.
  var cloneNets: OrderedTable[string, Net]
  # `materializeSimNetlist` rather than a bare `clone`: a component's own
  # `simReplace` is the design's statement of how it wants that part
  # simulated, and this analysis used to ignore it entirely.
  let work = materializeSimNetlist(nl, cloneNets, purpose = spSmallSignal)
  discard flattenForSim(work, spec.flattenHierarchy, spec.keepInstances)
  if spec.modelUnmodelledParts:
    result.assumptions.add expandPinModels(work, spec.pinModels)

  var globalNets: OrderedTable[string, Net]
  let iso = isolateNets(work, [powerNet], isoSpec, globalNets)
  result.assumptions.add iso.assumptions
  let frag = iso.netlist

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
  # A supply left ideal is a dead short at AC: the rail would read 0 ohm and
  # pass any target. `excludeRails` already stops one being *synthesized* for
  # the rail under test; this handles one the design carries itself.
  if spec.modelSources:
    result.assumptions.add expandSourceImpedance(frag, spec.sourceZ)
  if iso.dropped.len > 0:
    result.assumptions.add note("components " & iso.dropped.join(", ") &
      " were cut at the boundary: their actual current draw and input impedance " &
      "are not represented")

  let probe = addImpedanceProbe(frag, frag.nets[powerNet], frag.nets["0"])

  let card = ".ac dec " & $spec.ptsPerDecade & " " &
             spiceFormat.spiceValue(spec.fStart) & " " & spiceFormat.spiceValue(spec.fStop)
  try:
    result.raw = run(frag, @[card], label = "pdn:" & powerNet)
  except SpiceSimError as e:
    result.issues.add newIssue(KindSimulationFailed, sevWarning,
      "ngspice could not sweep the isolated PDN fragment: " & e.msg)
    return

  let f = result.raw.freq()
  # A 1 A drive means the node voltage is numerically the impedance.
  let z = result.raw.mag(probe.label)
  # The composite self-resonance: the frequency this decoupling scheme is
  # actually good at, and the ESR floor it bottoms out on.
  var minI = 0
  for i in 1 ..< z.len:
    if z[i] < z[minI]: minI = i
  result.add "z_min", z[minI], "ohm"
  result.add "f_z_min", f[minI], "Hz"

  # The worst impedance inside the band the target applies to. Deliberately
  # not the global maximum: a sweep starting below the bulk capacitor's
  # resonance always peaks at its very first point, in the capacitive region
  # the regulator owns, so a global maximum would say nothing at all about
  # the decoupling network.
  var maxI = -1
  for i in 0 ..< z.len:
    if f[i] >= spec.targetFrom and f[i] <= spec.targetTo and
       (maxI < 0 or z[i] > z[maxI]): maxI = i
  if maxI >= 0:
    result.add "z_max_in_band", z[maxI], "ohm"
    result.add "f_z_max_in_band", f[maxI], "Hz"

  # The worst anti-resonance anywhere in the sweep. An interior maximum is
  # two capacitor families ringing against each other -- one's inductance
  # against the other's capacitance -- and it is the failure mode that adding
  # more of the same capacitor makes worse rather than better.
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
