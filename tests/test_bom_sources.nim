import std/[math, unittest]

import verax/bom
import verax/bom/sources/local

const FixturePath = "tests/fixtures/catalog.json"

proc mpns(cs: seq[Candidate]): seq[string] =
  for c in cs: result.add c.mpn

proc part(mpn, mfr: string, stock = -1, lifecycle = ""): Candidate =
  Candidate(mpn: mpn, manufacturer: mfr, family: pfResistor, value: some(1000.0),
            caseCode: "0402",
            avail: Availability(stock: (if stock < 0: none(int) else: some(stock)),
                                lifecycle: lifecycle))

proc fixed(name: string, parts: seq[Candidate]): CatalogSource =
  proc search(q: PartQuery): seq[Candidate] =
    for p in parts:
      if p.matches(q): result.add p
  proc lookup(mpn, manufacturer: string): Candidate =
    for p in parts:
      if p.mpn == mpn: return p
  CatalogSource(name: name, search: search, lookup: lookup)

let q1k = newPartQuery(pfResistor, 1000, "0402")

test "no source is registered by importing the bom modules":
  check catalogSources().len == 0
  check searchAll(q1k).len == 0
  check lookupAll("anything") == nil

test "registration order is resolution order":
  clearCatalogSources()
  registerCatalogSource(fixed("a", @[part("R1", "Acme")]))
  registerCatalogSource(fixed("b", @[part("R1", "Acme", 99), part("R2", "Acme")]))
  check catalogSources() == @["a", "b"]
  check searchAll(q1k).mpns == @["R1", "R2"]
  check lookupAll("R2") != nil

test "searchAll de-duplicates on manufacturer and mpn, ignoring case":
  clearCatalogSources()
  registerCatalogSource(fixed("a", @[part("R1", "Acme")]))
  registerCatalogSource(fixed("b", @[part("r1", "ACME"), part("R1", "Other")]))
  let got = searchAll(q1k)
  check got.len == 2
  check got[0].manufacturer == "Acme"
  check got[1].manufacturer == "Other"

test "a later source fills only availability the first left unknown":
  clearCatalogSources()
  registerCatalogSource(fixed("a", @[part("R1", "Acme", -1, "active")]))
  registerCatalogSource(fixed("b", @[part("R1", "Acme", 500, "obsolete")]))
  let got = searchAll(q1k)
  check got.len == 1
  check got[0].avail.stock == some(500)
  check got[0].avail.lifecycle == "active"

test "folding stock never edits a source's own record":
  clearCatalogSources()
  let first = part("R1", "Acme")
  registerCatalogSource(fixed("a", @[first]))
  registerCatalogSource(fixed("b", @[part("R1", "Acme", 500)]))
  discard searchAll(q1k)
  check first.avail.stock.isNone

test "a nil search or lookup is skipped rather than crashing":
  clearCatalogSources()
  registerCatalogSource(CatalogSource(name: "empty"))
  registerCatalogSource(fixed("a", @[part("R1", "Acme")]))
  check searchAll(q1k).mpns == @["R1"]
  check lookupAll("R1") != nil

test "lookupAll returns the first source that knows the part":
  clearCatalogSources()
  registerCatalogSource(fixed("a", @[part("R1", "Acme", 1)]))
  registerCatalogSource(fixed("b", @[part("R1", "Acme", 2)]))
  check lookupAll("R1").avail.stock == some(1)
  check lookupAll("R9") == nil

test "a catalogue file registers as a source and answers through the registry":
  clearCatalogSources()
  let cat = registerCatalogFile(FixturePath, "house")
  check cat.parts.len == 18
  check catalogSources() == @["house"]
  check searchAll(newPartQuery(pfCapacitor, 1e-7, "0402")).len == 3
  let ldo = lookupAll("TPS7A2033PDBVR")
  check ldo.source == "house"
  check ldo.family == pfOther

test "a bad catalogue file registers nothing":
  clearCatalogSources()
  expect CatalogError:
    discard registerCatalogFile("tests/fixtures/no_such_catalog.json")
  check catalogSources().len == 0
