## Every built-in evaluator's declarations hold: each produced quantity has a
## declared unit, and each declared condition reaches the setup key -- two
## claims differing only in a condition the run reads must be two runs.
## (The `psrr_ac` key once omitted `at_f`; this is the class-wide check.)
## No simulator needed: only `setupKey` runs.

import std/[sets, tables, unittest]

import verax/netlist
import verax/contract/evaluate
import verax/analysis/evaluators/contract_eval

proc builtins(): seq[Evaluator] =
  var seen: HashSet[string]
  for q in evaluableQuantities():
    let ev = evaluatorFor(q).get
    if not seen.containsOrIncl(ev.name): result.add ev

proc boundDesign(): Design =
  ## One role instance binding every part any adapter reads, so a condition
  ## that only matters with a binding (`kick_v` needs a `kick`) is exercised.
  result = newDesign(newNetlist("keys"))
  var inst = RoleInstance(role: "probe", name: "r")
  for part in ["kick", "opamp", "input", "output", "source", "regulator"]:
    inst.bindings[part] = Subject(kind: skNet, name: part & "_net")
  result.roles["r"] = inst

proc probeClaim(ev: Evaluator, cond: OrderedTable[string, string]): Assertion =
  var subjects: seq[Subject]
  for i in 0 ..< max(ev.arity.a, 1):
    subjects.add Subject(kind: skNet, name: "n" & $i)
  Assertion(id: "k", quantity: ev.produces[0], subjects: subjects,
            expect: atLeast(0.0), condition: cond, origin: "r")

test "every built-in evaluator declares a unit for every quantity it produces":
  for ev in builtins():
    for q in ev.produces:
      checkpoint ev.name & " / " & q
      check ev.units.hasKey(q)

test "every declared condition changes the setup key":
  let ctx = newEvalContext(boundDesign(), allCapabilities)
  for ev in builtins():
    if ev.setupKey == nil: continue
    for k in ev.conditions:
      checkpoint ev.name & " / " & k
      let def = conditionDef(k)
      let (x, y) =
        if def.kind == cdText and def.allowed.len >= 2: (def.allowed[0], def.allowed[1])
        else: ("1.5", "2.5")
      var c1, c2: OrderedTable[string, string]
      c1[k] = x
      c2[k] = y
      check ev.setupKey(ctx, probeClaim(ev, c1)) != ev.setupKey(ctx, probeClaim(ev, c2))

test "every declared condition is registered":
  for ev in builtins():
    for k in ev.conditions:
      checkpoint ev.name & " / " & k
      check isConditionKey(k)
