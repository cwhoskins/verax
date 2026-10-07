## Stage 4 of docs/ibis_simulator_plan.md: SI measures. Analytic checks on
## synthetic waveforms, then one end-to-end run on the stage 3a reference
## case (no ngspice, no KiCad).

import std/[streams, unittest, math]

import verax/ibis
import verax/si/simulate
import verax/si/measure
import ./fixtures/ibis/synthetic

proc synth(edge: Edge, delay: float, pts: seq[(float, float)]): SiResult =
  result.status = ssOk
  result.stimulus = edgeStimulus(edge, delay)
  var w = SiWave(label: "U2.1:die")
  for (t, v) in pts:
    result.t.add t
    w.v.add v
  result.receivers = @[w]

proc drv33(): DriverBehaviour =
  driverBehaviour(readIbis(newStringStream(defaultLinearDriver().toIbs())).model("lin_drv"))

let th = Thresholds(vinh: 2.0, vinl: 0.8, present: true)

suite "analytic":
  test "a clean ramp":
    let r = synth(edRising, 1e-9, @[(0.0, 0.0), (1e-9, 0.0), (2e-9, 3.3), (5e-9, 3.3)])
    let m = measure(r, 0, drv33(), th, OvershootLimits(), 1.5e-9)
    check abs(m.flightTimeMin - (1e-9 + 0.8 / 3.3 * 1e-9 - 1.5e-9)) < 1e-15
    check abs(m.flightTimeMax - (1e-9 + 2.0 / 3.3 * 1e-9 - 1.5e-9)) < 1e-15
    check abs(m.overshoot) < 1e-12
    check abs(m.undershoot) < 1e-12
    check abs(m.ringbackMargin - 1.3) < 1e-12
    check m.monotonic
    check abs(m.thresholdMargin - 1.3) < 1e-12
    # Settles when it enters 2 % of the 3.3 V swing below 3.3 V.
    check abs(m.settleTime - (1e-9 + (1 - 0.02) * 1e-9 - 1.5e-9)) < 1e-15

  test "overshoot and ringback into the band":
    let r = synth(edRising, 0.0, @[(0.0, 0.0), (1e-9, 3.6), (2e-9, 1.8), (3e-9, 3.3), (6e-9, 3.3)])
    let m = measure(r, 0, drv33(), th, OvershootLimits(high: 3.5, hasHigh: true), 0.0)
    check abs(m.overshoot - 0.3) < 1e-12
    check abs(m.overshootHighMargin - (-0.1)) < 1e-12
    check m.overshootLowMargin.isNaN
    check abs(m.ringbackMargin - (-0.2)) < 1e-12
    check not m.monotonic
    # Last upward crossing of Vinh is on the recovery from the dip.
    check abs(m.flightTimeMax - (2e-9 + 0.2 / 1.5 * 1e-9)) < 1e-15
    check abs(m.flightTimeMin - 0.8 / 3.6 * 1e-9) < 1e-15

  test "falling edge undershoot against an absolute limit":
    let r = synth(edFalling, 0.0, @[(0.0, 3.3), (1e-9, -0.4), (2e-9, 0.0), (5e-9, 0.0)])
    let m = measure(r, 0, drv33(), th, OvershootLimits(low: -0.3, hasLow: true), 0.0)
    check abs(m.undershoot - 0.4) < 1e-12
    check abs(m.overshootLowMargin - (-0.1)) < 1e-12
    check abs(m.thresholdMargin - 0.8) < 1e-12
    check m.monotonic

  test "never switching is NaN with a reason, not zero":
    let r = synth(edRising, 0.0, @[(0.0, 0.0), (1e-9, 1.5), (5e-9, 1.5)])
    let m = measure(r, 0, drv33(), th, OvershootLimits(), 0.0)
    check m.flightTimeMax.isNaN
    check m.notes.len > 0
    check abs(m.thresholdMargin - (-0.5)) < 1e-12

  test "no thresholds, no timing reference":
    let r = synth(edRising, 0.0, @[(0.0, 0.0), (1e-9, 3.3), (5e-9, 3.3)])
    let m = measure(r, 0, drv33(), Thresholds(), OvershootLimits(), NaN)
    check m.flightTimeMin.isNaN
    check m.notes.len > 0
    let m2 = measure(r, 0, drv33(), th, OvershootLimits(), NaN)
    check m2.flightTimeMax.isNaN
    check not m2.ringbackMargin.isNaN

suite "end to end on the reference case":
  test "timing load, flight time and the rest, deterministic":
    var d = defaultLinearDriver()
    d.cComp = 2e-12
    d.samples = 201
    d.extraModelLines = "Vmeas = 1.65\nRref = 50\nVref = 0\nCref = 0\n"
    let b = driverBehaviour(readIbis(newStringStream(d.toIbs())).model(d.name))
    check b.timing.hasVmeas
    let rx = receiverBehaviour(readIbis(newStringStream(linearReceiverIbs())).model("lin_rx"))
    let pkg = PackageRlc(r: 0.2, l: 2e-9, c: 0.5e-12)
    let t = SiTemplate(name: "ref", driver: b, topology: ttPointToPoint,
                       driverPort: TemplatePort(label: "U1.1", pkg: pkg),
                       receivers: @[rx], receiverPorts: @[TemplatePort(label: "U2.1", pkg: pkg)],
                       line: idealLine(50.0, 1.0))
    let stim = edgeStimulus(edRising, 0.5e-9)
    let r = simulate(t.build(TemplateParams(length: 2e-9)), stim)
    check r.status == ssOk
    let (tRef, why, note) = timingReference(b, stim)
    check why == ""
    check note.detail.len > 0
    # Into 50 ohm to ground the pad reaches 1.65 V partway up the ramp.
    check tRef > 0.5e-9 and tRef < 1.5e-9
    let m = measure(r, 0, b, rx.thresholds, rx.overshoot, tRef)
    # Flight time is about the line delay (2 ns), give or take the package
    # and the different load.
    check m.flightTimeMin > 1.0e-9 and m.flightTimeMin < 3.0e-9
    check m.flightTimeMax >= m.flightTimeMin
    check m.overshoot > 0.0          # open, mismatched: it overshoots
    check not m.settleTime.isNaN
    let r2 = simulate(t.build(TemplateParams(length: 2e-9)), stim)
    let m2 = measure(r2, 0, b, rx.thresholds, rx.overshoot, tRef)
    check m2.flightTimeMax == m.flightTimeMax
    check m2.overshoot == m.overshoot
