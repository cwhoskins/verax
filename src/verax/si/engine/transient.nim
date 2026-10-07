## The transient loop and its numerical policy (docs/ibis_simulator_plan.md,
## stage 3). The numbers are starting values, tuned only with a test that
## shows why.
##
## - **Time grid.** A fixed base step `h = min(hMax, shortest line td,
##   tr / 20)`, `tr` the fastest edge in the stimulus. Breakpoints at every
##   source/weight knot, merged into one sorted list (points closer than
##   `1e-3 * h` are one breakpoint; ordering of equal times is by value, so
##   it is deterministic). The step is shortened to land on each.
## - **Integration.** Trapezoidal. After a **discontinuous** breakpoint (a
##   jump in a source or weight, including a step at `t = 0`) the next two
##   steps are backward Euler at `h / 2`, then trapezoidal resumes; this
##   damps trapezoidal's numerical ringing on a discontinuity. A knot where
##   only the *slope* changes (every `Ku`/`Kd` knot) is landed on but does
##   not restart -- restarting there would make a whole vendor edge first
##   order. At a jump the step that lands on it sees the left limit; the
##   next sees the right.
## - **Lines.** A line with `td < lumpFraction * tr` (default 1/20) becomes
##   a lumped pi (`L = Z0*td`, `C = td/Z0`, `C/2` at each end) so a short
##   section does not drive `h` down. Every other line is Bergeron.
## - **Newton failure** (`newton`): halve the step and retry; after
##   `maxHalvings` (10) the run stops and the result says when, where and at
##   what step. Never a silently wrong waveform.
## - The DC operating point is solved by the same Newton, with the weights
##   at their initial values -- not assumed.

import std/[math, algorithm, strutils]
import ./mna
import ./bergeron
import ./newton
import ../../ibis/behave

export mna, newton

type
  SimOptions* = object
    tStop*: float
    hMax*: float
      ## Upper bound on the base step; `Inf` lets the policy decide.
    tr*: float
      ## Fastest edge in the stimulus, s; `NaN` if none (then `hMax` or
      ## `tStop / 1000` bounds the step).
    newton*: NewtonOptions
    maxHalvings*: int
    gmin*: float
    lumpFraction*: float
    tableMarginFrac*: float
      ## A device node beyond its table by more than this fraction of the
      ## table's span is reported.

  TranResult* = object
    ok*: bool
    failure*: string
      ## Time, node and step of a solver failure.
    t*: seq[float]
    v*: seq[seq[float]]
      ## `[node][step]`; node 0 is ground.
    capI*: seq[seq[float]]
      ## Current through each capacitor `a -> b`, `[cap][step]`.
    devI*: seq[seq[float]]
      ## Current each device injects into its node, `[device][step]`.
    srcI*: seq[seq[float]]
      ## Voltage-source branch current `a -> b`, `[source][step]`.
    hBase*: float
    steps*, newtonIters*, rejected*: int
    lumped*: seq[string]
      ## Lines replaced by a lumped pi.
    issues*: seq[Issue]

proc defaultSimOptions*(tStop: float): SimOptions =
  SimOptions(tStop: tStop, hMax: Inf, tr: NaN, newton: defaultNewton(),
             maxHalvings: 10, gmin: 1e-12, lumpFraction: 0.05,
             tableMarginFrac: 0.05)

proc lumpShortLines(c: var Circuit, o: SimOptions): seq[string] =
  if o.tr.isNaN: return
  var keep: seq[Line]
  for ln in c.lines:
    if ln.td < o.lumpFraction * o.tr:
      let l = ln.z0 * ln.td
      let cap = ln.td / ln.z0
      c.inductors.add Ind(a: ln.a, b: ln.b, l: l, label: ln.label & " (lumped L)")
      c.capacitors.add Cap(a: ln.a, b: 0, c: cap / 2, label: ln.label & " (lumped C/2)")
      c.capacitors.add Cap(a: ln.b, b: 0, c: cap / 2, label: ln.label & " (lumped C/2)")
      result.add ln.label
    else:
      keep.add ln
  c.lines = keep

proc collectBreakpoints(c: Circuit, tStop, eps: float): seq[tuple[t: float, jump: bool]] =
  var all: seq[tuple[t: float, jump: bool]]
  for s in c.vsources: all.add s.wave.breakpoints
  for s in c.isources: all.add s.wave.breakpoints
  for d in c.devices:
    for w in d.weights: all.add w.breakpoints
  # A source whose t = 0 value differs from its DC value jumps at 0.
  for s in c.vsources:
    if not s.wave.isEmpty and s.wave.at(0.0) != s.wave.initial: all.add (0.0, true)
  for s in c.isources:
    if not s.wave.isEmpty and s.wave.at(0.0) != s.wave.initial: all.add (0.0, true)
  all.add (tStop, false)
  all.sort(proc(a, b: tuple[t: float, jump: bool]): int =
    result = cmp(a.t, b.t)
    if result == 0: result = cmp(ord(b.jump), ord(a.jump)))
  for bp in all:
    if bp.t < 0.0 or bp.t > tStop: continue
    if result.len > 0 and bp.t - result[^1].t < eps:
      result[^1].jump = result[^1].jump or bp.jump
    else:
      result.add bp

