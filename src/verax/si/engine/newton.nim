## Newton-Raphson over the piecewise-linear device tables, one time point.
## Derivatives are exact per segment, so each device's companion model is a
## conductance plus a current.
##
## - **Convergence**: every node `|dv| < reltol*|v| + vabstol`, every branch
##   `|di| < reltol*|i| + iabstol`, *and* every KCL residual `< iabstol`
##   (starting values `1e-4`, `1 uV`, `1 nA`).
## - **Exact step**: when no device leaves the table segment it was
##   linearised on, the PWL model was exactly linear, so the solve is the
##   answer -- accepted after the KCL check without a confirming solve.
## - **Damping**: from the third iteration on, an update that moves a
##   device node into a different table segment is halved, so Newton walks
##   across a knee instead of oscillating over it.
## - **Failure** is reported, never papered over: the caller halves the step
##   (`transient`) and finally gives up with the time, node and step.
## - **Factor reuse**: the matrix is the linear part (`LinSolver.a`, which
##   changes only with the step size or integration method) plus each
##   device's conductance on its diagonal. While both are unchanged -- the
##   same step, every device on the same table segment at the same weight --
##   the previous LU factors are reused and only the substitution runs.
##   Most steps away from an edge cost one substitution per iteration.

import ./mna
import ./lu
import ../../ibis/behave

export lu

type
  NewtonOptions* = object
    reltol*, vabstol*, iabstol*: float
    maxIter*: int

  DevLin* = object
    ## One device linearised: total current into `node` and `di/dv(node)`;
    ## per rail, the current drawn out of it and its share of the slope.
    i*, g*: float
    rails*: array[2, int]
      ## Rail nodes (0 = unused).
    iRail*, gRail*: array[2, float]

  LinSolver* = object
    ## The linear part of one time point's system, and the factor cache.
    pat*: Pattern
    n*: int
    sys*: System
      ## Row-major, original order; bump `version` whenever `sys.a` changes.
    version*: int
    lu: BandLu
    luVersion: int
    luG: seq[float]
    work: seq[float]
    key, inj, rhs: seq[float]
    lin: seq[DevLin]
    factorizations*, solves*: int

  PointResult* = object
    ok*: bool
    x*: seq[float]
    iters*: int
    worstNode*: int
      ## Node (1-based; 0 = none) with the largest unconverged update.

proc defaultNewton*(): NewtonOptions =
  NewtonOptions(reltol: 1e-4, vabstol: 1e-6, iabstol: 1e-9, maxIter: 50)

proc refOf(d: NlDevice, k: int): int {.inline.} =
  if k < d.refs.len: d.refs[k] else: 0

proc xOf(d: NlDevice, k: int, x: seq[float]): float {.inline.} =
  ## Where curve `k` is read: the node voltage, shifted by its rail's
  ## deviation from nominal.
  let r = refOf(d, k)
  if r > 0: nodeV(x, d.node) - (nodeV(x, r) - d.refNominal[k]) else: nodeV(x, d.node)

proc weightOf(d: NlDevice, k: int, t: float, left: bool): float {.inline.} =
  result =
    if k < d.weights.len and not d.weights[k].isEmpty:
      (if left: d.weights[k].atLeft(t) else: d.weights[k].at(t))
    else: 1.0
  if k < d.scale.len: result *= d.scale[k]

proc linearise*(d: NlDevice, x: seq[float], t: float, left: bool): DevLin =
  for k in 0 ..< d.curves.len:
    template c: untyped = d.curves[k]
    let w = d.weightOf(k, t, left)
    if w == 0.0: continue
    let e = c.eval(d.xOf(k, x))
    result.i += w * e.i
    result.g += w * e.g
    let r = refOf(d, k)
    if r > 0:
      var slot = -1
      for q in 0 .. 1:
        if result.rails[q] == r or (slot < 0 and result.rails[q] == 0):
          slot = q
          if result.rails[q] == r: break
      doAssert slot >= 0, "an NlDevice hangs from more than two rails"
      result.rails[slot] = r
      result.iRail[slot] += w * e.i
      result.gRail[slot] += w * e.g

proc deviceAt*(d: NlDevice, x: seq[float], t: float, left: bool): tuple[i, g: float] =
  ## Injected current and `di/dv(node)` at time `t` (left limit at a jump
  ## when `left`).
  let l = d.linearise(x, t, left)
  (l.i, l.g)

proc segmentKey(d: NlDevice, x: seq[float]): int =
  ## A hash of which segment each curve is on.
  for k in 0 ..< d.curves.len:
    result = result * 131 + d.curves[k].segmentOf(d.xOf(k, x)) + 1

proc initLinSolver*(s: var LinSolver, pat: Pattern) =
  s.pat = pat
  s.n = pat.n
  s.sys = newSystem(pat.n)
  s.version = 1
  s.luVersion = 0

