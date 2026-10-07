## Stage 3 of docs/ibis_simulator_plan.md, validation ladder rungs 1, 2 and 6
## on the raw engine (`si/engine/*`), before any IBIS device exists. Every
## golden waveform is closed-form or a lattice diagram; every run is also
## repeated at half the step and must agree (convergence, not just
## matching sampled points).

import std/[unittest, math, strutils]

import verax/ibis/behave
import verax/si/engine/transient

proc stepSrc(v: float, t0 = 0.0): Pwl =
  ## 0 before `t0`, `v` from `t0` on (a jump).
  result.add t0, 0.0
  result.add t0, v

proc nodeAt(r: TranResult, node: int, t: float): float =
  ## Linear interpolation of a recorded node voltage.
  for k in 0 ..< r.t.len - 1:
    if t >= r.t[k] and t <= r.t[k + 1]:
      let f = (t - r.t[k]) / (r.t[k + 1] - r.t[k])
      return r.v[node][k] + f * (r.v[node][k + 1] - r.v[node][k])
  r.v[node][^1]

proc maxErr(r: TranResult, node: int, f: proc(t: float): float, tFrom = 0.0): float =
  for k, t in r.t:
    if t < tFrom: continue
    result = max(result, abs(r.v[node][k] - f(t)))

proc rcCircuit(r, c: float): (Circuit, int) =
  var ck = newCircuit()
  let s = ck.addNode("src")
  let o = ck.addNode("out")
  ck.vsources.add VSrc(a: s, b: 0, wave: stepSrc(1.0))
  ck.resistors.add Res(a: s, b: o, r: r)
  ck.capacitors.add Cap(a: o, b: 0, c: c)
  (ck, o)

suite "rung 1: lumped step responses (closed form)":
  test "RC":
    let (ck, o) = rcCircuit(1e3, 1e-9)
    let tau = 1e-6
    var errs: seq[float]
    for hm in [tau / 50, tau / 100]:
      var opt = defaultSimOptions(5 * tau)
      opt.hMax = hm
      let r = transient(ck, opt)
      check r.ok
      errs.add r.maxErr(o, proc(t: float): float = 1 - exp(-t / tau))
    check errs[0] < 2e-3
    check errs[1] < errs[0]          # converges with h

  test "RL":
    var ck = newCircuit()
    let s = ck.addNode("src")
    let m = ck.addNode("mid")
    ck.vsources.add VSrc(a: s, b: 0, wave: stepSrc(1.0))
    ck.resistors.add Res(a: s, b: m, r: 10.0)
    ck.inductors.add Ind(a: m, b: 0, l: 1e-6)
    let tau = 1e-7
    var opt = defaultSimOptions(5 * tau)
    opt.hMax = tau / 100
    let r = transient(ck, opt)
    check r.ok
    # Inductor voltage = exp(-t/tau).
    check r.maxErr(m, proc(t: float): float = exp(-t / tau), tFrom = tau / 10) < 2e-3
    # Source current (a -> b through the source is -i into the circuit).
    check abs(-r.srcI[0][^1] - 0.1 * (1 - exp(-5.0))) < 1e-3

  test "series RLC, underdamped":
    var ck = newCircuit()
    let s = ck.addNode("src")
    let m = ck.addNode("m")
    let o = ck.addNode("o")
    ck.vsources.add VSrc(a: s, b: 0, wave: stepSrc(1.0))
    ck.resistors.add Res(a: s, b: m, r: 1.0)
    ck.inductors.add Ind(a: m, b: o, l: 10e-9)
    ck.capacitors.add Cap(a: o, b: 0, c: 1e-9)
    let a = 1.0 / (2 * 10e-9)
    let w0 = 1.0 / sqrt(10e-9 * 1e-9)
    let wd = sqrt(w0 * w0 - a * a)
    let f = proc(t: float): float = 1 - exp(-a * t) * (cos(wd * t) + a / wd * sin(wd * t))
    var errs: seq[float]
    for nd in [200.0, 400.0]:
      var opt = defaultSimOptions(100e-9)
      opt.hMax = (2 * PI / wd) / nd
      let r = transient(ck, opt)
      check r.ok
      errs.add r.maxErr(o, f)
    check errs[0] < 5e-3
    check errs[1] < errs[0]

  test "zero and tiny time constants":
    # C = 0: the output follows the step at once.
    let (ck, o) = rcCircuit(1e3, 0.0)
    var opt = defaultSimOptions(1e-9)
    opt.hMax = 1e-10
    let r = transient(ck, opt)
    check r.ok
    check abs(r.v[o][^1] - 1.0) < 1e-9
    # L = 0 is an exact short, R = 0 an exact 0 V branch.
    var ck2 = newCircuit()
    let s = ck2.addNode("s")
    let m = ck2.addNode("m")
    let n = ck2.addNode("n")
    ck2.vsources.add VSrc(a: s, b: 0, wave: stepSrc(2.0))
    ck2.inductors.add Ind(a: s, b: m, l: 0.0)
    ck2.resistors.add Res(a: m, b: n, r: 0.0)
    ck2.resistors.add Res(a: n, b: 0, r: 100.0)
    let r2 = transient(ck2, opt)
    check r2.ok
    check abs(r2.v[n][^1] - 2.0) < 1e-9
    # tau far below the step: settles within one step, no ringing.
    let (ck3, o3) = rcCircuit(1.0, 1e-15)
    let r3 = transient(ck3, opt)
    check r3.ok
    for k in 3 ..< r3.t.len: check abs(r3.v[o3][k] - 1.0) < 1e-6

