## `spice.dc_voltage` -- node voltages read off the shared `.op`.

import std/[math, strutils, tables]
import ./common

const dcVoltageQuantities = ["dc_voltage"]

proc opKey(ctx: EvalContext, a: Assertion): string = ""
  ## One `.op` answers every node, so all `dc_voltage` claims share a step.

proc opDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  let d = ctx.design
  var nets: seq[string]
  for a in batch:
    let n = subjectNet(d, a)
    if n.len > 0 and n notin nets: nets.add n
  result = "one `.op` solve of the whole design -- not isolated, so each " &
           "rail has to solve for itself rather than be told what it is"
  if nets.len > 0: result &= ". Reading net " & nets.join(", ")

proc runDcVoltage(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  ## **Not isolated**: isolation terminates rails at their nominal voltage,
  ## the number being checked. The whole design must solve, so unmodelled
  ## parts are stood in for by `expandPinModels`, and those invented
  ## impedances ride along as assumptions.
  let d = ctx.design
  const name = "spice.dc_voltage"

  # Reads the shared operating point.
  let op = sharedOperatingPoint(ctx)
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
    result.add verdict(a, v, "V", name, stood)

proc registerDcVoltageEvaluator*() =
  registerEvaluator(Evaluator(
    name: "spice.dc_voltage", produces: @dcVoltageQuantities,
    needs: {capSpiceOp}, arity: 1 .. 1, subjectKinds: {skNet},
    units: {"dc_voltage": "V"}.toTable,
    setupKey: opKey, setupDoc: opDoc, run: runDcVoltage))
