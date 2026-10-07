## Newton-Raphson over the piecewise-linear device tables, one time point.
## Derivatives are exact per segment, so each device's companion model is a
## conductance plus a current.
##
## - **Convergence**: every node `|dv| < reltol*|v| + vabstol`, every branch
##   `|di| < reltol*|i| + iabstol`, *and* every KCL residual `< iabstol`
##   (starting values `1e-4`, `1 uV`, `1 nA`).
## - **Damping**: from the third iteration on, an update that moves a
##   device node into a different table segment is halved, so Newton walks
##   across a knee instead of oscillating over it.
## - **Failure** is reported, never papered over: the caller halves the step
##   (`transient`) and finally gives up with the time, node and step.

import ./mna
import ../../ibis/behave

type
  NewtonOptions* = object
    reltol*, vabstol*, iabstol*: float
    maxIter*: int

  PointResult* = object
    ok*: bool
    x*: seq[float]
    iters*: int
    worstNode*: int
      ## Node (1-based; 0 = none) with the largest unconverged update.

proc defaultNewton*(): NewtonOptions =
  NewtonOptions(reltol: 1e-4, vabstol: 1e-6, iabstol: 1e-9, maxIter: 50)

proc deviceAt*(d: NlDevice, v, t: float, left: bool): tuple[i, g: float] =
  ## Injected current and `di/dv` at `v`, time `t` (left limit at a jump
  ## when `left`).
  for k, c in d.curves:
    let w =
      if k < d.weights.len and not d.weights[k].isEmpty:
        (if left: d.weights[k].atLeft(t) else: d.weights[k].at(t))
      else: 1.0
    if w == 0.0: continue
    let e = c.eval(v)
    result.i += w * e.i
    result.g += w * e.g

proc segmentKey(d: NlDevice, v: float): int =
  ## A hash of which segment each curve is on.
  for c in d.curves: result = result * 131 + c.segmentOf(v) + 1

proc solvePoint*(lin: System, devices: seq[NlDevice], t: float, left: bool,
                 x0: seq[float], nNodes: int, o: NewtonOptions): PointResult =
  result.x = x0
  if devices.len == 0:
    var x: seq[float]
    result.ok = luSolve(lin, x)
    result.x = x
    result.iters = 1
    return
  var sys = lin
  var xn: seq[float]
  for it in 1 .. o.maxIter:
    result.iters = it
    sys.a = lin.a
    sys.b = lin.b
    for d in devices:
      if d.node == 0: continue
      let v = nodeV(result.x, d.node)
      let (i, g) = d.deviceAt(v, t, left)
      # Injection i(v) ~ i + g (v' - v): moves -g to the matrix.
      sys.addA(d.node - 1, d.node - 1, -g)
      sys.b[d.node - 1] += i - g * v
    if not luSolve(sys, xn):
      result.worstNode = 0
      return
    if it >= 3:
      for d in devices:
        if d.node == 0: continue
        let k = d.node - 1
        if segmentKey(d, result.x[k]) != segmentKey(d, xn[k]):
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
    if not conv: continue
    # KCL residual with the true device currents.
    var ok = true
    for d in devices:
      if d.node == 0: continue
      let r = d.node - 1
      var acc = -lin.b[r]
      for c in 0 ..< lin.n: acc += lin.a[r * lin.n + c] * xn[c]
      for d2 in devices:
        if d2.node == d.node: acc -= d2.deviceAt(xn[r], t, left).i
      if abs(acc) > o.iabstol:
        ok = false
        result.worstNode = d.node
    if ok:
      result.ok = true
      result.worstNode = 0
      return
