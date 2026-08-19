import std/[strutils, tables, unittest]

import nimcir/netlist
import nimcir/pcb

proc place(pcb: Pcb, designator, footprint: string,
           attrs: openArray[(string, string)] = [],
           dnp = false, exclude = false): Placement =
  result = addPlacement(pcb, newPlacement(designator, footprint))
  result.doNotPopulate = dnp
  result.excludeFromBom = exclude
  for (k, v) in attrs:
    result.attrs[k] = v

proc assembly(): Pcb =
  result = newPcb("assembly")
  # KiCad-style property names on two identical passives and one distinct part.
  discard result.place("R1", "R_0402", {"Value": "10k"})
  discard result.place("R2", "R_0402", {"Value": "10k"})
  discard result.place("R3", "R_0402", {"Value": "1k"})
  # ODB++-style BOM DATA record names on a populated IC.
  discard result.place("U1", "SOT-23-5",
    {"VALUE": "FAN1654", "MPN": "MC74HC259ADT", "VND": "MOTOROLA INC.",
     "IPN": "1000045", "DSC": "16-ETSSOP FAN1654"})
  # A fitted-but-not-populated part, and a fiducial that is not a line item.
  discard result.place("C9", "C_0603", {"Value": "100n"}, dnp = true)
  discard result.place("FID1", "Fiducial_1mm", exclude = true)

test "identical passives roll up into one line, distinct values do not":
  let bom = buildBom(assembly())
  check bom.lines.len == 4

  let first = bom.lines[0]
  check first.quantity == 2
  check first.designators == @["R1", "R2"]
  check first.value == "10k"
  check first.footprint == "R_0402"

  check bom.lines[1].quantity == 1
  check bom.lines[1].value == "1k"

test "excluded placements are dropped and DNP parts keep their own line":
  let bom = buildBom(assembly())
  var designators: seq[string]
  for l in bom.lines:
    designators.add(l.designators)
  check "FID1" notin designators
  check "C9" in designators

  var dnpLines = 0
  for l in bom.lines:
    if l.doNotPopulate:
      inc dnpLines
      check l.designators == @["C9"]
  check dnpLines == 1

  # A do-not-populate part is a real line, but not a part to buy.
  check bom.totalParts == 4

test "well-known attribute names are promoted whichever format wrote them":
  let bom = buildBom(assembly())
  var ic: BomLine
  for l in bom.lines:
    if l.designators == @["U1"]: ic = l
  check ic != nil
  check ic.value == "FAN1654"
  check ic.mpn == "MC74HC259ADT"
  check ic.manufacturer == "MOTOROLA INC."
  check ic.partNumber == "1000045"
  check ic.description == "16-ETSSOP FAN1654"
  # Grouping prefers the manufacturer part number when one is known.
  check ic.key == "mpn:MC74HC259ADT"

test "parts with the same MPN merge even across different footprints":
  let pcb = newPcb("merge")
  discard pcb.place("R1", "R_0402", {"MPN": "RC0402FR-0710KL"})
  discard pcb.place("R2", "R_0603", {"MPN": "RC0402FR-0710KL"})
  let bom = buildBom(pcb)
  check bom.lines.len == 1
  check bom.lines[0].quantity == 2

test "component data falls back to the netlist when the board file carries none":
  let pcb = newPcb("fallback")
  let comp = addComponent(pcb.netlist, newComponent("R1", kind = "resistor",
                                                    partNumber = "RC0402"))
  comp.attrs["Value"] = "4k7"
  let p = addPlacement(pcb, newPlacement("R1", "R_0402"))
  bindComponent(p, comp)

  let bom = buildBom(pcb)
  check bom.lines.len == 1
  check bom.lines[0].value == "4k7"
  check bom.lines[0].partNumber == "RC0402"

test "a caller-supplied grouping key overrides the default":
  let bom = buildBom(assembly(), proc (p: Placement): string = p.footprint)
  var keys: seq[string]
  for l in bom.lines: keys.add(l.key)
  check keys == @["R_0402", "SOT-23-5", "C_0603"]
  check bom.lines[0].quantity == 3

test "rendering a BoM line is human-readable":
  let bom = buildBom(assembly())
  check $bom.lines[0] == "2x R1,R2  10k  R_0402"
  for l in bom.lines:
    if l.doNotPopulate:
      check "[DNP]" in $l
