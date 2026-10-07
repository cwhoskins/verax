import std/[math, sequtils, strutils, tables, unittest]

import verax/netlist
import verax/netlist/dsl
import verax/bom
import verax/bom/sources/local
import verax/units

const FixturePath = "tests/fixtures/catalog.json"

proc item(family: PartFamily, value: float, caseCode: string,
          tolerance = NaN, designator = "R1"): BomItem =
  BomItem(designators: @[designator], members: @[designator],
          kind: (case family
                 of pfResistor: "resistor"
                 of pfCapacitor: "capacitor"
                 of pfInductor: "inductor"
                 of pfFerrite: "ferrite_bead"
                 else: "opamp"),
          family: family, value: value, tolerance: tolerance,
          voltageRating: NaN, powerRating: NaN, currentRating: NaN, isat: NaN,
          caseCode: caseCode, quantity: 1)

proc other(designator: string, mpn = "", partNumber = ""): BomItem =
  result = item(pfOther, NaN, "", designator = designator)
  result.mpn = mpn
  result.partNumber = partNumber

proc kinds(r: Resolution): seq[string] =
  for x in r.issues: result.add x.kind

proc issueOf(r: Resolution, kind: string): Issue =
  for x in r.issues:
    if x.kind == kind: return x
  raise newException(KeyError, "no " & kind & " on " & $r.item.designators)

proc mpns(cs: seq[Candidate]): seq[string] =
  for c in cs: result.add c.mpn

proc useFixture() =
  clearCatalogSources()
  discard registerCatalogFile(FixturePath)

# --- parametric search and ranking -------------------------------------------

test "a parametric item is searched, ranked exact-then-stock, and alternates kept":
  useFixture()
  let r = resolveItem(item(pfResistor, 10e3, "0402", tolerance = 0.05))
  check r.chosen.mpn == "RC0402FR-0710KL"           # exact, most stock
  check r.candidates == 5                           # 4 exact + 9.76k in band
  check r.alternates.mpns ==
    @["ERJ-2RKF1002X", "CRCW040210K0FKED", "RC0402JR-0710KL"]
  check r.chosen.source == "local"
  check r.issues.len == 0

test "a candidate's whole tolerance band must sit inside the item's":
  useFixture()
  # 9.76k 1 % spans 9.66k..9.86k: inside 10k 5 %, outside 10k 1 %.
  let wide = resolveItem(item(pfResistor, 10e3, "0402", tolerance = 0.05))
  check "RC0402FR-079K76L" notin wide.alternates.mpns
  check wide.candidates == 5
  let tight = resolveItem(item(pfResistor, 10e3, "0402", tolerance = 0.01))
  check tight.candidates == 3                        # the 5 % part is out too
  check tight.chosen.mpn == "RC0402FR-0710KL"

test "an unstated tolerance asks for the exact value at any tolerance":
  useFixture()
  let r = resolveItem(item(pfResistor, 10e3, "0402"))
  check r.candidates == 4

test "a stated rating rejects a part under it, and few matches is uncommon":
  useFixture()
  var i = item(pfResistor, 10e3, "0402", tolerance = 0.01)
  i.powerRating = 0.1
  let r = resolveItem(i)
  check r.chosen.mpn == "ERJ-2RKF1002X"
  check r.candidates == 1
  let u = r.issueOf(KindBomUncommonPart)
  check u.severity == sevInfo
  check "only 1 orderable part match" in u.message
  check "10.0 kohm" in u.message and "±1 %" in u.message

test "the uncommon-part check can be turned off":
  useFixture()
  var opts = defaultResolveOptions()
  opts.minCandidates = 0
  var i = item(pfCapacitor, 22e-9, "0402", tolerance = 0.05, designator = "C1")
  i.dielectric = "C0G"
  i.voltageRating = 50
  let r = resolveItem(i, opts)
  check r.chosen.mpn == "GRM1555C1H223JA01D"
  check KindBomUncommonPart notin r.kinds

