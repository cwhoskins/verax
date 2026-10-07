## Stage 5 of docs/ibis_simulator_plan.md: constraint derivation. Exit
## criteria: a closed-form max length found to bisection tolerance, a
## deliberately non-monotonic case returning two intervals, a stub verdict
## that flips across the resonance; plus the report, its identity and the
## KiCad rules it emits.

import std/[streams, unittest, math, strutils, json]

import verax/ibis
import verax/pcb/via
import verax/si/simulate
import verax/si/constrain
import ./fixtures/ibis/synthetic

proc behaviour(d: LinearDriver): DriverBehaviour =
  driverBehaviour(readIbis(newStringStream(d.toIbs())).model(d.name))

proc rx(cComp = 0.0): ReceiverBehaviour =
  receiverBehaviour(readIbis(newStringStream(linearReceiverIbs(cComp = cComp))).model("lin_rx"))

proc p2p(d: LinearDriver, rxC = 0.0, tdPerM = 6e-9): SiTemplate =
  SiTemplate(name: "p2p", driver: behaviour(d), topology: ttPointToPoint,
             driverPort: TemplatePort(label: "U1.1"),
             receivers: @[rx(rxC)], receiverPorts: @[TemplatePort(label: "U2.1")],
             line: idealLine(50.0, tdPerM))

suite "closed form":
  test "max length under a flight-time budget":
    # Thevenin 50 ohm source into an open line: the receiver sees
    # Vcc*Ku(t - td). Timing load 50 ohm to 0 V at Vmeas = Vcc/4 crosses at
    # Ku = 1/2 (0.5 ns into the 1 ns ramp). Falling binds: the receiver
    # crosses Vinl = 0.8 V at Ku = 0.8/3.3, i.e. (1 - 0.8/3.3) ns in.
    var d = defaultLinearDriver()
    d.rpu = 50; d.rpd = 50
    d.extraModelLines = "Vmeas = 0.825\nRref = 50\nVref = 0\n"
    let t = p2p(d)
    let tdPerM = 6e-9
    let lStar = 0.1
    var c = defaultCriteria()
    c.maxFlightTime = lStar * tdPerM + (1.0 - 0.8 / 3.3) * 1e-9 - 0.5e-9
    let s = sweep([t], templateParams(0.0), spLength, 0.0, 0.3, 7, c, 1e-4)
    check s.passing.len == 1
    check s.passing[0].lo == 0.0
    check abs(s.maxFromStart - lStar) < 2e-4
    check "flight time" in s.binding
    check "falling" in s.binding
    check s.gaps.len == 0

suite "non-monotonic":
  test "ringback against length comes back as two intervals":
    # A via with a fixed 0.2 ns stub midway: the stub and far-end
    # reflections interfere, so the ringback margin dips, recovers, then
    # falls for good as the line grows.
    var d = defaultLinearDriver()
    d.rpu = 25; d.rpd = 25
    d.tEdge = 0.5e-9
    d.tEnd = 1e-9
    var t = p2p(d, rxC = 2e-12, tdPerM = 6.67e-9)
    t.hasVia = true
    t.via = ViaModel(stubBottom: 1.0, stubZ0: 50.0, stubTdPerM: 0.2e-9)
    var c = defaultCriteria()
    c.edges = {edRising}
    c.requireMonotonic = false
    c.minRingbackMargin = 1.12
    let s = sweep([t], templateParams(0.0, viaCount = 1), spLength, 0.0, 0.06, 13, c, 2e-4)
    check s.passing.len == 2
    check s.passing[0].lo == 0.0
    check s.passing[0].hi < s.passing[1].lo
    check s.maxFromStart < 0.03
    check "ringback" in s.binding

