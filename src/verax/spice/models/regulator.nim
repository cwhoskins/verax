## `regulatorModel`: an unmodelled regulator becomes an ideal source at the
## output voltage *the part* states, plus its input pin's load. Mutates its
## netlist; use a clone.

import std/[strutils, tables]
import ../../netlist/types
import ../../netlist/graph
import ../../netlist/annotations
import ../../eng
import ../../netlist/formats/spice as spiceFormat
import ./common
import ./behavioral

proc regulatorModel*(nl: Netlist, c: Component, gnd: Net): BehavioralResult =
  ## The output voltage is read from the **component**, never the net, so a
  ## `dc_voltage` claim compares the rail's requirement with the part's
  ## choice (a 5 V regulator on a 3.3 V rail is caught). Unstated, it
  ## declines to model rather than guess.
  let outPin = pinNamed(c, outNames)
  if outPin == nil or outPin.net == nil:
    var names: seq[string]
    for p in orderedPins(c): names.add p.name
    return (false, @[note(c.designator & " (" & c.kind & ") has no pin whose " &
      "name reads as an output -- it has " & names.join(", ") & ". Rename one " &
      "to OUT, or give the part a simReplace; it was left unmodelled.")])

  let v = dcVoltage(c)
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
  src.attrs["value"] = "DC " & spiceValue(float(v.value))

  result.handled = true
  result.notes.add note(c.designator & " modelled as an ideal " &
    eng(float(v.value), "V") & " source at its stated output: no load regulation, " &
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