test "a dielectric is required when stated; stock breaks the tie":
  useFixture()
  var i = item(pfCapacitor, 100e-9, "0402", tolerance = 0.1, designator = "C1")
  i.dielectric = "X7R"
  let r = resolveItem(i)
  check r.chosen.mpn == "CL05B104KO5NNNC"           # 7M beats 5M
  check r.alternates.mpns == @["GRM155R71C104KA88D"]

test "an NRND part ranks below an active one, and is warned about if chosen":
  useFixture()
  let any = resolveItem(item(pfCapacitor, 100e-9, "0402", tolerance = 0.1,
                             designator = "C1"))
  check any.alternates[^1].mpn == "GRM155R61A104KA01D"
  var x5r = item(pfCapacitor, 100e-9, "0402", tolerance = 0.1, designator = "C2")
  x5r.dielectric = "X5R"
  let only = resolveItem(x5r)
  check only.chosen.mpn == "GRM155R61A104KA01D"
  check only.issueOf(KindBomPartNrnd).severity == sevWarning

test "nothing matching is bom_no_match: an error, or info when DNP":
  useFixture()
  let r = resolveItem(item(pfResistor, 12345, "0402"))
  check r.chosen == nil
  check r.issueOf(KindBomNoMatch).severity == sevError
  var d = item(pfResistor, 12345, "0402")
  d.doNotPopulate = true
  check resolveItem(d).issueOf(KindBomNoMatch).severity == sevInfo

test "no case code is never searched: it needs an mpn":
  useFixture()
  var i = item(pfInductor, 4.7e-6, "", designator = "L1")
  i.footprint = "Inductor_SMD:L_Coilcraft_XFL4020"
  let r = resolveItem(i)
  check r.chosen == nil
  check r.candidates == 0
  check r.issueOf(KindBomNonstandardFootprint).severity == sevWarning
  check r.issueOf(KindBomMpnRequired).severity == sevError

test "an unparseable value is not searched, and its collect finding is kept":
  useFixture()
  var i = item(pfResistor, NaN, "0402")
  i.issues.add newIssue("bom_value_unparseable", sevWarning, "R1 ...")
  let r = resolveItem(i)
  check r.kinds == @["bom_value_unparseable", KindBomMpnRequired]

# --- by MPN ------------------------------------------------------------------

test "a stated mpn is looked up, for any family":
  useFixture()
  let r = resolveItem(other("U1", mpn = "tps7a2033pdbvr"))
  check r.chosen.mpn == "TPS7A2033PDBVR"
  check r.chosen.manufacturer == "Texas Instruments"
  check r.issues.len == 0
  var p = item(pfResistor, 10e3, "0402", tolerance = 0.01)
  p.mpn = "CRCW040210K0FKED"
  let rp = resolveItem(p)
  check rp.chosen.mpn == "CRCW040210K0FKED"
  check rp.candidates == 0                          # no search ran
  check rp.issues.len == 0

test "an mpn no source knows stays on the BOM, unverified, as a warning":
  useFixture()
  var i = other("U1", mpn = "NE5532P")
  i.manufacturer = "TI"
  let res = resolve(@[i])
  let r = res.resolutions[0]
  check r.chosen == nil
  check r.issueOf(KindBomPartNotFound).severity == sevWarning
  check res.lines[0].mpn == "NE5532P"
  check res.lines[0].manufacturer == "TI"

test "an obsolete part by mpn is a warning":
  useFixture()
  let r = resolveItem(other("U2", mpn = "MAX232CPE"))
  check r.chosen != nil
  check r.issueOf(KindBomPartObsolete).severity == sevWarning

test "an mpn that contradicts the stated spec is a warning naming why":
  useFixture()
  var i = item(pfResistor, 10e3, "0402", tolerance = 0.01)
  i.mpn = "RC0603FR-0710KL"
  let m = resolveItem(i).issueOf(KindBomMpnSpecMismatch)
  check m.severity == sevWarning
  check "case code is 0603, not 0402" in m.message
  var c = item(pfCapacitor, 100e-9, "0402", designator = "C1")
  c.voltageRating = 25
  c.mpn = "GRM155R71C104KA88D"
  check "voltage rating is 16.0 V, under 25.0 V" in
    resolveItem(c).issueOf(KindBomMpnSpecMismatch).message

