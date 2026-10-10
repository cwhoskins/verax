## Stage 7 of docs/ibis_simulator_plan.md: corner x stimulus x receiver
## sweeps with a worst-case report (`si/sweep`), pattern measures
## (`measure.measurePattern`), and stage 5's `judge` on the same runs.

import std/[streams, unittest, math, strutils, times, monotimes]

import verax/ibis
import verax/si/simulate
import verax/si/measure
import verax/si/sweep
import verax/si/constrain
import ./fixtures/ibis/synthetic

proc thevenin(r = 50.0): LinearDriver =
  result = defaultLinearDriver()
  result.rpu = r
  result.rpd = r

proc drvB(d: LinearDriver): DriverBehaviour =
  driverBehaviour(readIbis(newStringStream(d.toIbs())).model(d.name))

proc rxB(cComp = 0.0): ReceiverBehaviour =
  receiverBehaviour(readIbis(newStringStream(linearReceiverIbs(cComp = cComp))).model("lin_rx"))

proc p2p(d: DriverBehaviour, rxC: float, line: LineSection, length: float,
         parallelR = 0.0): SiNet =
  var t = SiTemplate(name: "p", driver: d, topology: ttPointToPoint,
                     driverPort: TemplatePort(label: "U1.1"), line: line)
  t.receivers.add rxB(rxC)
  t.receiverPorts.add TemplatePort(label: "U2.1")
  t.build(TemplateParams(length: length, parallelR: parallelR))

proc typOnly(net: SiNet): seq[SweepCorner] = @[SweepCorner(corner: coTyp, net: net)]

suite "stimuli":
  test "edges always, patterns only with a UI":
    check sweepStimuli(NaN).len == 2
    check sweepStimuli(0.0).len == 2
    let s = sweepStimuli(5e-9)
    check s.len == 2 + isiPatterns.len
    check s[2].kind == skPattern and s[2].ui == 5e-9
    check sweepStimuli(5e-9, edges = {edRising}).len == 1 + isiPatterns.len

suite "settled levels":
  test "the DC point at the end of each edge's table: a divider into 50 ohm":
    let net = p2p(drvB(thevenin()), 0.0, idealLine(50.0, 6e-9), 0.05, parallelR = 50.0)
    let lv = settledLevels(net)
    check abs(lv[0][edRising] - 3.3 * 50.0 / 100.0) < 1e-6
    check abs(lv[0][edFalling]) < 1e-6

suite "pattern measures":
  test "one window per transition, ending at the next one (or the pattern's end)":
    let d = drvB(thevenin())
    let net = p2p(d, 0.0, idealLine(50.0, 6e-9), 0.05, parallelR = 50.0)
    let r = simulate(net, patternStimulus("0110", 5e-9, 0.5e-9))
    check r.status == ssOk
    let es = measurePattern(r, 0, d, net.receivers[0].thresholds, net.receivers[0].overshoot,
                            [NaN, NaN], [1.65, 0.0])
    check es.len == 2
    check es[0].edge == edRising and es[0].index == 1
    check abs(es[0].t0 - 5.5e-9) < 1e-15 and abs(es[0].t1 - 15.5e-9) < 1e-15
    check es[1].edge == edFalling and abs(es[1].t1 - 20.5e-9) < 1e-15
    check r.t[^1] >= 20.5e-9 - 1e-15   # the run lasts the pattern's last bit

