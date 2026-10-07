## Stage 1 of docs/ibis_simulator_plan.md: `ibis/behave`, the interpretation
## layer. Linear-table fixtures make every expected number closed-form.

import std/[streams, unittest, math, strutils]

import verax/ibis
import verax/ibis/behave
import ./fixtures/ibis/synthetic

proc model(d: LinearDriver): IbisModel =
  readIbis(newStringStream(d.toIbs())).model(d.name)

proc hasIssue(xs: seq[Issue], kind: string): bool =
  for i in xs:
    if i.kind == kind: return true

suite "conventions":
  test "tables become absolute pad voltage, current out of the die":
    let b = driverBehaviour(defaultLinearDriver().model)
    check b.supported
    # Pulldown 20 ohm to ground: out-of-die current at 1 V is -50 mA.
    check abs(b.pulldown.eval(1.0).i - (-0.05)) < 1e-12
    # Pullup 25 ohm to 3.3 V: at 1 V it sources (3.3-1)/25 out of the die.
    check abs(b.pullup.eval(1.0).i - 2.3 / 25.0) < 1e-12
    check abs(b.pullup.eval(3.3).i) < 1e-12
    # Voltages ascending after the Vcc-relative flip.
    for k in 1 ..< b.pullup.v.len: check b.pullup.v[k] > b.pullup.v[k - 1]

  test "end segments extend linearly, not flat":
    let b = driverBehaviour(defaultLinearDriver().model)
    # Table spans -3.3 .. 6.6 V; at 10 V the resistor law still holds.
    check abs(b.pulldown.eval(10.0).i - (-0.5)) < 1e-12
    check abs(b.pulldown.eval(10.0).g - (-1.0 / 20.0)) < 1e-12

  test "a receiver with no stimulus cannot act as a driver":
    let m = readIbis(newStringStream(linearReceiverIbs(rgc = 1000.0, rpc = 1000.0))).model("lin_rx")
    let r = receiverBehaviour(m)
    check r.supported
    # Clamps are leaks to their rails: at mid-rail they cancel exactly, and
    # pulling the pad up makes it *sink* (negative out-of-die) current.
    check abs(r.receiverCurrent(1.65).i) < 1e-12
    check r.receiverCurrent(2.0).i < 0.0
    check r.receiverCurrent(1.0).i > 0.0
    check r.receiverCurrent(2.0).g < 0.0

suite "Ku/Kd extraction":
  test "linear tables give exact coefficients at every knot":
    let d = defaultLinearDriver()
    let b = driverBehaviour(d.model)
    for e in Edge:
      let k = b.edges[e]
      check k.source == ksWaveforms
      check k.available
      check k.waveformsUsed == @[0, 1]
      for i, t in k.t:
        let (ku, kd) = d.kAt(e == edRising, t)
        check abs(k.ku[i] - ku) < 1e-9
        check abs(k.kd[i] - kd) < 1e-9
      check k.residualV < 1e-9
      check k.residualI < 1e-9

  test "C_comp is part of the equation, not absorbed into Ku/Kd":
    var d = defaultLinearDriver()
    d.cComp = 5e-12
    d.samples = 201
    let b = driverBehaviour(d.model)
    let k = b.edges[edRising]
    check k.source == ksWaveforms
    check k.available
    var worst = 0.0
    for i, t in k.t:
      # Away from the ramp corners (where the knot slope rule averages).
      if abs(t - d.tEdge) < 3 * d.tEnd / 200 or t < 3 * d.tEnd / 200: continue
      let (ku, kd) = d.kAt(true, t)
      worst = max(worst, max(abs(k.ku[i] - ku), abs(k.kd[i] - kd)))
    check worst < 0.01
    # Dropping C_comp from the extraction would leave a visible error:
    var d2 = d
    d2.extraModelLines = ""
    let m = d.model
    var mNoC = m
    mNoC.cComp = newTriplet()
    mNoC.cComp.set(coTyp, 0.0)
    let bad = driverBehaviour(mNoC).edges[edRising]
    var worstBad = 0.0
    for i, t in bad.t:
      if t < 3 * d.tEnd / 200: continue
      let (ku, kd) = d.kAt(true, t)
      worstBad = max(worstBad, max(abs(bad.ku[i] - ku), abs(bad.kd[i] - kd)))
    check worstBad > 10 * worst

  test "the ramp fallback matches its closed form":
    var d = defaultLinearDriver()
    d.withWaveforms = false
    let b = driverBehaviour(d.model)
    let k = b.edges[edRising]
    check k.source == ksRamp
    check k.available
    check k.t == @[0.0, 0.6e-9 / 0.6]
    check k.ku == @[0.0, 1.0]
    check k.kd == @[1.0, 0.0]
    check b.edges[edFalling].ku == @[1.0, 0.0]
    check b.assumptions.len == 2
    check "Ramp" in $b.assumptions[0]

  test "one usable waveform with two unknowns falls back to the ramp":
    var d = defaultLinearDriver()
    d.fixtures = @[(50.0, 0.0, 0.0)]
    let b = driverBehaviour(d.model)
    check b.edges[edRising].source == ksRamp

  test "open drain: one unknown, one waveform suffices":
    var d = defaultLinearDriver()
    d.modelType = "Open_drain"
    d.rpu = 0.0
    d.fixtures = @[(50.0, 3.3, 0.0)]
    let b = driverBehaviour(d.model)
    check b.supported
    check not b.hasPullup
    let k = b.edges[edFalling]
    check k.source == ksWaveforms
    for i, t in k.t:
      check abs(k.kd[i] - d.kAt(false, t).kd) < 1e-9
      check k.ku[i] == 0.0

  test "three fixtures: least squares, residual kept":
    var d = defaultLinearDriver()
    d.fixtures.add (100.0, 1.65, 0.0)
    let k = driverBehaviour(d.model).edges[edRising]
    check k.waveformsUsed.len == 3
    check k.lsResidual < 1e-9
    check k.available

  test "clamps are counted once (double-counted tables are caught)":
    var d = defaultLinearDriver()
    d.modelType = "3-state"
    d.rgc = 200.0
    d.rpc = 300.0
    let good = driverBehaviour(d.model)
    for i, t in good.edges[edRising].t:
      check abs(good.edges[edRising].ku[i] - d.kAt(true, t).ku) < 1e-9
    # The same waveforms, but with the clamp current also folded into the
    # pullup/pulldown tables: the clamps now count twice and the steady
    # state no longer lands on Ku = 1, Kd = 0.
    var dd = d
    dd.clampsInTables = true
    let twice = driverBehaviour(dd.model).edges[edRising]
    let kuEnd = twice.ku[^1]
    let kdEnd = twice.kd[^1]
    check abs(kuEnd - 1.0) > 0.05 or abs(kdEnd) > 0.05