type
  State = object
    capV, capI: seq[float]
    indI, indV: seq[float]
    hist: seq[LineHistory]

proc assemble(c: Circuit, lay: Layout, dc: bool, t: float, left: bool, h: float,
              im: Integration, st: State, o: SimOptions): System =
  result = newSystem(lay.size)
  for n in 1 .. lay.nNodes:
    result.addA(n - 1, n - 1, o.gmin)
  for k, r in c.resistors:
    if lay.zeroR[k] >= 0: result.stampBranch(lay.zeroR[k], r.a, r.b, 0.0, 0.0)
    else: result.stampG(r.a, r.b, 1.0 / r.r)
  for k, s in c.vsources:
    let v = if dc: s.wave.initial elif left: s.wave.atLeft(t) else: s.wave.at(t)
    result.stampBranch(lay.vBase + k, s.a, s.b, 0.0, v)
  for s in c.isources:
    let i = if dc: s.wave.initial elif left: s.wave.atLeft(t) else: s.wave.at(t)
    result.stampI(s.a, s.b, i)
  for k, ind in c.inductors:
    let br = lay.lBase + k
    if dc:
      result.stampBranch(br, ind.a, ind.b, 0.0, 0.0)
    else:
      case im
      of imTrapezoidal:
        let r = 2.0 * ind.l / h
        result.stampBranch(br, ind.a, ind.b, r, -r * st.indI[k] - st.indV[k])
      of imBackwardEuler:
        let r = ind.l / h
        result.stampBranch(br, ind.a, ind.b, r, -r * st.indI[k])
  if not dc:
    for k, cp in c.capacitors:
      case im
      of imTrapezoidal:
        let g = 2.0 * cp.c / h
        result.stampG(cp.a, cp.b, g)
        # i = g v - (g v0 + i0): the constant part flows b -> a.
        result.stampI(cp.b, cp.a, g * st.capV[k] + st.capI[k])
      of imBackwardEuler:
        let g = cp.c / h
        result.stampG(cp.a, cp.b, g)
        result.stampI(cp.b, cp.a, g * st.capV[k])
  for k, ln in c.lines:
    if dc:
      result.stampBranch(lay.lineBase + k, ln.a, ln.b, 0.0, 0.0)
    else:
      let g = 1.0 / ln.z0
      result.stampG(ln.a, 0, g)
      result.stampG(ln.b, 0, g)
      let (ja, jb) = st.hist[k].injections(ln.z0, ln.td, t)
      result.stampInject(ln.a, ja)
      result.stampInject(ln.b, jb)

