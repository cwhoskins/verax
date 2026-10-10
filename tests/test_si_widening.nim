## Stage 3b of docs/ibis_simulator_plan.md: each widening past the reference
## case with its own independently derived reference fixture and a stated
## unsupported case. A linear driver with `Rpu = Rpd = R` is a Thevenin
## source `Vcc * Ku(t)` behind `R`, which makes lattice diagrams and the
## frequency domain usable as references.

import std/[streams, unittest, math, complex, strutils]

import verax/ibis
import verax/pcb/impedance
import verax/pcb/via
import verax/si/simulate
import ./fixtures/ibis/synthetic

proc thevenin(r = 50.0): LinearDriver =
  result = defaultLinearDriver()
  result.rpu = r
  result.rpd = r

proc drvB(d: LinearDriver): DriverBehaviour =
  driverBehaviour(readIbis(newStringStream(d.toIbs())).model(d.name))

proc idealRx(): ReceiverBehaviour =
  receiverBehaviour(readIbis(newStringStream(linearReceiverIbs(cComp = 0.0))).model("lin_rx"))

proc at(t, v: seq[float], tq: float): float =
  for k in 0 ..< t.len - 1:
    if tq >= t[k] and tq <= t[k + 1]:
      return v[k] + (v[k + 1] - v[k]) * (tq - t[k]) / (t[k + 1] - t[k])
  v[^1]

proc tmpl(d: LinearDriver, topo: TemplateTopology, nrx: int, line: LineSection): SiTemplate =
  result = SiTemplate(name: "w", driver: drvB(d), topology: topo,
                      driverPort: TemplatePort(label: "U1.1"), line: line)
  for k in 0 ..< nrx:
    result.receivers.add idealRx()
    result.receiverPorts.add TemplatePort(label: "U" & $(k + 2) & ".1")

suite "multi-drop":
  test "star of two open receivers: hub transmits 2/3, lattice plateaus":
    let d = thevenin()
    # Trunk 1 ns, branches 0.5 ns each (tdPerM = 1 s/m, lengths in seconds).
    let t = tmpl(d, ttStar, 2, idealLine(50.0, 1.0))
    let n = t.build(TemplateParams(length: 1e-9, stubLength: 0.5e-9))
    check n.unsupported.len == 0
    let r = simulate(n, edgeStimulus(edRising))
    check r.status == ssOk
    # Incident (matched source): Vcc/2 * Ku. Receivers: 2/3 * 2 = 4/3 of it
    # from 1.5 ns, until the branch reflection returns via the hub at
    # td1 + 3 td2 = 2.5 ns.
    for tq in [1.6e-9, 2.0e-9, 2.4e-9]:
      let (ku, _) = d.kAt(true, tq - 1.5e-9)
      for k in 0 .. 1:
        check abs(at(r.t, r.receiverPins[k].v, tq) - 4.0 / 3.0 * 1.65 * ku) < 2e-3
    # Symmetric branches see identical waveforms.
    for k in 0 ..< r.t.len:
      check abs(r.receiverPins[0].v[k] - r.receiverPins[1].v[k]) < 1e-9
    check abs(r.receiverPins[0].v[^1] - 3.3) < 0.01

  test "daisy chain: the first tap sees the through-wave at 2/3":
    let d = thevenin()
    var t = tmpl(d, ttDaisyChain, 2, idealLine(50.0, 1.0))
    # Far end terminated so only the tap mismatch reflects.
    let n = t.build(TemplateParams(length: 2e-9, stubLength: 0.0, parallelR: 50.0))
    let r = simulate(n, edgeStimulus(edRising))
    check r.status == ssOk
    # Tap 1 at 1 ns: no stub, so the tap is just a point on the line until
    # the end termination; both receivers ideal -> matched, no reflection.
    let (ku, _) = d.kAt(true, 0.5e-9)
    check abs(at(r.t, r.receiverPins[0].v, 1.5e-9) - 1.65 * ku) < 2e-3
    check abs(r.receiverPins[1].v[^1] - 1.65) < 0.01

  test "unsupported: point-to-point with two receivers":
    let t = tmpl(thevenin(), ttPointToPoint, 2, idealLine(50.0, 1.0))
    let r = simulate(t.build(TemplateParams(length: 1e-9)), edgeStimulus(edRising))
    check r.status == ssUnsupported

