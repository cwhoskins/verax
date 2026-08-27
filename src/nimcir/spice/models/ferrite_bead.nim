## The ferrite bead as the standard three-element model: a series DC
## resistance into a parallel R-L-C.
##
## A bead is not an inductor and modelling it as one is wrong in the
## direction that matters. Mutates the `Netlist` it is given; run it on a
## simulation clone.

import std/[math, tables]
import ../../netlist/types
import ../../netlist/graph
import ../../netlist/annotations
import ../../units
import ../../eng
import ../../netlist/formats/spice as spiceFormat
import ./common

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
