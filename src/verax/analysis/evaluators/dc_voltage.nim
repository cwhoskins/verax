## `spice.dc_voltage` -- node voltages read off the shared `.op`.
##
## `unmated = "J3"` solves the board with those connectors unplugged
## (`spice/bench.unmate`), one `.op` per set. A claim whose net then has no
## DC path at all fails rather than reporting the number: what ngspice
## solves a floating node to is whatever invented stand-in leak happens to
## sit on it, not a logic level.

import std/[math, strutils, tables]
import ../../netlist/graph
import ../io_check
import ./common

const dcVoltageQuantities = ["dc_voltage"]

proc opKey(ctx: EvalContext, a: Assertion): string =
  ## One `.op` answers every node, so all `dc_voltage` claims with the same
  ## `unmated` set share a step.
  let unmated = unmatedConnectors(a)
  if unmated.len == 0: "" else: "unmated=" & unmated.join(",")

proc opDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  let d = ctx.design
  var nets: seq[string]
  for a in batch:
    let n = subjectNet(d, a)
    if n.len > 0 and n notin nets: nets.add n
  result = "one `.op` solve of the whole design -- not isolated, so each " &
           "rail has to solve for itself rather than be told what it is"
  if batch.len > 0:
    let unmated = unmatedConnectors(batch[0])
    if unmated.len > 0:
      result &= ", with " & unmated.join(", ") & " unplugged (nothing mated)"
  if nets.len > 0: result &= ". Reading net " & nets.join(", ")

proc runDcVoltage(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  ## **Not isolated**: isolation terminates rails at their nominal voltage,
  ## the number being checked. The whole design must solve, so unmodelled
  ## parts are stood in for by `expandPinModels`, and those invented
  ## impedances ride along as assumptions.
  let d = ctx.design
  const name = "spice.dc_voltage"

  # Reads the shared operating point (every claim in a batch shares its
  # `unmated` set: `opKey`).
  let unmated = if batch.len > 0: unmatedConnectors(batch[0]) else: @[]
  let op = sharedOperatingPoint(ctx, unmated)
  let stood = op.assumptions
  if not op.solved:
    # Couldn't solve (no source or ground): not evaluated, not failed.
    return failBatch(batch, name,
      "the .op run did not produce a result: " & op.reason, stood)

  for a in batch:
    let netName = subjectNet(d, a)
    if netName.len == 0:
      result.add notEvaluable(a, name,
        "dc_voltage needs a net subject that exists in this design")
      continue
    let v = voltageAt(op, netName)
    if v.classify == fcNan:
      result.add notEvaluable(a, name,
        "the operating point holds no voltage for net '" & netName & "'")
      continue
    if unmated.len > 0:
      let net = findNet(d.netlist, netName)
      if net != nil:
        let (floats, mates) = floatsWithout(net, unmated)
        if floats:
          var r = verdict(a, v, "V", name, stood)
          r.status = esFail
          r.noMargin = true
          r.reason = " at net '" & netName & "', which floats with " &
            componentListLabel(mates) & " unmated: nothing on the board " &
            "holds it, so the reading is a stand-in's leak, not a level"
          result.add r
          continue
    result.add verdict(a, v, "V", name, stood)

proc registerDcVoltageEvaluator*() =
  registerEvaluator(Evaluator(
    name: "spice.dc_voltage", produces: @dcVoltageQuantities,
    needs: {capSpiceOp}, arity: 1 .. 1, subjectKinds: {skNet},
    conditions: @["unmated"],
    units: {"dc_voltage": "V"}.toTable,
    setupKey: opKey, setupDoc: opDoc, run: runDcVoltage))
