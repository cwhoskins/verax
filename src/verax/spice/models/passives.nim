## `wire`, `jumper` and `fuse`: electrically small resistances with no SPICE
## device. Mutates its netlist; use a clone.

import std/[math, tables]
import ../../netlist/types
import ../../netlist/graph
import ../../netlist/annotations
import ../../units
import ../../eng
import ../../netlist/formats/spice as spiceFormat
import ./common

type
  ResistiveStandIn* = object
    ## Cold resistances for parts SPICE has no device for.
    link*: Ohms      ## a `wire` or a `jumper`
    fuse*: Ohms      ## a `fuse`, unblown

proc defaultResistiveStandIn*(): ResistiveStandIn =
  ResistiveStandIn(link: 1.mohm, fuse: 50.mohm)

proc expandResistiveParts*(nl: Netlist, d = defaultResistiveStandIn()):
    seq[Assumption] =
  ## Rewrites `wire`, `jumper` and `fuse` into resistors. **A link's `value`
  ## is ohms; a fuse's is amps** -- reading "2 A" as 2 ohms would hide a
  ## large voltage drop -- so a fuse's `value` is its current rating and its
  ## resistance comes from `dcr`.
  ##
  ## Not modelled: a fuse blowing (an I^2t fault integral), and trace
  ## inductance (needs lengths from `verax/pcb`).
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
      # `value` is a current rating, never ohms.
      if not annotations.currentRating(part).has and
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
      # A link's `value` is ohms ("0 ohm jumper").
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
          "resistance and inductance are `verax/pcb`'s to answer")

    # Zero is floored: it can make two nodes indistinguishable to the
    # solver.
    let r = addComponent(nl, newComponent(
      $spiceFormat.designatorPrefix("resistor") & part.designator & "_R",
      kind = "resistor"))
    let a = pins[0].net
    let b = pins[1].net
    removeComponent(nl, part.designator)
    discard connect(r, "1", a, ptPassive)
    discard connect(r, "2", b, ptPassive)
    r.attrs["value"] = spiceValue(max(ohms, 1.0e-6))
