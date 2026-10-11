## Op-amp macromodels: `idealOpAmp`, a template a named analysis
## instantiates, and `opampModel`, the flat macromodel every unnamed op-amp
## gets so cascades are measurable. `opampModel` mutates its netlist; use a
## clone.

import std/[math, strutils, tables]
import ../../netlist/types
import ../../netlist/graph
import ../../netlist/annotations
import ../../netlist/kinds
import ../../eng
import ../../netlist/formats/spice as spiceFormat
import ./common
import ./behavioral

proc supplyRailsOf*(c: Component): tuple[hi, lo: float, known: bool] =
  ## The voltages on a part's supply pins, when both are stated -- read
  ## from the nets it's connected to.
  var hi = NaN
  var lo = NaN
  for _, p in c.pins:
    if p.net == nil: continue
    let v = annotations.railVoltage(p.net)
    if not v.has: continue
    if p.name.toLowerAscii in ["v+", "vcc", "vdd", "vs+", "vp"]:
      hi = float(v.value)
    elif p.name.toLowerAscii in ["v-", "vee", "vss", "vs-", "vn"]:
      lo = float(v.value)
  # Single-supply: V- on ground states no voltage and is 0 by definition.
  if hi.classify != fcNan and lo.classify == fcNan:
    for _, p in c.pins:
      if p.net != nil and isGround(p.net) and
         p.name.toLowerAscii in ["v-", "vee", "vss", "gnd", "vs-", "vn"]:
        lo = 0.0
  (hi: hi, lo: lo, known: hi.classify != fcNan and lo.classify != fcNan)

proc idealOpAmp*(name = "IDEAL_OPAMP", aol = 1.0e5, gbw = 1.0e6,
                 vsatHi = Inf, vsatLo = -Inf): Netlist =
  ## A single-pole op-amp template `Netlist` with ports `INP`, `INN`, `OUT`,
  ## for `graph.instantiate`: VCVS of gain `aol` -> RC pole at `gbw/aol` ->
  ## unity-gain buffer. Gives DC gain, -20 dB/decade, unity gain at `gbw`
  ## and 90 degrees of lag.
  ##
  ## Not modelled: offset, bias current, output impedance and current limit,
  ## slew, common-mode range, rails, higher poles. It checks the feedback
  ## network, not whether a specific part is stable.
  if aol <= 1.0:
    raise newException(NetlistError, "idealOpAmp: open-loop gain must exceed 1, got " & $aol)
  if gbw <= 0.0:
    raise newException(NetlistError, "idealOpAmp: gain-bandwidth must be positive")

  result = newNetlist(name)
  let inp = addNet(result, newNet("INP", ntSignal))
  let inn = addNet(result, newNet("INN", ntSignal))
  let outn = addNet(result, newNet("OUT", ntSignal))
  let gnd = addNet(result, newNet("0", ntGround))
  let n1 = addNet(result, newNet("N1", ntSignal))
  let n2 = addNet(result, newNet("N2", ntSignal))

  # Fixed 1k pole resistor; C sets the frequency.
  const rPole = 1.0e3
  let fPole = gbw / aol
  let cPole = 1.0 / (2.0 * PI * rPole * fPole)

  let ea = addComponent(result, newComponent("E1", kind = "vcvs"))
  discard connect(ea, "OUT+", n1, ptOutput)
  discard connect(ea, "OUT-", gnd, ptPassive)
  discard connect(ea, "IN+", inp, ptInput)
  discard connect(ea, "IN-", inn, ptInput)
  ea.attrs["value"] = spiceValue(aol)

  let rp = addComponent(result, newComponent("R1", kind = "resistor"))
  discard connect(rp, "1", n1, ptPassive)
  discard connect(rp, "2", n2, ptPassive)
  rp.attrs["value"] = spiceValue(rPole)

  let cp = addComponent(result, newComponent("C1", kind = "capacitor"))
  discard connect(cp, "1", n2, ptPassive)
  discard connect(cp, "2", gnd, ptPassive)
  cp.attrs["value"] = spiceValue(cPole)
  # The pole capacitor is a modelling element: an ESL would add a spurious
  # resonance.
  cp.attrs["parasitics.expanded"] = "true"

  # The output buffer. An unbounded VCVS can't saturate. Bounded, it becomes
  # a `B` source with `min(max(...))` on `V(N2)`: diodes across an ideal
  # source's output can't clamp it, so the clamp sits between pole and
  # buffer.
  if vsatHi.classify notin {fcInf, fcNan} and
     vsatLo.classify notin {fcNegInf, fcNan}:
    let bb = addComponent(result, newComponent("B1", kind = "bsource"))
    discard connect(bb, "OUT+", outn, ptOutput)
    discard connect(bb, "OUT-", gnd, ptPassive)
    bb.attrs["value"] = "V = min(max(V(" & n2.name & ")," &
      spiceValue(vsatLo) & ")," & spiceValue(vsatHi) & ")"
  else:
    let eb = addComponent(result, newComponent("E2", kind = "vcvs"))
    discard connect(eb, "OUT+", outn, ptOutput)
    discard connect(eb, "OUT-", gnd, ptPassive)
    discard connect(eb, "IN+", n2, ptInput)
    discard connect(eb, "IN-", gnd, ptInput)
    eb.attrs["value"] = spiceValue(1.0)

  addPort(result, "INP", inp)
  addPort(result, "INN", inn)
  addPort(result, "OUT", outn)

var boundOpAmpsToRails* = false
  ## Whether `opampModel` clamps to the supply rails. A module-level switch
  ## because `BehavioralModel` has a fixed signature.

