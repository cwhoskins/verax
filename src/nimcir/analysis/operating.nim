## One operating point, solved once and handed to everything that needs it.
##
## ## Why this can exist at all
##
## Chaining simulations usually means a fixed point: analysis B needs a result
## from A, and A's inputs depend on B's outputs, so you iterate and hope. That
## is not the case here, and the reason is worth stating because it is what
## makes the whole thing a straight line rather than a loop:
##
## **At DC a capacitor is an open circuit, so the operating point cannot depend
## on capacitance.** Measured, on a divider with a capacitor across the lower
## leg: `v(mid)` is bit-identical with 100 pF and with 1000 uF. So an `.op`
## may be solved *first*, its node voltages used to derate every Class 2
## ceramic in the design, and the `.ac` or `.tran` that follows run against the
## derated values -- with no iteration, no convergence question and no
## ordering ambiguity.
##
## ## What it buys
##
## The immediate consumer is DC-bias derating. Before this, `spice/models`
## could only read a *stated* rail voltage off a net, so a capacitor on any
## node whose voltage nobody had annotated was not derated at all -- and that
## blind spot covers exactly the nodes where bias is worst: a biased
## single-supply stage, a divider-derived reference, a charge pump. Measured:
## a 10 uF rated 6.3 V sitting on a 12 V divider's midpoint, therefore at 95%
## of its rating, came through completely underated because `mid` carried no
## `voltage` annotation. The `.op` says 6.000 V.
##
## The second consumer is arithmetic: `dc_voltage` and `analysis/derating`
## each used to run their own `.op` over the same design. Now they read this
## one. A design claiming two rails plus derating on both went from three
## solves to one.
##
## ## What it is not
##
## **A `.tran` bias moves with time**, and one number from t = 0 does not
## describe it. A charge pump's flying capacitor and a rail that is still
## soft-starting have no single DC across them, so derating them from this is
## wrong -- less wrong than not derating them at all, but wrong. Anything that
## cares should recompute per operating region rather than lean on this.

import std/[math, strutils, tables]

import ../netlist/types
import ../netlist/graph
import ../netlist/annotations
import ../spice/transform
import ../spice/flatten
import ../spice/models
import ../spice/ngspice

type
  OperatingPoint* = object
    ## Every node voltage in a design, or the reason there are none.
    voltages*: OrderedTable[string, float]
      ## Keyed by net name as it appears **after flattening**, which is the
      ## name a fragment will use too -- `XL.amp`, not `amp`.
    solved*: bool
    reason*: string
      ## Why not, when not. A design with no ground reference or no source is
      ## not solvable as authored, and that is a fact worth carrying rather
      ## than reducing to an empty table.
    assumptions*: seq[Assumption]
      ## What standing in for unmodelled parts invented to get here. A rail
      ## whose voltage depends on what an IC loads it with is resting on a
      ## guess, and every consumer of this inherits that guess.

  OperatingSpec* = object
    pinModels*: PinModelDefaults
    modelUnmodelledParts*: bool
    flattenHierarchy*: bool

proc defaultOperatingSpec*(): OperatingSpec =
  result.pinModels = defaultPinModels()
  result.modelUnmodelledParts = true
  result.flattenHierarchy = true

proc solveOperatingPoint*(nl: Netlist, spec = defaultOperatingSpec()): OperatingPoint =
  ## Solves the design **as authored** -- deliberately not isolated.
  ##
  ## Isolation terminates a cut rail with an ideal source at the rail's
  ## *nominal* voltage, which is the number half the consumers here are trying
  ## to find out. Isolating first would hand back the assumption. The whole
  ## design has to solve for itself, which is the same reasoning
  ## `contract_eval`'s `dc_voltage` has always run on.
  var globalNets: OrderedTable[string, Net]
  let simNl = materializeSimNetlist(root(nl), globalNets)
  if spec.flattenHierarchy: discard flatten(simNl)
  if spec.modelUnmodelledParts:
    result.assumptions.add expandPinModels(simNl, spec.pinModels)

  var sim: SimResult
  try:
    sim = run(simNl, @[".op"])
  except CatchableError as e:
    result.reason = e.msg
    return

  for name, vec in sim.vectors:
    if vec.kind != sdReal or vec.values.len == 0: continue
    if not (name.len > 3 and name[0] == 'v' and name[1] == '('): continue
    result.voltages[name[2 ..< name.high] ] = vec.values[0]
  result.solved = true

proc voltageAt*(op: OperatingPoint, net: string): float =
  ## `NaN` when this operating point says nothing about `net` -- which is a
  ## different answer from zero, and the distinction is the point: a node the
  ## solver never saw must not be reported as sitting at ground.
  if net.len == 0: return NaN
  if net == "0": return 0.0
  if op.voltages.hasKey(net): return op.voltages[net]
  # ngspice lowercases its vector names; a design may not have.
  for k, v in op.voltages:
    if cmpIgnoreCase(k, net) == 0: return v
  NaN

proc across*(op: OperatingPoint, a, b: string): float =
  ## The DC between two nets, or `NaN` if either is unknown.
  let va = voltageAt(op, a)
  let vb = voltageAt(op, b)
  if va.classify == fcNan or vb.classify == fcNan: return NaN
  abs(va - vb)

proc nodeVoltages*(op: OperatingPoint): OrderedTable[string, float] =
  ## The bare table, for passing to `spice/models`, which may not import this
  ## module: `models` is exported by the backend-agnostic `spice` hub and
  ## solving an operating point needs a backend.
  op.voltages
