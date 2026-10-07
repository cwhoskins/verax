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
- **`without` is reserved on every role**: names claim suffixes the instance declines. `explain` prints `declines ...`; a suffix matching nothing **raises** (`addRole` expands once to check). Prefer it over forking a role.
- **Everything that reads claims goes through `expandInstance`**, so `explain` and `evaluate` can't drift.
- **Never use a string-valued "mode" parameter to choose a branch**: `verify.claimingRoles` expands with the placeholder `"1"`, which selects no string branch and hides claims from `verax quantities`. Select by which limit is stated (e.g. `minPsrrDb` → `.tran` tone, `minPsrrBandDb` → `.ac`) or use a field (`RoleInstance.member`).
- A parameter can *redirect* a claim rather than add one (`gain_stage.atF`: `gain_max_db` → `gain_at_f`; `psrrAtF` likewise).
- **`regulator` / `linear_regulator` / `switching_regulator` are one role specialised twice**: specialisations call `regulatorExpand(inst)` whole then add topology-specific claims. Shared parts/params are module-level `let`s (forgetting to redeclare a param makes `Design.validate` reject it). Each claim is `hasParam`-gated on its own **limit**, never on the step/frequency (that's setup — the evaluator refuses a missing one). Output-current claims are about the bound `sense` part (a code model has no terminal current). **Conditions are stamped inside the template at every exit**, not in a trailing loop.
- `gain_stage` (AC-coupled, band-referenced, **no stability claim**) is separate from `opamp_stage` (DC-referenced, claims peaking/phase margin). Use both on one stage for margin *and* band.
- `oscillator` is separate from the stage roles because an `.ac` drive on the input node shorts a Wien bridge's feedback. Every claim is opt-in; `kick` is optional.
- **`channel_match` binds two other role instances** (`roleRef("<instance>")`, `skClass` subjects). The evaluator dereferences them (`subjectRoleBinding`). **Declare the referenced roles first** — `resolve` raises otherwise.
- `current_path` is the one built-in whose subject is a *component*. Derating claims read the part's own `isat`/`current_rating`.
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
- **`EvalContext` is the plugin ABI** — an evaluator's only argument. It carries `design`, `allowed`, and a type-erased `scratch: Table[string, RootRef]` (a module owning a type like `OperatingPoint` or `Pcb` stores a `ref object of RootObj` under its own dotted key and downcasts). A context lives one run — that's what makes caches like the shared `.op` safe. `plan(d, allowed)`/`evaluate(d, allowed)` overloads build a fresh context per call.
- **`Evaluator.needs` is a `set[Capability]`** — declare *every* capability used (an `.ac` evaluator that solves an `.op` for derating needs both). Empty normalises to `{capStatic}`. Gate is `ev.needs <= allowed`; `capLabel` renders `needs the .op + .ac capabilities`.
- `Evaluator.binds` names role parts read off `Assertion.origin`; non-empty means reachable only via a role. Declared, not inferred (`verax quantities` reports it).
- **Planned before run**: `plan` groups by `(evaluator, setupKey)` — one analysis per distinct setup is a planner property. `plan` is pure; `explainPlan` prints it.
- `ekRelative`/`ekPredicate` never reach an evaluator: `plan` emits hidden requests (ids prefixed `\x1f`, in `Plan.hidden`) plus a `ResolveStep`; `resolveHidden` folds back to one result per authored claim, propagating statuses, assumptions, issues and checking units.
- **Setup topology via `Assertion.origin`**: an evaluator reads bindings from `Design.roles[origin]`. Resolution order: subjects → origin-role bindings → `condition` → `notEvaluable` **naming what was missing**. `originRole` = the role that expanded this; `subjectRole`/`subjectRoleBinding` = the role a subject points at. Both return `none`.
- **`registerEvaluator` raises if a *different* evaluator already produces a quantity**; re-registering under the *same* name replaces (the override path).
- `verdict()` is the single pass/fail place. **`NaN` → notEvaluated, not fail**; unit mismatch → notEvaluable. Declining paths carry the analysis's assumptions **and issues** (the issue usually explains the `NaN`).
- `Margin`/`marginOf` live here; wording is `verify`'s.

## `evaluators/`

- **`static.nim`** — toolchain-free producers. `controller_count` is `notEvaluable` without a role binding (nothing in a netlist distinguishes I2C controller from target). `rc_corner` reports its invented pin capacitance as an `Assumption`. `dc_path_exists(a, b)` (`static.dc_isolation`) walks `condConductive` parts via `conductiveExits` on the design netlist (before `simReplace`). `miso_driver_count`: count only **leaf components** (`subNetlist == nil`, or each instance counts twice) and only pins that **drive** (`ptOutput`/`ptInOut`, or the controller counts); no stated direction on MISO → decline, not a vacuous pass.
- **`diff.nim`** — `diff_pair_symmetry` walks both legs in lock-step through two-terminal series parts (kind + value within 1%, 12-hop bound), emitting `diff_pair_leg_mismatch`. `intra_pair_skew`/`z_diff`/`inter_pair_skew` are **registered but always notEvaluable** (no routing data yet) so claims get a true reason instead of "no evaluator produces X".

## Deferred

`normalizeAnnotations` (alias pass via `AnnDef.aliases`) — the real collision now exists in `Placement.attrs["kicad.Value"]` but the pass isn't written. Runtime-loadable evaluators — keep open `quantity` strings, proc-valued `expand`, plain-data assertions and runtime registries to preserve the option.
