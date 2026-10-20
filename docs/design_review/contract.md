# `contract/` — design intent

What a circuit must do, and the machinery that routes each claim to something
that can check it. Imports only `netlist` (plus `units`/`eng`), so a design is
authorable and inspectable with no simulator in the build. That single
dependency is the most important structural fact about this module.

## Data structures

| type | shape | notes |
|---|---|---|
| `Subject` | `{kind: SubjectKind, name: string}` | `skNet/skComponent/skPin/skClass/skDesign`; a name, resolved on demand; `skClass` names a role instance |
| `Expectation` | **variant**: `ekNominal` (nominal, frac/abs tol), `ekMin`, `ekMax`, `ekRange`, `ekRelative` (op, coeff, `MeasurementRef`, band), `ekPredicate` (named deps + `{.nimcall.}` proc) | `bounds` gives the interval; `satisfies` is the one comparison; NaN never satisfies |
| `Assertion` | id, `subjects: seq[Subject]`, `quantity: string`, `condition: OrderedTable[string,string]`, `expect`, `unit: string`, severity, `rationale`, `origin` | plain data; `origin` is `"authored"` or the role instance name |
| `RoleDef` | name, doc, `expects` (interface), `parts: seq[RolePart]`, `params: seq[AnnDef]`, `apply` and `expand` procs | registered by name; built-ins use the same path |
| `RoleInstance` | role, name, `bindings: OrderedTable[string, Subject]`, `params: OrderedTable[string,string]`, `member`, `declined` | `member` is a field not a param (see below) |
| `Design` | `ref`; owns a `Netlist`, `roles: OrderedTable`, authored `assertions` | adds nothing to `netlist/types` |
| `Evaluator` | name, `produces: seq[string]`, `needs: set[Capability]`, `arity: Slice[int]`, `subjectKinds`, `binds`, `setupKey`/`setupDoc`/`run` procs | the plugin ABI is `run(ctx, batch)` |
| `EvalContext` | `ref`; design, allowed caps, `scratch: Table[string, RootRef]` | one per run; the only argument an evaluator gets |
| `Plan` | `steps: seq[PlanStep]` (evaluator, key, needs, batch), `rejected`, `resolves`, `hidden: HashSet[string]` | pure: built before anything runs |
| `AssertionResult` | assertion, `EvalStatus` (pass/fail/notEvaluated/notEvaluable), value, unit, reason, evaluator, assumptions, issues | deliberately not an `Issue` |
| `Capability` | closed enum: static, spice op/dc/ac/tran, si, bench | gate is `ev.needs <= allowed` |

## Patterns

