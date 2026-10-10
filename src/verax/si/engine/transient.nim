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
##   section does not drive `h` down. Every other line is Bergeron. A
##   coupled line is two Bergeron lines in modal form (even, odd) and is
##   never lumped (that would need a mutual inductance): its shorter modal
##   delay bounds `h`. An S-parameter block (`sblock`) bounds `h` by its tap
##   spacing. A
##   convolution line (`convline`) bounds `h` by its `tau` the same way;
##   `si/simulate` never makes one shorter than the lumping threshold.
## - **Newton failure** (`newton`): halve the step and retry; after
##   `maxHalvings` (10) the run stops and the result says when, where and at
##   what step. Never a silently wrong waveform.
## - The DC operating point is solved by the same Newton, with the weights
##   at their initial values -- not assumed.
## - **Power-aware `Ksso`** factors (`NlDevice.ksso`) are evaluated from the
##   last accepted step's rail voltages and held through the next (IBIS:
##   "updated at each time step"); `1` at the DC point.
## - Hot loops index (`template x = seq[k]`) instead of `for k, x in seq`:
##   `pairs` yields each element by value, a deep copy of a device's tables
##   per Newton iteration.

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
    factorizations*, solves*: int
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
    conv: seq[ConvState]
    evenH, oddH: seq[LineHistory]
      ## Coupled lines, in modal variables.
    sb: seq[SBlockState]

