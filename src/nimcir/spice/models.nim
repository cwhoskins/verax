## Simulation-only device models: parasitic expansion of real components, and
## synthesized macromodels for parts a netlist names but does not describe.
##
## Like `nimcir/spice/transform` and `nimcir/spice/probes`, everything here
## mutates whatever `Netlist` it is given -- run it on a simulation clone
## (`transform.materializeSimNetlist`, `extract.*` or `isolate.isolate`),
## never on the real design netlist.
##
## Both procs here *invent numbers the netlist does not contain*, so both
## return a `seq[string]` of human-readable assumption lines for the caller
## to put in `AnalysisReport.assumptions`. A result derived from an invented
## input has to say so where the reader will see it.

import std/[math, strutils, tables]
import ../netlist/types
import ../netlist/graph
import ../netlist/annotations
import ../netlist/kinds
import ../units
import ../eng
import ../netlist/formats/spice as spiceFormat

type
  Parasitic* = tuple[esr, esl: float]
    ## Equivalent series resistance (ohms) and inductance (henries).

  ParasiticDefaults* = object
    byPackage*: OrderedTable[string, Parasitic]
    fallback*: Parasitic

proc defaultParasitics*(): ParasiticDefaults =
  ## Typical order-of-magnitude MLCC figures by case size, **not** measured
  ## or vendor data. They exist so a board that carries no parasitic
  ## annotation still produces a qualitatively right impedance curve --
  ## self-resonance in roughly the right decade, and an anti-resonance peak
  ## where two capacitor families actually interact. Do not read a specific
  ## ESR number off a run that used these; annotate `attrs["esr"]`/
  ## `attrs["esl"]` from a real datasheet if the exact value matters.
  result.byPackage = {
    "0201": (esr: 0.05, esl: 0.4e-9),
    "0402": (esr: 0.03, esl: 0.6e-9),
    "0603": (esr: 0.02, esl: 0.8e-9),
    "0805": (esr: 0.015, esl: 1.0e-9),
    "1206": (esr: 0.010, esl: 1.2e-9),
    "1210": (esr: 0.010, esl: 1.4e-9),
    "tantalum": (esr: 0.100, esl: 3.0e-9),
    "electrolytic": (esr: 0.200, esl: 5.0e-9),
    "bulk": (esr: 0.100, esl: 3.0e-9),
  }.toOrderedTable
  result.fallback = (esr: 0.02, esl: 1.0e-9)

proc orderedPins(c: Component): seq[Pin] =
  for _, p in c.pins: result.add p

proc parasiticFor(c: Component, d: ParasiticDefaults): tuple[p: Parasitic, notes: seq[Assumption]] =
  ## Attribute first, then the package table, then the global fallback.
  ##
  ## Reads through `netlist/annotations`, so an unparseable value raises with
  ## the same message everywhere and a misspelled key is caught by
  ## `validateAnnotations` rather than silently landing here as a default.
  ## Each invented value is returned as an `Assumption` carrying its own
  ## provenance -- this proc is where the distinction between "the designer
  ## measured this" and "we guessed from the case size" is actually made, so
  ## it is where the record has to be created.
  var p = d.fallback
  var esrSrc = "from the global fallback"
  var eslSrc = "from the global fallback"
  let pkg = package(c)
  if pkg.has and d.byPackage.hasKey(pkg.value):
    p = d.byPackage[pkg.value]
    esrSrc = "from package default (" & pkg.value & ")"
    eslSrc = esrSrc

  let authoredEsr = esr(c)
  if authoredEsr.has:
    p.esr = authoredEsr.value
    esrSrc = ""
  let authoredEsl = esl(c)
  if authoredEsl.has:
    p.esl = authoredEsl.value
    eslSrc = ""

  var notes: seq[Assumption]
  if esrSrc.len > 0:
    notes.add assumption(c.designator, "esr", p.esr, "ohm", annDefaulted, esrSrc)
  if eslSrc.len > 0:
    notes.add assumption(c.designator, "esl", p.esl, "H", annDefaulted, eslSrc)
  (p: p, notes: notes)

type
  DeratingDefaults* = object
    ## How much capacitance a Class 2 ceramic loses to DC bias.
    byDielectric*: OrderedTable[string, seq[(float, float)]]
      ## Dielectric -> (V/Vrated, fraction of nominal capacitance remaining),
      ## interpolated linearly and clamped at both ends.
    assumeDielectric*: string
      ## What an un-annotated *ceramic* is taken to be.
    assumeRatingFactor*: float
      ## When no `voltage_rating` is stated, assume the part was rated at this
      ## multiple of the voltage actually across it.
    enabled*: bool

proc defaultDerating*(): DeratingDefaults =
  ## Typical Class 2 behaviour, and **not** vendor data for any part.
  ##
  ## State the size of the error before the numbers: an X5R bank at about two
  ## thirds of its rating measured 1.23 ohm of worst in-band rail impedance
  ## where the same parts at their nominal values said 173 mohm. Seven times.
  ## That is larger than every other correction in this module put together,
  ## which is why this is on by default.
  ##
  ## The honest caveat, which matters when reading any number that came
  ## through here: **real DC-bias loss depends far more on case size and
  ## capacitance density than on the dielectric letter**. A 10 uF 0402 X5R can
  ## be down to a fifth of its label at rated voltage while a 100 nF 1206 X7R
  ## barely moves, and both are "Class 2". These curves are a typical middle,
  ## so a design where the rail impedance is the product should state measured
  ## capacitance rather than lean on them. Class 1 is exact, not typical:
  ## C0G/NP0 is paraelectric and does not depend on applied voltage at all.
  result.assumeDielectric = "X7R"
  result.assumeRatingFactor = 2.0
  result.enabled = true
  let class2 = @[(0.0, 1.0), (0.25, 0.85), (0.5, 0.65), (0.75, 0.45), (1.0, 0.30)]
  let harsh  = @[(0.0, 1.0), (0.25, 0.70), (0.5, 0.35), (0.75, 0.22), (1.0, 0.15)]
  for k in ["X7R", "X5R", "X6S", "X7S"]: result.byDielectric[k] = class2
  for k in ["Y5V", "Z5U"]: result.byDielectric[k] = harsh
  for k in ["C0G", "NP0"]: result.byDielectric[k] = @[(0.0, 1.0), (1.0, 1.0)]

