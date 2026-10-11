## `si.net` -- the `si_net` role's claims, on the native SI engine. One run
## per role instance (every receiver, corner and edge of the net); each
## claim gets its receiver's worst value and the corner/edge that set it.
##
## Statuses (plan decision 6): unsupported input, an unbound pin or no
## board -> `esNotEvaluable`; a solver failure -> `esNotEvaluated`; measured
## -> pass/fail through `verdict`.

import std/[tables, strutils]
import ./common
import ../analyses/si
import ../../pcb/types as pcbtypes
import ../../si/simulate as sisim
import ../../si/sweep as sisweep
import ../../contract/roles/core as rolecore

proc siRequest(ctx: EvalContext, a: Assertion): tuple[ok: bool, req: SiNetRequest, why: string] =
  let inst = originRole(ctx.design, a)
  if inst.isNone or inst.get.role != "si_net":
    return (false, SiNetRequest(), "SI quantities are produced only through the `si_net` role " &
      "(it names the net, the driver and every receiver)")
  let i = inst.get
  var req = SiNetRequest(net: i.subject("net").name, driver: pinRef(i.subject("driver").name))
  for p in ["rx", "rx2", "rx3", "rx4"]:
    if i.hasPart(p): req.receivers.add pinRef(i.subject(p).name)
  if hasParam(i, "ui"): req.ui = paramFloat(i, "ui", 0.0)
  if i.hasPart("victim_rx"):
    req.hasVictim = true
    req.victimNet = i.subject("victim").name
    req.victimDriver = pinRef(i.subject("victim_driver").name)
    req.victimRx = pinRef(i.subject("victim_rx").name)
  if hasParam(i, "coupled_length"): req.coupledLength = paramFloat(i, "coupled_length", 0.0)
  if hasParam(i, "min_eye_height") or hasParam(i, "min_eye_width"): req.eyeBits = 127
  (true, req, "")

proc siKey(ctx: EvalContext, a: Assertion): string =
  a.origin

proc siDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  let (ok, req, _) = siRequest(ctx, batch[0])
  if not ok: return "an SI run"
  var rx: seq[string]
  for r in req.receivers: rx.add $r
  "the native SI engine on net '" & req.net & "' as routed on the board: IBIS driver " &
    $req.driver & " into " & rx.join(", ") & ", rising and falling edges" &
    (if req.ui > 0: " and the ISI patterns " & isiPatterns.join("/") & " at the UI" else: "") &
    (if req.ui > 0 and req.eyeBits > 0: ", " & $req.eyeBits & " bits of PRBS7 folded into an eye" else: "") &
    ", every IBIS corner the data supports, worst case kept"

proc runSi(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  const name = "si.net"
  # Crosstalk claims: coupling is not extracted from a routed board yet.
  var batch = batch
  var rest: seq[Assertion]
  for a in batch:
    if a.quantity in siCrosstalkQuantities:
      result.add notEvaluable(a, name, "crosstalk on a routed board needs coupled-trace " &
        "extraction, which is not implemented; `verax constraints` derives the minimum " &
        "spacing to the victim before layout")
    else: rest.add a
  if rest.len == 0: return
  batch = rest
  let (ok, req, why) = siRequest(ctx, batch[0])
  if not ok:
    for a in batch: result.add notEvaluable(a, name, why)
    return
  let board = ctx.scratch.getOrDefault(boardScratchKey)
  if board == nil or not (board of BoardRef):
    for a in batch:
      result.add notEvaluable(a, name,
        "no board to check: pass --board=<file.kicad_pcb>, or run `verax constraints " &
        "<design>` to derive the routing rules for net '" & req.net & "' before layout")
    return
  let chk = analyzeSiNet(BoardRef(board).pcb, ctx.design.netlist, req)
  case chk.status
  of ssUnsupported:
    for a in batch:
      var r = notEvaluable(a, name, chk.reason)
      r.assumptions = chk.assumptions
      r.issues = chk.issues
      result.add r
    return
  of ssSolverFailed:
    for a in batch:
      var r = notEvaluated(a, name, "SI solver failure: " & chk.reason)
      r.assumptions = chk.assumptions
      r.issues = chk.issues
      result.add r
    return
  of ssOk: discard
  for a in batch:
    var k = -1
    if a.subjects.len > 0:
      for j, r in req.receivers:
        if $r == a.subjects[0].name: k = j
    if k < 0:
      result.add notEvaluable(a, name, "subject is not one of the role's receivers")
      continue
    result.add harvest(a, chk.reports[k], name)

proc siUnits(): Table[string, string] =
  ## From the engine's own figure units, so the declaration can't drift.
  for i, q in siQuantities: result[q] = figureUnit[SiFigure(i)]
  result[siEyeQuantities[0]] = figureUnit[sfEyeHeight]
  result[siEyeQuantities[1]] = figureUnit[sfEyeWidth]
  result[siCrosstalkQuantities[0]] = figureUnit[sfCrosstalk]
  result[siCrosstalkQuantities[1]] = figureUnit[sfNoiseMargin]

proc registerSiEvaluator*() =
  registerEvaluator(Evaluator(
    name: "si.net", produces: @siQuantities & @siEyeQuantities & @siCrosstalkQuantities,
    needs: {capSiTran}, arity: 1 .. 1, subjectKinds: {skPin},
    binds: @["net", "driver"],
    units: siUnits(),
    setupKey: siKey, setupDoc: siDoc, run: runSi))
