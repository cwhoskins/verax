## Op-amp macromodels: the free-standing `idealOpAmp` template a named
## analysis instantiates, and `opampModel`, the flat macromodel every
## un-named op-amp gets so a *cascade* is measurable.
##
## `opampModel` mutates the `Netlist` it is given; run it on a simulation
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
  ## The voltages on a part's supply pins, when both are stated.
  ##
  ## Read from the *net* rather than from the component, unlike a
  ## regulator's output: here the rail is what the part is connected to
  ## rather than something it produces, so the net's nominal is the right
  ## source and there is no risk of measuring an assumption back.
  var hi = NaN
  var lo = NaN
  for _, p in c.pins:
    if p.net == nil: continue
    let v = annotations.railVoltage(p.net)
    if not v.has: continue
    if p.name.toLowerAscii in ["v+", "vcc", "vdd", "vs+", "vp"]:
      hi = v.value
    elif p.name.toLowerAscii in ["v-", "vee", "vss", "vs-", "vn"]:
      lo = v.value
  # A single-supply part often ties V- to ground, which states no voltage of
  # its own and is 0 by definition.
  if hi.classify != fcNan and lo.classify == fcNan:
    for _, p in c.pins:
      if p.net != nil and isGround(p.net) and
         p.name.toLowerAscii in ["v-", "vee", "vss", "gnd", "vs-", "vn"]:
        lo = 0.0
  (hi: hi, lo: lo, known: hi.classify != fcNan and lo.classify != fcNan)

proc idealOpAmp*(name = "IDEAL_OPAMP", aol = 1.0e5, gbw = 1.0e6,
                 vsatHi = Inf, vsatLo = -Inf): Netlist =
  ## A single-pole op-amp macromodel as a free-standing template `Netlist`
  ## with ports `INP`, `INN`, `OUT` in that order, ready for
  ## `graph.instantiate`.
  ##
  ## Topology: a VCVS of gain `aol` across the inputs, into an RC pole at
  ## `gbw/aol`, into a unity-gain VCVS output buffer. That gives exactly the
  ## open-loop behaviour a stability or bandwidth question turns on -- DC
  ## gain `aol`, -20 dB/decade above the pole, unity gain at `gbw`, and the
  ## 90 degrees of phase lag that comes with it -- and nothing else.
  ##
  ## What it deliberately does **not** model: input offset and bias current,
  ## finite output impedance and current limit, slew rate, common-mode range,
  ## supply rails (the model does not even connect to them), or any second
  ## pole. So it will never predict clipping, slewing, or the phase margin
  ## lost to a real amplifier's higher-order poles. It answers "does my
  ## feedback network give the closed-loop gain and bandwidth I expect", not
  ## "will this exact part be stable".
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

  # Pole placed with a fixed 1k so only C carries the frequency choice.
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
  # Never let parasitic expansion touch the pole capacitor: it is a modelling
  # element, not a physical part, and giving it an ESL would add a spurious
  # resonance to the amplifier's own response.
  cp.attrs["parasitics.expanded"] = "true"

  # The output buffer. Unbounded it is a VCVS, which is an ideal source and
  # therefore cannot saturate however hard the loop drives it -- so a stage
  # whose only nonlinearity is the amplifier running out of swing measures
  # perfectly clean, which is a statement about the model rather than about
  # the circuit.
  #
  # Bounded, it becomes a `B` source carrying the limit in its expression.
  # Clamping a VCVS's *output* with diodes instead achieves nothing: an
  # ideal source holds its node regardless of what is hung across it. The
  # clamp has to sit between the pole and the buffer, which is what
  # `min(max(...))` on `V(N2)` does.
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
  ## Whether `opampModel` clamps a substituted amplifier to its supply
  ## rails. A module-level switch rather than a parameter because
  ## `BehavioralModel` takes a fixed signature and every other model shares
  ## it; the alternative was a parameter no other model would ever use.

proc opampModel*(nl: Netlist, c: Component, gnd: Net): BehavioralResult =
  ## An amplifier with no model of its own becomes the same single-pole
  ## macromodel `analysis/opamp` substitutes for the stage it is measuring:
  ## a VCVS of gain `aol` into an RC pole at `gbw/aol`, into a unity-gain
  ## output buffer.
  ##
  ## This is what makes a *cascade* measurable. An analysis names one
  ## amplifier and models it deliberately; without an entry here every other
  ## op-amp in the path fell through to per-pin impedances -- 1 Mohm on each
  ## input, 50 ohm on the output, all to ground -- which does not lose
  ## accuracy so much as delete the stage. Measured that way, a 4th-order
  ## Sallen-Key filter reported 82 dB of peaking and a 2 MHz corner for a
  ## response that is flat to 20 kHz.
  ##
  ## The substitution order this sits in is the point, and it runs
  ## most-specific first: a part carrying its own `subNetlist` or a
  ## `simReplace` is never reached, because `expandPinModels` filters both
  ## out before it consults this registry; a kind with a model here gets that
  ## model; and only a part with neither falls through to per-pin
  ## impedances. The pin model is the last resort, not the first answer.
  ##
  ## **Built flat rather than as an instance of `idealOpAmp`**, which is the
  ## one non-obvious thing here. `spice/isolate` treats any component with a
  ## `subNetlist` as something it may not traverse, so a macromodel dropped
  ## in as a subcircuit is cut at the very boundary it was added to bridge --
  ## the same broken path as before, one layer along, and it cost the filter
  ## above a corner of 11 kHz instead of 20. Emitted flat, every part is a
  ## resistor, a capacitor or a VCVS, all of which `kinds.isPassive` accepts,
  ## so the walk crosses the stage exactly as it crosses a buffer.
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
  # `gbw` was a `const` here until it was noticed that the assumption line
  # below reported 1 MHz as invented while a stated `gbw` sat one field away
  # unread. That is the worst shape a default can take: the value the design
  # gave was ignored, and the report said so in a way that reads as the
  # design not having given one. `analysis/opamp` already honoured the
  # annotation, so the two paths disagreed about the same part -- and this is
  # the *only* path for every amplifier a `.tran` sees, since nothing there
  # names one stage to model deliberately.
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
  # The pole capacitor is a modelling element, not a part. Giving it an ESL
  # would put a resonance in the amplifier's own response that the real
  # device does not have.
  cp.attrs["parasitics.expanded"] = "true"

  # Bounded to the part's own supply rails when the design states them, for
  # the reason spelled out in `idealOpAmp`: an unbounded VCVS output cannot
  # saturate, so a stage running out of swing measures clean.
  # Same rule as the named amplifier's macromodel: a clamp has a zero
  # derivative at its limit, so it belongs in a large-signal run and nowhere
  # near an `.ac` linearisation. `boundOpAmpsToRails` is set by the one
  # caller that wants it.
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
  # The model is still a substitution even when both its numbers were
  # stated, so a note is always emitted -- but its *provenance* is the truth
  # about where the numbers came from, and `invented()` counts on it.
  result.notes.add assumption(desig, "gbw", gbw, "Hz",
    (if b.has and b.value > 0.0: annAuthored else: annDefaulted),
    "of a substituted ideal single-pole op-amp (Aol " & eng(aol) & "); no " &
    "offset, slew rate, output impedance, supply rails or second pole are " &
    "represented")