proc deratingFraction*(curve: seq[(float, float)], ratio: float): float =
  ## Linear interpolation on the curve, clamped outside it.
  if curve.len == 0: return 1.0
  if ratio <= curve[0][0]: return curve[0][1]
  if ratio >= curve[^1][0]: return curve[^1][1]
  for i in 1 ..< curve.len:
    if ratio <= curve[i][0]:
      let (x0, y0) = curve[i - 1]
      let (x1, y1) = curve[i]
      if x1 == x0: return y1
      return y0 + (y1 - y0) * (ratio - x0) / (x1 - x0)
  curve[^1][1]

proc dcAcrossCapacitor(cap: Component,
                       bias: OrderedTable[string, float]): float =
  ## The DC voltage a capacitor sits at.
  ##
  ## `bias` is a solved operating point, node name -> volts, and it is tried
  ## first because it *knows*: it covers a capacitor on any node, not just one
  ## with a stated rail on one plate. That blind spot was not academic -- a
  ## 10 uF rated 6.3 V on a 12 V divider's midpoint sits at 95% of its rating
  ## and came through completely underated, because `mid` carried no `voltage`
  ## annotation and nothing else could see it.
  ##
  ## There is no circularity in consulting it: at DC a capacitor is an open
  ## circuit, so the operating point does not depend on capacitance and the
  ## chain is a straight line rather than a fixed point. Verified -- `v(mid)`
  ## on that divider is bit-identical with 100 pF and with 1000 uF.
  ##
  ## Without a bias, the fallback is the one case that is unambiguous from the
  ## netlist alone: one plate on the reference, the other on a rail whose
  ## nominal voltage is stated. Everything else returns 0, meaning *not known
  ## here*, and no derating is applied.
  let pins = orderedPins(cap)
  if pins.len != 2: return 0.0

  if bias.len > 0 and pins[0].net != nil and pins[1].net != nil:
    let a = pins[0].net.name
    let b = pins[1].net.name
    let va = (if a == "0": 0.0 elif bias.hasKey(a): bias[a] else: NaN)
    let vb = (if b == "0": 0.0 elif bias.hasKey(b): bias[b] else: NaN)
    if va.classify != fcNan and vb.classify != fcNan:
      return abs(va - vb)
  for i in 0 .. 1:
    let a = pins[i].net
    let b = pins[1 - i].net
    if a == nil or b == nil: continue
    if not isGround(a): continue
    let v = annotations.railVoltage(b)
    if v.has: return abs(v.value)
  0.0

proc derateCapacitor(cap: Component, d: DeratingDefaults,
                     bias: OrderedTable[string, float]): seq[Assumption] =
  ## Rewrites `cap`'s value to the capacitance it actually has under bias.
  if not d.enabled: return
  if cap.attrs.getOrDefault("derating.applied", "") == "true": return

  var nominal: float
  if not cap.attrs.hasKey("value") or
     not spiceFormat.parseSpiceMagnitude(cap.attrs["value"], nominal):
    return                      # not a bare magnitude; nothing to scale
  if nominal <= 0.0: return

  let working = dcAcrossCapacitor(cap, bias)
  if working <= 0.0: return     # no DC across it, or not knowable here

  # Dielectric: stated, else inferred. A part whose package names a
  # non-ceramic family does not bias-derate at all and must not be guessed
  # into a ceramic.
  let stated = annotations.annotation(cap, "dielectric")
  var dielectric = stated.value
  if not stated.has:
    let pkg = annotations.package(cap)
    if pkg.has and pkg.value.toLowerAscii in
       ["tantalum", "electrolytic", "film", "bulk"]:
      return
    dielectric = d.assumeDielectric
  if not d.byDielectric.hasKey(dielectric.toUpperAscii): return
  let curve = d.byDielectric[dielectric.toUpperAscii]

  let ratedAnn = annotations.annotationFloat(cap, "voltage_rating")
  let rated =
    if ratedAnn.has and ratedAnn.value > 0.0: ratedAnn.value
    else: working * d.assumeRatingFactor
  if rated <= 0.0: return

  let frac = deratingFraction(curve, working / rated)
  if frac >= 0.999: return      # Class 1, or so lightly biased it is noise

  cap.attrs["value"] = spiceValue(nominal * frac)
  cap.attrs["derating.applied"] = "true"

  if not stated.has:
    result.add note(cap.designator, "dielectric assumed " &
      d.assumeDielectric & " for a ceramic that states none. C0G/NP0 does " &
      "not bias-derate at all, so stating it is the difference between " &
      eng(nominal, "F") & " and " & eng(nominal * frac, "F") & " here")
  if not (ratedAnn.has and ratedAnn.value > 0.0):
    result.add assumption(cap.designator, "voltage_rating", rated, "V",
      annDefaulted,
      "assumed as " & $d.assumeRatingFactor & "x the " & eng(working, "V") &
      " across the part")
  result.add note(cap.designator, eng(nominal, "F") & " derates to " &
    eng(nominal * frac, "F") & " (" & $int(frac * 100.0) & "% of nominal) at " &
    eng(working, "V") & " on a " & dielectric & " part rated " &
    eng(rated, "V") & "; DC-bias loss depends more on case size than on the " &
    "dielectric letter, so state a measured capacitance where this matters")

type
  BeadModel* = object
    ## The three-element ferrite bead, and the two defaults it needs.
    q*: float
      ## Shape of the impedance peak. `z_peak` and `f_peak` fix the height
      ## and the location; something has to fix the *width*, because those
      ## two only pin down the L-C product and not L and C separately.
      ##
      ## 1.0 by default, which is a broad peak -- and beads really are broad,
      ## because being lossy is the entire point of one. A high-Q bead would
      ## be an inductor, which is the part it is chosen instead of. A
      ## datasheet's impedance curve is what pins this down properly.
    dcr*: Ohms       ## used when the part states none
    fPeak*: Hertz    ## used when the part states none