proc opampModel*(nl: Netlist, c: Component, gnd: Net): BehavioralResult =
  ## An unmodelled amplifier becomes the same single-pole macromodel
  ## `analysis/opamp` uses, making a *cascade* measurable -- per-pin
  ## impedances would effectively delete each stage.
  ##
  ## Substitution order, most specific first: a `subNetlist` or `simReplace`
  ## is filtered out by `expandPinModels` before this registry; a kind here
  ## gets its model; anything else gets per-pin impedances.
  ##
  ## **Built flat, not as an `idealOpAmp` instance**: `spice/isolate` won't
  ## traverse a subcircuit, but crosses resistors, capacitors and VCVSs.
  let outPin = pinNamed(c, opampOutNames)
  let posPin = pinNamed(c, opampPosNames)
  let negPin = pinNamed(c, opampNegNames)
  if outPin == nil or posPin == nil or negPin == nil or
     outPin.net == nil or posPin.net == nil or negPin.net == nil:
    var names: seq[string]
    for p in orderedPins(c): names.add p.name
    return (false, @[note(c.designator & " (" & c.kind & ") needs pins " &
      "reading as +, - and OUT to be stood up as an amplifier -- it has " &
      names.join(", ") & ". It was left unmodelled rather than tied to " &
      "ground, which would open any loop running through it.")])

  let g = annotationFloat(c, "gain")
  let aol = if g.has and g.value > 1.0: g.value else: 1.0e5
  # A stated `gbw` is honoured (matching `analysis/opamp`); this is the only
  # path for amplifiers in a `.tran`.
  let b = annotationFloat(c, "gbw")
  let gbw = if b.has and b.value > 0.0: b.value else: 1.0e6
  const rPole = 1.0e3
  let cPole = 1.0 / (2.0 * PI * rPole * (gbw / aol))

  let posNet = posPin.net
  let negNet = negPin.net
  let outNet = outPin.net
  let desig = c.designator
  removeComponent(nl, desig)

  let n1 = addNet(nl, newNet(desig & "_N1", ntSignal))
  let n2 = addNet(nl, newNet(desig & "_N2", ntSignal))

  let ea = addComponent(nl, newComponent(
    $spiceFormat.designatorPrefix("vcvs") & desig & "_AOL", kind = "vcvs"))
  discard connect(ea, "OUT+", n1, ptOutput)
  discard connect(ea, "OUT-", gnd, ptPassive)
  discard connect(ea, "IN+", posNet, ptInput)
  discard connect(ea, "IN-", negNet, ptInput)
  ea.attrs["value"] = spiceValue(aol)

  let rp = addComponent(nl, newComponent(
    $spiceFormat.designatorPrefix("resistor") & desig & "_POLE", kind = "resistor"))
  discard connect(rp, "1", n1, ptPassive)
  discard connect(rp, "2", n2, ptPassive)
  rp.attrs["value"] = spiceValue(rPole)

  let cp = addComponent(nl, newComponent(
    $spiceFormat.designatorPrefix("capacitor") & desig & "_POLE", kind = "capacitor"))
  discard connect(cp, "1", n2, ptPassive)
  discard connect(cp, "2", gnd, ptPassive)
  cp.attrs["value"] = spiceValue(cPole)
  # The pole capacitor is a modelling element: no ESL.
  cp.attrs["parasitics.expanded"] = "true"

  # Bounded to stated rails, but only when `boundOpAmpsToRails` is set (by
  # the large-signal caller): the clamp's zero derivative would break `.ac`.
  let rails = supplyRailsOf(c)
  if boundOpAmpsToRails and rails.known:
    let bb = addComponent(nl, newComponent(
      $spiceFormat.designatorPrefix("bsource") & desig & "_BUF",
      kind = "bsource"))
    discard connect(bb, "OUT+", outNet, ptOutput)
    discard connect(bb, "OUT-", gnd, ptPassive)
    bb.attrs["value"] = "V = min(max(V(" & n2.name & ")," &
      spiceValue(rails.lo) & ")," & spiceValue(rails.hi) & ")"
    result.notes.add note(desig & " saturates exactly at its supply rails (" &
      eng(rails.lo, "V") & " to " & eng(rails.hi, "V") & "); a real part " &
      "stops short of them by anything from tens of millivolts to a couple " &
      "of volts, so this bounds the swing rather than predicting it")
  else:
    let eb = addComponent(nl, newComponent(
      $spiceFormat.designatorPrefix("vcvs") & desig & "_BUF", kind = "vcvs"))
    discard connect(eb, "OUT+", outNet, ptOutput)
    discard connect(eb, "OUT-", gnd, ptPassive)
    discard connect(eb, "IN+", n2, ptInput)
    discard connect(eb, "IN-", gnd, ptInput)
    eb.attrs["value"] = spiceValue(1.0)
    if boundOpAmpsToRails:
      result.notes.add note(desig & " has no stated supply rails, so its " &
        "output is unbounded and it cannot run out of swing: a stage whose " &
        "only nonlinearity is this amplifier saturating will measure clean")

  result.handled = true
  if not g.has:
    result.notes.add assumption(desig, "gain", aol, "", annDefaulted,
      "open-loop gain of a substituted ideal op-amp; annotate `gain` to " &
      "state the part's own")
  # Always noted (it's a substitution); provenance says whether the numbers
  # were stated, which `invented()` relies on.
  result.notes.add assumption(desig, "gbw", gbw, "Hz",
    (if b.has and b.value > 0.0: annAuthored else: annDefaulted),
    "of a substituted ideal single-pole op-amp (Aol " & eng(aol) & "); no " &
    "offset, slew rate, output impedance, supply rails or second pole are " &
    "represented")
