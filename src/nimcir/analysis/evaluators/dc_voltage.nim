## `spice.dc_voltage` -- node voltages read off the shared `.op`.

import std/[math, strutils]
import ./common

const dcVoltageQuantities = ["dc_voltage"]

proc opKey(ctx: EvalContext, a: Assertion): string = ""
  ## One `.op` answers every node voltage in the design at once, so every
  ## `dc_voltage` assertion shares a step no matter which net it names. This
  ## is the harvest model at its most visible: N assertions, one simulation.

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
  ## **Deliberately does not use `spice/isolate`**, unlike every other
  ## analysis in this submodule.
  ##
  ## `isolate` terminates a cut rail with an ideal source at the rail's
  ## *nominal* voltage, taken from `Net.attrs["voltage"]` -- which is exactly
  ## the number a `dc_voltage` claim is asking us to verify. Isolating first
  ## would therefore measure the assumption back and pass every time. The
  ## whole design has to solve for the rail itself.
  ##
  ## The design must therefore be simulatable end to end. A part carrying no
  ## model is stood in for by `models.expandPinModels`, which gives each of
  ## its pins an impedance chosen from `Pin.kind` -- otherwise a board with an
  ## MCU on it dies in ngspice on `u1 vdd 0 sda scl` with an unknown-model
  ## error, which tells the reader nothing about their circuit. Those
  ## stand-ins are invented, so they ride out on every result's
  ## `assumptions`; a rail whose verdict depends on what an IC loads it with
  ## is resting on a guess and has to say so.
  let d = ctx.design
  const name = "spice.dc_voltage"

  # This used to solve its own `.op`. It now reads the shared one, which is
  # the same solve on the same netlist -- `solveOperatingPoint` materializes,
  # flattens and stands in for unmodelled parts exactly as this did, and for
  # the same stated reasons.
  let op = sharedOperatingPoint(ctx)
  let stood = op.assumptions
  if not op.solved:
    # Tried and could not, which is `esNotEvaluated` -- not a failed claim.
    # A design with no sources or no ground reference is not simulatable
    # as-authored, and that is a fact about the fragment, not about the rail.
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
    setupKey: opKey, setupDoc: opDoc, run: runDcVoltage))
