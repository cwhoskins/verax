## The linear core of the native transient engine: a `Circuit` of R, L, C,
## sources, lossless lines and nonlinear shunt devices; modified nodal
## analysis stamping. The solve is `lu` (band LU over an RCM ordering).
##
## Unknowns, in order: node voltages `1 .. n-1` (node 0 is ground), then one
## branch current per voltage source, per inductor, and -- at the DC
## operating point only -- per line (a lossless line at DC is a wire; a
## convolution line is its DC two-port's series branch; a coupled line is
## two wires; an S-parameter block its `S(0)` pi's series branch).
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
import ./convline
import ./sblock
import ../../ibis/behave

export pwl, convline, sblock

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

  CoupledLine* = object
    ## A symmetric lossless coupled pair: conductor 1 from `a1` to `b1`,
    ## conductor 2 from `a2` to `b2`, all referenced to ground. Simulated
    ## as its two modes (even: `(v1 + v2)/2`, odd: `(v1 - v2)/2`), each a
    ## Bergeron line with its own impedance and delay.
    a1*, b1*, a2*, b2*: int
    zEven*, zOdd*, tdEven*, tdOdd*: float
    label*: string

  NlDevice* = object
    ## A nonlinear element at `node`: injects
    ## `sum_k weights[k](t) * scale[k] * curves[k](x_k)` **into** the node
    ## (out of the die). An empty weight is the constant 1.
    ##
    ## **Rail-referenced curves** (power-aware): when `refs[k] > 0`, curve
    ## `k` hangs from that rail node -- it is read at `x_k = v(node) -
    ## (v(ref) - refNominal[k])` (the tables' rail moved by its deviation)
    ## and its current is drawn **out of** the rail node. Otherwise (`refs`
    ## empty, or `0`) `x_k = v(node)` and the current comes from ground.
    ## At most two distinct rail nodes per device.
    node*: int
    curves*: seq[IvCurve]
    weights*: seq[Pwl]
    refs*: seq[int]
    refNominal*: seq[float]
    scale*: seq[float]
      ## Per-curve factor (power-aware `Ksso`), set by the transient loop
      ## from the last accepted step; empty = 1.
    ksso*: seq[IvCurve]
      ## Per curve: the factor against `Vtable` (`IvCurve.i` = factor);
      ## empty curve = none.
    kssoSign*: seq[float]
      ## `Vtable = kssoSign * (v(ref) - refNominal)`: `-1` for a pullup (the
      ## rail's droop), `+1` for a pulldown (its rise).
    label*: string

  Circuit* = object
    nodeNames*: seq[string]
    resistors*: seq[Res]
    capacitors*: seq[Cap]
    inductors*: seq[Ind]
    vsources*: seq[VSrc]
    isources*: seq[ISrc]
    lines*: seq[Line]
    convLines*: seq[ConvLine]
    coupled*: seq[CoupledLine]
    sblocks*: seq[SBlock]
    devices*: seq[NlDevice]

  Layout* = object
    ## Where each unknown lives in `x`.
    nNodes*: int       ## excluding ground
    zeroR*: seq[int]   ## resistor index -> extra branch, or -1
    vBase*, lBase*, rBase*, lineBase*, convBase*, coupledBase*, sblockBase*: int
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
  result.convBase = result.lineBase + (if dc: c.lines.len else: 0)
  result.coupledBase = result.convBase + (if dc: c.convLines.len else: 0)
  result.sblockBase = result.coupledBase + (if dc: 2 * c.coupled.len else: 0)
  result.size = result.sblockBase + (if dc: c.sblocks.len else: 0)

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

proc nodeV*(x: seq[float], node: int): float {.inline.} =
  if node == 0: 0.0 else: x[node - 1]