proc assemble(s: var System, c: Circuit, lay: Layout, dc: bool, t: float, left: bool,
              h: float, im: Integration, st: var State, o: SimOptions, matrix: bool) =
  ## Stamps the right-hand side, and the matrix too when `matrix` (it
  ## depends only on `dc`, `h` and `im`).
  if matrix:
    for x in s.a.mitems: x = 0.0
  for x in s.b.mitems: x = 0.0
  template g(na, nb: int, v: float) =
    if matrix: s.stampG(na, nb, v)
  template branch(br, na, nb: int, rCoef, rhs: float) =
    if matrix: s.stampBranch(br, na, nb, rCoef, rhs)
    else: s.b[br] += rhs
  if matrix:
    for n in 1 .. lay.nNodes:
      s.addA(n - 1, n - 1, o.gmin)
  for k in 0 ..< c.resistors.len:
    template r: untyped = c.resistors[k]
    if lay.zeroR[k] >= 0: branch(lay.zeroR[k], r.a, r.b, 0.0, 0.0)
    else: g(r.a, r.b, 1.0 / r.r)
  for k in 0 ..< c.vsources.len:
    template src: untyped = c.vsources[k]
    let v = if dc: src.wave.initial elif left: src.wave.atLeft(t) else: src.wave.at(t)
    branch(lay.vBase + k, src.a, src.b, 0.0, v)
  for src in c.isources:
    let i = if dc: src.wave.initial elif left: src.wave.atLeft(t) else: src.wave.at(t)
    s.stampI(src.a, src.b, i)
  for k in 0 ..< c.inductors.len:
    template ind: untyped = c.inductors[k]
    let br = lay.lBase + k
    if dc:
      branch(br, ind.a, ind.b, 0.0, 0.0)
    else:
      case im
      of imTrapezoidal:
        let r = 2.0 * ind.l / h
        branch(br, ind.a, ind.b, r, -r * st.indI[k] - st.indV[k])
      of imBackwardEuler:
        let r = ind.l / h
        branch(br, ind.a, ind.b, r, -r * st.indI[k])
  if not dc:
    for k in 0 ..< c.capacitors.len:
      template cp: untyped = c.capacitors[k]
      case im
      of imTrapezoidal:
        let gc = 2.0 * cp.c / h
        g(cp.a, cp.b, gc)
        # i = g v - (g v0 + i0): the constant part flows b -> a.
        s.stampI(cp.b, cp.a, gc * st.capV[k] + st.capI[k])
      of imBackwardEuler:
        let gc = cp.c / h
        g(cp.a, cp.b, gc)
        s.stampI(cp.b, cp.a, gc * st.capV[k])
  for k in 0 ..< c.lines.len:
    template ln: untyped = c.lines[k]
    if dc:
      branch(lay.lineBase + k, ln.a, ln.b, 0.0, 0.0)
    else:
      let gl = 1.0 / ln.z0
      g(ln.a, 0, gl)
      g(ln.b, 0, gl)
      let (ja, jb) = st.hist[k].injections(ln.z0, ln.td, t)
      s.stampInject(ln.a, ja)
      s.stampInject(ln.b, jb)
  for k in 0 ..< c.coupled.len:
    template ln: untyped = c.coupled[k]
    if dc:
      branch(lay.coupledBase + 2 * k, ln.a1, ln.b1, 0.0, 0.0)
      branch(lay.coupledBase + 2 * k + 1, ln.a2, ln.b2, 0.0, 0.0)
    else:
      # i1 = ie + io, i2 = ie - io with ie = ve/Ze - Je: conductance
      # 1/Ze from each conductor to ground, (1/Zo - 1/Ze)/2 between them.
      let gm = 0.5 * (1.0 / ln.zOdd - 1.0 / ln.zEven)
      for (na, nb) in [(ln.a1, ln.a2), (ln.b1, ln.b2)]:
        g(na, 0, 1.0 / ln.zEven)
        g(nb, 0, 1.0 / ln.zEven)
        g(na, nb, gm)
      let (jea, jeb) = st.evenH[k].injections(ln.zEven, ln.tdEven, t)
      let (joa, job) = st.oddH[k].injections(ln.zOdd, ln.tdOdd, t)
      s.stampInject(ln.a1, jea + joa)
      s.stampInject(ln.a2, jea - joa)
      s.stampInject(ln.b1, jeb + job)
      s.stampInject(ln.b2, jeb - job)
  for k in 0 ..< c.sblocks.len:
    template sb: untyped = c.sblocks[k]
    if dc:
      let (series, sh1, sh2) = sb.dcTwoPort
      if series == Inf: branch(lay.sblockBase + k, 0, 0, -1.0, 0.0)   # i = 0
      else: branch(lay.sblockBase + k, sb.p1, sb.p2, series, 0.0)
      g(sb.p1, 0, sh1)
      g(sb.p2, 0, sh2)
    else:
      if matrix:
        let ps = [sb.p1, sb.p2]
        for r in 0 .. 1:
          for q in 0 .. 1:
            if ps[r] > 0 and ps[q] > 0: s.addA(ps[r] - 1, ps[q] - 1, sb.g[2 * r + q])
      let (h1, h2) = sb.history(st.sb[k], t)
      let (j1, j2) = sb.injections(h1, h2)
      s.stampInject(sb.p1, j1)
      s.stampInject(sb.p2, j2)
  for k in 0 ..< c.convLines.len:
    template ln: untyped = c.convLines[k]
    if dc:
      let (series, shunt) = ln.dcTwoPort
      branch(lay.convBase + k, ln.a, ln.b, series, 0.0)
      if shunt > 0:
        g(ln.a, 0, shunt)
        g(ln.b, 0, shunt)
    else:
      st.conv[k].coefficients(ln, h)
      let q = st.conv[k].stamp(ln, t)
      g(ln.a, 0, q.geq)
      g(ln.b, 0, q.geq)
      s.stampInject(ln.a, q.ja)
      s.stampInject(ln.b, q.jb)

proc modal(x: seq[float], ln: CoupledLine): tuple[ea, oa, eb, ob: float] =
  ## Even and odd modal voltages at each end.
  let v1a = nodeV(x, ln.a1)
  let v2a = nodeV(x, ln.a2)
  let v1b = nodeV(x, ln.b1)
  let v2b = nodeV(x, ln.b2)
  (0.5 * (v1a + v2a), 0.5 * (v1a - v2a), 0.5 * (v1b + v2b), 0.5 * (v1b - v2b))

proc solverFor(c: Circuit, lay: Layout, dc: bool, st: var State, o: SimOptions): LinSolver =
  ## A solver whose ordering comes from the full structure of this layout
  ## (every element stamped, `h = 1`).
  var probe = newSystem(lay.size)
  probe.assemble(c, lay, dc, 0.0, true, 1.0, imTrapezoidal, st, o, matrix = true)
  # A rail-referenced device couples its node and its rails.
  for d in c.devices:
    if d.node == 0: continue
    for r in d.refs:
      if r <= 0: continue
      for (p, q) in [(d.node, r), (r, d.node), (r, r)]:
        probe.addA(p - 1, q - 1, 1.0)
  result.initLinSolver(patternOf(lay.size, probe.a))

