## `renderSvg(s, highlight)`: an empty set is byte-identical to
## `renderSvg(s)` (optional features must not move existing output), and a
## highlighted net only adds underlay polylines.

import std/[sets, strutils, unittest]
import verax/netlist
import verax/netlist/dsl
import verax/schematic

proc divider(): Netlist =
  netlist("hl"):
    net vin, kind = ntPower, voltage = "10"
    net mid, kind = ntSignal
    net gnd, kind = ntGround, name = "0"
    component V1, kind = "voltage_source", value = "DC 10":
      pin "+", vin, kind = ptPower
      pin "-", gnd, kind = ptGround
    component R1, kind = "resistor", value = "1k":
      pin "1", vin, kind = ptPassive
      pin "2", mid, kind = ptPassive
    component R2, kind = "resistor", value = "1k":
      pin "1", mid, kind = ptPassive
      pin "2", gnd, kind = ptPassive

suite "schematic highlight":
  let s = layout(divider())
  let plain = renderSvg(s)

  test "empty highlight is byte-identical":
    check renderSvg(s, initHashSet[string]()) == plain

  test "a highlighted net only adds lines":
    let hl = renderSvg(s, toHashSet(["mid"]))
    check hl.len > plain.len
    check highlightColour in hl
    check highlightColour notin plain
    # Removing the added underlay lines gives back the plain document.
    var kept: seq[string]
    for line in hl.splitLines:
      if highlightColour notin line: kept.add line
    check kept.join("\n") == plain

  test "an unknown net adds nothing":
    check renderSvg(s, toHashSet(["no_such_net"])) == plain