proc defaultBeadModel*(): BeadModel =
  BeadModel(q: 1.0, dcr: 100.mohm, fPeak: 100.MHz)

proc expandFerriteBeads*(nl: Netlist, d = defaultBeadModel()): seq[Assumption] =
  ## Rewrites every `kind == "ferrite_bead"` into the standard three-element
  ## model: a series DC resistance into a parallel R-L-C.
  ##
  ## **A ferrite bead is not an inductor, and modelling it as one is wrong in
  ## the direction that matters.** An inductor's impedance climbs without
  ## limit; a bead's climbs, peaks where the core goes lossy, and falls again
  ## as its own parasitic capacitance takes over. The peak is the whole
  ## product -- it is why a bead is chosen over an inductor for filtering --
  ## and an inductor model shows none of it. It also has a real DC
  ## resistance, which an ideal inductor does not, and on a supply rail that
  ## is a steady IR drop and a floor the filter can never get below.
  ##
  ## The parallel R-L-C is the standard fit and it falls out of the three
  ## numbers a datasheet gives:
  ##
  ##     R = z_peak - dcr        L = R / (2*pi*f_peak*Q)
  ##                             C = Q / (2*pi*f_peak*R)
  ##
  ## At `f_peak` the reactances cancel and the impedance is `R` -- which is
  ## what makes `z_peak` and `f_peak` land exactly where the datasheet says,
  ## by construction rather than by fitting.
  ##
  ## **This is also what stops a bead being simulated as the wrong device.**
  ## `ferrite_bead` is in `kinds.conductiveKinds`, so `isPassive` accepts it
  ## and `expandPinModels` skips it -- but SPICE has no bead device, so
  ## before this the part reached the deck as `FB1`, and ngspice reads a
  ## leading `F` as a current-controlled current source. After this pass
  ## there is no bead left to misread.
  var beads: seq[Component]
  for _, c in nl.components:
    if c.kind == "ferrite_bead" and c.subNetlist == nil: beads.add c

  for bead in beads:
    let pins = orderedPins(bead)
    if pins.len != 2: continue
    if pins[0].net == nil or pins[1].net == nil: continue

    # `zPeak` is checked for NaN as well as for sign, and not out of caution:
    # `parseSpiceMagnitude` sets its out-parameter to NaN when it refuses,
    # and `NaN <= 0.0` is **false**, so a sign test alone lets the failure
    # straight through and every element value below comes out NaN.
    var zPeak = 0.0
    let zAnn = annotations.annotationFloat(bead, "z_peak")
    if zAnn.has and zAnn.value > 0.0:
      zPeak = zAnn.value
    elif bead.attrs.hasKey("value") and
         spiceFormat.parseSpiceMagnitude(bead.attrs["value"], zPeak):
      # A bead's `value` is conventionally its impedance in ohms at the
      # quoted frequency -- "600" means a 600 ohm bead -- so reading it that
      # way is following the convention rather than guessing at one.
      result.add note(bead.designator & ": `value` read as " &
        eng(zPeak, "ohm") & " of peak impedance, the convention a bead is " &
        "sold by; state `z_peak` to be explicit")
    if zPeak.classify == fcNan or zPeak <= 0.0:
      result.add note(bead.designator &
        " states neither `z_peak` nor a numeric `value`, so it cannot be " &
        "modelled and was left as it is -- which SPICE will misread")
      continue

    let dcrAnn = annotations.annotationFloat(bead, "dcr")
    let dcr = if dcrAnn.has and dcrAnn.value > 0.0: dcrAnn.value
              else: float(d.dcr)
    if not (dcrAnn.has and dcrAnn.value > 0.0):
      result.add assumption(bead.designator, "dcr", dcr, "ohm", annDefaulted,
        "typical for a small bead; it is a steady IR drop on a supply rail " &
        "and the floor the filter cannot get below, so state it from the " &
        "datasheet where the rail is what you are studying")

    let fAnn = annotations.annotationFloat(bead, "f_peak")
    let fPeak = if fAnn.has and fAnn.value > 0.0: fAnn.value else: float(d.fPeak)
    if not (fAnn.has and fAnn.value > 0.0):
      result.add assumption(bead.designator, "f_peak", fPeak, "Hz", annDefaulted,
        "the frequency datasheets quote a bead's headline impedance at")

    let rp = max(zPeak - dcr, zPeak * 0.5)
    let w0 = 2.0 * PI * fPeak
    let l = rp / (w0 * d.q)
    let c = d.q / (w0 * rp)
    result.add note(bead.designator & ": " & eng(zPeak, "ohm") & " at " &
      eng(fPeak, "Hz") & " modelled as " & eng(dcr, "ohm") & " + (" &
      eng(rp, "ohm") & " || " & eng(l, "H") & " || " & eng(c, "F") &
      "), Q " & $d.q & " setting the width of the peak")

    let a = pins[0].net
    let b = pins[1].net
    let desig = bead.designator
    let mid = addNet(nl, newNet(desig & "_MID"))
    removeComponent(nl, desig)

    proc add2(nl: Netlist, kind, suffix, value: string, x, y: Net) =
      let comp = addComponent(nl, newComponent(
        $spiceFormat.designatorPrefix(kind) & desig & suffix, kind = kind))
      discard connect(comp, "1", x, ptPassive)
      discard connect(comp, "2", y, ptPassive)
      comp.attrs["value"] = value

    add2(nl, "resistor", "_DCR", spiceValue(dcr), a, mid)
    add2(nl, "resistor", "_RP", spiceValue(rp), mid, b)
    add2(nl, "inductor", "_L", spiceValue(l), mid, b)
    add2(nl, "capacitor", "_C", spiceValue(c), mid, b)

type
  ResistiveStandIn* = object
    ## Cold resistances for parts that are electrically a small resistance and
    ## that SPICE has no device for.
    link*: Ohms      ## a `wire` or a `jumper`
    fuse*: Ohms      ## a `fuse`, unblown

