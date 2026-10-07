import std/[math, strutils, tables, unittest]

import verax/bom
import verax/bom/sources/local

const FixturePath = "tests/fixtures/catalog.json"

proc problemsOf(text: string): seq[string] =
  try:
    discard parseCatalog(text)
  except CatalogError as e:
    return e.problems

proc doc(rows: string): string =
  """{"schema": "verax.catalog/1", "parts": [""" & rows & "]}"

proc mpns(cs: seq[Candidate]): seq[string] =
  for c in cs: result.add c.mpn

# --- loading ----------------------------------------------------------------

test "the fixture catalogue loads every row":
  let cat = loadCatalog(FixturePath)
  check cat.parts.len == 18
  check cat.origin == FixturePath

test "a row's fields land on the candidate in SI base units and fractions":
  let c = loadCatalog(FixturePath).lookup("GRM155R71C104KA88D")
  check c != nil
  check c.family == pfCapacitor
  check c.value == 1e-7
  check c.tolerance == 0.1
  check c.dielectric == "X7R"
  check c.voltageRating == 16.0
  check c.caseCode == "0402"
  check c.avail.stock == 5_000_000
  check c.avail.lifecycle == "active"

test "an unstated rating, stock or moq is unknown, never zero":
  let c = loadCatalog(FixturePath).lookup("GRM155R71H103KA88D")
  check c.voltageRating.isNaN
  check c.powerRating.isNaN
  check c.avail.stock == -1
  check c.avail.moq == -1
  check c.avail.lifecycle == ""

test "a stated stock of zero stays zero":
  check loadCatalog(FixturePath).lookup("MAX232CPE").avail.stock == 0

test "a bare imperial package fills the case code; a non-chip one does not":
  let cat = loadCatalog(FixturePath)
  check cat.lookup("RC0402FR-074K7L").caseCode == "0402"
  check cat.lookup("XFL4020-472MEC").caseCode == ""

test "attrs carry a house part number through":
  check loadCatalog(FixturePath).lookup("RC0402FR-0710KL").attrs["ipn"] == "R-0001"

test "an empty parts list is a valid catalogue":
  check parseCatalog(doc("")).parts.len == 0

# --- strictness ---------------------------------------------------------------

test "a value written as a string is refused, naming the row":
  let p = problemsOf(doc("""{"mpn": "X", "manufacturer": "M",
    "family": "resistor", "value": "10k", "caseCode": "0402"}"""))
  check p.len == 1
  check p[0].startsWith("parts[0] (X): value must be a number in SI base units")

test "a tolerance written as a percentage is refused":
  let p = problemsOf(doc("""{"mpn": "X", "manufacturer": "M",
    "family": "resistor", "value": 1000, "tolerance": 1}"""))
  check p.len == 1
  check "fraction" in p[0]

test "an unknown field, family, lifecycle or case code is refused":
  check "unknown field \"vlaue\"" in problemsOf(doc("""{"mpn": "X",
    "manufacturer": "M", "family": "other", "vlaue": 3}""")).join
  check "family must be one of" in problemsOf(doc("""{"mpn": "X",
    "manufacturer": "M", "family": "diode"}""")).join
  check "lifecycle must be one of" in problemsOf(doc("""{"mpn": "X",
    "manufacturer": "M", "family": "other", "lifecycle": "eol"}""")).join
  check "not a standard imperial" in problemsOf(doc("""{"mpn": "X",
    "manufacturer": "M", "family": "resistor", "value": 1,
    "caseCode": "1005"}""")).join

test "a parametric row without a value is refused":
  check "must state value" in problemsOf(doc("""{"mpn": "X",
    "manufacturer": "M", "family": "capacitor", "caseCode": "0402"}""")).join

test "a value on a part bought by MPN is refused":
  check "only read for a parametric family" in problemsOf(doc("""{"mpn": "X",
    "manufacturer": "M", "family": "other", "value": 5}""")).join

test "a missing mpn or manufacturer is refused":
  let p = problemsOf(doc("""{"family": "other", "manufacturer": ""}"""))
  check p.len == 2

test "a duplicate part is refused, ignoring case":
  let p = problemsOf(doc("""
    {"mpn": "ABC-1", "manufacturer": "Acme", "family": "other"},
    {"mpn": "abc-1", "manufacturer": "ACME", "family": "other"}"""))
  check p.len == 1
  check "duplicates parts[0]" in p[0]

test "the same mpn from two manufacturers is two parts":
  check problemsOf(doc("""
    {"mpn": "ABC-1", "manufacturer": "Acme", "family": "other"},
    {"mpn": "ABC-1", "manufacturer": "Other", "family": "other"}""")).len == 0

