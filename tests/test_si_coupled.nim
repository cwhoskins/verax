## Stage 8.1 of docs/ibis_simulator_plan.md: coupled lines (modal
## decomposition into two Bergeron lines) and crosstalk.

import std/[unittest, math]

import verax/si/engine/transient
import verax/pcb/impedance

proc ramp(v, t0, tr: float): Pwl =
  result.add 0.0, 0.0
  result.add t0, 0.0
  result.add t0 + tr, v

proc piMatch(c: var Circuit, n1, n2: int, ze, zo: float, label: string) =
  ## Matches both modes: `Ze` from each conductor to ground and
  ## `2 Ze Zo / (Ze - Zo)` between them.
  c.resistors.add Res(a: n1, b: 0, r: ze, label: label)
  c.resistors.add Res(a: n2, b: 0, r: ze, label: label)
  c.resistors.add Res(a: n1, b: n2, r: 2 * ze * zo / (ze - zo), label: label)

suite "coupled line, exact modal solution":
  # Fully matched at both ends (pi networks), source Vs in conductor 1's Ze
  # leg. Then 2 Yc V = [Vs/Ze, 0] at the near end: v1 = Vs/4 (1 + Zo/Ze),
  # v2 = Vs/4 (1 - Zo/Ze), and each mode arrives at the far end after its
  # own delay with no reflection.
  const ze = 60.0
  const zo = 40.0
  const tde = 1.0e-9
  const tdo = 0.8e-9
  const vs = 2.0
  const tr = 0.2e-9
  var c = newCircuit()
  let n1 = c.addNode("n1")
  let n2 = c.addNode("n2")
  let f1 = c.addNode("f1")
  let f2 = c.addNode("f2")
  let s = c.addNode("s")
  c.vsources.add VSrc(a: s, b: 0, wave: ramp(vs, 0.1e-9, tr), label: "Vs")
  c.resistors.add Res(a: n1, b: s, r: ze, label: "src Ze")
  c.resistors.add Res(a: n2, b: 0, r: ze, label: "src Ze")
  c.resistors.add Res(a: n1, b: n2, r: 2 * ze * zo / (ze - zo), label: "src Rm")
  c.piMatch(f1, f2, ze, zo, "far")
  c.coupled.add CoupledLine(a1: n1, b1: f1, a2: n2, b2: f2, zEven: ze, zOdd: zo,
                            tdEven: tde, tdOdd: tdo, label: "pair")
  var o = defaultSimOptions(4e-9)
  o.tr = tr
  let r = transient(c, o)

  proc s0(t: float): float = clamp((t - 0.1e-9) / tr, 0.0, 1.0)

  test "near and far ends match the closed form at every step":
    check r.ok
    var worst = 0.0
    for k, t in r.t:
      let near1 = vs / 4 * (1 + zo / ze) * s0(t)
      let near2 = vs / 4 * (1 - zo / ze) * s0(t)
      let far1 = vs / 4 * (s0(t - tde) + zo / ze * s0(t - tdo))
      let far2 = vs / 4 * (s0(t - tde) - zo / ze * s0(t - tdo))
      worst = max(worst, abs(r.v[n1][k] - near1))
      worst = max(worst, abs(r.v[n2][k] - near2))
      worst = max(worst, abs(r.v[f1][k] - far1))
      worst = max(worst, abs(r.v[f2][k] - far2))
    checkpoint "worst error " & $worst
    check worst < 1e-3 * vs

  test "far-end crosstalk is the modal delay difference: a pulse of width tde - tdo":
    # f2 = Vs/4 [s(t - tde) - (Zo/Ze) s(t - tdo)]: before tdo it is 0, the
    # odd mode arrives first (negative), the even one ends it.
    var minV = 0.0
    var tMin = 0.0
    for k, t in r.t:
      if r.v[f2][k] < minV:
        minV = r.v[f2][k]
        tMin = t
    check minV < -0.1
    check tMin > tdo and tMin < tde + 0.1e-9 + tr

  test "the DC point holds both conductors as wires":
    var d = newCircuit()
    let a1 = d.addNode("a1")
    let a2 = d.addNode("a2")
    let b1 = d.addNode("b1")
    let b2 = d.addNode("b2")
    d.vsources.add VSrc(a: a1, b: 0, wave: constPwl(1.5), label: "V1")
    d.resistors.add Res(a: b1, b: 0, r: 100.0, label: "R1")
    d.resistors.add Res(a: a2, b: 0, r: 100.0, label: "R2")
    d.resistors.add Res(a: b2, b: 0, r: 100.0, label: "R3")
    d.coupled.add CoupledLine(a1: a1, b1: b1, a2: a2, b2: b2, zEven: 55, zOdd: 45,
                              tdEven: 1e-9, tdOdd: 1e-9, label: "pair")
    let q = transient(d, defaultSimOptions(5e-9))
    check q.ok
    for k in 0 ..< q.t.len:
      check abs(q.v[b1][k] - 1.5) < 1e-6
      check abs(q.v[b2][k]) < 1e-6