test "partNumber stands in for a missing mpn: info if recognised, a warning if not":
  useFixture()
  let r = resolveItem(other("U3", partNumber = "LM358DR"))
  check r.chosen.mpn == "LM358DR"
  let used = r.issueOf(KindBomPartnumberUsedAsMpn)
  check used.severity == sevInfo
  check "mpn = \"LM358DR\"" in used.message
  let label = resolveItem(other("U4", partNumber = "OPA320AIDBVR"))
  check label.chosen == nil
  check KindBomMpnRequired notin label.kinds
  check label.issueOf(KindBomPartnumberUsedAsMpn).severity == sevWarning
  let res = resolve(@[other("U4", partNumber = " OPA320AIDBVR ")])
  check res.lines[0].mpn == "OPA320AIDBVR"
  check res.worstSeverity == sevWarning           # ordered, unverified

test "an unresolved DNP part is info, not an error":
  useFixture()
  var i = other("U5")
  i.doNotPopulate = true
  check resolveItem(i).issueOf(KindBomMpnRequired).severity == sevInfo

# --- lock ----------------------------------------------------------------------

test "the signature is the requirement, not the designator":
  let a = item(pfResistor, 10e3, "0402", tolerance = 0.01, designator = "R1")
  let b = item(pfResistor, 10e3, "0402", tolerance = 0.01, designator = "R7")
  check signatureOf(a) == signatureOf(b)
  check signatureOf(a) != signatureOf(item(pfResistor, 10e3, "0603", 0.01))
  check signatureOf(other("U1")) == ""

test "a lock entry wins when its part still qualifies":
  useFixture()
  let i = item(pfResistor, 10e3, "0402", tolerance = 0.01)
  var opts = defaultResolveOptions()
  opts.lock[signatureOf(i)] = LockEntry(signature: signatureOf(i),
    mpn: "CRCW040210K0FKED", manufacturer: "vishay")
  let r = resolveItem(i, opts)
  check r.locked
  check r.chosen.mpn == "CRCW040210K0FKED"
  check "CRCW040210K0FKED" notin r.alternates.mpns
  check r.alternates[0].mpn == "RC0402FR-0710KL"

test "a stale lock entry is reported and ranking takes over":
  useFixture()
  let i = item(pfResistor, 10e3, "0402", tolerance = 0.01)
  var opts = defaultResolveOptions()
  opts.lock[signatureOf(i)] = LockEntry(signature: signatureOf(i),
    mpn: "RC0402FR-079K76L", manufacturer: "Yageo")   # 9.76k: no longer fits
  let r = resolveItem(i, opts)
  check not r.locked
  check r.chosen.mpn == "RC0402FR-0710KL"
  check r.issueOf(KindBomLockStale).severity == sevInfo

# --- roll-up and the whole result -------------------------------------------

test "items roll up by part, DNP apart, excluded on no line":
  useFixture()
  var dnp = item(pfResistor, 10e3, "0402", 0.01, "R3")
  dnp.doNotPopulate = true
  var ex = item(pfResistor, 10e3, "0402", 0.01, "R4")
  ex.excluded = true
  let res = resolve(@[item(pfResistor, 10e3, "0402", 0.01, "R1"),
                      item(pfResistor, 10e3, "0402", 0.01, "R2"),
                      dnp, ex, other("U1", mpn = "LM358DR")])
  check res.resolutions.len == 5
  check res.lines.len == 3
  check res.lines[0].designators == @["R1", "R2"]
  check res.lines[0].quantity == 2
  check res.lines[0].mpn == "RC0402FR-0710KL"
  check res.lines[1].designators == @["R3"]
  check res.lines[1].doNotPopulate
  check res.lines[2].mpn == "LM358DR"
  check res.resolutions[3].chosen == nil
  check res.resolutions[3].issueOf(KindBomExcluded).severity == sevInfo

