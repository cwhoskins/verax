## Stage 3a of docs/ibis_simulator_plan.md: the reference-case gate. One
## Output driver, one Input receiver, one uniform lossless line, package
## R/L/C, C_comp, one edge, typ corner -- plus rungs 3 (linear driver into a
## resistor) and 4 (reconstruction) of the validation ladder.

import std/[streams, unittest, math]

import verax/ibis
import verax/si/simulate
import ./fixtures/ibis/synthetic

proc drvModel(d: LinearDriver): IbisModel =
  readIbis(newStringStream(d.toIbs())).model(d.name)

proc zeroPkg(): PackageRlc = PackageRlc()

proc at(t, v: seq[float], tq: float): float =
  for k in 0 ..< t.len - 1:
    if tq >= t[k] and tq <= t[k + 1]:
      return v[k] + (v[k + 1] - v[k]) * (tq - t[k]) / (t[k + 1] - t[k])
  v[^1]

suite "rung 3: linear-table driver into a resistor":
  test "resistive divider with the analytic ramp, voltage and current":
    let d = defaultLinearDriver()
    let b = driverBehaviour(d.drvModel)
    var n = newSiNet("divider")
    n.setDriver("U1.1", b, zeroPkg())
    n.addResistor(n.driverPort.pinNode, 0, 75.0, "load")
    var o = defaultSiOptions()
    o.tStop = 3e-9
    let r = simulate(n, edgeStimulus(edRising, 0.5e-9), o)
    check r.status == ssOk
    var worstV, worstI = 0.0
    for k, t in r.t:
      let (ku, kd) = d.kAt(true, t - 0.5e-9)
      let g = ku / d.rpu + kd / d.rpd + 1.0 / 75.0
      let v = ku * d.vcc / d.rpu / g
      worstV = max(worstV, abs(r.driverPin.v[k] - v))
      worstI = max(worstI, abs(r.driver.i[k] - v / 75.0))
    check worstV < 1e-6
    check worstI < 1e-7

suite "rung 4: reconstruction (internal consistency)":
  test "the model driving its own fixture reproduces its V/T tables":
    var d = defaultLinearDriver()
    d.cComp = 3e-12
    d.samples = 201
    d.fixtures = @[(50.0, 0.0, 0.0), (50.0, 3.3, 0.0)]
    let m = d.drvModel
    let b = driverBehaviour(m)
    check b.edges[edRising].source == ksWaveforms
    for e in Edge:
      for wi, w in (if e == edRising: m.risingWaveforms else: m.fallingWaveforms):
        var n = newSiNet("fixture")
        n.setDriver("U1.1", b, zeroPkg())
        let vf = n.addNode("vfix")
        n.addResistor(n.driverPort.pinNode, vf, w.rFixture, "R_fixture")
        n.addSource(vf, 0, w.vFixture.get(coTyp), "V_fixture")
        var o = defaultSiOptions()
        o.tStop = d.tEnd
        let r = simulate(n, edgeStimulus(e), o)
        check r.status == ssOk
        var worstV, worstI = 0.0
        for p in w.points:
          let vs = at(r.t, r.driverPin.v, p.t)
          let vt = p.v.get(coTyp)
          worstV = max(worstV, abs(vs - vt))
          # Fixture current from the simulated pad vs from the table.
          worstI = max(worstI, abs((vs - vt) / w.rFixture))
        check worstV < 0.02 * d.vcc
        check worstI < 0.02 * d.vcc / w.rFixture