proc defaultResistiveStandIn*(): ResistiveStandIn =
  ResistiveStandIn(link: 1.mohm, fuse: 50.mohm)

proc expandResistiveParts*(nl: Netlist, d = defaultResistiveStandIn()):
    seq[Assumption] =
  ## Rewrites `wire`, `jumper` and `fuse` into the resistor each one is.
  ##
  ## They are grouped because they collapse to the same thing and differ only
  ## in where the number comes from -- and that difference is the whole
  ## hazard. **A link's `value` is ohms and a fuse's is amps.** A "0 ohm
  ## jumper" is spelled in ohms because that is what it is sold as; a "2 A
  ## fuse" is spelled in amps, and reading that as 2 ohms would put forty
  ## times a 2 A fuse's real cold resistance in series with a rail and quietly
  ## explain away a voltage drop nobody would otherwise accept. So a fuse's
  ## `value` is read as a **current rating** and its resistance comes from
  ## `dcr`, which is the same question the ferrite bead had to answer before
  ## it could be modelled at all.
  ##
  ## What is deliberately not modelled: a fuse **blowing**. That is an I^2t
  ## integral over a fault, and a design check is asking whether the circuit
  ## works, not what it does while failing. The `current_rating` this reads
  ## off `value` is what a derating check compares against instead.
  ##
  ## Trace inductance is not modelled either. A wire is roughly a nanohenry a
  ## millimetre, and a netlist carries no length -- that is `nimcir/pcb`'s to
  ## answer, not this module's.
  var parts: seq[Component]
  for _, c in nl.components:
    if c.kind in ["wire", "jumper", "fuse"] and c.subNetlist == nil:
      parts.add c

  for part in parts:
    let pins = orderedPins(part)
    if pins.len != 2: continue
    if pins[0].net == nil or pins[1].net == nil: continue

    var stated = false
    var ohms = 0.0
    let dcrAnn = annotations.annotationFloat(part, "dcr")
    if dcrAnn.has and dcrAnn.value > 0.0:
      ohms = dcrAnn.value
      stated = true

    if part.kind == "fuse":
      # `value` is a current rating. Read it as one -- following the
      # convention rather than inventing another -- and never as ohms.
      if not annotations.annotationFloat(part, "current_rating").has and
         part.attrs.hasKey("value"):
        var amps: float
        if spiceFormat.parseSpiceMagnitude(part.attrs["value"], amps) and
           amps.classify != fcNan and amps > 0.0:
          annotations.setAnnotation(part, "current_rating", Amps(amps), annDerived)
          result.add note(part.designator & ": `value` read as " &
            eng(amps, "A") & " of current rating, which is what a fuse is " &
            "sold by -- it is **not** a resistance, and reading it as one " &
            "would put " & eng(amps, "ohm") & " in series with this net")
      if not stated:
        ohms = float(d.fuse)
        result.add assumption(part.designator, "dcr", ohms, "ohm", annDefaulted,
          "typical cold resistance for a small fuse; state it from the " &
          "datasheet where the rail's drop is what you are studying")
    else:
      # A link's `value` genuinely is ohms: a "0 ohm jumper" is sold that way.
      if not stated and part.attrs.hasKey("value"):
        var v: float
        if spiceFormat.parseSpiceMagnitude(part.attrs["value"], v) and
           v.classify != fcNan and v >= 0.0:
          ohms = v
          stated = true
      if not stated:
        ohms = float(d.link)
        result.add assumption(part.designator, "dcr", ohms, "ohm", annDefaulted,
          "typical for a link; a netlist carries no length, so trace " &
          "resistance and inductance are `nimcir/pcb`'s to answer")

    # A literal zero is legal in a deck and is also the one value that can
    # make a node indistinguishable from its neighbour for the solver, so it
    # is floored rather than passed through.
    let r = addComponent(nl, newComponent(
      $spiceFormat.designatorPrefix("resistor") & part.designator & "_R",
      kind = "resistor"))
    let a = pins[0].net
    let b = pins[1].net
    removeComponent(nl, part.designator)
    discard connect(r, "1", a, ptPassive)
    discard connect(r, "2", b, ptPassive)
    r.attrs["value"] = spiceValue(max(ohms, 1.0e-6))

proc expandCapacitorParasitics*(nl: Netlist, d = defaultParasitics(),
                                derating = defaultDerating(),
                                bias = initOrderedTable[string, float]()):
    seq[Assumption] =
  ## Rewrites every `kind == "capacitor"` into an ideal C in series with its
  ## ESR and ESL, using only the `graph` API.
  ##
  ## This is not cosmetic. An ideal capacitor's impedance falls monotonically
  ## with frequency, so a PDN sweep over ideal caps shows no self-resonance,
  ## no ESR floor and no anti-resonance between capacitor families -- i.e.
  ## none of the three things such a sweep is run to find. The expansion is
  ## what makes the result mean anything above a megahertz.
  ##
  ## Only `nl`'s own components are touched, never `nl.children` -- a
  ## capacitor inside a macromodel (e.g. `idealOpAmp`'s pole cap) is a
  ## modelling element, not a physical part, and giving it an ESL would add a
  ## resonance the real amplifier does not have. Such caps are also marked
  ## `attrs["parasitics.expanded"]`, which this proc honours, so expanding
  ## twice is a no-op rather than a doubling.
  ##
  ## Returns one `Assumption` per invented value, each carrying which
  ## capacitor, which key, the magnitude and where it came from.
  var caps: seq[Component]
  for _, c in nl.components:
    if c.kind == "capacitor" and c.subNetlist == nil and
       c.attrs.getOrDefault("parasitics.expanded", "") != "true":
      caps.add c

  for cap in caps:
    let pins = orderedPins(cap)
    if pins.len != 2:
      raise newException(NetlistError,
        "cannot expand parasitics for " & cap.designator & ": expected 2 pins, got " & $pins.len)
    if pins[0].net == nil or pins[1].net == nil:
      continue  # a dangling cap contributes nothing; leave it exactly as-is

    # Before the parasitics, because it rewrites the capacitance itself: a
    # Class 2 ceramic on a rail is not the part its label says it is, and
    # every impedance computed from the label is wrong by that factor.
    result.add derateCapacitor(cap, derating, bias)

    let (par, notes) = parasiticFor(cap, d)
    result.add notes

    let farNet = pins[1].net
    let midR = addNet(nl, newNet(cap.designator & "_ESR_N"))
    let midL = addNet(nl, newNet(cap.designator & "_ESL_N"))

    disconnect(pins[1])
    connect(pins[1], midR)

    let r = addComponent(nl, newComponent(
      $spiceFormat.designatorPrefix("resistor") & cap.designator & "_ESR",
      kind = "resistor"))
    discard connect(r, "1", midR, ptPassive)
    discard connect(r, "2", midL, ptPassive)
    r.attrs["value"] = spiceValue(par.esr)

    let l = addComponent(nl, newComponent(
      $spiceFormat.designatorPrefix("inductor") & cap.designator & "_ESL",
      kind = "inductor"))
    discard connect(l, "1", midL, ptPassive)
    discard connect(l, "2", farNet, ptPassive)
    l.attrs["value"] = spiceValue(par.esl)

    cap.attrs["parasitics.expanded"] = "true"

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

