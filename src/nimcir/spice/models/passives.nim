## `wire`, `jumper` and `fuse`: parts that are electrically a small resistance
## and that SPICE has no device for. They collapse to the same thing and
## differ only in where the number comes from -- and that difference is the
## whole hazard.
##
## Mutates the `Netlist` it is given; run it on a simulation clone.

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