proc transient*(circuit: Circuit, o: SimOptions): TranResult =
  var c = circuit
  result.lumped = lumpShortLines(c, o)
  # Base step.
  var h = o.hMax
  if not o.tr.isNaN: h = min(h, o.tr / 20.0)
  for ln in c.lines: h = min(h, ln.td)
  if h == Inf or h <= 0.0: h = o.tStop / 1000.0
  result.hBase = h
  let eps = 1e-3 * h
  let bps = collectBreakpoints(c, o.tStop, eps)
  let nN = c.nodeNames.len - 1

  # DC operating point.
  let layDc = layout(c, true)
  var st = State(capV: newSeq[float](c.capacitors.len), capI: newSeq[float](c.capacitors.len),
                 indI: newSeq[float](c.inductors.len), indV: newSeq[float](c.inductors.len),
                 hist: newSeq[LineHistory](c.lines.len))
  let linDc = assemble(c, layDc, true, 0.0, true, 0.0, imTrapezoidal, st, o)
  var dcNewton = o.newton
  dcNewton.maxIter = max(dcNewton.maxIter, 200)
  let op = solvePoint(linDc, c.devices, 0.0, true, newSeq[float](layDc.size), nN, dcNewton)
  if not op.ok:
    result.failure = "DC operating point did not converge" &
      (if op.worstNode > 0: " at node '" & c.nodeNames[op.worstNode] & "'" else: "")
    result.issues.add newIssue("si_solver_failure", sevError, result.failure)
    return
  let lay = layout(c, false)
  var x = newSeq[float](lay.size)
  for k in 0 ..< nN: x[k] = op.x[k]
  for k in 0 ..< c.vsources.len: x[lay.vBase + k] = op.x[layDc.vBase + k]
  for k in 0 ..< c.inductors.len:
    x[lay.lBase + k] = op.x[layDc.lBase + k]
    st.indI[k] = op.x[layDc.lBase + k]
  var nz = 0
  for k in 0 ..< c.resistors.len:
    if lay.zeroR[k] >= 0:
      x[lay.zeroR[k]] = op.x[layDc.zeroR[k]]
      inc nz
  for k, cp in c.capacitors:
    st.capV[k] = nodeV(x, cp.a) - nodeV(x, cp.b)
  for k, ln in c.lines:
    let i = op.x[layDc.lineBase + k]
    st.hist[k].record(0.0, nodeV(x, ln.a), i, nodeV(x, ln.b), -i)

  result.v = newSeq[seq[float]](c.nodeNames.len)
  result.capI = newSeq[seq[float]](c.capacitors.len)
  result.devI = newSeq[seq[float]](c.devices.len)
  result.srcI = newSeq[seq[float]](c.vsources.len)
  var maxOut = newSeq[float](c.devices.len)

  proc rec(res: var TranResult, t: float, x: seq[float], st: State, left: bool) =
    res.t.add t
    res.v[0].add 0.0
    for n in 1 .. nN: res.v[n].add x[n - 1]
    for k in 0 ..< c.capacitors.len: res.capI[k].add st.capI[k]
    for k, d in c.devices:
      let v = nodeV(x, d.node)
      res.devI[k].add d.deviceAt(v, t, left).i
      for cv in d.curves:
        if cv.v.len < 2: continue
        let span = cv.v[^1] - cv.v[0]
        let beyond = max(cv.v[0] - v, v - cv.v[^1])
        if beyond > o.tableMarginFrac * span: maxOut[k] = max(maxOut[k], beyond)
    for k in 0 ..< c.vsources.len: res.srcI[k].add x[lay.vBase + k]

  result.rec(0.0, x, st, true)

  var t = 0.0
  var bi = 0
  while bi < bps.len and bps[bi].t <= eps: inc bi
  var beLeft = if bps.len > 0 and bps[0].t <= eps and bps[0].jump: 2 else: 0
  while t < o.tStop - eps:
    let hTarget = if beLeft > 0: h / 2 else: h
    var tNext = t + hTarget
    var landed = false
    if bi < bps.len and tNext >= bps[bi].t - eps:
      tNext = bps[bi].t
      landed = true
    var halvings = 0
    var accepted = false
    var pr: PointResult
    var im = if beLeft > 0: imBackwardEuler else: imTrapezoidal
    while true:
      let hs = tNext - t
      let left = landed and bps[bi].jump
      let lin = assemble(c, lay, false, tNext, left, hs, im, st, o)
      pr = solvePoint(lin, c.devices, tNext, left, x, nN, o.newton)
      result.newtonIters += pr.iters
      if pr.ok:
        accepted = true
        break
      inc result.rejected
      inc halvings
      if halvings > o.maxHalvings:
        break
      tNext = t + hs / 2
      landed = false
    if not accepted:
      let node = if pr.worstNode > 0: c.nodeNames[pr.worstNode] else: "?"
      result.failure = "Newton did not converge at t = " & formatFloat(tNext, ffScientific, 4) &
        " s, node '" & node & "', step " & formatFloat(tNext - t, ffScientific, 3) &
        " s after " & $o.maxHalvings & " halvings"
      result.issues.add newIssue("si_solver_failure", sevError, result.failure)
      return
    let hs = tNext - t
    let xn = pr.x
    # Update element states.
    for k, cp in c.capacitors:
      let v1 = nodeV(xn, cp.a) - nodeV(xn, cp.b)
      case im
      of imTrapezoidal:
        st.capI[k] = 2.0 * cp.c / hs * (v1 - st.capV[k]) - st.capI[k]
      of imBackwardEuler:
        st.capI[k] = cp.c / hs * (v1 - st.capV[k])
      st.capV[k] = v1
    for k, ind in c.inductors:
      st.indI[k] = xn[lay.lBase + k]
      st.indV[k] = nodeV(xn, ind.a) - nodeV(xn, ind.b)
    for k, ln in c.lines:
      let (ja, jb) = st.hist[k].injections(ln.z0, ln.td, tNext)
      let va = nodeV(xn, ln.a)
      let vb = nodeV(xn, ln.b)
      st.hist[k].record(tNext, va, va / ln.z0 - ja, vb, vb / ln.z0 - jb)
    x = xn
    let leftRec = landed and bps[bi].jump
    t = tNext
    result.rec(t, x, st, leftRec)
    inc result.steps
    if beLeft > 0: dec beLeft
    if landed:
      if bps[bi].jump: beLeft = 2
      inc bi
    while bi < bps.len and bps[bi].t <= t + eps: inc bi
  for k, d in c.devices:
    if maxOut[k] > 0:
      result.issues.add newIssue("si_table_range", sevWarning,
        d.label & " pad left its I/V table by " & formatFloat(maxOut[k], ffDecimal, 3) &
        " V; the end segment was extended linearly")
  result.ok = true
