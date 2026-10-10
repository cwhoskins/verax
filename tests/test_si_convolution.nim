## Stage 7 of docs/ibis_simulator_plan.md: lossy lines by recursive
## convolution (`si/engine/ratfit`, `si/engine/convline`). Checked against
## closed forms (an exactly representable rational function, Bergeron for a
## lossless line, the DC divider), against the exact line in the frequency
## domain (constant and frequency-dependent RLGC), against the ladder, and
## the causal RLGC form against `impedance.propagation` (what
## `tline.sparams` cascades).

import std/[streams, unittest, math, complex]

import verax/ibis
import verax/pcb/impedance
import verax/si/simulate
import verax/si/engine/ratfit
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

proc conv(): SiOptions =
  result = defaultSiOptions()
  result.lossyModel = lmConvolution

proc ladder(): SiOptions =
  result = defaultSiOptions()
  result.lossyModel = lmLadder

let spec = LineSpec(geometry: lgMicrostrip, w: 0.1e-3, t: 35e-6, h1: 0.1e-3,
                    er: 4.3, tand: 0.02, rho: 1.72e-8)

proc p2p(d: LinearDriver, sec: LineSection, length: float): SiNet =
  var t = SiTemplate(name: "c", driver: drvB(d), topology: ttPointToPoint,
                     driverPort: TemplatePort(label: "U1.1"), line: sec)
  t.receivers.add idealRx()
  t.receiverPorts.add TemplatePort(label: "U2.1")
  t.build(TemplateParams(length: length, parallelR: 50.0))

proc exactPulse(d: LinearDriver, length, ui, tq: float, causal: bool, sec: LineSection): float =
  ## Source `Vcc Ku(t)` behind 50 ohm, trapezoid pulse "010" at `ui`, the
  ## exact line's ABCD, 50 ohm load; inverse Fourier integral.
  let T = d.tEdge
  let df = 5e6
  var acc = 0.0
  var f = df / 2
  while f < 60e9:
    let w = 2 * PI * f
    let jw = complex(0.0, w)
    let (zs, ys) =
      if causal: causalLine(spec, f, 1e9)
      else: (complex(sec.r, w * sec.l), complex(sec.g, w * sec.c))
    let zc = sqrt(zs / ys)
    let gl = sqrt(zs * ys) * length
    let a = cosh(gl)
    let b = zc * sinh(gl)
    let c = sinh(gl) / zc
    let r50 = complex(50.0, 0.0)
    let h = r50 / (a * r50 + b + c * r50 * r50 + a * r50)
    let x = complex(3.3 / T, 0.0) / (jw * jw) *
            (complex(1.0, 0.0) - exp(-jw * T)) * (complex(1.0, 0.0) - exp(-jw * ui)) *
            exp(-jw * ui)
    acc += (h * x * exp(jw * tq)).re * 2 * PI * df
    f += df
  acc / PI

suite "rational fit":
  test "an exactly representable function is recovered, DC exact":
    let p = @[-2 * PI * 1e8, -2 * PI * 1e9, -2 * PI * 1e10]
    proc f(s: Complex64): Complex64 = complex(0.5, 0.0) + complex(2e9, 0.0) / (s - complex(p[1], 0.0))
    var fs: seq[float]
    var vs: seq[Complex64]
    var fr = 1e6
    while fr < 1e11:
      fs.add fr
      vs.add f(complex(0.0, 2 * PI * fr))
      fr *= 1.5
    let dc = f(complex(0.0, 0.0)).re
    let r = fitRational(fs, vs, dc, p)
    check abs(r.residues[1] - 2e9) < 1e-6 * 2e9
    check abs(r.residues[0]) < 1e-6 * 2e9
    check abs(r.residues[2]) < 1e-6 * 2e9
    check abs(r.dcValue - dc) < 1e-12 * abs(dc)
    check r.maxErr < 1e-9

  test "a line's Yc and delay-free H fit to well under the tolerance":
    let sec = lineSection(spec, lossy = true)
    var n = newSiNet("f")
    let a = n.addNode("a")
    let b = n.addNode("b")
    n.addLossyLine(a, b, spec, 1e9, 0.5, "l")
    let (ln, _) = convLineFor(n.elements[0], a, b, 100e-9, 0.5e-9, 6)
    check ln.yc.maxErr < 1e-4
    check ln.hm.maxErr < 1e-2
    check abs(ln.yc.dcValue) < 1e-15    # no DC shunt loss
    check abs(ln.hm.dcValue - 1.0) < 1e-12
    check ln.tau < 0.5 * sec.tdPerM     # the asymptotic delay is the fastest