test "every problem is reported at once, and nothing is loaded":
  let text = doc("""
    {"mpn": "A", "manufacturer": "M", "family": "resistor", "value": "1k"},
    {"mpn": "B", "manufacturer": "M", "family": "nope"},
    {"mpn": "C", "manufacturer": "M", "family": "other"}""")
  check problemsOf(text).len == 2
  expect CatalogError:
    discard parseCatalog(text)

test "a wrong or missing schema is refused":
  check "schema must be" in problemsOf("""{"parts": []}""").join
  check "schema must be" in problemsOf(
    """{"schema": "verax.catalog/2", "parts": []}""").join

test "invalid JSON and an unreadable file are CatalogErrors":
  expect CatalogError:
    discard parseCatalog("{not json")
  expect CatalogError:
    discard loadCatalog("tests/fixtures/no_such_catalog.json")

# --- search ---------------------------------------------------------------------

test "a search returns every exact match in file order":
  let cat = loadCatalog(FixturePath)
  let q = newPartQuery(pfResistor, 10e3, "0402")
  check cat.search(q).mpns == @["RC0402FR-0710KL", "ERJ-2RKF1002X",
    "CRCW040210K0FKED", "RC0402JR-0710KL"]

test "the case code is required and must match":
  let cat = loadCatalog(FixturePath)
  check cat.search(newPartQuery(pfResistor, 10e3, "")).len == 0
  check cat.search(newPartQuery(pfResistor, 10e3, "0603")).mpns ==
    @["RC0603FR-0710KL"]

test "an unknown value matches nothing":
  check loadCatalog(FixturePath).search(
    newPartQuery(pfResistor, NaN, "0402")).len == 0

test "a value tolerance admits a nearby nominal":
  let cat = loadCatalog(FixturePath)
  var q = newPartQuery(pfResistor, 10e3, "0402")
  q.valueTolerance = 0.03
  check "RC0402FR-079K76L" in cat.search(q).mpns
  q.valueTolerance = 0.02
  check "RC0402FR-079K76L" notin cat.search(q).mpns

test "maxTolerance rejects a looser part":
  let cat = loadCatalog(FixturePath)
  var q = newPartQuery(pfResistor, 10e3, "0402")
  q.maxTolerance = 0.01
  check "RC0402JR-0710KL" notin cat.search(q).mpns
  check cat.search(q).len == 3

test "a stated minimum rating rejects a lower or unknown rating":
  let cat = loadCatalog(FixturePath)
  var q = newPartQuery(pfCapacitor, 1e-8, "0402")
  check cat.search(q).mpns == @["GRM155R71H103KA88D"]
  q.minVoltage = 6.3
  check cat.search(q).len == 0      # its voltage rating is unknown
  var p = newPartQuery(pfResistor, 10e3, "0402")
  p.minPower = 0.1
  check cat.search(p).mpns == @["ERJ-2RKF1002X"]

test "a dielectric must match, ignoring case":
  let cat = loadCatalog(FixturePath)
  var q = newPartQuery(pfCapacitor, 1e-7, "0402")
  q.dielectric = "x5r"
  check cat.search(q).mpns == @["GRM155R61A104KA01D"]

test "the family must match":
  check loadCatalog(FixturePath).search(
    newPartQuery(pfCapacitor, 10e3, "0402")).len == 0

test "preferred manufacturers do not filter":
  let cat = loadCatalog(FixturePath)
  var q = newPartQuery(pfResistor, 10e3, "0402")
  q.manufacturers = @["Vishay"]
  check cat.search(q).len == 4

test "limit caps the result":
  var q = newPartQuery(pfResistor, 10e3, "0402")
  q.limit = 2
  check loadCatalog(FixturePath).search(q).len == 2

test "search hands out copies, so a caller cannot edit the catalogue":
  let cat = loadCatalog(FixturePath)
  let q = newPartQuery(pfResistor, 4700, "0402")
  cat.search(q)[0].avail.stock = 1
  check cat.search(q)[0].avail.stock == 1_000_000

# --- lookup ---------------------------------------------------------------------

test "lookup ignores case and narrows by manufacturer when given":
  let cat = loadCatalog(FixturePath)
  check cat.lookup("lm358dr") != nil
  check cat.lookup("LM358DR", "texas instruments") != nil
  check cat.lookup("LM358DR", "Onsemi") == nil
  check cat.lookup("NOPE-123") == nil

test "a catalogue source stamps its name on what it returns":
  let s = catalogSource(loadCatalog(FixturePath), "house")
  check s.lookup("LM358DR", "").source == "house"
  for c in s.search(newPartQuery(pfResistor, 10e3, "0402")):
    check c.source == "house"
