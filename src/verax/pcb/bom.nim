## BoM compilation from an imported board's own data (no catalogue
## resolution -- that's `verax/bom`). KiCad footprints carry properties and
## `dnp`/`exclude_from_bom`; ODB++ carries `PRP` records and a `BOM DATA`
## block. Readers put it all in `Placement.attrs`; this promotes known keys
## and rolls placements into lines.

import std/[strutils, tables]
import ./types
import ../netlist/packages

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
    ## Candidate attribute names in priority order (KiCad and ODB++ spellings
    ## both appear).

proc firstAttr*(p: Placement, keys: openArray[string]): string =
  ## The first non-empty value among `keys` in `p.attrs`.
  for k in keys:
    if p.attrs.hasKey(k) and p.attrs[k].len > 0:
      return p.attrs[k]
  ""

proc packageDefOf*(p: Placement): PackageDef =
  ## The `PackageDef` a sectioned placement stands for, or `nil`.
  for _, sc in p.sections:
    let dn = packageDefName(sc)
    if dn.has and isPackageRegistered(dn.value):
      return packageDef(dn.value)
  nil

proc valueOf*(p: Placement): string =
  result = firstAttr(p, ValueKeys)
  if result.len == 0 and p.component != nil:
    for k in ValueKeys:
      if p.component.attrs.hasKey(k): return p.component.attrs[k]

proc partNumberOf*(p: Placement): string =
  result = firstAttr(p, PartNumberKeys)
  if result.len == 0 and p.component != nil:
    result = p.component.partNumber
  if result.len == 0:
    let def = packageDefOf(p)
    if def != nil: result = def.partNumber

proc footprintOf*(p: Placement): string =
  ## `p.footprint`, else the package definition's.
  result = p.footprint
  if result.len == 0:
    let def = packageDefOf(p)
    if def != nil: result = def.footprint

proc mpnOf*(p: Placement): string = firstAttr(p, MpnKeys)
proc manufacturerOf*(p: Placement): string = firstAttr(p, ManufacturerKeys)
proc descriptionOf*(p: Placement): string = firstAttr(p, DescriptionKeys)

proc defaultKey*(p: Placement): string =
  ## Group by MPN if known, then internal part number, then value/footprint.
  ## DNP never merges with populated.
  let dnp = if p.doNotPopulate: "|DNP" else: ""
  let mpn = mpnOf(p)
  if mpn.len > 0: return "mpn:" & mpn & dnp
  let pn = partNumberOf(p)
  if pn.len > 0: return "pn:" & pn & dnp
  "vf:" & valueOf(p) & "|" & footprintOf(p) & dnp

proc buildBom*(pcb: Pcb, groupBy: proc (p: Placement): string {.closure.} = nil): Bom =
  ## Rolls placements into `BomLine`s. `excludeFromBom` parts are dropped;
  ## `doNotPopulate` parts are **kept** on their own lines.
  result = Bom()
  var byKey: OrderedTable[string, BomLine]
  for _, p in pcb.placements:
    if p.excludeFromBom: continue
    let key = if groupBy == nil: defaultKey(p) else: groupBy(p)
    if not byKey.hasKey(key):
      let line = BomLine(key: key,
                         value: valueOf(p),
                         footprint: footprintOf(p),
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
