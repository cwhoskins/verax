import std/[json, math, sequtils, strutils, unittest]

import verax/bom
import verax/bom/sources/local

proc opt(x: float): Option[float] =
  ## Fixture shorthand: `NaN` is unstated.
  if x.isNaN: none(float) else: some(x)
proc st(x: float): Stated[float] =
  if x.isNaN: absent(float) else: stated(x)


const FixturePath = "tests/fixtures/catalog.json"

proc item(family: PartFamily, value: float, caseCode: string,
          designator: string, tolerance = NaN): BomItem =
  BomItem(designators: @[designator], members: @[designator],
          kind: (if family == pfResistor: "resistor"
                 elif family == pfCapacitor: "capacitor" else: "opamp"),
          family: family, value: opt(value), valueText: $value,
          tolerance: st(tolerance), caseCode: caseCode, quantity: 1)

proc board(): BomResult =
  ## Two 10k resistors on one line, a DNP 100n, an op-amp with no MPN, an
  ## excluded part.
  clearCatalogSources()
  discard registerCatalogFile(FixturePath)
  var dnp = item(pfCapacitor, 100e-9, "0402", "C1", 0.1)
  dnp.dielectric = "X7R"
  dnp.doNotPopulate = true
  var gone = item(pfResistor, 1e3, "0402", "R9")
  gone.excluded = true
  resolve(@[item(pfResistor, 10e3, "0402", "R1", 0.05),
            item(pfResistor, 10e3, "0402", "R2", 0.05),
            dnp,
            item(pfOther, NaN, "", "U1"),
            gone])

test "CSV has one header row and one row per line, quantities summing to the parts":
  let r = board()
  let rows = renderCsv(r).strip.splitLines
  check rows[0] == "Quantity,Designators,Value,Footprint,Manufacturer,MPN," &
                   "Description,Datasheet,DNP"
  check rows.len == 1 + r.lines.len
  var total = 0
  for row in rows[1 .. ^1]: total += parseInt(row.split(',')[0])
  check total == 4                                # R1, R2, C1, U1; not R9
  check rows[1].startsWith("2,\"R1,R2\",10.0 kohm,")   # quoted: holds a comma
  check rows.anyIt(it.endsWith(",yes"))           # the DNP line says so

test "a CSV field holding a quote is quoted with the quote doubled":
  var r = board()
  r.lines[0].description = "10k \"thick film\", 1%"
  check "\"10k \"\"thick film\"\", 1%\"" in renderCsv(r)

test "the text report lists every line and names every issue":
  let r = board()
  let text = render(r)
  for line in r.lines:
    check line.designators.join(",") in text
  for i in allIssues(r):
    check i.message in text
  check "ERRORS (1)" in text                      # U1 has no MPN
  check "(unresolved)" in text
  check "DNP" in text
  check "1 excluded" in text

test "JSON carries the schema, lines by index into parts, and null for NaN":
  let r = board()
  let doc = renderJson(r)
  check "nan" notin doc.toLowerAscii.replace("\"nan\"", "")
  let j = parseJson(doc)
  check j["schema"].getStr == "verax.bom/1"
  check j["parts"].len == r.resolutions.len       # excluded included
  check j["lines"].len == r.lines.len
  let r1 = j["parts"][0]
  check r1["mpn"].getStr == "RC0402FR-0710KL"
  check r1["signature"].getStr.len > 0
  check r1["requirement"]["voltage_rating"].kind == JNull
  check r1["alternates"].len == 3
  check j["lines"][0]["parts"].getElems.mapIt(it.getInt) == @[0, 1]
  let u1 = j["parts"][3]
  check not u1["resolved"].getBool
  check u1["chosen"].kind == JNull
  check u1["issues"][0]["severity"].getStr == "error"
  check j["summary"]["worst"].getStr == "error"
  check j["summary"]["excluded"].getInt == 1

test "unknown stock is null in JSON, not -1":
  clearCatalogSources()
  discard registerCatalogFile(FixturePath)
  var i = item(pfResistor, 10e3, "0402", "R1")
  i.mpn = "RC0402JR-0710KL"                       # the fixture states no stock
  let j = parseJson(renderJson(resolve(@[i])))
  check j["parts"][0]["chosen"]["stock"].kind == JNull