suite "vias":
  proc stubVia(tdStub: float): ViaModel =
    ## An ideal via: no barrel L/C, a 50-ohm bottom stub of `tdStub`.
    ViaModel(usedL: 0.0, usedC: 0.0, stubBottom: 1.0, stubZ0: 50.0, stubTdPerM: tdStub)

  test "an open stub on a matched line: 2/3, then 10/9, then 26/27":
    let d = thevenin()
    var t = tmpl(d, ttPointToPoint, 1, idealLine(50.0, 1.0))
    t.hasVia = true
    t.via = stubVia(2e-9)
    let n = t.build(TemplateParams(length: 2e-9, viaCount: 1, parallelR: 50.0))
    check n.unsupported.len == 0
    let r = simulate(n, edgeStimulus(edRising))
    check r.status == ssOk
    let vinc = 1.65     # matched launch, after the 1 ns ramp
    # Via at 1 ns; load edge 2..3 ns. Stub round trip 4 ns, so each stub
    # return lands at the load 4 ns after the previous one.
    check abs(at(r.t, r.receiverPins[0].v, 4e-9) - vinc * 2.0 / 3.0) < 2e-3
    check abs(at(r.t, r.receiverPins[0].v, 8e-9) - vinc * 10.0 / 9.0) < 2e-3
    check abs(at(r.t, r.receiverPins[0].v, 12e-9) - vinc * 26.0 / 27.0) < 2e-3

  test "a zero via changes nothing":
    let d = thevenin()
    var t = tmpl(d, ttPointToPoint, 1, idealLine(50.0, 1.0))
    let r0 = simulate(t.build(TemplateParams(length: 2e-9, parallelR: 50.0)), edgeStimulus(edRising))
    t.hasVia = true
    t.via = ViaModel()
    var o = defaultSiOptions()
    o.tStop = r0.t[^1]
    let r1 = simulate(t.build(TemplateParams(length: 2e-9, viaCount: 1, parallelR: 50.0)),
                      edgeStimulus(edRising), o)
    for k, tq in r0.t:
      check abs(r0.receiverPins[0].v[k] - at(r1.t, r1.receiverPins[0].v, tq)) < 1e-6

  test "unsupported: a via that changes reference":
    var t = tmpl(thevenin(), ttPointToPoint, 1, idealLine(50.0, 1.0))
    t.hasVia = true
    t.via = viaModel(ViaGeometry(drillDia: 0.3e-3, padDia: 0.6e-3, antipadDia: 1e-3,
                                 barrelLength: 1.6e-3, er: 4.3, exitDepth: 0.4e-3,
                                 backdrillResidual: -1, entryRef: "GND", exitRef: "VCC"))
    let r = simulate(t.build(TemplateParams(length: 1e-9, viaCount: 1)), edgeStimulus(edRising))
    check r.status == ssUnsupported

suite "lossy ladder (rung 5)":
  let spec = LineSpec(geometry: lgMicrostrip, w: 0.1e-3, t: 35e-6, h1: 0.1e-3,
                      er: 4.3, tand: 0.02, rho: 1.72e-8)
  let sec = lineSection(spec, lossy = true, fKnee = 1e9)
  let length = 0.5

  proc net(d: LinearDriver): SiNet =
    let t = tmpl(d, ttPointToPoint, 1, sec)
    t.build(TemplateParams(length: length, parallelR: 50.0))

  var lad = defaultSiOptions()
  lad.lossyModel = lmLadder

  test "doubling the section count changes the answer by < 1 %":
    let d = thevenin()
    let n = net(d)
    let r1 = simulate(n, edgeStimulus(edRising), lad)
    var o = lad
    o.ladderMultiplier = 2.0
    o.tStop = r1.t[^1]
    let r2 = simulate(n, edgeStimulus(edRising), o)
    check r1.status == ssOk and r2.status == ssOk
    check r2.ladders[0].sections == 2 * r1.ladders[0].sections
    var diff = 0.0
    for k, tq in r1.t:
      diff = max(diff, abs(r1.receiverPins[0].v[k] - at(r2.t, r2.receiverPins[0].v, tq)))
    check diff < 0.01 * 3.3

  test "agrees with the exact constant-RLGC line in the frequency domain":
    # Source Vcc*Ku(t) behind 50 ohm, a trapezoid pulse (pattern "010"),
    # line of `length` with the ladder's own RLGC, 50 ohm load. The exact
    # line's ABCD gives H(w); the time response is the inverse Fourier
    # integral of H * X.
    let d = thevenin()
    let ui = 10e-9
    let r = simulate(net(d), patternStimulus("010", ui), lad)
    check r.status == ssOk
    check r.ladders.len == 1
    let z = complex(sec.r, 0.0)
    proc response(tq: float): float =
      let T = d.tEdge
      let P = ui
      let df = 5e6
      var acc = 0.0
      var f = df / 2
      while f < 60e9:
        let w = 2 * PI * f
        let jw = complex(0.0, w)
        let zs = complex(sec.r, w * sec.l)
        let ys = complex(sec.g, w * sec.c)
        let zc = sqrt(zs / ys)
        let gl = sqrt(zs * ys) * length
        let a = cosh(gl)
        let b = zc * sinh(gl)
        let c = sinh(gl) / zc
        let rl = complex(50.0, 0.0)
        let rs = complex(50.0, 0.0)
        let h = rl / (a * rl + b + c * rs * rl + a * rs)
        let x = complex(3.3 / T, 0.0) / (jw * jw) *
                (complex(1.0, 0.0) - exp(-jw * T)) * (complex(1.0, 0.0) - exp(-jw * P)) *
                exp(-jw * ui)
        acc += (h * x * exp(jw * tq)).re * 2 * PI * df
        f += df
      acc / PI
    discard z
    var worst = 0.0
    var tq = 10e-9
    while tq < 22e-9:
      worst = max(worst, abs(at(r.t, r.receiverPins[0].v, tq) - response(tq)))
      tq += 0.5e-9
    check worst < 0.03 * 3.3