proc updateKsso(c: var Circuit, x: seq[float]) =
  for k in 0 ..< c.devices.len:
    template d: untyped = c.devices[k]
    if d.ksso.len == 0: continue
    d.scale.setLen d.curves.len
    for q in 0 ..< d.curves.len:
      d.scale[q] = 1.0
      if q < d.ksso.len and not d.ksso[q].isEmpty and q < d.refs.len and d.refs[q] > 0:
        let vt = d.kssoSign[q] * (nodeV(x, d.refs[q]) - d.refNominal[q])
        d.scale[q] = d.ksso[q].eval(vt).i

proc transient*(circuit: Circuit, o: SimOptions): TranResult =
  var c = circuit
  result.lumped = lumpShortLines(c, o)
  # Base step.
  var h = o.hMax
  if not o.tr.isNaN: h = min(h, o.tr / 20.0)
  for ln in c.lines: h = min(h, ln.td)
  for ln in c.convLines: h = min(h, ln.tau)
  for ln in c.coupled: h = min(h, min(ln.tdEven, ln.tdOdd))
  for sb in c.sblocks: h = min(h, sb.dt)
  if h == Inf or h <= 0.0: h = o.tStop / 1000.0
  result.hBase = h
  let eps = 1e-3 * h
  let bps = collectBreakpoints(c, o.tStop, eps)
  let nN = c.nodeNames.len - 1

  # DC operating point.
  let layDc = layout(c, true)
  var st = State(capV: newSeq[float](c.capacitors.len), capI: newSeq[float](c.capacitors.len),
                 indI: newSeq[float](c.inductors.len), indV: newSeq[float](c.inductors.len),
                 hist: newSeq[LineHistory](c.lines.len),
                 conv: newSeq[ConvState](c.convLines.len),
                 evenH: newSeq[LineHistory](c.coupled.len),
                 oddH: newSeq[LineHistory](c.coupled.len),
                 sb: newSeq[SBlockState](c.sblocks.len))
  var solDc = solverFor(c, layDc, true, st, o)
  solDc.sys.assemble(c, layDc, true, 0.0, true, 0.0, imTrapezoidal, st, o, matrix = true)
  var dcNewton = o.newton
  dcNewton.maxIter = max(dcNewton.maxIter, 200)
  let op = solDc.solvePoint(c.devices, 0.0, true, newSeq[float](layDc.size), nN, dcNewton)
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
  for k in 0 ..< c.capacitors.len:
    template cp: untyped = c.capacitors[k]
    st.capV[k] = nodeV(x, cp.a) - nodeV(x, cp.b)
  for k in 0 ..< c.lines.len:
    template ln: untyped = c.lines[k]
    let i = op.x[layDc.lineBase + k]
    st.hist[k].record(0.0, nodeV(x, ln.a), i, nodeV(x, ln.b), -i)
  for k in 0 ..< c.convLines.len:
    template ln: untyped = c.convLines[k]
    let i = op.x[layDc.convBase + k]
    let (_, shunt) = ln.dcTwoPort
    let va = nodeV(x, ln.a)
    let vb = nodeV(x, ln.b)
    st.conv[k] = initState(ln, va, i + shunt * va, vb, -i + shunt * vb)

  for k in 0 ..< c.coupled.len:
    template ln: untyped = c.coupled[k]
    let i1 = op.x[layDc.coupledBase + 2 * k]
    let i2 = op.x[layDc.coupledBase + 2 * k + 1]
    let m = modal(x, ln)
    st.evenH[k].record(0.0, m.ea, 0.5 * (i1 + i2), m.eb, -0.5 * (i1 + i2))
    st.oddH[k].record(0.0, m.oa, 0.5 * (i1 - i2), m.ob, -0.5 * (i1 - i2))
  for k in 0 ..< c.sblocks.len:
    template sb: untyped = c.sblocks[k]
    let (series, sh1, sh2) = sb.dcTwoPort
    let ib = op.x[layDc.sblockBase + k]
    let v1 = nodeV(x, sb.p1)
    let v2 = nodeV(x, sb.p2)
    let ibr = if series == Inf: 0.0 else: ib
    st.sb[k] = sb.initState(v1, ibr + sh1 * v1, v2, -ibr + sh2 * v2)
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
    for k in 0 ..< c.devices.len:
      template d: untyped = c.devices[k]
      let v = nodeV(x, d.node)
      res.devI[k].add d.deviceAt(x, t, left).i
      for cv in d.curves:
        if cv.v.len < 2: continue
        let span = cv.v[^1] - cv.v[0]
        let beyond = max(cv.v[0] - v, v - cv.v[^1])
        if beyond > o.tableMarginFrac * span: maxOut[k] = max(maxOut[k], beyond)
    for k in 0 ..< c.vsources.len: res.srcI[k].add x[lay.vBase + k]

  result.rec(0.0, x, st, true)

  var sol = solverFor(c, lay, false, st, o)
  var lastH = NaN
  var lastIm = imTrapezoidal

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
    c.updateKsso(x)
    var halvings = 0
    var accepted = false
    var pr: PointResult
    var im = if beLeft > 0: imBackwardEuler else: imTrapezoidal
    while true:
      let hs = tNext - t
      let left = landed and bps[bi].jump
      let newMatrix = hs != lastH or im != lastIm
      sol.sys.assemble(c, lay, false, tNext, left, hs, im, st, o, matrix = newMatrix)
      if newMatrix:
        inc sol.version
        lastH = hs
        lastIm = im
      pr = sol.solvePoint(c.devices, tNext, left, x, nN, o.newton)
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
    for k in 0 ..< c.capacitors.len:
      template cp: untyped = c.capacitors[k]
      let v1 = nodeV(xn, cp.a) - nodeV(xn, cp.b)
      case im
      of imTrapezoidal:
        st.capI[k] = 2.0 * cp.c / hs * (v1 - st.capV[k]) - st.capI[k]
      of imBackwardEuler:
        st.capI[k] = cp.c / hs * (v1 - st.capV[k])
      st.capV[k] = v1
    for k in 0 ..< c.inductors.len:
      template ind: untyped = c.inductors[k]
      st.indI[k] = xn[lay.lBase + k]
      st.indV[k] = nodeV(xn, ind.a) - nodeV(xn, ind.b)
    for k in 0 ..< c.lines.len:
      template ln: untyped = c.lines[k]
      let (ja, jb) = st.hist[k].injections(ln.z0, ln.td, tNext)
      let va = nodeV(xn, ln.a)
      let vb = nodeV(xn, ln.b)
      st.hist[k].record(tNext, va, va / ln.z0 - ja, vb, vb / ln.z0 - jb)
    for k in 0 ..< c.coupled.len:
      template ln: untyped = c.coupled[k]
      let (jea, jeb) = st.evenH[k].injections(ln.zEven, ln.tdEven, tNext)
      let (joa, job) = st.oddH[k].injections(ln.zOdd, ln.tdOdd, tNext)
      let m = modal(xn, ln)
      st.evenH[k].record(tNext, m.ea, m.ea / ln.zEven - jea, m.eb, m.eb / ln.zEven - jeb)
      st.oddH[k].record(tNext, m.oa, m.oa / ln.zOdd - joa, m.ob, m.ob / ln.zOdd - job)
    for k in 0 ..< c.sblocks.len:
      template sb: untyped = c.sblocks[k]
      let (h1, h2) = sb.history(st.sb[k], tNext)
      let (j1, j2) = sb.injections(h1, h2)
      st.sb[k].record(sb, tNext, nodeV(xn, sb.p1), nodeV(xn, sb.p2), j1, j2)
    for k in 0 ..< c.convLines.len:
      template ln: untyped = c.convLines[k]
      let q = st.conv[k].stamp(ln, tNext)
      st.conv[k].advance(ln, tNext, nodeV(xn, ln.a), nodeV(xn, ln.b), q.ua, q.ub)
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
  result.factorizations = sol.factorizations
  result.solves = sol.solves
  for k in 0 ..< c.devices.len:
    template d: untyped = c.devices[k]
    if maxOut[k] > 0:
      result.issues.add newIssue("si_table_range", sevWarning,
        d.label & " pad left its I/V table by " & formatFloat(maxOut[k], ffDecimal, 3) &
        " V; the end segment was extended linearly")
  result.ok = true