proc solveWith(s: var LinSolver, lin: seq[DevLin], devices: seq[NlDevice],
               rhs: openArray[float], x: var seq[float]): bool =
  ## Solve `(a - J) x = rhs`, `J` the devices' Jacobian, refactoring only
  ## when the matrix differs from the cached factor's.
  s.key.setLen 0
  for l in lin:
    s.key.add l.g
    if l.rails[0] > 0: s.key.add l.gRail[0]
    if l.rails[1] > 0: s.key.add l.gRail[1]
  var same = s.luVersion == s.version and s.luG.len == s.key.len and s.lu.ok
  if same:
    for k in 0 ..< s.key.len:
      if s.luG[k] != s.key[k]:
        same = false
        break
  if not same:
    s.work.setLen s.sys.a.len
    for k in 0 ..< s.sys.a.len: s.work[k] = s.sys.a[k]
    for k in 0 ..< devices.len:
      template d: untyped = devices[k]
      if d.node == 0: continue
      let n = d.node - 1
      s.work[n * s.n + n] -= lin[k].g
      for q in 0 .. 1:
        let r = lin[k].rails[q]
        if r <= 0: continue
        let gr = lin[k].gRail[q]
        # i(node) depends on v(ref) with -gr; the rail loses i.
        s.work[n * s.n + r - 1] += gr
        s.work[(r - 1) * s.n + n] += gr
        s.work[(r - 1) * s.n + r - 1] -= gr
    s.lu.factor(s.pat, s.work)
    inc s.factorizations
    s.luVersion = s.version
    s.luG.setLen s.key.len
    for k in 0 ..< s.key.len: s.luG[k] = s.key[k]
    if not s.lu.ok:
      s.luVersion = 0
      return false
  s.lu.solve(s.pat, rhs, x)
  inc s.solves
  true

proc solvePoint*(s: var LinSolver, devices: seq[NlDevice], t: float, left: bool,
                 x0: seq[float], nNodes: int, o: NewtonOptions): PointResult =
  ## One time point. `s.sys` holds the linear system.
  result.x = x0
  s.lin.setLen devices.len
  var xn: seq[float]
  if devices.len == 0:
    result.ok = s.solveWith(s.lin, devices, s.sys.b, xn)
    result.x = xn
    result.iters = 1
    return
  s.rhs.setLen s.n
  template rhs: untyped = s.rhs
  template lin: untyped = s.lin
  for it in 1 .. o.maxIter:
    result.iters = it
    for k in 0 ..< s.n: rhs[k] = s.sys.b[k]
    for k in 0 ..< devices.len:
      template d: untyped = devices[k]
      if d.node == 0: continue
      let l = d.linearise(result.x, t, left)
      lin[k] = l
      # i(x) ~ i + g (v' - v) - gr (vr' - vr): the constant part to the
      # right-hand side, the slopes to the matrix.
      let v = nodeV(result.x, d.node)
      var c0 = l.i - l.g * v
      for q in 0 .. 1:
        let r = l.rails[q]
        if r <= 0: continue
        let vr = nodeV(result.x, r)
        c0 += l.gRail[q] * vr
        # The rail: loses iRail ~ iRail + gr (v' - v) - gr (vr' - vr).
        rhs[r - 1] -= l.iRail[q] - l.gRail[q] * v + l.gRail[q] * vr
      rhs[d.node - 1] += c0
    if not s.solveWith(lin, devices, rhs, xn):
      result.worstNode = 0
      return
    # Every device on the segment it was linearised on: the PWL model is
    # exactly linear there, so `xn` is the solution, not an estimate (the
    # KCL check below still confirms it). Saves the confirming solve.
    var exact = true
    for d in devices:
      if d.node == 0: continue
      if segmentKey(d, result.x) != segmentKey(d, xn):
        exact = false
        break
    if it >= 3:
      # Halve the move of every node a segment-changing device reads (its
      # pad and any rail it hangs from), each once.
      var damped: seq[int]
      for d in devices:
        if d.node == 0: continue
        if segmentKey(d, result.x) == segmentKey(d, xn): continue
        if d.node notin damped: damped.add d.node
        for r in d.refs:
          if r > 0 and r notin damped: damped.add r
      for node in damped:
        let k = node - 1
        xn[k] = result.x[k] + 0.5 * (xn[k] - result.x[k])
    # Update test. The node blamed on failure is the nonlinear one moving
    # most: a linear node only moves because a device node does.
    var conv = true
    var worst = 0.0
    for k in 0 ..< xn.len:
      let dx = abs(xn[k] - result.x[k])
      let tol = if k < nNodes: o.reltol * abs(xn[k]) + o.vabstol
                else: o.reltol * abs(xn[k]) + o.iabstol
      if dx > tol: conv = false
    for d in devices:
      if d.node == 0: continue
      let k = d.node - 1
      let tol = o.reltol * abs(xn[k]) + o.vabstol
      let r = abs(xn[k] - result.x[k]) / tol
      if r > 1.0 and r > worst:
        worst = r
        result.worstNode = d.node
    result.x = xn
    if not conv and not exact: continue
    # KCL residual with the true device currents, at every device node and
    # every rail a device hangs from.
    s.inj.setLen s.n
    for k in 0 ..< s.n: s.inj[k] = 0.0
    for d in devices:
      if d.node == 0: continue
      let l = d.linearise(xn, t, left)
      s.inj[d.node - 1] += l.i
      for q in 0 .. 1:
        if l.rails[q] > 0: s.inj[l.rails[q] - 1] -= l.iRail[q]
    var ok = true
    template check(node: int) =
      let r = node - 1
      var acc = -s.sys.b[r] - s.inj[r]
      for c in 0 ..< s.n: acc += s.sys.a[r * s.n + c] * xn[c]
      if abs(acc) > o.iabstol:
        ok = false
        result.worstNode = node
    for d in devices:
      if d.node == 0: continue
      check(d.node)
      for r in d.refs:
        if r > 0: check(r)
    if ok:
      result.ok = true
      result.worstNode = 0
      return