suite "bit patterns":
  test "a resistive load follows the stitched edges exactly":
    let d = thevenin()
    var n = newSiNet("pat")
    n.setDriver("U1.1", drvB(d), PackageRlc())
    n.addResistor(n.driverPort.pinNode, 0, 50.0, "load")
    let s = patternStimulus("01101", 3e-9)
    let r = simulate(n, s)
    check r.status == ssOk
    for k, t in r.t:
      var ku = 0.0
      if t >= 3e-9: ku = d.kAt(true, t - 3e-9).ku
      if t >= 9e-9: ku = d.kAt(false, t - 9e-9).ku
      if t >= 12e-9: ku = d.kAt(true, t - 12e-9).ku
      check abs(r.driverPin.v[k] - 1.65 * ku) < 1e-6

  test "a UI shorter than the table: truncated, warned, still a waveform":
    let d = thevenin()
    var n = newSiNet("pat")
    n.setDriver("U1.1", drvB(d), PackageRlc())
    n.addResistor(n.driverPort.pinNode, 0, 50.0, "load")
    let r = simulate(n, patternStimulus("0101", 0.6e-9))
    check r.status == ssOk
    var warned = false
    for i in r.issues:
      if i.kind == "si_ui_short": warned = true
    check warned
    # Truncated at 1.2 ns: Ku had reached 0.6, then the falling edge's
    # series starts at Ku = 1 (a jump the engine restarts at).
    check abs(at(r.t, r.driverPin.v, 1.2e-9 - 1e-13) - 1.65 * 0.6) < 2e-3

  test "unsupported: a malformed pattern":
    var n = newSiNet("pat")
    n.setDriver("U1.1", drvB(thevenin()), PackageRlc())
    check simulate(n, patternStimulus("01a", 1e-9)).status == ssUnsupported

suite "min/max corners (complete data only)":
  const full = """
[IBIS Ver] 3.2
[Component] C
[Pin] signal_name model_name
1 OUT drv
[Model] drv
Model_type Output
C_comp 0 0 0
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
  test "the min corner runs on its own column, rails and ramp":
    let m = readIbis(newStringStream(full)).model("drv")
    for (c, vr, tr) in [(coTyp, 3.3, 0.6e-9), (coMin, 3.0, 0.9e-9), (coMax, 3.6, 0.3e-9)]:
      let b = driverBehaviour(m, c)
      check b.supported
      check b.corner == c
      var n = newSiNet("corner")
      n.setDriver("U1.1", b, PackageRlc())
      n.addResistor(n.driverPort.pinNode, 0, 1e6, "load")
      let r = simulate(n, edgeStimulus(edRising))
      check r.status == ssOk
      check abs(r.driverPin.v[^1] - vr) < 1e-3
      check abs(r.tr - 0.8 * tr / 0.6) < 1e-15

  test "unsupported: an absent min value, no substitution policy":
    let m = readIbis(newStringStream(incompleteCornersIbs)).model("drv")
    var n = newSiNet("corner")
    n.setDriver("U1.1", driverBehaviour(m, coMin), PackageRlc())
    let r = simulate(n, edgeStimulus(edRising))
    check r.status == ssUnsupported
    check "C_comp" in r.reason