suite "causal RLGC form":
  test "equals rlgc's G + jwC at the reference frequency":
    let q = rlgc(spec, 1e9)
    let (z, y) = causalLine(spec, 1e9, 1e9)
    check abs(y.re - q.g) < 1e-9 * q.g
    check abs(y.im - 2 * PI * 1e9 * q.c) < 1e-9 * 2 * PI * 1e9 * q.c
    check abs(z.re - q.r) < 0.02 * q.r
    check abs(causalLine(spec, 0.0).z.re - spec.rho / (spec.w * spec.t)) < 1e-12

  test "attenuation tracks impedance.propagation (what tline.sparams cascades)":
    for f in [0.1e9, 1e9, 5e9, 10e9]:
      let (z, y) = causalLine(spec, f, 1e9)
      let a = sqrt(z * y).re
      let ref0 = propagation(spec, f).gamma.re
      check abs(a - ref0) < 0.1 * ref0

suite "convolution line":
  test "lossless (R = G = 0) matches Bergeron":
    let d = thevenin()
    let l = 50.0 * 5e-9
    let c = 5e-9 / 50.0
    var nb = newSiNet("b")
    nb.setDriver("U1.1", drvB(d), PackageRlc())
    let far = nb.addNode("far")
    nb.addLine(nb.driverPort.pinNode, far, 50.0, 5e-9, "line")
    nb.addResistor(far, 0, 100.0, "load")
    var nc = newSiNet("c")
    nc.setDriver("U1.1", drvB(d), PackageRlc())
    let far2 = nc.addNode("far")
    nc.addLossyLine(nc.driverPort.pinNode, far2, 0.0, l, 0.0, c, 1.0, "line")
    nc.addResistor(far2, 0, 100.0, "load")
    let rb = simulate(nb, edgeStimulus(edRising))
    var o = conv()
    o.tStop = rb.t[^1]
    let rc = simulate(nc, edgeStimulus(edRising), o)
    check rb.status == ssOk and rc.status == ssOk
    check rc.convolution == @["line"]
    var worst = 0.0
    for k, tq in rb.t:
      worst = max(worst, abs(rb.v[far][k] - at(rc.t, rc.v[far2], tq)))
    check worst < 1e-3 * 3.3

  test "constant RLGC: agrees with the exact line, and with the ladder":
    let d = thevenin()
    var sec = lineSection(spec, lossy = true, fKnee = 1e9)
    sec.hasSpec = false
    let net = p2p(d, sec, 0.5)
    let ui = 10e-9
    let rl = simulate(net, patternStimulus("010", ui), ladder())
    var o = conv()
    o.tStop = rl.t[^1]
    let rc = simulate(net, patternStimulus("010", ui), o)
    check rl.status == ssOk and rc.status == ssOk
    check rc.convolution.len == 1 and rc.ladders.len == 0
    var exact, parity = 0.0
    var tq = 10e-9
    while tq < 24e-9:
      let vc = at(rc.t, rc.receiverPins[0].v, tq)
      exact = max(exact, abs(vc - exactPulse(d, 0.5, ui, tq, false, sec)))
      parity = max(parity, abs(vc - at(rl.t, rl.receiverPins[0].v, tq)))
      tq += 0.5e-9
    check exact < 1e-3 * 3.3
    check parity < 0.03 * 3.3      # the ladder's own tolerance against the exact line

  test "frequency-dependent RLGC: agrees with the exact causal line":
    let d = thevenin()
    let sec = lineSection(spec, lossy = true, fKnee = 1e9)
    let ui = 10e-9
    let r = simulate(p2p(d, sec, 0.5), patternStimulus("010", ui), conv())
    check r.status == ssOk
    check r.convolution.len == 1
    var worst = 0.0
    var tq = 10e-9
    while tq < 24e-9:
      worst = max(worst, abs(at(r.t, r.receiverPins[0].v, tq) - exactPulse(d, 0.5, ui, tq, true, sec)))
      tq += 0.5e-9
    check worst < 2e-3 * 3.3

  test "DC: the operating point is the model's own steady state":
    # Falling edge from high through Rdc * l: the receiver holds its DC
    # level exactly until the edge.
    let d = thevenin()
    let net = p2p(d, lineSection(spec, lossy = true), 0.5)
    let r = simulate(net, edgeStimulus(edFalling, 2e-9), conv())
    check r.status == ssOk
    let rdc = spec.rho / (spec.w * spec.t) * 0.5
    let v0 = 3.3 * 50.0 / (50.0 + rdc + 50.0)
    let v = r.receiverPins[0].v
    check abs(v[0] - v0) < 1e-9
    for k, t in r.t:
      if t < 2e-9: check abs(v[k] - v0) < 1e-9

  test "DC: the settled level is the divider through R l":
    # Constant RLGC (the causal dielectric relaxes for microseconds, so its
    # final level is not reached in a short run -- that is the physics).
    var sec = lineSection(spec, lossy = true)
    sec.hasSpec = false
    sec.g = 0.0
    var o = conv()
    o.tStop = 300e-9
    let r = simulate(p2p(thevenin(), sec, 0.5), edgeStimulus(edRising), o)
    check r.status == ssOk
    let vEnd = 3.3 * 50.0 / (100.0 + sec.r * 0.5)
    check abs(r.receiverPins[0].v[^1] - vEnd) < 1e-3

  test "halving the step changes the answer by < 0.1 %":
    let d = thevenin()
    let net = p2p(d, lineSection(spec, lossy = true), 0.3)
    let r1 = simulate(net, edgeStimulus(edRising), conv())
    var o = conv()
    o.tStop = r1.t[^1]
    o.hMax = r1.hBase / 2
    let r2 = simulate(net, edgeStimulus(edRising), o)
    check r2.hBase < r1.hBase
    var worst = 0.0
    for k, tq in r1.t:
      worst = max(worst, abs(r1.receiverPins[0].v[k] - at(r2.t, r2.receiverPins[0].v, tq)))
    check worst < 1e-3 * 3.3

  test "a fit outside tolerance falls back to the ladder, warned":
    var o = conv()
    o.convFitTol = 1e-15
    let r = simulate(p2p(thevenin(), lineSection(spec, lossy = true), 0.3), edgeStimulus(edRising), o)
    check r.status == ssOk
    check r.convolution.len == 0 and r.ladders.len == 1
    var warned = false
    for i in r.issues:
      if i.kind == "si_conv_fit": warned = true
    check warned

  test "a line shorter than the lumping threshold stays a ladder":
    let r = simulate(p2p(thevenin(), lineSection(spec, lossy = true), 1e-3), edgeStimulus(edRising), conv())
    check r.status == ssOk
    check r.convolution.len == 0 and r.ladders.len == 1

  test "a lossy daisy chain runs, every trunk and stub by convolution":
    var t = SiTemplate(name: "dc", driver: drvB(thevenin()), topology: ttDaisyChain,
                       driverPort: TemplatePort(label: "U1.1"), line: lineSection(spec, lossy = true))
    for k in 0 ..< 3:
      t.receivers.add idealRx()
      t.receiverPorts.add TemplatePort(label: "U" & $(k + 2) & ".1")
    let r = simulate(t.build(templateParams(0.2, stubLength = 0.02)), edgeStimulus(edRising), conv())
    check r.status == ssOk
    check r.ladders.len == 0
    check r.convolution.len >= 3