**A role is a parameterised assertion generator, not a tag.** `RoleDef` has
two halves: `apply` (writes annotations the simulator needs regardless of
checking — a rail's `voltage`) and `expand` (pure; returns `seq[Assertion]`).
Every reader of claims goes through `expandInstance`, so `explain`, `plan`
and `verax roles` cannot drift. Membership is stamped onto entities as
`role.<instance>` attrs so it survives cloning and isolation.

**Quantity names are the join between intent and measurement.** An
assertion names a quantity string; an evaluator declares the strings it
produces; `quantityIndex` maps one to the other (one producer per quantity,
enforced). Comparison is shared (`verdict`/`satisfies`), so evaluators only
produce numbers.

**Plan, then run, then fold.** `plan` routes each assertion (authored and
expanded) to an evaluator, checks arity/subject kinds/capabilities, and
groups by `(evaluator, setupKey)`. `ekRelative`/`ekPredicate` are decomposed
into hidden plain requests (ids prefixed `\x1f`) plus a `ResolveStep`;
`resolveHidden` folds them back. Evaluators never see the composite forms.

**Batch-shaped plugin ABI.** `EvalProc` takes every assertion sharing a setup
key, so "one simulation per distinct setup" is a property of the planner,
provable by counting steps, not something each evaluator re-implements.

**Fault isolation per step.** `runStep` catches an evaluator's exception and
converts the batch to `notEvaluated`; a wrong result count is matched back by
id and the remainder accounted for.

**Two kinds of "couldn't check".** `esNotEvaluable` (nothing can produce this
for these subjects) vs `esNotEvaluated` (a producer exists but did not run or
returned NaN). They map to different exit codes and different fixes.

**Setup topology from the role, not the netlist.** Evaluators read role
bindings back through `Assertion.origin` (`originBinding`,
`subjectRoleBinding`). `Evaluator.binds` declares which role parts are read,
so "can a bare `require` reach this quantity?" is answerable without running.

## What this buys

- **A design is useful without a simulator.** `explain`, `plan`,
  `explainPlan`, static evaluators and structural checks all run with only
  `netlist` linked. The CLI catalog and the Python spike both
  lean on this.
- **Extensibility without privilege.** User roles and evaluators register
  the same way built-ins do; a test pins it.
- **Grouping is correct by construction.** The batch ABI plus setup keys
  turned "don't re-run the `.op` for every `dc_voltage` claim" from a
  per-evaluator optimisation into a planner guarantee.
- **Composite expectations without an expression language.** Decomposing
  relative/predicate claims into hidden requests means the evaluator ABI did
  not change when they were added — the variant `Expectation` did its job.
- **The report can explain itself.** Because the plan is data, `Readiness`
  can show which claims came from one run and what that run was.

## Critique

1. **`Assertion.condition` is an unvalidated string map.** Conditions are the
   inputs that most directly change what gets simulated (`f_from`,
   `t_settle`, `step_to`, `ripple_f`, `sweep`…), yet there is no registry of
   condition keys. A misspelled key (`f_form`) is silently ignored and the
   evaluator uses its default — exactly the failure mode the annotation
   registry was built to prevent for `attrs`. `types.conditionUnits` lists
   keys, but only for rendering.
   **Fixed 2026-10-10:** a condition registry (`ConditionDef`, `registerCondition`); `plan` refuses an unknown bare key with a did-you-mean, and dotted keys stay free. `at_t`, which `authoring.md` documented but nothing read, is now refused. A registered key the evaluator doesn't read is now refused too (`Evaluator.conditions`, R1.2).

2. **`conditionFloat` swallows parse errors.** It returns the fallback on any
   `CatchableError`, so a malformed condition value becomes the default value
   with no issue raised. The DSL path produces well-formed values, so this
   mostly bites the runtime API (`assertion(..., condition = …)`, the Python
   front end).
   **Fixed 2026-10-10:** `plan` refuses a malformed value, and `conditionFloat` now defaults only an absent key and raises on a malformed one.

3. **Setup keys and run procs must agree, and nothing checks it.** Each
   evaluator's `setupKey` decides which assertions share a run; its `run`
   then typically reads conditions from `batch[0]` only. If a key omits a
   condition the run reads, two claims with different values for it are
   silently answered by one simulation configured from the first. The rule is
   documented ("setup keys carry everything that changes the run"), not
   structural, and there is a live instance: `spice.psrr_ac`'s key omits
   `at_f` while its run reads `at_f` from `batch[0]` (see
   [analysis.md](analysis.md), critique 1). A design where the key is
   *derived* from a declared list of setup-relevant condition keys would make
   this class of bug impossible.

4. **Units are strings compared case-insensitively, and empty means
   "unchecked".** `unitsAgree("", "V")` is true. `verify.claimLint` exists as
   a stopgap for the dangerous case (`5.pct` against a percent-valued
   measurement). Evaluators do not declare per-quantity units, so the check
   happens only after a measurement exists.

5. **Assertion ids are not checked for uniqueness** (as far as a search of
   `contract/` and `verify.nim` shows). Role-expanded ids are
   `<instance>.<suffix>` and instance names are unique, so collisions need an
   authored claim or a role that emits a suffix twice. When ids collide,
   `runStep`'s id-based recovery and `--baseline` diffing become ambiguous.

6. **`runStep` trusts order when the count matches.** If an evaluator returns
   the right number of results in the wrong order, they are accepted
   positionally; id matching only happens on a count mismatch.

7. **`Capability` is closed while everything else is open.** Justified in the
   doc comment (the library owns execution environments), but a third-party
   evaluator that needs a new tool (a field solver, a bench instrument class)
   cannot declare it. `fem/` will hit this.

8. **Role parameters are untyped strings validated only for `akFloat`.** The
   documented consequence — "never use a string-valued mode parameter",
   because `verify.claimingRoles` probes with `"1"` — is a rule created by the
   representation. `RoleInstance.member` became a field to escape it.

9. **Hidden requests are encoded in the id string** (`\x1fcontract-dep\x1f…`)
   *and* tracked in `Plan.hidden`. Robust in practice; a dedicated flag on the
   request would make it impossible to forget either.

10. **Resolution helpers are inconsistent about hierarchy.**
    `netSubject` looks only at `d.netlist.nets` (flat), while
    `analysis/evaluators/common.subjectNet` uses `findNet` (hierarchical).
    An evaluator using the former silently gets `none` for `XL.vout`.

## Things that look odd but are right

- `NaN` → `esNotEvaluated`, not fail: `z_antiresonance = NaN` (no peak) is
  the good outcome, and "didn't find it in range" is not "the design is
  wrong".
- An empty `needs` normalises to `{capStatic}`, never `{}` — otherwise
  "declared nothing" would mean "runs anywhere".
- `registerEvaluator` replaces under the *same* name (the override path) but
  raises when a *different* evaluator claims a quantity (an accident).
- `capSiTran` is in `offlineCapabilities`: the SI engine is native, so an
  `--offline` check runs SI simulations.