# --- source output impedance ---------------------------------------------

type
  SourceImpedance* = tuple[rout, lout: float]
    ## Series output resistance (ohms) and inductance (henries).

  SourceDefaults* = object
    byKind*: OrderedTable[string, SourceImpedance]
    fallback*: SourceImpedance

proc defaultSourceImpedance*(): SourceDefaults =
  ## A supply is not a short circuit, and modelling it as one is not a small
  ## error: an ideal source pins its rail at zero ohms, so a PDN sweep over a
  ## design that includes its own regulator reports 0 ohm at every frequency
  ## and passes every target that could be set. Measured on a rail that
  ## reads 129 mohm undriven, adding an ideal source takes it to 0.
  ##
  ## The flat part is the regulator's closed-loop output resistance; the
  ## inductive part stands in for two things at once -- the supply wiring,
  ## and the rise in output impedance above the loop's bandwidth, where the
  ## regulator stops being able to correct and the decoupling takes over.
  ##
  ## The exact numbers matter far less than their being finite. The supply
  ## sits in *parallel* with the decoupling, so once its impedance is well
  ## above the capacitors' the answer barely moves -- which is the whole
  ## reason a default is defensible here and not, say, for an ESR. Annotate
  ## `rout`/`lout` from a datasheet when the supply is what you are studying.
  result.byKind = {
    "voltage_source": (rout: 10.0e-3, lout: 1.0e-6),
    "regulator": (rout: 10.0e-3, lout: 1.0e-6),
    "ldo": (rout: 5.0e-3, lout: 1.0e-6),
    "battery": (rout: 100.0e-3, lout: 500.0e-9),
  }.toOrderedTable
  result.fallback = (rout: 10.0e-3, lout: 1.0e-6)

proc sourceImpedanceFor(c: Component, d: SourceDefaults):
    tuple[z: SourceImpedance, notes: seq[Assumption]] =
  var z = d.fallback
  var rSrc = "from the global fallback"
  var lSrc = "from the global fallback"
  if d.byKind.hasKey(c.kind):
    z = d.byKind[c.kind]
    rSrc = "typical for a " & c.kind
    lSrc = rSrc

  let ar = annotationFloat(c, "rout")
  if ar.has:
    z.rout = ar.value
    rSrc = ""
  let al = annotationFloat(c, "lout")
  if al.has:
    z.lout = al.value
    lSrc = ""

  var notes: seq[Assumption]
  if rSrc.len > 0:
    notes.add assumption(c.designator, "rout", z.rout, "ohm", annDefaulted, rSrc)
  if lSrc.len > 0:
    notes.add assumption(c.designator, "lout", z.lout, "H", annDefaulted, lSrc)
  (z: z, notes: notes)

proc expandSourceImpedance*(nl: Netlist, d = defaultSourceImpedance(),
                            kinds: openArray[string] = ["voltage_source"]): seq[Assumption] =
  ## Puts a finite output impedance in series with every source of a listed
  ## `kind`, so a rail that has a supply on it is not reported as a short.
  ##
  ## Annotate `rout = 0.ohm` and `lout = 0.H` on a source to opt out and keep
  ## it ideal -- which is right for a stimulus source, and wrong for anything
  ## standing in for a real supply.
  ##
  ## Idempotent: a source already expanded is marked and skipped, so running
  ## twice does not stack two networks in series.
  var sources: seq[Component]
  for _, c in nl.components:
    if c.kind in kinds and c.subNetlist == nil and
       c.attrs.getOrDefault("source.zout.expanded", "") != "true":
      sources.add c

  for src in sources:
    let pins = orderedPins(src)
    if pins.len != 2: continue
    if pins[0].net == nil or pins[1].net == nil: continue

    let (z, notes) = sourceImpedanceFor(src, d)
    if z.rout == 0.0 and z.lout == 0.0:
      # Deliberately ideal. Say nothing and change nothing.
      src.attrs["source.zout.expanded"] = "true"
      continue
    result.add notes

    let outNet = pins[0].net
    let midR = addNet(nl, newNet(src.designator & "_ROUT_N"))
    let midL = addNet(nl, newNet(src.designator & "_LOUT_N"))

    disconnect(pins[0])
    connect(pins[0], midR)

    let r = addComponent(nl, newComponent(
      $spiceFormat.designatorPrefix("resistor") & src.designator & "_ROUT",
      kind = "resistor"))
    discard connect(r, "1", midR, ptPassive)
    discard connect(r, "2", midL, ptPassive)
    r.attrs["value"] = spiceValue(max(z.rout, 1.0e-9))

    let l = addComponent(nl, newComponent(
      $spiceFormat.designatorPrefix("inductor") & src.designator & "_LOUT",
      kind = "inductor"))
    discard connect(l, "1", midL, ptPassive)
    discard connect(l, "2", outNet, ptPassive)
    l.attrs["value"] = spiceValue(max(z.lout, 1.0e-15))

    src.attrs["source.zout.expanded"] = "true"