suite "reference case":
  proc refNet(d: LinearDriver, rxCComp = 2e-12, z0 = 50.0, td = 2e-9,
              pkg = PackageRlc(r: 0.2, l: 2e-9, c: 0.5e-12)): SiNet =
    let b = driverBehaviour(d.drvModel)
    let rx = receiverBehaviour(readIbis(newStringStream(
      linearReceiverIbs(cComp = rxCComp))).model("lin_rx"))
    var t = SiTemplate(name: "ref", driver: b, topology: ttPointToPoint,
                       driverPort: TemplatePort(label: "U1.1", pkg: pkg),
                       receivers: @[rx],
                       receiverPorts: @[TemplatePort(label: "U2.1", pkg: pkg)],
                       line: idealLine(z0, 1.0))
    t.build(TemplateParams(length: td))

  test "open line, ideal ports: the lattice diagram with an algebraic source":
    # No package, no C_comp, no clamps: the near end solves the driver
    # equation against Z0, the far end doubles it one td later.
    var d = defaultLinearDriver()
    let td = 2e-9
    let n = refNet(d, rxCComp = 0.0, td = td, pkg = PackageRlc())
    proc vInc(t: float): float =
      let (ku, kd) = d.kAt(true, t)
      ku * d.vcc / d.rpu / (ku / d.rpu + kd / d.rpd + 1.0 / 50.0)
    var worsts: seq[float]
    var hb = Inf
    for pass in 0 .. 1:
      var o = defaultSiOptions()
      o.hMax = hb
      let r = simulate(n, edgeStimulus(edRising), o)
      check r.status == ssOk
      hb = r.hBase / 2
      var worst = 0.0
      for k, t in r.t:
        if t < td:
          check abs(r.receiverPins[0].v[k]) < 1e-9     # nothing before td
        elif t < 3 * td - r.hBase:
          worst = max(worst, abs(r.receiverPins[0].v[k] - 2.0 * vInc(t - td)))
      worsts.add worst
      # Final value: the open receiver rings down (Gs = -1/3 per round
      # trip) towards the rail.
      check abs(r.receiverPins[0].v[^1] - d.vcc) < 0.01
    # The residual is the delayed-history interpolation of a curved wave:
    # second order in h.
    check worsts[0] < 1e-3
    check worsts[1] < worsts[0] / 3

  test "the full reference case converges with the step and obeys the invariants":
    var d = defaultLinearDriver()
    d.cComp = 2e-12
    d.samples = 201
    let n = refNet(d)
    let r1 = simulate(n, edgeStimulus(edRising, 0.5e-9))
    check r1.status == ssOk
    var o = defaultSiOptions()
    o.hMax = r1.hBase / 2
    o.tStop = r1.t[^1]
    let r2 = simulate(n, edgeStimulus(edRising, 0.5e-9), o)
    check r2.status == ssOk
    var diff = 0.0
    for k, t in r1.t:
      diff = max(diff, abs(r1.receivers[0].v[k] - at(r2.t, r2.receivers[0].v, t)))
    check diff < 0.02            # volts, h vs h/2
    # Causality: nothing reaches the receiver die before the line delay.
    let v0 = r1.receivers[0].v[0]
    for k, t in r1.t:
      if t < 0.5e-9 + 2e-9: check abs(r1.receivers[0].v[k] - v0) < 1e-6
    # Overshoot exists (open, mismatched) but it settles at the rail.
    var peak = 0.0
    for v in r1.receivers[0].v: peak = max(peak, v)
    check peak > d.vcc
    check abs(r1.receivers[0].v[^1] - d.vcc) < 0.01

  test "falling edge and the open-drain case":
    var d = defaultLinearDriver()
    let r = simulate(refNet(d), edgeStimulus(edFalling))
    check r.status == ssOk
    check abs(r.receivers[0].v[0] - d.vcc) < 1e-6
    check abs(r.receivers[0].v[^1]) < 0.01
    var od = defaultLinearDriver()
    od.modelType = "Open_drain"
    od.rpu = 0.0
    od.fixtures = @[(50.0, 3.3, 0.0)]
    var net = refNet(od)
    # An open-drain net needs its pull-up: 1 k to 3.3 V at the receiver.
    let vt = net.addNode("vpu")
    net.addResistor(net.receiverPorts[0].pinNode, vt, 1000.0, "pull-up")
    net.addSource(vt, 0, 3.3, "rail")
    let ro = simulate(net, edgeStimulus(edFalling))
    check ro.status == ssOk
    check ro.receivers[0].v[0] > 3.2
    check ro.receivers[0].v[^1] < 0.2

  test "unsupported and solver failure are statuses, not waveforms":
    var d = defaultLinearDriver()
    d.modelType = "Series"
    let n = refNet(d)
    let r = simulate(n, edgeStimulus(edRising))
    check r.status == ssUnsupported
    check r.t.len == 0
    var o = defaultSiOptions()
    o.newton.maxIter = 1
    var dc = defaultLinearDriver()
    dc.rgc = 50.0
    dc.modelType = "3-state"
    let rf = simulate(refNet(dc), edgeStimulus(edRising), o)
    check rf.status == ssSolverFailed
    check rf.t.len == 0
    check rf.reason.len > 0