proc lineCircuit(rs, rl, z0, td: float): (Circuit, int, int) =
  ## Step source -- Rs -- line -- RL. `rl = Inf` is open, `0` a short.
  var ck = newCircuit()
  let s = ck.addNode("s")
  let a = ck.addNode("near")
  let b = ck.addNode("far")
  ck.vsources.add VSrc(a: s, b: 0, wave: stepSrc(1.0))
  ck.resistors.add Res(a: s, b: a, r: rs)
  ck.lines.add Line(a: a, b: b, z0: z0, td: td, label: "tl")
  if rl < Inf: ck.resistors.add Res(a: b, b: 0, r: rl)
  (ck, a, b)

suite "rung 2: lossless line, lattice diagram":
  let td = 1e-9
  proc run(rs, rl: float, hdiv = 10.0): (TranResult, int, int) =
    let (ck, a, b) = lineCircuit(rs, rl, 50.0, td)
    var opt = defaultSimOptions(10 * td)
    opt.hMax = td / hdiv
    (transient(ck, opt), a, b)

  test "matched: nothing before td, then the full step, no reflection":
    let (r, a, b) = run(50.0, 50.0)
    check r.ok
    for k, t in r.t:
      if t < td - 1e-15: check abs(r.v[b][k]) < 1e-12
    check abs(r.nodeAt(b, 1.5 * td) - 0.5) < 1e-9
    check abs(r.nodeAt(a, 0.5 * td) - 0.5) < 1e-9
    check abs(r.nodeAt(a, 5.5 * td) - 0.5) < 1e-9     # nothing came back

  test "open end doubles, reflection reaches the source at 2 td":
    let (r, a, b) = run(50.0, Inf)
    check abs(r.nodeAt(b, 1.5 * td) - 1.0) < 1e-9
    check abs(r.nodeAt(a, 1.5 * td) - 0.5) < 1e-9
    check abs(r.nodeAt(a, 2.5 * td) - 1.0) < 1e-9

  test "short end reflects with inverted sign":
    let (r, a, b) = run(50.0, 0.0)
    check abs(r.nodeAt(b, 1.5 * td)) < 1e-9
    check abs(r.nodeAt(a, 1.5 * td) - 0.5) < 1e-9
    check abs(r.nodeAt(a, 2.5 * td)) < 1e-9

  test "mismatched both ends: lattice plateaus":
    # Gs = -1/3, Gl = +1/3, launch 2/3.
    for hdiv in [10.0, 20.0]:
      let (r, _, b) = run(25.0, 100.0, hdiv)
      check abs(r.nodeAt(b, 0.5 * td)) < 1e-12
      check abs(r.nodeAt(b, 2.0 * td) - 8.0 / 9.0) < 1e-9
      check abs(r.nodeAt(b, 4.0 * td) - 64.0 / 81.0) < 1e-9
      check abs(r.nodeAt(b, 6.0 * td) - (64.0 / 81.0 + 8.0 / 729.0)) < 1e-9

  test "td not a multiple of h: interpolated history keeps the plateaus":
    let (ck, a, b) = lineCircuit(25.0, 100.0, 50.0, 1.03e-9)
    var opt = defaultSimOptions(10e-9)
    opt.hMax = 0.07e-9
    let r = transient(ck, opt)
    check abs(r.nodeAt(b, 2.0e-9) - 8.0 / 9.0) < 1e-9
    check abs(r.nodeAt(b, 4.2e-9) - 64.0 / 81.0) < 1e-9

  test "a passive channel creates no energy":
    var ck = newCircuit()
    let s = ck.addNode("s")
    let a = ck.addNode("near")
    let b = ck.addNode("far")
    var pulse: Pwl
    pulse.add 0.0, 0.0
    pulse.add 0.0, 1.0
    pulse.add 1e-9, 1.0
    pulse.add 1e-9, 0.0
    ck.vsources.add VSrc(a: s, b: 0, wave: pulse)
    ck.resistors.add Res(a: s, b: a, r: 20.0)
    ck.lines.add Line(a: a, b: b, z0: 50.0, td: 0.7e-9)
    ck.resistors.add Res(a: b, b: 0, r: 200.0)
    var opt = defaultSimOptions(40e-9)
    opt.hMax = 0.01e-9
    let r = transient(ck, opt)
    var eSrc, eDiss: float
    for k in 1 ..< r.t.len:
      let dt = r.t[k] - r.t[k - 1]
      template p(j: int): untyped =
        (let vs = r.v[s][j]; let i = -r.srcI[0][j];
         (vs * i, (vs - r.v[a][j]) ^ 2 / 20.0 + r.v[b][j] ^ 2 / 200.0))
      let (ps0, pd0) = p(k - 1)
      let (ps1, pd1) = p(k)
      eSrc += 0.5 * (ps0 + ps1) * dt
      eDiss += 0.5 * (pd0 + pd1) * dt
    check eSrc > 0
    check abs(eDiss - eSrc) / eSrc < 0.02
    check abs(r.v[b][^1]) < 1e-6

  test "a line shorter than tr/20 becomes a lumped pi":
    let (ck, _, b) = lineCircuit(50.0, 50.0, 50.0, 1e-12)
    var opt = defaultSimOptions(2e-9)
    opt.tr = 1e-9
    let r = transient(ck, opt)
    check r.lumped.len == 1
    check abs(r.hBase - 0.05e-9) < 1e-18
    # A lumped pi far below 1/h rings at trapezoidal's Nyquist mode; tiny.
    check abs(r.v[b][^1] - 0.5) < 1e-3
    var opt2 = opt
    opt2.tr = 1e-11
    let r2 = transient(ck, opt2)
    check r2.lumped.len == 0
    check r2.hBase <= 1e-12