# --- pin-kind stand-ins for parts that carry no model ---------------------

type
  PinModelDefaults* = object
    ## What impedance each kind of pin presents, in ohms to the ground
    ## reference. Zero means "leave this pin alone".
    byKind*: array[PinType, float]
    fallback*: float

proc defaultPinModels*(): PinModelDefaults =
  ## Order-of-magnitude stand-ins, and nothing more. They exist so that a
  ## board carrying an MCU is *simulatable* rather than rejected: without
  ## them a `.op` over a real design dies on `u1 vdd 0 sda scl` with ngspice
  ## reporting an unknown model, which tells the reader nothing about their
  ## circuit.
  ##
  ## What each choice means, and what it does not:
  ##
  ## - **Input, in-out, power, passive: high.** A CMOS input is picofarads
  ##   and megohms; an in-out pin on a shared bus is not driving most of the
  ##   time; a supply pin's real load is a current the netlist does not
  ##   carry. High impedance is also the *conservative* choice for a PDN
  ##   sweep, since a load resistor in parallel would only make the rail look
  ##   better than it is.
  ## - **Output: low.** A push-pull driver is a low impedance to one rail or
  ##   the other. Which one depends on a logic state a netlist does not
  ##   record, so it is modelled to ground -- a small-signal stand-in, not a
  ##   claim that the pin is driving low. An open-drain or open-emitter
  ##   output is genuinely high-impedance and is not distinguishable from a
  ##   push-pull one by `Pin.kind` alone: tag it `ptInOut`, or annotate
  ##   `zin` on the pin.
  ## - **Ground: untouched.** It is the reference; a resistor from it to
  ##   itself models nothing.
  ##
  ## Annotate `zin` on a pin (or on the component, for all of its pins) to
  ## replace any of this with a number somebody actually knows.
  result.byKind[ptUnknown] = 1.0e6
  result.byKind[ptInput] = 1.0e6
  result.byKind[ptOutput] = 50.0
  result.byKind[ptInOut] = 1.0e6
  result.byKind[ptPower] = 1.0e6
  result.byKind[ptGround] = 0.0
  result.byKind[ptPassive] = 1.0e6
  result.fallback = 1.0e6

proc groundOf*(nl: Netlist): Net =
  ## The node everything is referenced to: SPICE's `"0"` if it exists, else
  ## the first net that reads as ground by kind or by pin.
  if nl.nets.hasKey("0"): return nl.nets["0"]
  for _, n in nl.nets:
    if isGround(n): return n
  nil

proc pinImpedanceFor(p: Pin, c: Component, d: PinModelDefaults):
    tuple[z: float, note: Assumption, invented: bool] =
  let onPin = annotationFloat(p, "zin")
  if onPin.has:
    return (onPin.value, Assumption(), false)
  let onComp = annotationFloat(c, "zin")
  if onComp.has:
    return (onComp.value, Assumption(), false)
  var z = d.byKind[p.kind]
  if z == 0.0 and p.kind != ptGround: z = d.fallback
  (z, assumption(c.designator & "." & p.name, "zin", z, "ohm", annDefaulted,
     "no model for this " & (if c.kind.len > 0: c.kind else: "part") &
     "; stood in from the pin kind (" & $p.kind & ")"), true)

# --- behavioural stand-ins for parts with a path through them ------------

type
  BehavioralResult* = tuple[handled: bool, notes: seq[Assumption]]
    ## `handled` says the model replaced the component itself. **False means
    ## leave the part exactly as it is** -- emphatically not "fall back to
    ## per-pin impedances". A part known to carry a path from one pin to
    ## another, stood in for by two independent resistors to ground, reports
    ## its output rail at 0 V: a confident wrong answer where refusing to
    ## simulate would have been an honest one.

  BehavioralModel* = proc (nl: Netlist, c: Component, gnd: Net): BehavioralResult {.nimcall.}
    ## Replaces one component with a network that keeps its *function*.
    ## Registered by `Component.kind`, so a part nobody has modelled falls
    ## through to the per-pin defaults, which is right for an MCU and wrong
    ## for a regulator.

type BehavioralDef = tuple[model: BehavioralModel, passesSignal: bool]

var behavioral: OrderedTable[string, BehavioralDef]

proc registerBehavioralModel*(kind: string, m: BehavioralModel,
                              passesSignal = false) =
  ## A runtime table for the same reason the role and evaluator registries
  ## are: a part family nobody here anticipated must be modellable without
  ## editing this module.
  ##
  ## `passesSignal` says the stand-in keeps a path from the part's input to
  ## its output. A regulator does not (its output is a source); a buffer
  ## does. It is declared here rather than inferred because a *static* check
  ## has to know the answer without simulating -- `analysis/opamp`'s feedback
  ## walk asks exactly this, and would otherwise call a loop open that the
  ## simulation is about to close.
  behavioral[kind] = (model: m, passesSignal: passesSignal)

proc behavioralModelFor*(kind: string): BehavioralModel =
  if behavioral.hasKey(kind): behavioral[kind].model else: nil

proc passesSignal*(kind: string): bool =
  ## Whether a stand-in for this kind keeps a path through the part.
  behavioral.hasKey(kind) and behavioral[kind].passesSignal

proc modelledKinds*(): seq[string] =
  for k in behavioral.keys: result.add k

const
  outNames = ["out", "vout", "output", "o", "vo"]
  inNames = ["in", "vin", "input", "i", "vi"]
  # Kept deliberately identical to `analysis/opamp`'s lists. `Pin.kind`
  # cannot make this distinction -- it separates input from output but not
  # `+` from `-`, and that difference is the entire content of "negative
  # feedback" -- so both modules match on names, and they must agree.
  opampPosNames = ["+", "in+", "inp", "vin+", "ninv", "noninv"]
  opampNegNames = ["-", "in-", "inn", "vin-", "inv"]
  opampOutNames = ["out", "vout", "o", "output"]

