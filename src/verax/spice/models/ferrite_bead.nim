## The ferrite bead as the standard three-element model: series DC
## resistance into a parallel R-L-C. Mutates its netlist; use a clone.

import std/[math, tables]
import ../../netlist/types
import ../../netlist/graph
import ../../netlist/annotations
import ../../units
import ../../eng
import ../../netlist/formats/spice as spiceFormat
import ./common
import ../provenance

type
  BeadModel* = object
    ## The three-element ferrite bead, and the two defaults it needs.
    q*: float
      ## Peak width (`z_peak`/`f_peak` fix only L*C). Default 1.0, a broad
      ## peak: beads are lossy by design. A datasheet curve pins it properly.
    dcr*: Ohms       ## used when the part states none
    fPeak*: Hertz    ## used when the part states none

proc defaultBeadModel*(): BeadModel =
  BeadModel(q: 1.0, dcr: 100.mohm, fPeak: 100.MHz)

proc expandFerriteBeads*(nl: Netlist, d = defaultBeadModel()): seq[Assumption] =
  ## Rewrites every `ferrite_bead` into series DCR + parallel R-L-C. **A
  ## bead is not an inductor**: its impedance peaks where the core goes lossy
  ## and falls past self-resonance, and it has real DC resistance.
  ##
  ##     R = z_peak - dcr        L = R / (2*pi*f_peak*Q)
  ##                             C = Q / (2*pi*f_peak*R)
  ##
  ## At `f_peak` the reactances cancel and Z = R, so the datasheet's peak
  ## lands exactly. Also prevents `FB1` reaching the deck (ngspice would
  ## read `F` as a CCCS).
  var beads: seq[Component]
  for _, c in nl.components:
    if c.kind == "ferrite_bead" and c.subNetlist == nil: beads.add c

  for bead in beads:
    provenance(nl, bead, brStandIn):
      let pins = orderedPins(bead)
      if pins.len != 2: continue
      if pins[0].net == nil or pins[1].net == nil: continue

      # Check `zPeak` for NaN too: a refused parse yields NaN, and `NaN <= 0.0`
      # is false.
      var zPeak = 0.0
      let zAnn = annotations.annotationFloat(bead, "z_peak")
      if zAnn.has and zAnn.value > 0.0:
        zPeak = zAnn.value
      elif bead.attrs.hasKey("value") and
           spiceFormat.parseSpiceMagnitude(bead.attrs["value"], zPeak):
        # A bead's `value` is conventionally its impedance in ohms ("600").
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
