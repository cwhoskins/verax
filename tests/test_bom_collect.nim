import std/[math, sequtils, strutils, unittest]

import verax/netlist
import verax/netlist/dsl
import verax/netlist/annotations
import verax/netlist/packages
import verax/netlist/bomdefaults
import verax/bom
import verax/units

proc itemFor(items: seq[BomItem], designator: string): BomItem =
  for i in items:
    if designator in i.designators: return i
  nil

proc kinds(i: BomItem): seq[string] =
  for x in i.issues: result.add x.kind

# --- value ------------------------------------------------------------------

test "a bare magnitude value is read in SI base units":
  let nl = netlist("b"):
    net a
    net gnd, kind = ntGround, name = "0"
    component R1, kind = "resistor", value = "10k":
      pin "1", a
      pin "2", gnd
    component R2, kind = "resistor", value = 2.2.kohm:
      pin "1", a
      pin "2", gnd
  let items = collect(nl)
  check itemFor(items, "R1").value == 10000.0
  check abs(itemFor(items, "R2").value - 2200.0) < 1e-9
  check itemFor(items, "R1").issues.len == 0

test "an RKM value is refused and reported, read as neither 2200 nor 2000":
  let nl = netlist("b"):
    net a
    component R1, kind = "resistor", value = "2k2":
      pin "1", a
      pin "2", a
  let r = itemFor(collect(nl), "R1")
  check r.value.isNaN
  check r.valueText == "2k2"
  check KindBomValueUnparseable in kinds(r)
  check r.issues[0].severity == sevWarning
  check "2.2.kohm" in r.issues[0].message

test "a non-passive's value is a model name and is never parsed":
  # `1N4148` is lexically valid RKM -- parsing it would read 1.4148 nF.
  let nl = netlist("b"):
    net a
    net k
    component D1, kind = "diode", value = "1N4148":
      pin "A", a
      pin "K", k
  let d = itemFor(collect(nl), "D1")
  check d.family == pfOther
  check d.value.isNaN
  check d.valueText == "1N4148"
  check d.issues.len == 0

# --- classification ------------------------------------------------------------

test "familyOf maps the four searchable kinds, leaves the rest to pfOther":
  check familyOf("resistor") == pfResistor
  check familyOf("Capacitor") == pfCapacitor
  check familyOf("inductor") == pfInductor
  check familyOf("ferrite_bead") == pfFerrite
  check familyOf("opamp") == pfOther
  check familyOf("battery") == pfOther
  check familyOf("voltage_source") == pfNotAPart

test "registerPartFamily lets a project add its own kind":
  check familyOf("my_stimulus") == pfOther
  registerPartFamily("my_stimulus", pfNotAPart)
  check familyOf("my_stimulus") == pfNotAPart

test "simulation-only kinds are left off the BOM":
  let nl = netlist("b"):
    net vin
    net gnd, kind = ntGround, name = "0"
    component V1, kind = "voltage_source", value = "DC 5":
      pin "+", vin
      pin "-", gnd
    component C1, kind = "capacitor", value = "100n":
      pin "1", vin
      pin "2", gnd
  let items = collect(nl)
  check items.len == 1
  check itemFor(items, "C1") != nil

test "caseCodeOf reads a KiCad chip footprint and refuses anything else":
  check caseCodeOf("Resistor_SMD:R_0402_1005Metric", "") == "0402"
  check caseCodeOf("Capacitor_SMD:C_0603_1608Metric_Pad1.08x0.95mm_HandSolder", "") == "0603"
  check caseCodeOf("Package_DFN_QFN:QFN-16-1EP_3x3mm_P0.5mm_EP1.7x1.7mm", "") == ""
  check caseCodeOf("Package_SO:SOIC-8_3.9x4.9mm_P1.27mm", "") == ""
  check caseCodeOf("", "0805") == "0805"
  check caseCodeOf("", "tantalum") == ""
  # A stated footprint is the only authority: the land pattern wins.
  check caseCodeOf("Package_SO:SOIC-8_3.9x4.9mm_P1.27mm", "0805") == ""
  # Metric 0603 is imperial 0201 -- only the paired name is trusted.
  check caseCodeOf("R_0201_0603Metric", "") == "0201"
  check caseCodeOf("R_0603", "") == ""

# --- hierarchy and packages -------------------------------------------------

test "a leaf two instance levels down gets its hierarchical path":
  let inner = subckt("inner", [a]):
    net a
    component R1, kind = "resistor", value = "1k":
      pin "1", a
      pin "2", a
  let mid = subckt("mid", [a]):
    net a
    instance X2, inner, [a]
  let top = netlist("top"):
    net n
    instance X1, mid, [n]
  let items = collect(top)
  check items.len == 1
  check items[0].designators == @["X1.X2.R1"]
  check items[0].members == @["X1.X2.R1"]

proc dualDef(name: string): PackageDef =
  newPackageDef(name, [
    (id: "1", section: "A", logical: "OUT"),
    (id: "2", section: "A", logical: "IN-"),
    (id: "3", section: "A", logical: "IN+"),
    (id: "4", section: "",  logical: "V-"),
    (id: "5", section: "B", logical: "IN+"),
    (id: "6", section: "B", logical: "IN-"),
    (id: "7", section: "B", logical: "OUT"),
    (id: "8", section: "",  logical: "V+")],
    partNumber = "NE5532", footprint = "Package_SO:SOIC-8_3.9x4.9mm_P1.27mm")

