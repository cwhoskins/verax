## Netlist -> `BomItem`s: one per physical part, carrying what the design
## states about it and, where it states nothing, the `bom:` default that
## filled the gap -- recorded as an `Assumption`, so a default that moved a
## choice says so.
##
## Hermetic: no catalogue, no network. Everything here is read off the
## netlist, and nothing here decides *which* part to buy.

import std/[math, strutils, tables]

import ../netlist/types
import ../netlist/graph
import ../netlist/annotations
import ../netlist/issue
import ../netlist/packages
import ../netlist/bomdefaults
import ../netlist/formats/spice
import ./types
import ./classify

const
  KindBomValueUnparseable* = "bom_value_unparseable"
  KindBomAnnotationUnparseable* = "bom_annotation_unparseable"
  KindBomPackageDnpConflict* = "bom_package_dnp_conflict"

proc collectLeaves(nl: Netlist, prefix: string,
                   res: var seq[tuple[c: Component, path: string]]) =
  ## Every non-hierarchical component under `nl` with its hierarchical path,
  ## walking `subNetlist` instances rather than flattening them -- a local
  ## copy of `pcb/assemble.collectLeaves`, which `bom/` may not import
  ## (`bom/` has no edge to `pcb/`), and the same six lines
  ## `netlist/packages`/`netlist/pinmux` each keep their own of.
  for _, c in nl.components:
    let p = hierName(prefix, c.designator)
    if c.subNetlist != nil:
      collectLeaves(c.subNetlist, p, res)
    else:
      res.add (c, p)

proc floatOf(item: BomItem, c: Component, path, key: string): float =
  ## A stated float annotation, `NaN` when absent. An unparseable one is
  ## `NaN` too, reported rather than raised: collection reports what is
  ## wrong with a whole board in one pass, and `readiness` already reports
  ## the same value as `annotation_unparseable` with an error severity.
  try:
    let v = annotationFloat(c, key)
    if v.has: v.value else: NaN
  except NetlistError as e:
    item.issues.add newIssue(KindBomAnnotationUnparseable, sevWarning,
      path & ": " & e.msg & " -- read as unstated.", components = @[c])
    NaN

proc fill(item: BomItem, c: Component, path: string) =
  ## The first member to state a field wins; a packaged part's sections name
  ## the same physical part, so a later one stating the same field again
  ## adds nothing.
  template firstStr(field: untyped, key: string) =
    if item.field.len == 0:
      let v = annotation(c, key)
      if v.has: item.field = v.value
  template firstFloat(field: untyped, key: string) =
    if item.field.isNaN: item.field = floatOf(item, c, path, key)
  if item.valueText.len == 0: item.valueText = c.attrs.getOrDefault("value")
  firstFloat(tolerance, "tolerance")
  firstFloat(voltageRating, "voltage_rating")
  firstFloat(powerRating, "power_rating")
  firstFloat(currentRating, "current_rating")
  firstFloat(isat, "isat")
  firstStr(dielectric, "dielectric")
  firstStr(package, "package")
  firstStr(footprint, "footprint")
  firstStr(use, "part_use")
  firstStr(mpn, "mpn")
  firstStr(manufacturer, "manufacturer")
  if item.partNumber.len == 0: item.partNumber = c.partNumber
  if c.attrs.getOrDefault(generatedDesignatorAttr) == "true":
    item.generated = true

proc newItem(c: Component): BomItem =
  BomItem(kind: c.kind, family: familyOf(c.kind), value: NaN,
          tolerance: NaN, voltageRating: NaN, powerRating: NaN,
          currentRating: NaN, isat: NaN, quantity: 1)

