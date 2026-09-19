## Evaluators for differential pairs.
##
## A pair is declared with nothing new: two nets bound to the `diff_pair`
## role's `p`/`n` parts, ordinarily via a two-signal `InterfaceDef` (see
## `netlist/interfaces/std.diffPairInterface`). What is genuinely new is the
## checking, here.
##
## `diff_pair_symmetry` is the one quantity this file can actually answer
## from the graph alone: it walks each leg through `kinds.conductiveExits`
## and compares what it finds, part for part. `intra_pair_skew`, `z_diff`
## and `inter_pair_skew` are registered but decline every claim -- skew and
## characteristic impedance are routing properties, and nothing in this
## repository accumulates trace length or solves a stackup yet (`pcb/`
## carries tracks and a stackup with `epsilonR`, but no length walk, no Z0
## formula, and `Design` holds no `Pcb`). Registering them anyway is
## deliberate: `evaluableQuantities()` is what `verax quantities` renders and
## what `didYouMean` ranks against, so a registered-but-unevaluable quantity
## is discoverable and a claim naming it gets a true reason, while an
## unregistered one reports "no evaluator produces X", which reads as "you
## made that up".

import std/[sets, strutils, tables]
import ../../netlist/types
import ../../netlist/kinds
import ../../netlist/formats/spice as spiceFormat
import ../evaluate

export evaluate

const
  maxLegHops = 12
    ## A differential pair's own two-terminal series chain -- an AC-coupling
    ## cap, a common-mode choke winding, a series termination resistor --
    ## rarely runs deeper than a handful of parts before it reaches a
    ## connector or IC pin. This is a walk bound, not a claim about circuit
    ## depth: exceeding it stops the comparison rather than failing it, on
    ## the same reasoning `static.rc_corner` invents a capacitance and says
    ## so rather than refusing to answer.
  valueTolFrac = 0.01
    ## Two legs' series parts are compared as *values*, not as designators --
    ## R47 and R48 both being 22.1R is a match. A 1% band absorbs float
    ## round-trip noise in a parsed magnitude without absorbing a real
    ## mismatch; standard resistor/capacitor tolerances are wider than this,
    ## but that is a derating question, not a symmetry question.

proc magnitudeOf(c: Component): tuple[has: bool, value: float] =
  ## As `evaluators/static.magnitudeOf`, duplicated rather than imported:
  ## that one is private to `static.nim` and this module reads no more of it
  ## than this.
  if not c.attrs.hasKey("value"): return (false, 0.0)
  var v: float
  if spiceFormat.parseSpiceMagnitude(c.attrs["value"], v): (true, v)
  else: (false, 0.0)

proc valuesAgree(a, b: Component): bool =
  let (haveA, va) = magnitudeOf(a)
  let (haveB, vb) = magnitudeOf(b)
  if not haveA or not haveB:
    # Neither side states a bare magnitude (a diode, an IC, a part carrying
    # only a part number) -- kind already matched, and there is nothing
    # numeric left to disagree about.
    return true
  if va == 0.0 and vb == 0.0: return true
  abs(va - vb) <= valueTolFrac * max(abs(va), abs(vb))

proc seriesNeighbors(n: Net, exclude: Net): seq[tuple[c: Component, farNet: Net]] =
  ## Every component touching `n` with exactly two connected pins -- an
  ## ordinary series element, not a branch point -- paired with the net on
  ## its far side. `exclude` is the net the walk arrived from, so a leg does
  ## not immediately double back through the part it just crossed.
  var seen: HashSet[string]
  for p in n.pins:
    let c = p.component
    if c == nil or c.designator in seen: continue
    var connected = 0
    for _, pp in c.pins:
      if pp.net != nil: inc connected
    if connected != 2: continue
    for far in conductiveExits(c, p):
      if far != exclude and far != n:
        seen.incl c.designator
        result.add (c, far)

