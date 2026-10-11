# `contract` submodule

Design *intent*: what a circuit is meant to be and must do. **Depends only on `netlist`**, so a design is inspectable with no simulator — never give it an edge to `analysis` or `pcb`. `contract/dsl.nim` is opt-in.

## Model

- **A role is a parameterized bundle of assertions, not a tag.** Built-in roles use **no privileged mechanism** — ordinary `RoleDef`s registered the ordinary way (`tests/test_contract_roles.nim` pins this). User roles outside the library: `designs/lib/i2c_parts.nim` (`i2c_transaction`), `designs/lib/xbar_parts.nim` (`safe_default`).
- **`types.nim`** — `Subject`, `Expectation`, `Assertion`. Keep these shapes: `subjects` is a **seq** (multi-subject quantities aren't a special case); `quantity` is an **open string naming an analysis `Measurement`**; `Expectation` is a **variant** (`ekRelative`, `ekPredicate` are additive). `satisfies` is the shared comparison; **`NaN` never satisfies**.
- Every registered quantity is electrical. A digital outcome reaches the report by driving it out through a `dac_bridge` and claiming the voltage (`settled_v`).
- **Not an expression language.** Escalation: derived quantity from a Nim proc → `ekRelative` (`number * measurement`) → Nim predicate (`require pred(a=..., b=...) do (a, b: float) -> bool`). The planner decomposes both into hidden measurement requests.

## `roles/`

`roles/core.nim` is the machinery (types, registry, helpers); built-ins are split into `power.nim`, `analog.nim`, `digital.nim`, `interconnect.nim`; `roles/built_in.nim` registers them (import it to get the built-ins). Run `verax roles` / `verax role <name>` for the live list and parameters.

- **`RoleDef` has two separate halves**: `apply` writes annotations (e.g. `Net.attrs["voltage"]`, which `isolate` needs regardless of checking); `expand` is **pure** and returns assertions. Both are proc values so runtime roles behave identically.
- **Optional parameters add a claim only when stated** (`power_rail.targetZ`). Never invent a default limit — it manufactures a claim the designer didn't make.
- **Role param defaults live in the expander**, not the registry.
- **Conditions (setup like `tSettle`, step size, swept range, `atF`) go in `Assertion.condition`** and join the evaluator setup key — two claims over two setups are two runs.
- **`Evaluator.conditions` lists every bare condition the run reads.** `plan` refuses a claim carrying a bare key its evaluator doesn't list (naming the ones it does) — a registered but unread key would otherwise be silently ignored. Empty = reads none. For relative/predicate claims the DSL stamps trailing conditions on every dependency, so a key read by *some* dependency is dropped from the others (`routePlain`'s `shared`); one read by none is refused. `registerEvaluator` raises on an unregistered key. `spi` stamps `spi.frequency` (dotted) because no evaluator reads it.
- **`Evaluator.units` (quantity → unit, `""` for counts/ratios)**: `plan` refuses a claim stated in another unit before running; `verdict` returns not-evaluated (`internal: ...`) if a measurement's unit disagrees with the declaration; `verify.claimLint` uses it for unitless claims even when unrun. A quantity left out is undeclared (checked only post-run). `tests/test_contract_eval_keys.nim` requires every built-in to declare every quantity.
- **Setup keys come from the run's own spec: `specKey(spec)`** (every field, recursively; tables by content). Each adapter has one `*SpecOf(a)` used by both its key and its run, so a field the run reads is a field the key sees. Nothing solved at run time (an `.op` bias) goes in the keyed spec. `tests/test_contract_eval_keys.nim` checks that every declared condition changes the key. `explainPlan` abbreviates long keys.
- **Condition keys are a registry** (`types.nim`: `ConditionDef`, `registerCondition`, `conditionProblem`), like annotations: a **bare key must be registered**, a dotted key is the author's own. `plan` refuses (`esNotEvaluable`, with a did-you-mean) an unknown bare key, a `cdFloat` value that isn't a plain SI number, or a `cdText` value outside `allowed` — otherwise a typo'd `f_form` would be ignored and the evaluator's default used. An evaluator reading a new bare key registers it. `conditionFloat` defaults only an **absent** key; a malformed one raises (plan already refused it).
- **`without` is reserved on every role**: names claim suffixes the instance declines. `explain` prints `declines ...`; a suffix matching nothing **raises** (`addRole` expands once to check). Prefer it over forking a role.
- **Everything that reads claims goes through `expandInstance`**, so `explain` and `evaluate` can't drift.
- **Never use a string-valued "mode" parameter to choose a branch**: `verify.claimingRoles` expands with the placeholder `"1"`, which selects no string branch and hides claims from `verax quantities`. Select by which limit is stated (e.g. `minPsrrDb` → `.tran` tone, `minPsrrBandDb` → `.ac`) or use a field (`RoleInstance.member`).
- A parameter can *redirect* a claim rather than add one (`gain_stage.atF`: `gain_max_db` → `gain_at_f`; `psrrAtF` likewise).
- **`regulator` / `linear_regulator` / `switching_regulator` are one role specialised twice**: specialisations call `regulatorExpand(inst)` whole then add topology-specific claims. Shared parts/params are module-level `let`s (forgetting to redeclare a param makes `Design.validate` reject it). Each claim is `hasParam`-gated on its own **limit**, never on the step/frequency (that's setup — the evaluator refuses a missing one). Output-current claims are about the bound `sense` part (a code model has no terminal current). **Conditions are stamped inside the template at every exit**, not in a trailing loop.
- `gain_stage` (AC-coupled, band-referenced, **no stability claim**) is separate from `opamp_stage` (DC-referenced, claims peaking/phase margin). Use both on one stage for margin *and* band.
- `oscillator` is separate from the stage roles because an `.ac` drive on the input node shorts a Wien bridge's feedback. Every claim is opt-in; `kick` is optional.
- **`channel_match` binds two other role instances** (`roleRef("<instance>")`, `skClass` subjects). The evaluator dereferences them (`subjectRoleBinding`). **Declare the referenced roles first** — `resolve` raises otherwise.
- `current_path` is the one built-in whose subject is a *component*. `si_net` (in `interconnect.nim`) is the one whose claims are about *pins*: parts `net`, `driver`, `rx`..`rx4`; threshold and ringback margins are always claimed (the receiver's own IBIS thresholds are the limit), flight time/overshoot/undershoot/settle and the eye (`min_eye_height`/`min_eye_width`, needing `ui`) only when stated. An optional victim (`victim`/`victim_driver`/`victim_rx`, all or none) adds its noise-margin claim (and `max_crosstalk`); `coupled_length` (plain metres) is what `verax constraints` derives a spacing for. `diff_pair` optionally names `driver`/`rx` (the P leg; validated together) so `verax constraints` can derive the pair's rules. Its claims are also `verax constraints`' pass criteria (`verify.siCriteria`). Derating claims read the part's own `isat`/`current_rating`.
- **`spi` fan-out**: a wide `cs` can't bind a scalar role part, so `design.addImpliedRoles` (not `addRoleFromInterface`, which is untouched) creates one instance per member via `interfaces.narrow`, named `<iface>_<signal><k>`; mismatched widths across wide signals raise. `RoleInstance.member` is a **field, not a param** (see the mode-param rule); `spiExpand` gates `controller_count` to `member == 0`. `cs.pullup` only when `csPullup` is stated. `spi` and `diff_pair` declare no `expects` so differently-named defs can imply them.
- `RoleClaim.binds` on `InterfaceDef.implies` maps differently-named signals to role parts (e.g. `dp`/`dn` → `p`/`n`).

## `design.nim`

- `Design` **owns** a `Netlist`; nothing is added to `netlist/types.nim`.
- **Role membership lives on the entity** (`net.attrs["role.i2c0"] = "sda"`) so it survives clone/extract/isolate (including the rename of ground to `"0"`).
- Subjects may address entities **inside an instance** by `hierSep` path; `Component.innerComponent`/`innerNet`/`innerPin` walk immediately and raise on typos.
- `roleRef(name)` returns an `skClass` subject; `subjectOf(Subject)` is an identity overload so the DSL binds it without macro changes.
- `explain` prints every role's expansion — generated assertions must be inspectable.

## `dsl.nim`

`design(...)` = everything `netlist(...)` accepts (via `buildNetlistBody`) plus `role` and `require`. **Bindings vs parameters are told apart by type** (`when compiles(subjectOf(value))`), not position — the macro can't see the runtime role registry. `require` uses ordinary comparisons over `quantity(subjects)`; the unit comes from the literal.

## `evaluate.nim`

- `AssertionResult` status: pass / fail / **notEvaluated** (an evaluator exists but didn't run or returned no number) / **notEvaluable** (nothing can produce it here). Deliberately not an `Issue`.
- **`EvalContext` is the plugin ABI** — an evaluator's only argument. It carries `design`, `allowed`, and a type-erased `scratch: Table[string, RootRef]` (a module owning a type like `OperatingPoint` or `Pcb` stores a `ref object of RootObj` under its own dotted key and downcasts). A context lives one run — that's what makes caches like the shared `.op` safe. An optional `onStep(index, starting)` closure is called around each step by `runPlan`, so a caller (the HTML report) can attribute side effects like simulator runs to the step that caused them; evaluators never touch it. `plan(d, allowed)`/`evaluate(d, allowed)` overloads build a fresh context per call.
- **`capSiTran`** (label/`--caps` spelling `si`) is the native SI engine: in `allCapabilities` **and `offlineCapabilities`** (no external tool; plan open decision 4), not in `simCapabilities` (that set means "needs ngspice"). Don't gate SI on `capSpiceTran`.
- **`Evaluator.needs` is a `set[Capability]`** — declare *every* capability used (an `.ac` evaluator that solves an `.op` for derating needs both). Empty normalises to `{capStatic}`. Gate is `ev.needs <= allowed`; `capLabel` renders `needs the .op + .ac capabilities`.
- `Evaluator.binds` names role parts read off `Assertion.origin`; non-empty means reachable only via a role. Declared, not inferred (`verax quantities` reports it).
- **Planned before run**: `plan` groups by `(evaluator, setupKey)` — one analysis per distinct setup is a planner property. `plan` is pure; `explainPlan` prints it.
- `ekRelative`/`ekPredicate` never reach an evaluator: `plan` emits hidden requests (ids prefixed `\x1f`, in `Plan.hidden`) plus a `ResolveStep`; `resolveHidden` folds back to one result per authored claim, propagating statuses, assumptions, issues and checking units.
- **Setup topology via `Assertion.origin`**: an evaluator reads bindings from `Design.roles[origin]`. Resolution order: subjects → origin-role bindings → `condition` → `notEvaluable` **naming what was missing**. `originRole` = the role that expanded this; `subjectRole`/`subjectRoleBinding` = the role a subject points at. Both return `none`.
- **`registerEvaluator` raises if a *different* evaluator already produces a quantity**; re-registering under the *same* name replaces (the override path).
- **`AssertionResult.scope`** — the nets and parts (flattened names, `netlist/region.flatName`) an answer was read from, set with `withScope`; empty means "the subjects". Static evaluators fill it (`dc_path_exists`: the path it found; bus checks: the net and every part on it; `controller_count`/`miso_driver_count`: the controllers/drivers). Relative and predicate claims take the union of their dependencies'. Plain names, so `Readiness` stays small. The report's picture grows from it.
- `verdict()` is the single pass/fail place. **`NaN` → notEvaluated, not fail**; unit mismatch → notEvaluable. Declining paths carry the analysis's assumptions **and issues** (the issue usually explains the `NaN`).
- `Margin`/`marginOf` live here; wording is `verify`'s.

## `evaluators/`

- **`static.nim`** — toolchain-free producers. `controller_count` is `notEvaluable` without a role binding (nothing in a netlist distinguishes I2C controller from target). `rc_corner` reports its invented pin capacitance as an `Assumption`. `dc_path_exists(a, b)` (`static.dc_isolation`) walks `condConductive` parts via `conductiveExits` on the design netlist (before `simReplace`). `miso_driver_count`: count only **leaf components** (`subNetlist == nil`, or each instance counts twice) and only pins that **drive** (`ptOutput`/`ptInOut`, or the controller counts); no stated direction on MISO → decline, not a vacuous pass.
- **`diff.nim`** — `diff_pair_symmetry` walks both legs in lock-step through two-terminal series parts (kind + value within 1%, 12-hop bound), emitting `diff_pair_leg_mismatch`. `intra_pair_skew`/`z_diff`/`inter_pair_skew` are **registered but always notEvaluable** (no routing data yet) so claims get a true reason instead of "no evaluator produces X".

## Deferred

`normalizeAnnotations` (alias pass via `AnnDef.aliases`) — the real collision now exists in `Placement.attrs["kicad.Value"]` but the pass isn't written. Runtime-loadable evaluators — keep open `quantity` strings, proc-valued `expand`, plain-data assertions and runtime registries to preserve the option.