proc applyDefaults(item: BomItem, d: BomDefaults) =
  ## Fills only what the part left unstated, and only for the parametric
  ## families -- a default tolerance means nothing to an op-amp. A part's
  ## own `spec:` is never overridden here; that is the whole point of
  ## reading the part first (`bomdefaults`' module comment).
  if not item.family.isParametric: return
  let who = item.designators[0]
  if item.tolerance.isNaN and float(d.tolerance) > 0.0:
    item.tolerance = float(d.tolerance)
    item.assumptions.add assumption(who, "tolerance", item.tolerance, "",
      annDefaulted, "from the bom: default (the part states no tolerance)")
  if item.family == pfCapacitor and item.dielectric.len == 0 and
      d.dielectric.len > 0:
    item.dielectric = d.dielectric
    item.assumptions.add note(who, "dielectric " & d.dielectric &
      " from the bom: default (the part states none)")
  # A stated footprint already fixes the land pattern, so a default package
  # beside it would decide nothing and record an assumption that misleads.
  if item.package.len == 0 and item.footprint.len == 0:
    let p =
      case item.family
      of pfResistor: d.resistorPackage
      of pfCapacitor: d.capacitorPackage
      of pfInductor, pfFerrite: d.inductorPackage
      else: ""
    if p.len > 0:
      item.package = p
      item.assumptions.add note(who, "package " & p &
        " from the bom: default (the part states neither package nor footprint)")

proc parseValue(item: BomItem) =
  ## Only a parametric family's `value` is a magnitude; anything else's is a
  ## model name (`1N4148` is lexically valid RKM, which is the reason this is
  ## never attempted on one). RKM (`2k2`) is refused by `parseSpiceMagnitude`
  ## on purpose and lands here as a warning, read as neither 2200 nor 2000.
  if not item.family.isParametric: return
  var v: float
  if parseSpiceMagnitude(item.valueText, v):
    item.value = v
  else:
    let why =
      if item.valueText.strip().len == 0: "states no value"
      else: "has value " & item.valueText.escape() & ", which is not a " &
            "bare magnitude (RKM like \"2k2\" is refused on purpose: " &
            "ngspice reads it as 2000, an EDA tool as 2200 -- write 2.2.kohm)"
    item.issues.add newIssue(KindBomValueUnparseable, sevWarning,
      item.designators[0] & " " & why & ", so it cannot be searched for " &
      "by value.", components = item.components)

proc collect*(nl: Netlist): seq[BomItem] =
  ## One `BomItem` per physical part under `nl`, in netlist order.
  ## Simulation-only kinds (`pfNotAPart`) are left out; parts marked
  ## `bom_exclude` are kept with `excluded = true`, so the resolver can say
  ## what it left out. Each item's `bom:` defaults are read from the netlist
  ## its (first) member lives in -- most specific wins, per `bomDefaults`.
  var leaves: seq[tuple[c: Component, path: string]]
  collectLeaves(nl, "", leaves)
  var byPkg: Table[string, BomItem]
  var dnpSeen: Table[string, tuple[yes, no: int]]
  for (c, path) in leaves:
    if familyOf(c.kind) == pfNotAPart: continue
    let r = packageRef(c)
    var item: BomItem
    if r.has and byPkg.hasKey(r.value):
      item = byPkg[r.value]
    else:
      item = newItem(c)
      item.designators.add(if r.has: r.value else: path)
      if r.has: byPkg[r.value] = item
      result.add item
    item.members.add path
    item.components.add c
    fill(item, c, path)
    let isDnp = dnp(c)
    if isDnp.has and isDnp.value: item.doNotPopulate = true
    let ex = bomExclude(c)
    if ex.has and ex.value: item.excluded = true
    if r.has:
      var t = dnpSeen.getOrDefault(r.value)
      if isDnp.has and isDnp.value: inc t.yes else: inc t.no
      dnpSeen[r.value] = t
      # A packaged part's footprint may live only on its definition.
      if item.footprint.len == 0:
        let dn = packageDefName(c)
        if dn.has and isPackageRegistered(dn.value):
          let def = packageDef(dn.value)
          item.footprint = def.footprint
          if item.partNumber.len == 0: item.partNumber = def.partNumber

  for item in result:
    let r = item.designators[0]
    if dnpSeen.hasKey(r):
      let t = dnpSeen[r]
      if t.yes > 0 and t.no > 0:
        item.issues.add newIssue(KindBomPackageDnpConflict, sevWarning,
          r & ": " & $t.yes & " of its " & $(t.yes + t.no) & " sections are " &
          "marked dnp and the rest are not. A package is fitted or not as " &
          "a whole, so it is treated as dnp -- mark every section, or none.",
          components = item.components)
    parseValue(item)
    applyDefaults(item, bomDefaults(item.components[0].netlist))
    item.caseCode = caseCodeOf(item.footprint, item.package)
