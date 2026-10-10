## One forward SI run: an `SiNet` and a `Stimulus` in, an `SiResult` out --
## the waveform and current at every die pad and pin, with the decision-6
## status so a failed or unsupported run can never be read as a waveform.
##
## Lossy lines, by `SiOptions.lossyModel`:
##
## - **`lmLadder`**: an RLGC ladder through the linear core, RLGC
##   at one frequency. Section count rule: each section's delay is at most
##   `ladderFraction * tr` (default 1/10); `ladderMultiplier` scales the
##   count for the convergence test (doubling it must change the answer by
##   less than the tolerance).
## - **`lmConvolution`** (default): recursive convolution (`engine/convline`). A line
##   that kept its cross-section (`hasSpec`) uses `impedance.causalLine`
##   over frequency; otherwise its constant RLGC. Fitted over
##   `0.1 / tStop .. clamp(10 / tr, 1 GHz, 100 GHz)`, 20 samples and
##   `convPolesPerDecade` real poles per decade (poles one decade beyond
##   the band each side). A fit worse than `convFitTol` of its peak falls
##   back to the ladder, warned; so does a line whose delay is under the
##   lumping threshold.

import std/[math, strutils, complex, algorithm]
import ./topology
import ./drive
import ./engine/transient
import ./engine/ibisdev
import ./engine/ratfit
import ../pcb/impedance
import ../netlist/annotations

export topology, drive, transient

type
  SiStatus* = enum
    ssOk             ## simulated; the waveform is valid
    ssUnsupported    ## input/model support missing -> `esNotEvaluable`
    ssSolverFailed   ## Newton gave up -> `esNotEvaluated`

  SiWave* = object
    label*: string
    node*: int
    v*: seq[float]
    i*: seq[float]
      ## Current out of the die into the package (die waves only).

  LossyModel* = enum
    lmLadder, lmConvolution

  SiOptions* = object
    tStop*: float
      ## `NaN`: the drive's last change + 10x the total line delay + 3 tr,
      ## and at least to the end of a pattern's last bit.
    hMax*: float
    newton*: NewtonOptions
    maxHalvings*: int
    lumpFraction*: float
    ladderFraction*: float
    ladderMultiplier*: float
    lossyModel*: LossyModel
    convPolesPerDecade*: int
    convFitTol*: float

  SiResult* = object
    status*: SiStatus
    reason*: string
    net*: string
    stimulus*: Stimulus
    t*: seq[float]
    driver*, driverPin*: SiWave
    receivers*, receiverPins*: seq[SiWave]
    extraDrivers*, extraDriverPins*: seq[SiWave]
      ## Other conductors' drivers, in `SiNet.extraDrivers` order.
    nodes*: seq[string]
    v*: seq[seq[float]]
      ## Every node, `[node][step]`.
    rails*: Rails
    tr*: float
    hBase*: float
    steps*: int
    factorizations*, solves*: int
      ## LU factorisations vs substitutions: how often the factor was reused.
    ladders*: seq[tuple[label: string, sections: int]]
    convolution*: seq[string]
      ## Lossy lines simulated by recursive convolution.
    lumped*: seq[string]
    assumptions*: seq[Assumption]
    issues*: seq[Issue]

proc defaultSiOptions*(): SiOptions =
  SiOptions(tStop: NaN, hMax: Inf, newton: defaultNewton(), maxHalvings: 10,
            lumpFraction: 0.05, ladderFraction: 0.1, ladderMultiplier: 1.0,
            lossyModel: lmConvolution, convPolesPerDecade: 6, convFitTol: 1e-2)

proc totalDelay*(n: SiNet): float =
  ## Sum of every line's delay: an upper bound on any path's.
  for e in n.elements:
    case e.kind
    of sekLine: result += e.td
    of sekLossyLine: result += e.length * sqrt(e.l * e.c)
    of sekCoupledLine: result += max(e.tdEven, e.tdOdd)
    of sekSParams:
      # Up to the S21 impulse's peak: the channel's delay.
      let tr = impulseTaps(e.sparams, 1, 2)
      var pk = 0
      for k in 0 ..< tr.sb.taps[2].len:
        if abs(tr.sb.taps[2][k]) > abs(tr.sb.taps[2][pk]): pk = k
      result += pk.float * tr.sb.dt
    else: discard

