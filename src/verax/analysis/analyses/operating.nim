## One operating point, solved once and shared.
##
## A straight line, not a fixed point: **at DC a capacitor is open, so the
## operating point doesn't depend on capacitance**. So an `.op` can be solved
## first, its node voltages used to derate Class 2 ceramics, and the
## `.ac`/`.tran` run against the derated values, with no iteration.
##
## Uses: DC-bias derating on nodes with no annotated voltage (biased stages,
## divider references, charge pumps), and one shared solve for `dc_voltage`
## and `analysis/derating`.
##
## Limitation: **a `.tran` bias moves with time** (a soft-starting rail, a
## charge pump's flying cap); derating from one operating point is then
## approximate.

import std/[math, strutils, tables]

import ../../netlist/types
import ../../netlist/graph
import ../../netlist/annotations
import ../../spice/transform
import ../../spice/flatten
import ../../spice/models
import ../../spice/ngspice

type
  OperatingPoint* = object
    ## Every node voltage in a design, or the reason there are none.
    voltages*: OrderedTable[string, float]
      ## Keyed by net name **after flattening** (`XL.amp`), as fragments use.
    solved*: bool
    reason*: string
      ## Why not, when not (e.g. no ground reference or no source).
    assumptions*: seq[Assumption]
      ## What standing in for unmodelled parts invented; consumers inherit
      ## it.

  OperatingSpec* = object
    pinModels*: PinModelDefaults
    modelUnmodelledParts*: bool
    flattenHierarchy*: bool

proc defaultOperatingSpec*(): OperatingSpec =
  result.pinModels = defaultPinModels()
  result.modelUnmodelledParts = true
  result.flattenHierarchy = true

proc solveOperatingPoint*(nl: Netlist, spec = defaultOperatingSpec()): OperatingPoint =
  ## Solves the design **as authored**, not isolated: isolation would
  ## terminate rails at the nominal voltages consumers are trying to find.
  # Clone, flatten, *then* `simReplace` (not `materializeSimNetlist`), so a
  # nested XSPICE component's ports use post-flatten net names.
  var globalNets: OrderedTable[string, Net]
  let simNl = clone(root(nl), globalNets)
  if spec.flattenHierarchy: discard flatten(simNl)
  applySimReplacements(simNl, purpose = spOperating)
  if spec.modelUnmodelledParts:
    result.assumptions.add expandPinModels(simNl, spec.pinModels)

  var sim: SimResult
  try:
    sim = run(simNl, @[".op"], label = "operating point")
  except CatchableError as e:
    result.reason = e.msg
    return

  for name, vec in sim.vectors:
    if vec.kind != sdReal or vec.values.len == 0: continue
    if not (name.len > 3 and name[0] == 'v' and name[1] == '('): continue
    result.voltages[name[2 ..< name.high] ] = vec.values[0]
  result.solved = true

proc voltageAt*(op: OperatingPoint, net: string): float =
  ## `NaN` when this operating point says nothing about `net` (not zero).
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
  ## The bare table, for `spice/models`, which can't import this module
  ## (solving needs a backend).
  op.voltages