proc pinNamed(c: Component, names: openArray[string]): Pin =
  for p in orderedPins(c):
    if p.name.toLowerAscii in names: return p
  nil

proc signalPathPins*(c: Component): tuple[inp, outp: Pin] =
  ## The pins a signal-passing stand-in would wire together, by name. Exposed
  ## so a static check can follow the same path the model will build, rather
  ## than guessing at it from the other side of the module boundary.
  (pinNamed(c, inNames), pinNamed(c, outNames))

proc regulatorModel(nl: Netlist, c: Component, gnd: Net): BehavioralResult =
  ## A regulator becomes an ideal source at the output voltage *the part*
  ## states, plus whatever its input pin loads the upstream rail with.
  ##
  ## The output voltage is read from the **component**, never from the net.
  ## That distinction is what keeps a `dc_voltage` claim worth making: the
  ## rail's nominal is what you require and the part's output is what you
  ## chose, so comparing them catches a 5 V regulator on a 3.3 V rail. Read
  ## it off the net instead and the check measures its own assumption back
  ## and passes every time -- the same trap `runDcVoltage` avoids by
  ## refusing to isolate.
  ##
  ## Unstated, it declines to model rather than guessing. There is no
  ## defensible default for what a regulator outputs, and the failure mode
  ## of guessing is a rail that silently reads whatever we made up.
  let outPin = pinNamed(c, outNames)
  if outPin == nil or outPin.net == nil:
    var names: seq[string]
    for p in orderedPins(c): names.add p.name
    return (false, @[note(c.designator & " (" & c.kind & ") has no pin whose " &
      "name reads as an output -- it has " & names.join(", ") & ". Rename one " &
      "to OUT, or give the part a simReplace; it was left unmodelled.")])

  let v = annotationFloat(c, "voltage")
  if not v.has:
    return (false, @[note(c.designator & " (" & c.kind & ") carries a path " &
      "from its input to its output that nothing can simulate, and states no " &
      "`voltage` of its own. It was left as it is rather than stood in for by " &
      "impedances to ground, which would report '" & outPin.net.name &
      "' as 0 V -- a wrong answer where no answer is the honest one. State " &
      "`voltage` on the part (what this regulator outputs, not what the rail " &
      "is required to be) to model it.")])

  let outNet = outPin.net
  let inPin = pinNamed(c, inNames)
  let inNet = if inPin != nil: inPin.net else: nil

  removeComponent(nl, c.designator)

  let src = addComponent(nl, newComponent(
    $spiceFormat.designatorPrefix("voltage_source") & c.designator & "_OUT",
    kind = "voltage_source"))
  discard connect(src, "+", outNet, ptPower)
  discard connect(src, "-", gnd, ptGround)
  src.attrs["value"] = "DC " & spiceValue(v.value)

  result.handled = true
  result.notes.add note(c.designator & " modelled as an ideal " &
    eng(v.value, "V") & " source at its stated output: no load regulation, " &
    "no dropout, no current limit and no start-up ramp. A rail that is " &
    "wrong here is wrong; one that is right here may still misbehave for " &
    "reasons this cannot see.")

  if inNet != nil and inNet != gnd:
    let quiescent = 1.0e6
    let r = addComponent(nl, newComponent(
      $spiceFormat.designatorPrefix("resistor") & c.designator & "_IN",
      kind = "resistor"))
    discard connect(r, "1", inNet, ptPassive)
    discard connect(r, "2", gnd, ptPassive)
    r.attrs["value"] = spiceValue(quiescent)
    r.attrs["models.pin.expanded"] = "true"
    result.notes.add assumption(c.designator & "." & inPin.name, "zin",
      quiescent, "ohm", annDefaulted,
      "quiescent draw of a regulator input, which a netlist does not carry")

proc bufferModel(nl: Netlist, c: Component, gnd: Net): BehavioralResult =
  ## A part that passes a signal through becomes a VCVS from its input to its
  ## output, so the path survives.
  ##
  ## Without this a buffer sitting in a feedback path is stood in for by two
  ## impedances to ground, which does not merely lose accuracy -- it opens
  ## the loop, and a loop-gain measurement over an opened loop is a confident
  ## number about a circuit that is not the one on the bench. Same failure as
  ## a regulator read at 0 V, one analysis further along.
  ##
  ## Unity is assumed where nothing states otherwise, which is defensible
  ## here and was not for a regulator's output voltage: a part whose kind is
  ## `buffer` has a gain of one by definition, whereas nothing about the word
  ## `regulator` says what voltage it makes. Annotate `gain` to say otherwise.
  let outPin = pinNamed(c, outNames)
  let inPin = pinNamed(c, inNames)
  if outPin == nil or inPin == nil or outPin.net == nil or inPin.net == nil:
    var names: seq[string]
    for p in orderedPins(c): names.add p.name
    return (false, @[note(c.designator & " (" & c.kind & ") needs a pin " &
      "reading as an input and one reading as an output to keep its signal " &
      "path -- it has " & names.join(", ") & ". It was left unmodelled " &
      "rather than tied to ground, which would open any path through it.")])

  let g = annotationFloat(c, "gain")
  let gain = if g.has: g.value else: 1.0
  let outNet = outPin.net
  let inNet = inPin.net
  removeComponent(nl, c.designator)

  let e = addComponent(nl, newComponent(
    $spiceFormat.designatorPrefix("vcvs") & c.designator & "_BUF",
    kind = "vcvs"))
  discard connect(e, "OUT+", outNet, ptOutput)
  discard connect(e, "OUT-", gnd, ptPassive)
  discard connect(e, "IN+", inNet, ptInput)
  discard connect(e, "IN-", gnd, ptInput)
  e.attrs["value"] = spiceValue(gain)

  result.handled = true
  if not g.has:
    result.notes.add assumption(c.designator, "gain", gain, "", annDefaulted,
      "unity, which is what its kind (" & c.kind & ") means; annotate " &
      "`gain` if this part is not unity")
  result.notes.add note(c.designator & " modelled as an ideal gain-" &
    eng(gain) & " source: infinite input impedance, zero output impedance, " &
    "no bandwidth limit and no supply rails")