proc lineDelay(e: SiElement): float =
  ## The asymptotic (fastest) delay: the causal dielectric's `eps_inf`
  ## with a cross-section, else `sqrt(LC)`.
  if e.hasSpec: e.length * sqrt(e.l * causalHighFrequencyC(e.spec, e.fRef))
  else: e.length * sqrt(e.l * e.c)

proc convLineFor*(e: SiElement, a, b: int, tStop, tr: float, perDecade: int):
    tuple[line: ConvLine, note: string] =
  ## Fit `Yc` and the delay-free `H` of a lossy element.
  let fLo = 0.1 / tStop
  let fHi = clamp((if tr.isNaN: 1e10 else: 10.0 / tr), 1e9, 1e11)
  let tau = lineDelay(e)
  var fs: seq[float]
  var yc, hm: seq[Complex64]
  let n = max(2, int(ceil(log10(fHi / fLo) * 20)) + 1)
  for k in 0 ..< n:
    let f = fLo * pow(fHi / fLo, k.float / (n - 1).float)
    let sj = complex(0.0, 2 * PI * f)
    let (z, y) =
      if e.hasSpec: causalLine(e.spec, f, e.fRef)
      else: (complex(e.r, 2 * PI * f * e.l), complex(e.g, 2 * PI * f * e.c))
    fs.add f
    yc.add sqrt(y / z)
    hm.add exp(-sqrt(z * y) * complex(e.length, 0.0) + sj * complex(tau, 0.0))
  let (rDc, gDc) =
    if e.hasSpec: (e.spec.rho / max(e.spec.w * e.spec.t, 1e-18), 0.0)
    else: (e.r, e.g)
  let ycDc = if gDc > 0: sqrt(gDc / rDc) elif rDc > 0: 0.0 else: sqrt(e.c / e.l)
  let hDc = exp(-e.length * sqrt(rDc * gDc))
  let poles = logPoles(fLo / 10, fHi * 10, perDecade)
  result.line = ConvLine(a: a, b: b, tau: tau, rDc: rDc, gDc: gDc, length: e.length,
                         label: e.label,
                         yc: fitRational(fs, yc, ycDc, poles),
                         hm: fitRational(fs, hm, hDc, poles))
  proc frac(x: float): string = formatFloat(x, ffScientific, 1)
  result.note = "lossy line by recursive convolution: " & $poles.len & " real poles each for Yc " &
    "and H, fitted " & formatFloat(fLo / 1e6, ffDecimal, 3) & " MHz .. " &
    formatFloat(fHi / 1e9, ffDecimal, 1) & " GHz (error " & frac(result.line.yc.maxErr) &
    " / " & frac(result.line.hm.maxErr) & " of peak)" &
    (if e.hasSpec: "; RLGC over frequency in causal form (skin effect Rdc + Rac(1+j), " &
                   "Djordjevic-Sarkar dielectric matching tand at " &
                   formatFloat(e.fRef / 1e9, ffDecimal, 3) & " GHz)"
     else: "; RLGC constant over frequency")

