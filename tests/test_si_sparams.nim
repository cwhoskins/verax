## Stage 8.5 of docs/ibis_simulator_plan.md: an S-parameter channel (a
## Touchstone 2-port) as an engine element by its impulse response,
## checked against lines whose S-parameters are known in closed form.

import std/[unittest, math, complex, streams, strutils]

import verax/touchstone
import verax/si/engine/transient
import verax/si/engine/convline
import verax/si/engine/ratfit

proc lineS(z, tau, r, g: float, fMax = 20e9, df = 10e6, zRef = 50.0): SParams =
  ## A uniform line (per-unit-length R, G scaled into one section of delay
  ## `tau`) as `S` at `zRef`, through its ABCD.
  result = SParams(nPorts: 2, z0: zRef)
  let l = z * tau
  let c = tau / z
  var f = df
  while f <= fMax + 1:
    let w = 2 * PI * f
    let zs = complex(r, w * l)
    let ys = complex(g, w * c)
    let gl = sqrt(zs * ys)
    let zc = sqrt(zs / ys)
    let a = cosh(gl)
    let b = zc * sinh(gl)
    let cc = sinh(gl) / zc
    let d = a
    let z0c = complex(zRef, 0.0)
    let den = a + b / z0c + cc * z0c + d
    result.freqs.add f
    result.points.add @[(a + b / z0c - cc * z0c - d) / den,
                        complex(2.0, 0.0) * (a * d - b * cc) / den,
                        complex(2.0, 0.0) / den,
                        (-a + b / z0c - cc * z0c + d) / den]
    f += df

proc ramp(v, t0, tr: float): Pwl =
  result.add 0.0, 0.0
  result.add t0, 0.0
  result.add t0 + tr, v

proc run(withBlock: bool, sp: SParams, z, td, rl: float, tStop = 12e-9,
         conv = ConvLine(), useConv = false): tuple[t, near, far: seq[float]] =
  var c = newCircuit()
  let s = c.addNode("s")
  let n1 = c.addNode("n1")
  let n2 = c.addNode("n2")
  c.vsources.add VSrc(a: s, b: 0, wave: ramp(1.0, 0.5e-9, 0.2e-9), label: "Vs")
  c.resistors.add Res(a: s, b: n1, r: 50.0, label: "Rs")
  c.resistors.add Res(a: n2, b: 0, r: rl, label: "RL")
  if useConv:
    var ln = conv
    ln.a = n1
    ln.b = n2
    c.convLines.add ln
  elif withBlock:
    c.sblocks.add impulseTaps(sp, n1, n2, label = "channel").sb
  else:
    c.lines.add Line(a: n1, b: n2, z0: z, td: td, label: "line")
  var o = defaultSimOptions(tStop)
  o.tr = 0.2e-9
  o.hMax = 10e-12
  let r = transient(c, o)
  doAssert r.ok, r.failure
  (r.t, r.v[n1], r.v[n2])

proc worstDiff(a, b: tuple[t, near, far: seq[float]]): float =
  ## On `a`'s time grid, `b` interpolated.
  var j = 0
  for k, t in a.t:
    while j < b.t.len - 2 and b.t[j + 1] < t: inc j
    let f = clamp((t - b.t[j]) / (b.t[j + 1] - b.t[j]), 0.0, 1.0)
    let bn = b.near[j] + f * (b.near[j + 1] - b.near[j])
    let bf = b.far[j] + f * (b.far[j + 1] - b.far[j])
    result = max(result, max(abs(a.near[k] - bn), abs(a.far[k] - bf)))