var boundOpAmpsToRails* = false
  ## Whether `opampModel` clamps a substituted amplifier to its supply
  ## rails. A module-level switch rather than a parameter because
  ## `BehavioralModel` takes a fixed signature and every other model shares
  ## it; the alternative was a parameter no other model would ever use.

proc opampModel(nl: Netlist, c: Component, gnd: Net): BehavioralResult =
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
  const
    gbw = 1.0e6
    rPole = 1.0e3
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
  result.notes.add assumption(desig, "gbw", gbw, "Hz", annDefaulted,
    "of a substituted ideal single-pole op-amp (Aol " & eng(aol) & "); no " &
    "offset, slew rate, output impedance, supply rails or second pole are " &
    "represented")

proc registerBuiltinBehavioralModels*() =
  ## Called at module init. Exposed so a test can prove re-registering is
  ## idempotent, and so an application that clears the table can restore it.
  for kind in ["regulator", "ldo", "vreg", "dcdc", "smps", "switcher",
               "buck", "boost"]:
    registerBehavioralModel(kind, regulatorModel)
  for kind in ["buffer", "voltage_follower", "unity_gain_buffer",
               "line_driver", "level_shifter"]:
    registerBehavioralModel(kind, bufferModel, passesSignal = true)
  # `passesSignal` stays false, unlike a buffer's. It governs whether
  # `analysis/opamp`'s static feedback walk may cross the part, and that walk
  # is forwards-only through `signalPathPins` -- which cannot answer for an
  # amplifier, because an op-amp has *two* inputs and nothing in a netlist
  # says which one a path enters by. The simulated stand-in above still
  # closes the path, so an `.ac` sees the cascade; only the static walk stays
  # conservative, which is the direction to be wrong in.
  # Deliberately not `comparator`: this macromodel is linear, and a
  # comparator's entire behaviour is that it is not.
  for kind in ["opamp", "op_amp", "operational_amplifier"]:
    registerBehavioralModel(kind, opampModel)

proc expandPinModels*(nl: Netlist, d = defaultPinModels(),
                      exclude: openArray[string] = []): seq[Assumption] =
  ## Replaces every component whose behaviour nothing describes with a
  ## per-pin impedance to ground, chosen from `Pin.kind`.
  ##
  ## "Nothing describes it" means `kinds.isPassive` is false -- the same test
  ## `spice/isolate` uses to decide what it can absorb -- and no `subNetlist`
  ## and no `simReplace` left to apply. A part with a real model, a
  ## macromodel or a stated replacement is never touched.
  ##
  ## **This destroys topology.** Every pin of the replaced part is tied to
  ## ground independently, so any path *through* the part is gone. That is
  ## correct for the questions these models are for -- what a part loads a
  ## rail or a bus with -- and wrong for anything that needs signal to pass
  ## through it. Run it on a simulation clone, never on a design netlist,
  ## exactly as with everything else in this module.
  ##
  ## `exclude` names designators to leave untouched. Every caller that seeds
  ## an isolation on a particular part passes it here, because that part is
  ## about to be modelled deliberately -- `analyzeStartup` stands its
  ## regulator up as a soft-start ramp and `analyzeOpAmpResponse` substitutes
  ## a macromodel, and a generic stand-in applied first would quietly replace
  ## the very thing the analysis exists to model.
  ##
  ## Returns one `Assumption` per invented impedance. That is the point of
  ## the pass as much as the simulability is: the numbers here are stand-ins,
  ## and a result resting on them has to say so.
  # A ferrite bead is electrically passive, so `isPassive` accepts it and
  # the loop below skips it -- but SPICE has no bead device, so left alone
  # it reaches the deck as `FB1` and ngspice reads the leading `F` as a
  # current-controlled current source. It is expanded here rather than at
  # each of the six call sites because the invariant this proc really
  # enforces is "every part reaching the deck is something SPICE can
  # simulate", and a bead breaks that in a way the passivity filter misses.
  result.add expandFerriteBeads(nl)
  result.add expandResistiveParts(nl)

  let gnd = groundOf(nl)
  if gnd == nil:
    return @[note("no ground reference was found, so parts without models " &
                  "were left as they are; nothing can be referenced to " &
                  "ground until some net is named \"0\" or marked ntGround")]

  var unmodelled: seq[Component]
  for _, c in nl.components:
    if c.subNetlist == nil and c.simReplace == nil and not isPassive(c) and
       c.designator notin exclude and
       c.attrs.getOrDefault("models.pin.expanded", "") != "true":
      unmodelled.add c

  for c in unmodelled:
    # A part whose kind is modelled decides its own fate -- including
    # declining, which leaves it untouched rather than falling through to
    # impedances that would break a path we know is there.
    let bm = behavioralModelFor(c.kind)
    if bm != nil:
      let (handled, notes) = bm(nl, c, gnd)
      result.add notes
      if handled: c.attrs["models.pin.expanded"] = "true"
      continue

    # Snapshot before removing: the pins go with the component.
    var terminals: seq[tuple[name: string, z: float, net: Net]]
    for p in orderedPins(c):
      if p.net == nil or p.net == gnd: continue
      let (z, note, invented) = pinImpedanceFor(p, c, d)
      if z <= 0.0: continue
      if invented: result.add note
      terminals.add (name: p.name, z: z, net: p.net)

    removeComponent(nl, c.designator)

    for t in terminals:
      let r = addComponent(nl, newComponent(
        $spiceFormat.designatorPrefix("resistor") & c.designator & "_" & t.name,
        kind = "resistor"))
      discard connect(r, "1", t.net, ptPassive)
      discard connect(r, "2", gnd, ptPassive)
      r.attrs["value"] = spiceValue(t.z)
      r.attrs["models.pin.expanded"] = "true"

registerBuiltinBehavioralModels()