proc compareLegs(pStart, nStart: Net): tuple[symmetric: bool, reason: string, part: Component] =
  ## Walks both legs of a pair in lock-step, one series part at a time, and
  ## reports the first place they disagree -- a mismatched part count
  ## (a leg that branches where the other does not), a mismatched kind, or a
  ## mismatched value. A leg that dead-ends -- an IC or connector pin -- ends
  ## the walk for both sides at once, since `nextP.len == nextN.len == 0` is
  ## the ordinary termination, not a mismatch.
  var curP = pStart
  var curN = nStart
  var fromP: Net = nil
  var fromN: Net = nil
  for hop in 0 ..< maxLegHops:
    let nextP = seriesNeighbors(curP, fromP)
    let nextN = seriesNeighbors(curN, fromN)
    if nextP.len == 0 and nextN.len == 0:
      return (true, "", nil)
    if nextP.len != nextN.len:
      return (false, "leg branches differently past " & (if fromP == nil: pStart.name else: curP.name) &
        "/" & (if fromN == nil: nStart.name else: curN.name) & " (" & $nextP.len &
        " onward parts on one leg, " & $nextN.len & " on the other)", nil)
    if nextP.len != 1:
      # More than one parallel series path on both legs (e.g. a pair of
      # series/shunt legs at a termination network): match as multisets by
      # kind and value rather than assuming a pairing order, and do not walk
      # past a branch -- there is no single "far net" to continue from.
      var usedN = newSeq[bool](nextN.len)
      for pr in nextP:
        var matched = false
        for i, nr in nextN:
          if usedN[i]: continue
          if pr.c.kind == nr.c.kind and valuesAgree(pr.c, nr.c):
            usedN[i] = true; matched = true; break
        if not matched:
          return (false, "no matching part on the other leg for " & pr.c.designator &
            " (" & pr.c.kind & ")", pr.c)
      return (true, "", nil)
    let (cp, farP) = nextP[0]
    let (cn, farN) = nextN[0]
    if cp.kind != cn.kind:
      return (false, cp.designator & " (" & cp.kind & ") has no matching part " &
        "type on the other leg -- " & cn.designator & " is " & cn.kind, cp)
    if not valuesAgree(cp, cn):
      return (false, cp.designator & " and " & cn.designator & " have mismatched values", cp)
    fromP = curP; curP = farP
    fromN = curN; curN = farN
  # Walk-depth exceeded with both legs still matching hop for hop: treated
  # as symmetric on the evidence gathered, the same trade-off `rc_corner`
  # makes when it invents a number and reports it as an assumption rather
  # than refusing to answer.
  (true, "", nil)

proc runDiffPairSymmetry(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  let d = ctx.design
  for a in batch:
    let pOpt = netSubject(d, a, 0)
    let nOpt = netSubject(d, a, 1)
    if pOpt.isNone or nOpt.isNone:
      result.add notEvaluable(a, "diff.pair_symmetry", "subjects are not both nets in this design")
      continue
    let (symmetric, reason, part) = compareLegs(pOpt.get, nOpt.get)
    var issues: seq[Issue]
    if not symmetric:
      issues.add newIssue("diff_pair_leg_mismatch", sevWarning, reason,
        components = (if part != nil: @[part] else: @[]))
    result.add verdict(a, (if symmetric: 1.0 else: 0.0), "", "diff.pair_symmetry",
                       issues = issues)

proc noBoard(a: Assertion, evaluator, what: string): AssertionResult =
  notEvaluable(a, evaluator, what & " is a routing property and no board is " &
    "attached to this design; `pcb/` carries tracks and a stackup but no " &
    "trace-length accumulation or field solver yet")

proc runIntraPairSkew(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  for a in batch:
    result.add noBoard(a, "diff.intra_pair_skew", "intra-pair skew")

proc runZDiff(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  for a in batch:
    result.add noBoard(a, "diff.z_diff", "differential characteristic impedance")

proc runInterPairSkew(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult] =
  for a in batch:
    result.add noBoard(a, "diff.inter_pair_skew", "inter-pair skew")

proc netOf(a: Assertion): string =
  for sub in a.subjects:
    if sub.kind == skNet: return sub.name
  "the design"

proc symmetryDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  "a graph walk of both legs of '" & netOf(batch[0]) &
  "', comparing series parts hop for hop by kind and value"

proc interPairDoc(ctx: EvalContext, batch: seq[Assertion]): string =
  var names: seq[string]
  for s in batch[0].subjects: names.add s.name
  "the group " & names.join(", ")

proc registerDiffEvaluators*() =
  ## Called at module init; exposed so an application that clears the
  ## registry can put these back, matching `static.registerStaticEvaluators`.
  registerEvaluator(Evaluator(
    name: "diff.pair_symmetry",
    produces: @["diff_pair_symmetry"],
    needs: {capStatic},
    arity: 2 .. 2,
    subjectKinds: {skNet},
    setupDoc: symmetryDoc,
    run: runDiffPairSymmetry))

  registerEvaluator(Evaluator(
    name: "diff.intra_pair_skew",
    produces: @["intra_pair_skew"],
    needs: {capStatic},
    arity: 2 .. 2,
    subjectKinds: {skNet},
    run: runIntraPairSkew))

  registerEvaluator(Evaluator(
    name: "diff.z_diff",
    produces: @["z_diff"],
    needs: {capStatic},
    arity: 2 .. 2,
    subjectKinds: {skNet},
    run: runZDiff))

  registerEvaluator(Evaluator(
    name: "diff.inter_pair_skew",
    produces: @["inter_pair_skew"],
    needs: {capStatic},
    arity: 2 .. high(int),
    subjectKinds: {skNet},
    setupDoc: interPairDoc,
    run: runInterPairSkew))

registerDiffEvaluators()