suite "S-parameter block":
  test "taps: a matched lossless line is a delayed unit impulse, DC exact":
    let sp = lineS(50.0, 1e-9, 0.0, 0.0)
    let tr = impulseTaps(sp, 1, 2)
    let b = tr.sb
    check abs(b.dt - 25e-12) < 1e-18
    var peak = 0
    for k in 0 ..< b.taps[2].len:
      if abs(b.taps[2][k]) > abs(b.taps[2][peak]): peak = k
    check abs(peak.float * b.dt - 1e-9) <= b.dt
    var sum = 0.0
    for x in b.taps[2]: sum += x
    check abs(sum - 1.0) < 1e-9
    check tr.nonCausal < 0.01

  test "matched 50 ohm line: as Bergeron's, into a 1 k load":
    let sp = lineS(50.0, 1e-9, 0.0, 0.0)
    let a = run(true, sp, 50.0, 1e-9, 1000.0)
    let b = run(false, sp, 50.0, 1e-9, 1000.0)
    let e = worstDiff(a, b)
    checkpoint "worst " & $e
    check e < 0.01
    check abs(a.far[^1] - 1000.0 / 1050.0) < 2e-3   # settles at the DC divider

  test "75 ohm line in a 50 ohm reference: reflections from S11/S22":
    let sp = lineS(75.0, 0.8e-9, 0.0, 0.0)
    let a = run(true, sp, 75.0, 0.8e-9, 1000.0)
    let b = run(false, sp, 75.0, 0.8e-9, 1000.0)
    let e = worstDiff(a, b)
    checkpoint "worst " & $e
    check e < 0.03

  test "lossy line: as the convolution line of the same RLGC":
    # 0.3 m of R = 5 ohm/m, Z 50, 6 ns/m: R 1.5 ohm, td 1.8 ns.
    let sp = lineS(50.0, 1.8e-9, 1.5, 0.0)
    let l = 50.0 * 6e-9
    let cpm = 6e-9 / 50.0
    var fs: seq[float]
    var yc, hm: seq[Complex64]
    let tau = 1.8e-9
    var f = 1e6
    while f < 1e11:
      let sj = complex(0.0, 2 * PI * f)
      let zz = complex(5.0, 2 * PI * f * l)
      let yy = complex(0.0, 2 * PI * f * cpm)
      fs.add f
      yc.add sqrt(yy / zz)
      hm.add exp(-sqrt(zz * yy) * complex(0.3, 0.0) + sj * complex(tau, 0.0))
      f *= 1.2
    let poles = logPoles(1e5, 1e12, 6)
    let conv = ConvLine(tau: tau, rDc: 5.0, gDc: 0.0, length: 0.3,
                        yc: fitRational(fs, yc, 0.0, poles),
                        hm: fitRational(fs, hm, 1.0, poles))
    let a = run(true, sp, 0, 0, 1000.0, 15e-9)
    let b = run(false, sp, 0, 0, 1000.0, 15e-9, conv, useConv = true)
    let e = worstDiff(a, b)
    checkpoint "worst " & $e
    check e < 0.01
    check abs(a.far[^1] - 1000.0 / 1051.5) < 3e-3

  test "a Touchstone file in, the same block out":
    let sp = lineS(50.0, 1e-9, 0.0, 0.0, fMax = 10e9, df = 20e6)
    var txt = "# HZ S RI R 50\n"
    for k, f in sp.freqs:
      let p = sp.points[k]
      txt.add $f
      for x in [p[0], p[2], p[1], p[3]]:   # 2-port file order: S11 S21 S12 S22
        txt.add " " & $x.re & " " & $x.im
      txt.add "\n"
    let back = readTouchstone(newStringStream(txt), "line.s2p")
    check back.nPorts == 2
    let t1 = impulseTaps(sp, 1, 2).sb
    let t2 = impulseTaps(back, 1, 2).sb
    var d = 0.0
    for k in 0 ..< t1.taps[2].len: d = max(d, abs(t1.taps[2][k] - t2.taps[2][k]))
    check d < 1e-9

# --- in a template ----------------------------------------------------------

import verax/ibis
import verax/si/simulate
import verax/si/sweep
import ./fixtures/ibis/synthetic

suite "a channel in a template":
  test "a Touchstone channel after the trunk: as the same line, simulated":
    var d = defaultLinearDriver()
    d.rpu = 50.0
    d.rpd = 50.0
    let drv = driverBehaviour(readIbis(newStringStream(d.toIbs())).model(d.name))
    let rx = receiverBehaviour(readIbis(newStringStream(linearReceiverIbs())).model("lin_rx"))
    var t = SiTemplate(name: "ch", driver: drv, topology: ttPointToPoint,
                       driverPort: TemplatePort(label: "U1.1"), line: idealLine(50.0, 6e-9),
                       receivers: @[rx], receiverPorts: @[TemplatePort(label: "U2.1")])
    t.channel = lineS(50.0, 1.2e-9, 0.0, 0.0)
    t.hasChannel = true
    t.channelName = "cable.s2p"
    let withCh = t.build(templateParams(0.05))
    let r1 = simulate(withCh, edgeStimulus(edRising, 0.5e-9))
    check r1.status == ssOk
    var said = false
    for a in r1.assumptions:
      if "impulse response" in $a: said = true
    check said
    # The same, the channel as a 0.2 m trunk extension (0.05 + 0.2 m at 6 ns/m).
    var plain = t
    plain.hasChannel = false
    let r2 = simulate(plain.build(templateParams(0.25)), edgeStimulus(edRising, 0.5e-9))
    var worst = 0.0
    var j = 0
    for k, tt in r1.t:
      while j < r2.t.len - 2 and r2.t[j + 1] < tt: inc j
      let f = clamp((tt - r2.t[j]) / (r2.t[j + 1] - r2.t[j]), 0.0, 1.0)
      let v2 = r2.receivers[0].v[j] + f * (r2.receivers[0].v[j + 1] - r2.receivers[0].v[j])
      worst = max(worst, abs(r1.receivers[0].v[k] - v2))
    checkpoint "worst " & $worst
    check worst < 0.05 * 3.3
    let sw = sweepNet([SweepCorner(corner: coTyp, net: withCh)], sweepStimuli(NaN))
    check sw.status == ssOk