test "a dual op-amp's two sections collapse to one item of quantity 1":
  registerPackage(dualDef("BOM_TEST_DUAL"))
  let pkg = packageInstance("BOM_TEST_DUAL", "U9")
  let nl = netlist("flat"):
    net gnd, kind = ntGround, name = "0"
    component U9A, kind = "opamp":
      pin "OUT", gnd
    component U9B, kind = "opamp":
      pin "OUT", gnd
  pkg.assign(nl, "A", "U9A")
  pkg.assign(nl, "B", "U9B")
  let items = collect(nl)
  check items.len == 1
  check items[0].designators == @["U9"]
  check items[0].members == @["U9A", "U9B"]
  check items[0].quantity == 1
  # Taken from the package definition, since neither section states one.
  check items[0].footprint == "Package_SO:SOIC-8_3.9x4.9mm_P1.27mm"
  check items[0].partNumber == "NE5532"
  check items[0].mpn == ""   # partNumber is never promoted to an MPN

test "a package with only some sections marked dnp is reported and treated as dnp":
  registerPackage(dualDef("BOM_TEST_DUAL_DNP"))
  let pkg = packageInstance("BOM_TEST_DUAL_DNP", "U7")
  let nl = netlist("flat"):
    net gnd, kind = ntGround, name = "0"
    component U7A, kind = "opamp":
      spec:
        dnp = true
      pin "OUT", gnd
    component U7B, kind = "opamp":
      pin "OUT", gnd
  pkg.assign(nl, "A", "U7A")
  pkg.assign(nl, "B", "U7B")
  let u = collect(nl)[0]
  check u.doNotPopulate
  check KindBomPackageDnpConflict in kinds(u)

# --- dnp / exclude ------------------------------------------------------------

test "dnp and bom_exclude are read from spec:":
  let nl = netlist("b"):
    net a
    component R1, kind = "resistor", value = "0":
      spec:
        dnp = true
      pin "1", a
      pin "2", a
    component J1, kind = "connector":
      spec:
        bom_exclude = true
      pin "1", a
    component R2, kind = "resistor", value = "1k":
      pin "1", a
      pin "2", a
  let items = collect(nl)
  check items.len == 3
  check itemFor(items, "R1").doNotPopulate
  check not itemFor(items, "R1").excluded
  check itemFor(items, "J1").excluded
  check not itemFor(items, "R2").doNotPopulate
  check not itemFor(items, "R2").excluded

# --- stated fields and defaults -------------------------------------------------

test "stated fields are read, and a part's own spec beats every default":
  let nl = netlist("b"):
    bom:
      tolerance = 5.pct
      dielectric = "X7R"
      capacitor_package = "0603"
    net a
    component C1, kind = "capacitor", value = "22n":
      spec:
        tolerance = 1.pct
        dielectric = "C0G"
        voltage_rating = 50.V
        footprint = "Capacitor_SMD:C_0402_1005Metric"
        mpn = "GRM1555C1H223JA01D"
        manufacturer = "Murata"
        part_use = "timing"
      pin "1", a
      pin "2", a
  let c = itemFor(collect(nl), "C1")
  check abs(c.tolerance - 0.01) < 1e-12
  check c.dielectric == "C0G"
  check c.voltageRating == 50.0
  check c.caseCode == "0402"
  check c.package == ""          # a footprint was stated, so no default package
  check c.mpn == "GRM1555C1H223JA01D"
  check c.manufacturer == "Murata"
  check c.use == "timing"
  check c.assumptions.len == 0
  check c.powerRating.isNaN

test "an absent tolerance takes the board default and records an Assumption":
  let nl = netlist("b"):
    bom:
      tolerance = 5.pct
      dielectric = "X7R"
      capacitor_package = "0603"
    net a
    component C1, kind = "capacitor", value = "100n":
      pin "1", a
      pin "2", a
  let c = itemFor(collect(nl), "C1")
  check abs(c.tolerance - 0.05) < 1e-12
  check c.dielectric == "X7R"
  check c.package == "0603"
  check c.caseCode == "0603"
  check c.assumptions.len == 3
  var keys: seq[string]
  for a in c.assumptions: keys.add a.key & "|" & a.detail
  check keys.anyIt("tolerance" in it)
  check keys.anyIt("X7R" in it)
  check keys.anyIt("0603" in it)
  for a in c.assumptions: check a.entity == "C1"

test "defaults never reach a non-parametric part":
  let nl = netlist("b"):
    bom:
      tolerance = 5.pct
    net a
    component U1, kind = "mcu":
      pin "1", a
  let u = itemFor(collect(nl), "U1")
  check u.tolerance.isNaN
  check u.assumptions.len == 0

test "each part takes the defaults of the netlist it lives in":
  let sheet = subckt("filt", [a]):
    bom:
      dielectric = "C0G"
    net a
    component C1, kind = "capacitor", value = "10n":
      pin "1", a
      pin "2", a
  let top = netlist("top"):
    bom:
      dielectric = "X7R"
      tolerance = 10.pct
    net n
    instance X1, sheet, [n]
    component C2, kind = "capacitor", value = "100n":
      pin "1", n
      pin "2", n
  let items = collect(top)
  let inner = itemFor(items, "X1.C1")
  check inner.dielectric == "C0G"
  check abs(inner.tolerance - 0.10) < 1e-12   # inherited from the board
  check itemFor(items, "C2").dielectric == "X7R"

test "a generated designator is marked":
  let nl = newNetlist("b")
  let a = addNet(nl, newNet("a"))
  let r = addGenerated(nl, "resistor")
  setRawAnnotation(r, "value", "1k")
  discard connect(r, "1", a, ptPassive)
  check collect(nl)[0].generated