suite "coupled cross-sections":
  test "stripline: equal modal velocities, Ze > Z0 > Zo, both -> Z0 as s grows":
    let base = LineSpec(geometry: lgEdgeCoupledStripline, w: 0.15e-3, t: 18e-6,
                        h1: 0.2e-3, h2: 0.2e-3, er: 4.3)
    var tight = base
    tight.s = 0.1e-3
    let m = coupledModes(tight)
    let z = z0(tight)
    check m.zEven > z and m.zOdd < z
    check m.epsEven == m.epsOdd
    var wide = base
    wide.s = 5e-3
    let w = coupledModes(wide)
    check abs(w.zEven - z) < 1e-3 * z and abs(w.zOdd - z) < 1e-3 * z

  test "microstrip: the odd mode is faster (less field in the dielectric)":
    let ms = LineSpec(geometry: lgEdgeCoupledMicrostrip, w: 0.3e-3, t: 35e-6,
                      h1: 0.2e-3, s: 0.2e-3, er: 4.3)
    let m = coupledModes(ms)
    check m.epsOdd < epsEff(ms) and epsEff(ms) < m.epsEven
    check m.inRange
    # Zdiff of a 1.5 h wide pair at s = h: the usual ~90 ohm region.
    check 2 * m.zOdd > 80 and 2 * m.zOdd < 100
    var wide = ms
    wide.s = 20e-3
    let w = coupledModes(wide)
    check abs(w.zEven - z0(ms)) < 2e-3 * z0(ms)
    check abs(w.zOdd - z0(ms)) < 2e-3 * z0(ms)

# --- templates: aggressor and victim ---------------------------------------

import std/[streams, strutils]
import verax/ibis
import verax/si/simulate
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

let stripPair = LineSpec(geometry: lgEdgeCoupledStripline, w: 0.15e-3, t: 18e-6,
                         h1: 0.2e-3, h2: 0.2e-3, er: 4.3, s: 0.15e-3)
let msPair = LineSpec(geometry: lgEdgeCoupledMicrostrip, w: 0.35e-3, t: 35e-6,
                      h1: 0.2e-3, er: 4.3, s: 0.2e-3)

proc busTemplate(pair: LineSpec): SiTemplate =
  var single = pair
  single.geometry = (if pair.geometry == lgEdgeCoupledStripline: lgStripline else: lgMicrostrip)
  result = SiTemplate(name: "AGG", driver: drvB(thevenin()), topology: ttPointToPoint,
                      driverPort: TemplatePort(label: "U1.1"),
                      line: lineSection(single),
                      receivers: @[rxB()], receiverPorts: @[TemplatePort(label: "U2.1")])
  result.partner = TemplatePartner(role: prVictim, name: "VIC", driver: drvB(thevenin()),
                                   driverPort: TemplatePort(label: "U1.2"),
                                   receiver: rxB(), receiverPort: TemplatePort(label: "U2.2"),
                                   coupled: pair)