suite "classification":
  test "unsupported fixture parasitic: reported, not used":
    var d = defaultLinearDriver()
    d.extraFixtureLines = "L_fixture = 2nH\n"
    let b = driverBehaviour(d.model)
    check b.issues.hasIssue("ibis_waveform_unsupported")
    var named = false
    for i in b.issues:
      if "L_fixture" in i.message: named = true
    check named
    check b.edges[edRising].source == ksRamp

  test "absent corner without a policy is unsupported, naming the field":
    let m = readIbis(newStringStream(incompleteCornersIbs)).model("drv")
    check driverBehaviour(m, coTyp).supported
    let mn = driverBehaviour(m, coMin)
    check not mn.supported
    check "C_comp" in mn.reason
    let mx = driverBehaviour(m, coMax)
    check not mx.supported
    check "[Pulldown]" in mx.reason

  test "model-type gating":
    let f = readIbis(newStringStream(selectorIbs))
    check not driverBehaviour(f.model("rx_only")).supported
    check receiverBehaviour(f.model("rx_only")).supported
    check driverBehaviour(f.model("io_fast")).supported
    check receiverBehaviour(f.model("io_fast")).supported
    var d = defaultLinearDriver()
    d.modelType = "Series"
    check not driverBehaviour(d.model).supported
    check not receiverBehaviour(defaultLinearDriver().model).supported

  test "singular fixtures are rejected, not solved":
    var d = defaultLinearDriver()
    d.fixtures = @[(50.0, 0.0, 0.0), (50.0, 0.0, 0.0)]
    let b = driverBehaviour(d.model)
    check b.issues.hasIssue("ibis_waveform_ill_conditioned")
    check b.edges[edRising].source == ksRamp

  test "inconsistent waveforms: out-of-range warning and unavailability":
    var d = defaultLinearDriver()
    let good = d.model
    # Tables say 20/25 ohm; the waveforms were drawn from a much weaker
    # buffer. The extracted coefficients must leave [0, 1] and the edge
    # must fail reconstruction... except that with exact 2x2 solves the
    # fixtures reconstruct by construction. So add a third fixture that
    # disagrees, which least squares cannot absorb.
    var weak = d
    weak.rpu = 60.0
    weak.rpd = 50.0
    weak.fixtures = @[(100.0, 1.65, 0.0)]
    let wm = readIbis(newStringStream(weak.toIbs())).model(weak.name)
    var m = good
    m.risingWaveforms.add wm.risingWaveforms[0]
    let k = driverBehaviour(m).edges[edRising]
    check k.waveformsUsed.len == 3
    check k.lsResidual > 1e-4
    check not k.available
    # And a scaled-down table set makes Ku exceed 1:
    var strong = d
    strong.rpu = 250.0
    strong.rpd = 200.0
    var ms = readIbis(newStringStream(strong.toIbs())).model(strong.name)
    ms.risingWaveforms = good.risingWaveforms
    let b2 = driverBehaviour(ms)
    check b2.issues.hasIssue("ibis_coefficient_out_of_range")

  test "repeated timestamps reject that waveform":
    var m = defaultLinearDriver().model
    m.risingWaveforms[0].points[3].t = m.risingWaveforms[0].points[2].t
    let b = driverBehaviour(m)
    check b.issues.hasIssue("ibis_waveform_unsupported")
    check b.edges[edRising].source == ksRamp

  test "[Model Spec] overrides [Model] thresholds; NA min is typ by rule":
    let spec = "Vinh 2.1 NA NA\nVinl 0.7 0.6 NA\nS_overshoot_high 4.0 NA NA\n"
    let m = readIbis(newStringStream(linearReceiverIbs(modelSpec = spec))).model("lin_rx")
    let r = receiverBehaviour(m)
    check abs(r.thresholds.vinh - 2.1) < 1e-12
    check abs(r.thresholds.vinl - 0.7) < 1e-12
    check r.overshoot.hasHigh and not r.overshoot.hasLow
    # Min corner: Vinh NA -> typ (the spec's rule, recorded).
    var mm = m
    mm.cComp.set(coMin, 2e-12)
    mm.voltageRange.set(coMin, 3.0)
    let rmin = receiverBehaviour(mm, coMin)
    check rmin.supported
    check abs(rmin.thresholds.vinh - 2.1) < 1e-12
    check abs(rmin.thresholds.vinl - 0.6) < 1e-12
    check rmin.substitutions.len >= 1

  test "rise time of a coefficient series":
    let b = driverBehaviour(defaultLinearDriver().model)
    check abs(b.edges[edRising].riseTime - 0.8e-9) < 1e-15