suite "sweep":
  # A 50 ohm Thevenin source into a 100 pF receiver: RC = 5 ns. A 3 ns UI
  # leaves an isolated one well short of Vinh = 2.0 V.
  let d = drvB(thevenin())
  let slow = p2p(d, 100e-12, idealLine(50.0, 6e-9), 0.01)

  test "ISI: a single edge passes, the isolated bit does not reach its threshold":
    let sw = sweepNet(typOnly(slow), sweepStimuli(3e-9))
    check sw.status == ssOk
    # Closed form: a 1 ns ramp (T) into RC (tau = 50 ohm x 100.5 pF with
    # C_pkg), read at the bit's end t = UI: the fraction of the swing
    # covered is 1 - (tau/T)(e^-(t-T)/tau - e^-t/tau). The isolated zero
    # (from high) is the worst; the isolated one is its mirror.
    let tau = 50.0 * 100.5e-12
    let frac = 1.0 - tau / 1e-9 * (exp(-(3e-9 - 1e-9) / tau) - exp(-3e-9 / tau))
    let w = sw.worst[0][sfThresholdMargin]
    check abs(w.value - (0.8 - 3.3 * (1 - frac))) < 0.05
    check "pattern 1011" in w.at and "bit 1 falling" in w.at
    var one = NaN
    for me in sw.measured:
      if "pattern 0100" in me.run and "bit 1 rising" in me.run: one = me.m.thresholdMargin
    check abs(one - (3.3 * frac - 2.0)) < 0.05
    let single = sweepNet(typOnly(slow), sweepStimuli(NaN))
    check single.worst[0][sfThresholdMargin].value > 0.5
    var skipped = false
    for r in sw.runs:
      if r.skipped: skipped = true
    check not skipped

  test "a pattern is skipped (and says so) when every edge settles in the UI":
    let fast = p2p(d, 0.0, idealLine(50.0, 6e-9), 0.05, parallelR = 50.0)
    let sw = sweepNet(typOnly(fast), sweepStimuli(20e-9))
    check sw.status == ssOk
    var skipped = 0
    for r in sw.runs:
      if r.skipped: inc skipped
    check skipped == isiPatterns.len
    var said = false
    for a in sw.assumptions:
      if "not run" in $a: said = true
    check said
    var o = defaultSweepOptions()
    o.skipSettledPatterns = false
    let all = sweepNet(typOnly(fast), sweepStimuli(20e-9), o)
    for f in [sfOvershoot, sfUndershoot, sfThresholdMargin]:
      check abs(all.worst[0][f].value - sw.worst[0][f].value) < 0.02 * 3.3

  test "a ringing edge's run is lengthened until it settles":
    # 5 ohm source into an open 1 ns line: source reflection -0.82, a
    # ~40 ns ring-down, far past the automatic run length.
    let ring = p2p(drvB(thevenin(5.0)), 0.0, idealLine(50.0, 1.0), 1e-9)
    let sw = sweepNet(typOnly(ring), sweepStimuli(NaN))
    check sw.status == ssOk
    check sw.runs[0].extended >= 1
    let st = sw.worst[0][sfSettleTime].value
    check st > 15e-9 and st < Inf
    # Without the exact level, the old reading settled around a still
    # ringing last sample and came out far shorter.
    let r = simulate(ring, edgeStimulus(edRising, 0.5e-9))
    let naive = measure(r, 0, ring.driver, ring.receivers[0].thresholds,
                        ring.receivers[0].overshoot, NaN)
    check naive.settleTime.isNaN or naive.settleTime < st

  test "an unsupported corner decides the status, named":
    var bad = slow
    bad.unsupported = @["test: no model"]
    let sw = sweepNet(@[SweepCorner(corner: coTyp, net: slow), SweepCorner(corner: coMin, net: bad)],
                      sweepStimuli(NaN))
    check sw.status == ssUnsupported
    check sw.reason.startsWith("min ")

  test "the report names every receiver and the worst run":
    let txt = renderText(sweepNet(typOnly(slow), sweepStimuli(3e-9)))
    check "U2.1" in txt
    check "threshold margin" in txt
    check "worst at typ pattern 0100" in txt

suite "3 corners x 3 receivers (the stage 7 exit)":
  const full = """
[IBIS Ver] 3.2
[Component] C
[Pin] signal_name model_name
1 OUT drv
[Model] drv
Model_type Output
C_comp 1p 0.8p 1.2p
Vmeas = 1.65
Rref = 50
[Voltage Range] 3.3 3.0 3.6
[Pulldown]
-3.3 -0.066 -0.06  -0.072
 6.6  0.132  0.12   0.144
[Pullup]
-3.3  0.066  0.06   0.072
 6.6 -0.132 -0.12  -0.144
[Ramp]
dV/dt_r 1.98/0.6n 1.8/0.9n 2.16/0.3n
dV/dt_f 1.98/0.6n 1.8/0.9n 2.16/0.3n
[End Model]
[End]
"""
  let m = readIbis(newStringStream(full)).model("drv")
  let pkg = PackageRlc(r: 0.2, l: 2e-9, c: 0.5e-12)
  proc chain(c: Corner): SiNet =
    var t = SiTemplate(name: "bus", driver: driverBehaviour(m, c), topology: ttDaisyChain,
                       driverPort: TemplatePort(label: "U1.1", pkg: pkg),
                       line: idealLine(50.0, 6.67e-9))
    for k in 0 ..< 3:
      t.receivers.add rxB(2e-12)
      t.receiverPorts.add TemplatePort(label: "U" & $(k + 2) & ".1", pkg: pkg)
    t.build(templateParams(0.15, stubLength = 0.01))

  test "every corner and receiver, worst named, in interactive time":
    var cs: seq[SweepCorner]
    for c in [coTyp, coMin, coMax]: cs.add SweepCorner(corner: c, net: chain(c))
    let t0 = getMonoTime()
    let sw = sweepNet(cs, sweepStimuli(10e-9))
    let ms = (getMonoTime() - t0).inMilliseconds
    check sw.status == ssOk
    check sw.corners == @[coTyp, coMin, coMax]
    check sw.receivers.len == 3
    for k in 0 ..< 3:
      for f in figuresFor(sw.probes[k]):
        let w = sw.worst[k][f]
        check w.undefined.len > 0 or w.at.len > 0
    # The worst overshoot is at the fastest, highest-rail corner.
    check sw.worst[2][sfOvershoot].at.startsWith("max")
    checkpoint "3x3 sweep: " & $ms & " ms"
    check ms < 2000   # generous: a debug build on a slow CI box

suite "judge on the sweep (stage 5)":
  test "a UI in the criteria makes ISI a failure, named":
    let t = SiTemplate(name: "slow", driver: drvB(thevenin()), topology: ttPointToPoint,
                       driverPort: TemplatePort(label: "U1.1"), line: idealLine(50.0, 6e-9),
                       receivers: @[rxB(100e-12)], receiverPorts: @[TemplatePort(label: "U2.1")])
    var c = defaultCriteria()
    check judge([t], templateParams(0.01), c).verdict == vPass
    c.ui = 3e-9
    let p = judge([t], templateParams(0.01), c)
    check p.verdict == vFail
    check "pattern 0100" in p.failures[0]
    check "ISI pattern" in $c
