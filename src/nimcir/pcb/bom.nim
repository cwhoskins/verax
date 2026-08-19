## Bill-of-materials compilation from an imported board.
##
## This *compiles* what the board file already carries; it does not resolve
## parts against a catalogue -- parametric part matching against a supplier
## database is a separate concern and a separate submodule.
##
## Both formats do carry per-part data on the board itself, so a BoM does not
## depend on having a schematic or a netlist to hand. KiCad footprints hold
## `(property "Reference"/"Value"/"Datasheet"/"Description" ...)` plus
## whatever user fields the schematic propagated, and `dnp` /
## `exclude_from_bom` inside `(attr ...)`. ODB++ holds per-component `PRP`
## records *and* an explicit `BOM DATA` block (`CPN`/`IPN`/`DSC`/`VND`/`MPN`/
## `VPL_*`). A reader drops all of it into `Placement.attrs`; this module
## promotes the well-known keys to typed fields and rolls placements up into
## lines.

import std/[strutils, tables]
import ./types

export types

type
  BomLine* = ref object
    key*: string
      ## Grouping key that produced this line.
    designators*: seq[string]
    quantity*: int
    value*: string
    footprint*: string
    partNumber*: string
    manufacturer*: string
    mpn*: string
    description*: string
    doNotPopulate*: bool
    attrs*: OrderedTable[string, string]

  Bom* = ref object
    lines*: seq[BomLine]
    attrs*: OrderedTable[string, string]

const
  ValueKeys* = ["Value", "VALUE", "value"]
  MpnKeys* = ["MPN", "Manufacturer Part Number", "VPL_MPN", "mpn"]
  ManufacturerKeys* = ["Manufacturer", "VPL_VND", "VND", "manufacturer"]
  PartNumberKeys* = ["IPN", "PART_NUMBER", "CPN", "Part Number", "partNumber"]
  DescriptionKeys* = ["Description", "DSC", "desc1", "Part Description"]
    ## Candidate attribute names, in priority order. KiCad's mixed-case
    ## property names and ODB++'s upper-case record names both appear, so the
    ## lookup tries each in turn rather than assuming one convention.

proc firstAttr*(p: Placement, keys: openArray[string]): string =
  ## The first non-empty value among `keys` in `p.attrs`.
  for k in keys:
    if p.attrs.hasKey(k) and p.attrs[k].len > 0:
      return p.attrs[k]
  ""

proc valueOf*(p: Placement): string =
  result = firstAttr(p, ValueKeys)
  if result.len == 0 and p.component != nil:
    for k in ValueKeys:
      if p.component.attrs.hasKey(k): return p.component.attrs[k]

proc partNumberOf*(p: Placement): string =
  result = firstAttr(p, PartNumberKeys)
  if result.len == 0 and p.component != nil:
    result = p.component.partNumber

proc mpnOf*(p: Placement): string = firstAttr(p, MpnKeys)
proc manufacturerOf*(p: Placement): string = firstAttr(p, ManufacturerKeys)
proc descriptionOf*(p: Placement): string = firstAttr(p, DescriptionKeys)

proc defaultKey*(p: Placement): string =
  ## Groups by manufacturer part number where one is known, then by internal
  ## part number, and finally by the value/footprint pair that is all a
  ## generic passive usually offers. Do-not-populate parts never merge with
  ## populated ones.
  let dnp = if p.doNotPopulate: "|DNP" else: ""
  let mpn = mpnOf(p)
  if mpn.len > 0: return "mpn:" & mpn & dnp
  let pn = partNumberOf(p)
  if pn.len > 0: return "pn:" & pn & dnp
  "vf:" & valueOf(p) & "|" & p.footprint & dnp

proc buildBom*(pcb: Pcb, groupBy: proc (p: Placement): string {.closure.} = nil): Bom =
  ## Rolls every placed component up into `BomLine`s.
  ##
  ## Placements flagged `excludeFromBom` are dropped. Placements flagged
  ## `doNotPopulate` are **kept**, on their own lines -- a DNP part is a real
  ## line item on a real BoM, and silently dropping it hides an assembly
  ## decision.
  result = Bom()
  var byKey: OrderedTable[string, BomLine]
  for _, p in pcb.placements:
    if p.excludeFromBom: continue
    let key = if groupBy == nil: defaultKey(p) else: groupBy(p)
    if not byKey.hasKey(key):
      let line = BomLine(key: key,
                         value: valueOf(p),
                         footprint: p.footprint,
                         partNumber: partNumberOf(p),
                         manufacturer: manufacturerOf(p),
                         mpn: mpnOf(p),
                         description: descriptionOf(p),
                         doNotPopulate: p.doNotPopulate)
      byKey[key] = line
      result.lines.add(line)
    let line = byKey[key]
    line.designators.add(p.designator)
    line.quantity = line.designators.len

proc totalParts*(b: Bom): int =
  for l in b.lines:
    if not l.doNotPopulate: result += l.quantity

proc `$`*(l: BomLine): string =
  result = $l.quantity & "x " & l.designators.join(",")
  if l.value.len > 0: result.add "  " & l.value
  if l.footprint.len > 0: result.add "  " & l.footprint
  if l.mpn.len > 0: result.add "  " & l.mpn
  if l.doNotPopulate: result.add "  [DNP]"

proc `$`*(b: Bom): string =
  var parts: seq[string]
  for l in b.lines: parts.add($l)
  parts.join("\n")