proc diodeCurve(knee, rOn: float): IvCurve =
  ## Sinks current above `knee` with slope `1/rOn` (out-of-die negative).
  IvCurve(v: @[-5.0, knee, 10.0], i: @[0.0, 0.0, -(10.0 - knee) / rOn])

suite "rung 3 prep: a plain nonlinear shunt":
  test "DC and transient through a clamp knee":
    var ck = newCircuit()
    let s = ck.addNode("s")
    let o = ck.addNode("o")
    ck.vsources.add VSrc(a: s, b: 0, wave: stepSrc(2.0))
    ck.resistors.add Res(a: s, b: o, r: 100.0)
    ck.capacitors.add Cap(a: o, b: 0, c: 1e-12)
    ck.devices.add NlDevice(node: o, curves: @[diodeCurve(0.7, 1.0)], label: "clamp")
    var opt = defaultSimOptions(2e-9)
    opt.hMax = 1e-11
    let r = transient(ck, opt)
    check r.ok
    let expect = (0.02 + 0.7) / 1.01
    check abs(r.v[o][^1] - expect) < 1e-6
    # The device carries the KCL balance.
    check abs(r.devI[0][^1] + (expect - 0.7)) < 1e-6

suite "rung 6: robustness":
  test "steep clamp knee converges":
    var ck = newCircuit()
    let s = ck.addNode("s")
    let o = ck.addNode("o")
    ck.vsources.add VSrc(a: s, b: 0, wave: stepSrc(5.0))
    ck.resistors.add Res(a: s, b: o, r: 10.0)
    ck.capacitors.add Cap(a: o, b: 0, c: 1e-12)
    ck.devices.add NlDevice(node: o, curves: @[diodeCurve(3.3, 1e-3)], label: "clamp")
    var opt = defaultSimOptions(1e-9)
    opt.hMax = 1e-11
    let r = transient(ck, opt)
    check r.ok
    check abs(r.v[o][^1] - 3.3) < 2e-3

  test "forced non-convergence is a failure with time, node and step":
    var ck = newCircuit()
    let s = ck.addNode("s")
    let o = ck.addNode("pad")
    ck.vsources.add VSrc(a: s, b: 0, wave: stepSrc(5.0, 0.5e-9))
    ck.resistors.add Res(a: s, b: o, r: 10.0)
    ck.capacitors.add Cap(a: o, b: 0, c: 1e-12)
    ck.devices.add NlDevice(node: o, curves: @[diodeCurve(3.3, 1e-3)], label: "clamp")
    var opt = defaultSimOptions(1e-9)
    opt.hMax = 1e-11
    opt.newton.maxIter = 1
    let r = transient(ck, opt)
    check not r.ok
    check "pad" in r.failure
    check "t = " in r.failure
    check "halvings" in r.failure
    check r.issues[0].kind == "si_solver_failure"

  test "deterministic: equal breakpoints, identical runs":
    var ck = newCircuit()
    let s = ck.addNode("s")
    let s2 = ck.addNode("s2")
    let o = ck.addNode("o")
    ck.vsources.add VSrc(a: s, b: 0, wave: stepSrc(1.0, 1e-9))
    ck.vsources.add VSrc(a: s2, b: 0, wave: stepSrc(1.0, 1e-9))
    ck.resistors.add Res(a: s, b: o, r: 50.0)
    ck.resistors.add Res(a: s2, b: o, r: 50.0)
    ck.capacitors.add Cap(a: o, b: 0, c: 1e-12)
    var opt = defaultSimOptions(3e-9)
    opt.hMax = 0.1e-9
    let r1 = transient(ck, opt)
    let r2 = transient(ck, opt)
    check r1.t == r2.t
    check r1.v == r2.v
    var at1 = 0
    for t in r1.t:
      if abs(t - 1e-9) < 1e-15: inc at1
    check at1 == 1

  test "the table-range issue fires when a pad leaves its table":
    var ck = newCircuit()
    let s = ck.addNode("s")
    let o = ck.addNode("o")
    ck.vsources.add VSrc(a: s, b: 0, wave: stepSrc(20.0))
    ck.resistors.add Res(a: s, b: o, r: 1e6)
    ck.devices.add NlDevice(node: o, curves: @[IvCurve(v: @[0.0, 1.0], i: @[0.0, -1e-9])], label: "tiny")
    var opt = defaultSimOptions(1e-9)
    opt.hMax = 1e-10
    let r = transient(ck, opt)
    check r.ok
    var found = false
    for i in r.issues:
      if i.kind == "si_table_range": found = true
    check found
