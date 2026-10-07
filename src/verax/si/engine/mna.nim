## The linear core of the native transient engine: a `Circuit` of R, L, C,
## sources, lossless lines and nonlinear shunt devices; modified nodal
## analysis stamping; dense LU with partial pivoting (SI nets are tens to
## low hundreds of nodes -- sparse only if profiling asks).
##
## Unknowns, in order: node voltages `1 .. n-1` (node 0 is ground), then one
## branch current per voltage source, per inductor, and -- at the DC
## operating point only -- per line (a lossless line at DC is a wire).
##
## Companion models (`h` the step):
##
## - **Capacitor**, trapezoidal: `i1 = (2C/h)(v1 - v0) - i0`; backward
##   Euler: `i1 = (C/h)(v1 - v0)`. Open at DC.
## - **Inductor**, as a branch so `L = 0` is an exact short: trapezoidal
##   `v1 = (2L/h)(i1 - i0) - v0`; backward Euler `v1 = (L/h)(i1 - i0)`.
##   Short at DC.
## - **Resistor** of exactly `0` ohms is stamped as a 0 V source, not an
##   infinite conductance.
## - Every node has `gmin` (default `1e-12` S) to ground so a node held
##   only by capacitors or a flat table segment stays solvable.

import ./pwl
import ../../ibis/behave

export pwl

type
  Integration* = enum
    imTrapezoidal, imBackwardEuler

  Res* = object
    a*, b*: int
    r*: float
    label*: string

  Cap* = object
    a*, b*: int
    c*: float
    label*: string

  Ind* = object
    a*, b*: int
    l*: float
    label*: string

  VSrc* = object
    ## `v(a) - v(b) = wave(t)`; the DC operating point uses `wave.initial`.
    a*, b*: int
    wave*: Pwl
    label*: string

  ISrc* = object
    ## Current `wave(t)` flowing through the source from `a` to `b`
    ## (injected into `b`).
    a*, b*: int
    wave*: Pwl
    label*: string

  Line* = object
    ## Lossless line between `a` and `b`, both ends referenced to ground.
    a*, b*: int
    z0*, td*: float
    label*: string

  NlDevice* = object
    ## A nonlinear shunt element at `node`: injects
    ## `sum_k weights[k](t) * curves[k](v)` **into** the node (out of the
    ## die). An empty weight is the constant 1.
    node*: int
    curves*: seq[IvCurve]
    weights*: seq[Pwl]
    label*: string

  Circuit* = object
    nodeNames*: seq[string]
    resistors*: seq[Res]
    capacitors*: seq[Cap]
    inductors*: seq[Ind]
    vsources*: seq[VSrc]
    isources*: seq[ISrc]
    lines*: seq[Line]
    devices*: seq[NlDevice]

  Layout* = object
    ## Where each unknown lives in `x`.
    nNodes*: int       ## excluding ground
    zeroR*: seq[int]   ## resistor index -> extra branch, or -1
    vBase*, lBase*, rBase*, lineBase*: int
    size*: int

proc newCircuit*(): Circuit = Circuit(nodeNames: @["0"])

proc addNode*(c: var Circuit, name: string): int =
  c.nodeNames.add name
  c.nodeNames.high

proc layout*(c: Circuit, dc: bool): Layout =
  result.nNodes = c.nodeNames.len - 1
  result.vBase = result.nNodes
  result.lBase = result.vBase + c.vsources.len
  result.rBase = result.lBase + c.inductors.len
  var nz = 0
  for r in c.resistors:
    if r.r == 0.0:
      result.zeroR.add result.rBase + nz
      inc nz
    else:
      result.zeroR.add -1
  result.lineBase = result.rBase + nz
  result.size = result.lineBase + (if dc: c.lines.len else: 0)

type
  System* = object
    n*: int
    a*: seq[float]   ## row-major n x n
    b*: seq[float]

proc newSystem*(n: int): System =
  System(n: n, a: newSeq[float](n * n), b: newSeq[float](n))

proc clear*(s: var System) =
  for x in s.a.mitems: x = 0.0
  for x in s.b.mitems: x = 0.0

template idx(node: int): int = node - 1

proc addA*(s: var System, r, c: int, v: float) {.inline.} =
  s.a[r * s.n + c] += v

proc stampG*(s: var System, a, b: int, g: float) =
  ## Conductance between nodes (0 = ground).
  if a > 0: s.addA(idx(a), idx(a), g)
  if b > 0: s.addA(idx(b), idx(b), g)
  if a > 0 and b > 0:
    s.addA(idx(a), idx(b), -g)
    s.addA(idx(b), idx(a), -g)

proc stampI*(s: var System, a, b: int, i: float) =
  ## A current `i` flowing from `a` to `b` through an external source:
  ## leaves `a`, enters `b`.
  if a > 0: s.b[idx(a)] -= i
  if b > 0: s.b[idx(b)] += i

proc stampInject*(s: var System, node: int, i: float) =
  ## Current injected into `node` from ground.
  if node > 0: s.b[idx(node)] += i

proc stampBranch*(s: var System, br, a, b: int, rCoef, rhs: float) =
  ## Branch current `x[br]` flows `a -> b` through the element; its row is
  ## `v(a) - v(b) - rCoef * i = rhs`.
  if a > 0:
    s.addA(idx(a), br, 1.0)
    s.addA(br, idx(a), 1.0)
  if b > 0:
    s.addA(idx(b), br, -1.0)
    s.addA(br, idx(b), -1.0)
  s.addA(br, br, -rCoef)
  s.b[br] += rhs

proc luSolve*(s: System, x: var seq[float]): bool =
  ## Solve `a x = b` (copies `a`). False when (numerically) singular.
  let n = s.n
  var a = s.a
  var b = s.b
  var scale = 0.0
  for v in a: scale = max(scale, abs(v))
  if scale == 0.0: scale = 1.0
  for k in 0 ..< n:
    var p = k
    var best = abs(a[k * n + k])
    for r in k + 1 ..< n:
      let v = abs(a[r * n + k])
      if v > best: best = v; p = r
    if best <= 1e-300 or best < scale * 1e-18: return false
    if p != k:
      for c in 0 ..< n: swap(a[k * n + c], a[p * n + c])
      swap(b[k], b[p])
    let piv = a[k * n + k]
    for r in k + 1 ..< n:
      let f = a[r * n + k] / piv
      if f == 0.0: continue
      a[r * n + k] = 0.0
      for c in k + 1 ..< n: a[r * n + c] -= f * a[k * n + c]
      b[r] -= f * b[k]
  x.setLen n
  for k in countdown(n - 1, 0):
    var acc = b[k]
    for c in k + 1 ..< n: acc -= a[k * n + c] * x[c]
    x[k] = acc / a[k * n + k]
  true

proc nodeV*(x: seq[float], node: int): float {.inline.} =
  if node == 0: 0.0 else: x[node - 1]