test "unresolved items with one requirement share a line":
  useFixture()
  let res = resolve(@[item(pfResistor, 12345, "0402", designator = "R1"),
                      item(pfResistor, 12345, "0402", designator = "R2")])
  check res.lines.len == 1
  check res.lines[0].quantity == 2
  check res.lines[0].mpn == ""
  check res.worstSeverity == sevError

test "low stock is flagged per line; unknown stock never is":
  useFixture()
  var opts = defaultResolveOptions()
  opts.stockFactor = 100_000                     # 40k in stock < 1 x 100k
  var c = item(pfCapacitor, 22e-9, "0402", tolerance = 0.05, designator = "C1")
  c.dielectric = "C0G"
  var r5 = item(pfResistor, 10e3, "0402", designator = "R1")
  r5.mpn = "RC0402JR-0710KL"                      # stock unknown
  let res = resolve(@[c, r5], opts)
  check res.issues.len == 1
  check res.issues[0].kind == KindBomLowStock
  check "C1" in res.issues[0].message and "40000" in res.issues[0].message
  check KindBomLowStock notin resolve(@[c]).issues.mapIt(it.kind)

test "no registered source is said once, up front":
  clearCatalogSources()
  let res = resolve(@[other("U1", mpn = "LM358DR")])
  check res.issues[0].kind == KindBomNoSources
  check res.allIssues.mapIt(it.kind) ==
    @[KindBomNoSources, KindBomPartNotFound]

test "a re-run is identical":
  useFixture()
  let items = @[item(pfResistor, 10e3, "0402", 0.05),
                item(pfCapacitor, 100e-9, "0402", 0.1, "C1")]
  let a = resolve(items)
  let b = resolve(items)
  for k in 0 ..< a.resolutions.len:
    check a.resolutions[k].chosen.mpn == b.resolutions[k].chosen.mpn
    check a.resolutions[k].alternates.mpns == b.resolutions[k].alternates.mpns

# --- end to end -----------------------------------------------------------------

test "collect then resolve: bom: manufacturers ranks, a part's spec rules":
  useFixture()
  let nl = netlist("b"):
    bom:
      tolerance = 1.pct
      resistor_package = "0402"
      manufacturers = ["Vishay"]
    net a
    net gnd, kind = ntGround, name = "0"
    component R1, kind = "resistor", value = 10.kohm:
      pin "1", a
      pin "2", gnd
    component R2, kind = "resistor", value = 4.7.kohm:
      pin "1", a
      pin "2", gnd
    component U1, kind = "opamp", value = "LM358":
      spec:
        mpn = "LM358DR"
      pin "1", a
      pin "2", gnd
    component V1, kind = "voltage_source", value = "5":
      pin "p", a
      pin "n", gnd
  let res = resolve(collect(nl))
  check res.resolutions.len == 3                 # V1 is not a part
  check res.resolutions[0].chosen.mpn == "CRCW040210K0FKED"   # preferred
  check res.resolutions[1].chosen.mpn == "RC0402FR-074K7L"
  check res.resolutions[2].chosen.mpn == "LM358DR"
  check res.lines.mapIt(it.designators) == @[@["R1"], @["R2"], @["U1"]]
  check res.worstSeverity == sevInfo             # uncommon 4.7k only

test "a description labels the line and is never ordered as a part number":
  useFixture()
  let nl = netlist("b"):
    net a
    net gnd, kind = ntGround, name = "0"
    component J1, kind = "connector", description = "USB-C 2.0 receptacle":
      pin "1", a
      pin "2", gnd
    component U1, kind = "opamp", value = "LM358":
      spec:
        mpn = "LM358DR"
        description = "dual op-amp"
      pin "1", a
      pin "2", gnd
  let items = collect(nl)
  check items[0].description == "USB-C 2.0 receptacle"
  check items[0].partNumber == ""
  let res = resolve(items)
  check res.lines[0].mpn == ""
  check res.lines[0].description == "USB-C 2.0 receptacle"
  check res.resolutions[0].issueOf(KindBomMpnRequired).severity == sevError
  # A catalogue's own description wins; the design's fills a gap only.
  check res.lines[1].description ==
    (if res.resolutions[1].chosen.description.len > 0:
       res.resolutions[1].chosen.description else: "dual op-amp")
