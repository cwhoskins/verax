import std/[math, os, sequtils, strutils, tables, unittest]

import verax/netlist
import verax/netlist/annotations
import verax/bom
import verax/bom/sources/local

const FixturePath = "tests/fixtures/catalog.json"

proc useFixture() =
  clearCatalogSources()
  discard registerCatalogFile(FixturePath)

proc resistor(designator: string, value: float, tolerance = 0.05): BomItem =
  BomItem(designators: @[designator], members: @[designator],
          kind: "resistor", family: pfResistor, value: value,
          tolerance: tolerance, voltageRating: NaN, powerRating: NaN,
          currentRating: NaN, isat: NaN, caseCode: "0402", quantity: 1)

proc relock(r: BomResult): ResolveOptions =
  result = defaultResolveOptions()
  result.lock = parseLock(renderJson(r))

# A source registered ahead of the fixture, offering a 10k 1 % 0402 part with
# more stock than anything in it -- what a fresh ranking would now pick.
const Better = """{"schema": "verax.catalog/1", "parts": [
  {"mpn": "ACME-10K", "manufacturer": "Acme", "family": "resistor",
   "value": 10000, "tolerance": 0.01, "caseCode": "0402",
   "stock": 99000000, "lifecycle": "active"}]}"""

test "the JSON report reads back as a lock keyed on each searched part's signature":
  useFixture()
  var u1 = BomItem(designators: @["U1"], members: @["U1"], kind: "opamp",
                   family: pfOther, value: NaN, tolerance: NaN,
                   voltageRating: NaN, powerRating: NaN, currentRating: NaN,
                   isat: NaN, mpn: "LM358DR", quantity: 1)
  let r = resolve(@[resistor("R1", 10e3), resistor("R2", 10e3), u1])
  let lock = parseLock(renderJson(r))
  check lock.len == 1                     # one requirement; U1 is bought by MPN
  let e = lock[r.resolutions[0].signature]
  check e.mpn == "RC0402FR-0710KL"
  check e.manufacturer == "Yageo"
  check e.designators == @["R1", "R2"]

test "a lock pins its part even when a better-stocked one appears":
  useFixture()
  let first = resolve(@[resistor("R1", 10e3)])
  check first.resolutions[0].chosen.mpn == "RC0402FR-0710KL"
  let opts = relock(first)

  clearCatalogSources()
  registerCatalogSource(catalogSource(parseCatalog(Better), "acme"))
  discard registerCatalogFile(FixturePath)
  check resolve(@[resistor("R1", 10e3)]).resolutions[0].chosen.mpn == "ACME-10K"
  let again = resolve(@[resistor("R1", 10e3)], opts)
  check again.resolutions[0].chosen.mpn == "RC0402FR-0710KL"
  check again.resolutions[0].locked
  check again.resolutions[0].issues.len == 0

test "a lock whose part is gone is stale, and the item is re-resolved":
  clearCatalogSources()
  registerCatalogSource(catalogSource(parseCatalog(Better), "acme"))
  discard registerCatalogFile(FixturePath)
  let first = resolve(@[resistor("R1", 10e3)])
  check first.resolutions[0].chosen.mpn == "ACME-10K"
  let opts = relock(first)

  useFixture()                            # Acme is gone
  let again = resolve(@[resistor("R1", 10e3)], opts)
  check again.resolutions[0].chosen.mpn == "RC0402FR-0710KL"
  check not again.resolutions[0].locked
  check KindBomLockStale in again.allIssues.mapIt(it.kind)

proc generatedBoard(values: seq[string]): Netlist =
  ## Resistors under generated designators, in the order given.
  result = newNetlist("b")
  let a = addNet(result, newNet("a"))
  for v in values:
    let r = addGenerated(result, "resistor")
    setRawAnnotation(r, "value", v)
    setRawAnnotation(r, "package", "0402")
    discard connect(r, "1", a, ptPassive)

test "inserting a part earlier renumbers generated designators and invalidates no lock":
  useFixture()
  let before = resolve(collect(generatedBoard(@["10k", "4.7k"])))
  check before.resolutions.mapIt(it.item.designators[0]) == @["R1", "R2"]
  let opts = relock(before)

  # A 1k inserted first: the 10k is now R2 and the 4.7k R3.
  let after = resolve(collect(generatedBoard(@["1k", "10k", "4.7k"])), opts)
  check after.resolutions.mapIt(it.item.designators[0]) == @["R1", "R2", "R3"]
  check not after.resolutions[0].locked   # new; nothing to lock
  check after.resolutions[1].chosen.mpn ==
        before.resolutions[0].chosen.mpn
  check after.resolutions[1].locked
  check after.resolutions[2].chosen.mpn ==
        before.resolutions[1].chosen.mpn
  check after.resolutions[2].locked

test "a second run against the emitted JSON reproduces the selection, all locked":
  useFixture()
  let items = @[resistor("R1", 10e3), resistor("R2", 4.7e3, 0.01)]
  let first = resolve(items)
  let second = resolve(items, relock(first))
  for k in 0 ..< items.len:
    check second.resolutions[k].chosen.mpn == first.resolutions[k].chosen.mpn
    check second.resolutions[k].locked
  check renderCsv(second) == renderCsv(first)

test "a missing, unparseable or foreign lock file is a LockError":
  expect LockError:
    discard loadLock(getTempDir() / "verax-no-such-lock.json")
  expect LockError:
    discard parseLock("{not json")
  expect LockError:
    discard parseLock("""{"schema": "verax.readiness/1", "results": []}""")

test "a lock tying one requirement to two parts is refused":
  let sig = "resistor|1.000000e+04|-|0402||-|-|-"
  let doc = """{"schema": "verax.bom/1", "parts": [
    {"signature": "$1", "resolved": true, "mpn": "A", "manufacturer": "X",
     "designators": ["R1"]},
    {"signature": "$1", "resolved": true, "mpn": "B", "manufacturer": "X",
     "designators": ["R2"]}]}""" % sig
  expect LockError:
    discard parseLock(doc)
