## `bufferModel`: a signal-passing part becomes a VCVS from input to output.
## Mutates its netlist; use a clone.

import std/[strutils, tables]
import ../../netlist/types
import ../../netlist/graph
import ../../netlist/annotations
import ../../eng
import ../../netlist/formats/spice as spiceFormat
import ./common
import ./behavioral

proc bufferModel*(nl: Netlist, c: Component, gnd: Net): BehavioralResult =
  ## A signal-passing part becomes a VCVS from input to output, so a buffer
  ## in a feedback path doesn't open the loop. Unity gain unless `gain` is
  ## annotated (a buffer is unity by definition).
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