proc simulate*(net: SiNet, stim: Stimulus, o = defaultSiOptions()): SiResult =
  result = SiResult(net: net.name, stimulus: stim, nodes: net.nodes,
                    assumptions: net.assumptions, issues: net.issues,
                    rails: net.driver.rails)
  if net.unsupported.len > 0:
    result.status = ssUnsupported
    result.reason = net.unsupported.join("; ")
    return
  var dw = driveWaves(net.driver, stim)
  result.issues.add dw.issues
  if not dw.supported:
    result.status = ssUnsupported
    result.reason = dw.reason
    return
  # Every other conductor's driver.
  var extra: seq[DriveWaves]
  for x in net.extraDrivers:
    let s =
      case x.mode
      of dmStimulus: stim.delayed(x.skew)
      of dmInverted: stim.complement.delayed(x.skew)
      of dmQuietLow: held(false)
      of dmQuietHigh: held(true)
    let w = driveWaves(x.behaviour, s)
    result.issues.add w.issues
    if not w.supported:
      result.status = ssUnsupported
      result.reason = x.port.label & ": " & w.reason
      return
    extra.add w
  var tr0 = dw.tr
  var lastChange = dw.lastChange
  for w in extra:
    if not w.tr.isNaN: tr0 = (if tr0.isNaN: w.tr else: min(tr0, w.tr))
    lastChange = max(lastChange, w.lastChange)
  dw.tr = tr0
  dw.lastChange = lastChange
  result.tr = dw.tr
  var tStop = o.tStop
  if tStop.isNaN:
    let tr = if dw.tr.isNaN: 1e-9 else: dw.tr
    tStop = max(dw.lastChange + 10.0 * totalDelay(net) + 3.0 * tr, 2e-9)
    if stim.kind == skPattern:
      # A pattern lasts its whole last bit.
      tStop = max(tStop, stim.delay + stim.bits.len.float * stim.ui)
  var c = newCircuit()
  for k in 1 ..< net.nodes.len: discard c.addNode(net.nodes[k])
  for e in net.elements:
    case e.kind
    of sekResistor: c.resistors.add Res(a: e.a, b: e.b, r: e.value, label: e.label)
    of sekInductor: c.inductors.add Ind(a: e.a, b: e.b, l: e.value, label: e.label)
    of sekCapacitor: c.capacitors.add Cap(a: e.a, b: e.b, c: e.value, label: e.label)
    of sekVoltage: c.vsources.add VSrc(a: e.a, b: e.b, wave: constPwl(e.value), label: e.label)
    of sekLine: c.lines.add Line(a: e.a, b: e.b, z0: e.z0, td: e.td, label: e.label)
    of sekSParams:
      let tp = impulseTaps(e.sparams, e.a, e.b, label = e.label)
      c.sblocks.add tp.sb
      result.assumptions.add note(e.label, "S-parameter block by impulse response: " & tp.note &
        "; the file's data below its first point extrapolated to a real DC value")
      if tp.nonCausal > 0.01:
        result.issues.add newIssue("si_sparams_noncausal", sevWarning, e.label & ": " &
          formatFloat(tp.nonCausal * 100, ffDecimal, 1) & " % of the impulse response's " &
          "energy is non-causal or past the kept window; the data may be non-causal or " &
          "too coarse in frequency")
    of sekCoupledLine:
      c.coupled.add CoupledLine(a1: e.a, b1: e.b, a2: e.a2, b2: e.b2, zEven: e.zEven,
                                zOdd: e.zOdd, tdEven: e.tdEven, tdOdd: e.tdOdd,
                                label: e.label)
    of sekLossyLine:
      if o.lossyModel == lmConvolution and
         (dw.tr.isNaN or lineDelay(e) >= o.lumpFraction * dw.tr):
        let (ln, why) = convLineFor(e, e.a, e.b, tStop, dw.tr, o.convPolesPerDecade)
        if max(ln.yc.maxErr, ln.hm.maxErr) <= o.convFitTol:
          c.convLines.add ln
          result.convolution.add e.label
          result.assumptions.add note(e.label, why)
          continue
        result.issues.add newIssue("si_conv_fit", sevWarning, e.label & ": " & why &
          " exceeds " & $o.convFitTol & "; simulated as a ladder instead")
      let td = e.length * sqrt(e.l * e.c)
      var n =
        if dw.tr.isNaN: 10
        else: max(1, int(ceil(td / (o.ladderFraction * dw.tr))))
      n = max(1, int(ceil(n.float * o.ladderMultiplier)))
      result.ladders.add (e.label, n)
      let dx = e.length / n.float
      var prev = e.a
      for k in 0 ..< n:
        let mid = c.addNode(e.label & ":r" & $k)
        let nxt = if k == n - 1: e.b else: c.addNode(e.label & ":n" & $(k + 1))
        c.resistors.add Res(a: prev, b: mid, r: e.r * dx, label: e.label)
        c.inductors.add Ind(a: mid, b: nxt, l: e.l * dx, label: e.label)
        for nd in [prev, nxt]:
          c.capacitors.add Cap(a: nd, b: 0, c: e.c * dx / 2, label: e.label)
          if e.g > 0: c.resistors.add Res(a: nd, b: 0, r: 2.0 / (e.g * dx), label: e.label)
        prev = nxt
      result.assumptions.add note(e.label,
        "lossy line as a " & $n & "-section RLGC ladder, RLGC taken at one frequency")
  # Buffers.
  let dp = net.driverPort
  let vccDie = if net.supply.present: net.supply.vccDie else: 0
  let gndDie = if net.supply.present: net.supply.gndDie else: 0
  c.devices.add driverDevice(net.driver, dp.dieNode, dw.ku, dw.kd, dp.label, vccDie, gndDie)
  let dCap = c.capacitors.len
  c.capacitors.add Cap(a: dp.dieNode, b: 0, c: net.driver.cComp, label: dp.label & " C_comp")
  var rCaps: seq[int]
  for k, r in net.receivers:
    let p = net.receiverPorts[k]
    c.devices.add receiverDevice(r, p.dieNode, p.label)
    rCaps.add c.capacitors.len
    c.capacitors.add Cap(a: p.dieNode, b: 0, c: r.cComp, label: p.label & " C_comp")
  var xCaps: seq[int]
  for k, x in net.extraDrivers:
    c.devices.add driverDevice(x.behaviour, x.port.dieNode, extra[k].ku, extra[k].kd,
                               x.port.label, vccDie, gndDie)
    xCaps.add c.capacitors.len
    c.capacitors.add Cap(a: x.port.dieNode, b: 0, c: x.behaviour.cComp,
                         label: x.port.label & " C_comp")
  # Pre-driver current (power-aware): every switching driver's, rail to
  # rail, from each transition it makes.
  if net.supply.present:
    var pieces: seq[tuple[t0: float, w: tuple[t, i: seq[float]]]]
    proc addFor(d: DriverBehaviour, s: Stimulus) =
      for (t0, e) in transitionsOf(s):
        if d.preDriver[e].t.len >= 2: pieces.add (t0, d.preDriver[e])
    addFor(net.driver, stim)
    for x in net.extraDrivers:
      case x.mode
      of dmStimulus: addFor(x.behaviour, stim.delayed(x.skew))
      of dmInverted: addFor(x.behaviour, stim.complement.delayed(x.skew))
      else: discard
    if pieces.len > 0:
      var ts: seq[float]
      for p in pieces:
        for t in p.w.t: ts.add p.t0 + t
      ts.sort()
      var wave: Pwl
      wave.add 0.0, 0.0
      for t in ts:
        if t <= wave.t[^1]: continue
        var i = 0.0
        for p in pieces:
          let tt = t - p.t0
          if tt >= p.w.t[0] and tt <= p.w.t[^1]:
            var k = 0
            while k < p.w.t.len - 2 and p.w.t[k + 1] < tt: inc k
            let f = (tt - p.w.t[k]) / max(p.w.t[k + 1] - p.w.t[k], 1e-30)
            i += p.w.i[k] + f * (p.w.i[k + 1] - p.w.i[k])
        wave.add t, i
      c.isources.add ISrc(a: vccDie, b: gndDie, wave: wave, label: "pre-driver current")
      result.assumptions.add note("net " & net.name, "pre-driver current ([Composite Current] " &
        "minus the I/V tables' share) drawn rail to rail at each transition")
  # Run.
  var so = defaultSimOptions(tStop)
  so.hMax = o.hMax
  so.tr = dw.tr
  so.newton = o.newton
  so.maxHalvings = o.maxHalvings
  so.lumpFraction = o.lumpFraction
  let tr = transient(c, so)
  result.issues.add tr.issues
  result.hBase = tr.hBase
  result.steps = tr.steps
  result.factorizations = tr.factorizations
  result.solves = tr.solves
  result.lumped = tr.lumped
  if not tr.ok:
    result.status = ssSolverFailed
    result.reason = tr.failure
    return
  result.status = ssOk
  result.t = tr.t
  result.v = tr.v[0 ..< net.nodes.len]
  proc dieWave(label: string, node, dev, cap: int): SiWave =
    result = SiWave(label: label & ":die", node: node, v: tr.v[node])
    result.i = newSeq[float](tr.t.len)
    for k in 0 ..< tr.t.len: result.i[k] = tr.devI[dev][k] - tr.capI[cap][k]
  result.driver = dieWave(dp.label, dp.dieNode, 0, dCap)
  result.driverPin = SiWave(label: dp.label & ":pin", node: dp.pinNode, v: tr.v[dp.pinNode])
  for k, p in net.receiverPorts:
    result.receivers.add dieWave(p.label, p.dieNode, k + 1, rCaps[k])
    result.receiverPins.add SiWave(label: p.label & ":pin", node: p.pinNode, v: tr.v[p.pinNode])
  for k, x in net.extraDrivers:
    let p = x.port
    result.extraDrivers.add dieWave(p.label, p.dieNode, 1 + net.receivers.len + k, xCaps[k])
    result.extraDriverPins.add SiWave(label: p.label & ":pin", node: p.pinNode, v: tr.v[p.pinNode])