suite "stubs":
  proc stubTemplate(): SiTemplate =
    var d = defaultLinearDriver()
    d.rpu = 50; d.rpd = 50
    d.tEdge = 0.5e-9
    d.tEnd = 1e-9
    result = p2p(d, rxC = 1e-12, tdPerM = 6.67e-9)
    result.hasVia = true
    result.via = ViaModel(stubBottom: 0.0, stubZ0: 50.0, stubTdPerM: 6.67e-9)

  test "the verdict flips across the stub's resonance":
    let t = stubTemplate()
    let c = defaultCriteria()
    let short = judge([t], templateParams(0.1, viaCount = 1, viaStub = 0.02), c)
    let long = judge([t], templateParams(0.1, viaCount = 1, viaStub = 0.08), c)
    check short.verdict == vPass
    check long.verdict == vFail
    # The flip sits where the stub's quarter-wave resonance drops toward the
    # edge's knee (0.35 / tr): within a factor of two of the rule of thumb.
    let vs = stubRemoval([t], templateParams(0.1, viaCount = 1),
                         [("L1-L3", 0.02), ("L1-L6", 0.07)], 9, c, 5e-4)
    check vs[0].answer == "backdrill not needed"
    check vs[1].answer.startsWith("backdrill needed")
    let tr = 0.8 * 0.5e-9
    let fKnee = 0.35 / tr
    let fFlip = stubResonance(vs[0].maxPassingStub, 6.67e-9)
    check fFlip > fKnee / 2 and fFlip < fKnee * 2

  test "a stub that fails even at zero says avoid the transition":
    var t = stubTemplate()
    var c = defaultCriteria()
    c.maxFlightTime = 1e-12      # impossible
    c.edges = {edRising}
    var d = defaultLinearDriver()
    d.extraModelLines = "Vmeas = 0.825\nRref = 50\nVref = 0\n"
    d.rpu = 50; d.rpd = 50
    t.driver = behaviour(d)
    let vs = stubRemoval([t], templateParams(0.1, viaCount = 1), [("L1-L6", 0.05)], 3, c, 1e-3)
    check vs[0].answer.startsWith("avoid")

suite "trade-off tables":
  test "via count and series termination":
    var d = defaultLinearDriver()
    d.rpu = 10; d.rpd = 10
    d.tEdge = 0.5e-9
    d.tEnd = 1e-9
    var t = p2p(d, rxC = 2e-12)
    t.hasVia = true
    t.via = viaModel(ViaGeometry(drillDia: 0.3e-3, padDia: 0.6e-3, antipadDia: 1.0e-3,
                                 barrelLength: 1.6e-3, er: 4.3, exitDepth: 0.4e-3,
                                 backdrillResidual: -1, entryRef: "GND", exitRef: "GND"))
    var c = defaultCriteria()
    c.edges = {edRising}
    let vt = viaTable([t], templateParams(0.0), [0, 2], 0.0, 0.2, 5, c, 2e-3)
    check vt.len == 2
    check vt[0].vias == 0
    let tt = terminationTable([t], templateParams(0.0), [0.0, 39.0], 0.0, 0.3, 7, c, 2e-3)
    check tt.rows.len == 2
    # A 10 ohm driver into 50 ohm rings back; 39 ohm series (10 + 39 ~ Z0)
    # source-terminates it.
    check tt.best == 39.0
    check tt.rows[0].s.maxFromStart < 0.1
    check tt.rows[1].s.maxFromStart == 0.3

suite "invalid points are gaps, not failures":
  test "a solver failure leaves an unexamined gap":
    var d = defaultLinearDriver()
    d.modelType = "3-state"
    d.rgc = 50.0
    let t = p2p(d)
    var so = defaultSiOptions()
    so.newton.maxIter = 1
    let s = sweep([t], templateParams(0.0), spLength, 0.0, 0.1, 3, defaultCriteria(), 1e-3, so)
    check s.passing.len == 0
    check s.gaps.len == 1
    check s.binding == ""

suite "report":
  test "identity, text, JSON and KiCad rules":
    var d = defaultLinearDriver()
    d.rpu = 50; d.rpd = 50
    d.extraModelLines = "Vmeas = 0.825\nRref = 50\nVref = 0\n"
    let t = p2p(d)
    var c = defaultCriteria()
    c.maxFlightTime = 0.6e-9 + (1.0 - 0.8 / 3.3) * 1e-9 - 0.5e-9
    let base = templateParams(0.0)
    var r = ConstraintReport(net: "SPI_SCK", identity: identity(t, [coTyp], base, c),
                             hasLength: true, bestSeriesR: NaN)
    r.length = sweep([t], base, spLength, 0.0, 0.3, 7, c, 1e-4)
    r.criticalLength = criticalLength(t.driver.edges[edRising].riseTime, 6e-9)
    let txt = renderText(r)
    check "SI constraints for net SPI_SCK" in txt
    check "length passes: 0.000..100." in txt
    check "binding failure: flight time" in txt
    check "critical length" in txt
    check "corners run: typ" in txt
    check "closed-form" in txt
    let j = renderJson(r)
    check j["schema"].getStr == "verax.si_constraints/1"
    check j["length"]["passing"].len == 1
    check abs(j["length"]["passing"][0][1].getFloat - 0.1) < 2e-4
    check j["identity"]["corners"][0].getStr == "typ"
    let rules = druRules(r, "SPI_SCK", 0)
    check rules.len == 2
    check abs(rules[0].maxLength - 0.1) < 2e-4
    check rules[1].maxViaCount == 0
    let dru = renderDru(rules)
    check "(constraint length (max 100." in dru
    check "A.NetName == 'SPI_SCK'" in dru
