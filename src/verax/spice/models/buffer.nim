## `bufferModel`: a part that passes a signal through becomes a VCVS from its
## input to its output, so the path survives.
##
## Mutates the `Netlist` it is given; run it on a simulation clone.

import std/[strutils, tables]
import ../../netlist/types
import ../../netlist/graph
import ../../netlist/annotations
import ../../eng
import ../../netlist/formats/spice as spiceFormat
import ./common
import ./behavioral

proc bufferModel*(nl: Netlist, c: Component, gnd: Net): BehavioralResult =
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