suite "crosstalk on a template":
  test "stripline: NEXT is the backward coefficient times the incident step, FEXT ~ 0":
    let t = busTemplate(stripPair)
    # Matched both ends (50 ohm source, 50 ohm far-end termination to 0 V).
    let net = t.build(templateParams(0.15, parallelR = 50.0, coupledLength = 0.15))
    check net.unsupported.len == 0
    check net.extraDrivers.len == 1 and net.extraDrivers[0].mode == dmQuietLow
    let r = simulate(net, edgeStimulus(edRising, 0.5e-9))
    check r.status == ssOk
    let m = coupledModes(stripPair)
    let kb = (m.zEven - m.zOdd) / (2 * (m.zEven + m.zOdd))
    # The incident step on the aggressor: half the 3.3 V swing.
    let near = r.extraDriverPins[0].v
    var peakNear = 0.0
    for x in near: peakNear = max(peakNear, x)
    checkpoint "NEXT " & $peakNear & " vs Kb * 1.65 = " & $(kb * 1.65)
    check abs(peakNear - kb * 1.65) < 0.2 * kb * 1.65
    var farPeak = 0.0
    for x in r.receivers[1].v: farPeak = max(farPeak, abs(x))
    check farPeak < 0.25 * peakNear   # homogeneous: FEXT only from mismatch

  test "microstrip: FEXT at the far end, negative on a rising aggressor, grows with length":
    let t = busTemplate(msPair)
    proc fext(len: float): float =
      let net = t.build(templateParams(len, parallelR = 50.0, coupledLength = len))
      let r = simulate(net, edgeStimulus(edRising, 0.5e-9))
      check r.status == ssOk
      for x in r.receivers[1].v: result = min(result, x)
    let short = fext(0.05)
    let long = fext(0.15)
    check short < -0.01
    check long < short * 1.5    # more negative

  # From here the 50 ohm drivers are source-matched into open far ends:
  # full swing at the receivers, so only crosstalk can fail.
  test "sweep: victim probes report crosstalk, judged against a budget":
    let t = busTemplate(msPair)
    let net = t.build(templateParams(0.1, coupledLength = 0.1))
    let sw = sweepNet([SweepCorner(corner: coTyp, net: net)], sweepStimuli(NaN))
    check sw.status == ssOk
    check sw.probes.len == 3   # AGG receiver, VIC receiver, VIC near end
    check sw.probes[0].kind == pkSignal
    check sw.probes[1].kind == pkVictim and sw.probes[2].kind == pkVictim
    let xt = sw.worst[1][sfCrosstalk]
    check xt.value > 0.01 and xt.at.len > 0
    check sw.worst[1][sfNoiseMargin].value < 0.8
    let txt = renderText(sw)
    check "crosstalk" in txt and "U1.2 (near end)" in txt
    var c = defaultCriteria()
    c.maxCrosstalk = 0.01
    let p = judge([t], templateParams(0.1, coupledLength = 0.1), c)
    check p.verdict == vFail
    check "crosstalk" in p.failures[0]

  test "a minimum spacing for a coupled length, as a KiCad clearance":
    let t = busTemplate(msPair)
    var c = defaultCriteria()
    c.maxCrosstalk = 0.1
    let base = templateParams(0.1, coupledLength = 0.1)
    let sp = spacingFor([t], base, 0.1e-3, 1.5e-3, 8, c, 0.02e-3)
    let m = sp.minToEnd
    checkpoint $sp.passing
    check not m.isNaN and m > 0.1e-3 and m < 1.5e-3
    # Just inside passes, just outside fails.
    check judge([t], base.withSpacing(m + 0.05e-3), c).verdict == vPass
    check judge([t], base.withSpacing(m - 0.05e-3), c).verdict == vFail
    var rep = ConstraintReport(net: "AGG", identity: identity(t, [coTyp], base, c),
                               spacing: sp, hasSpacing: true, victimNet: "VIC",
                               coupledLength: 0.1)
    let rules = druRules(rep, "AGG")
    var found = false
    for r in rules:
      if not r.minClearance.isNaN:
        found = true
        check abs(r.minClearance - m) < 1e-12
    check found
    check "min spacing" in renderText(rep)
