# Recommendations for the structural strain points

The strain points from the [README](README.md#overall-assessment) that are
still open, each with a recommendation, how to get there in steps, what it
costs, and a suggested priority. **Nothing here is implemented.** (Strain 1,
the stringly-typed core, and strain 5, absence spelled six ways, were
implemented on 2026-10-10 and removed from this list.) Every recommendation is
written to keep the project's fixed constraints: stdlib only, runtime
extensibility (roles/evaluators added without recompiling), designs as
ordinary Nim programs, and "silence must never read as approval".

Priority is by how likely the current shape is to produce the next
*silent* wrong answer, weighed against cost.

| # | strain | recommendation | priority |
|---|---|---|---|
| 2 | invariants held by convention | phase-typed transform chain; hide `ckZone`; private-by-default fields | medium |
| 3 | global registries, mixed semantics | one registry contract; a `Session` object owning them | medium (contract), low (session) |
| 4 | large integrating modules | split `verify.nim` by concern; modularise the schematic engine | medium / low |

---

## 2. Invariants held by convention

**What's wrong.** "Only `graph.nim` mutates back-references", "flatten before
model passes", "skip `ckZone` in copper walks", "snapshot net names before
`removeComponent`" are enforced by docs and tests, not by construction.

### R2.1 — A phase-typed simulation-prep chain *(medium)*

Future proposal only (no new prep API or transform refactor implemented): wrap
intermediates in distinct types. The actual order to preserve is **clone →
flatten → applySimReplacements → behavioural/pin-model passes → optional
isolation**, with some capacitor/source impedance passes after isolation:

```nim
type
  SimClone*    = distinct Netlist   ## cloned, replacements still inert
  FlatNet*     = distinct Netlist   ## flattened
  ReplacedNet* = distinct Netlist   ## purpose-selected simReplace applied
  ModelledNet* = distinct Netlist   ## pin models / behavioural stand-ins applied
  Fragment*    = object             ## isolated + terminated
    nl*: Netlist
    iso*: Isolated

proc copyForSim*(nl: Netlist): SimClone
proc flatten*(x: SimClone, keep: openArray[string]): FlatNet
proc replace*(x: FlatNet, purpose: string): ReplacedNet
proc standIn*(x: ReplacedNet, exclude: openArray[string]): (ModelledNet, seq[Assumption])
proc isolate*(x: ModelledNet, ...): Fragment
proc withParasitics*(f: var Fragment, bias: ...): seq[Assumption]
```

Replacement-built `xspice.ports` is frozen text: later flattening changes the
graph but not those node names. `materializeSimNetlist` is still useful for
already-flat netlists or hierarchical uses with **no subsequent flattening**;
it cannot serve as `SimClone` above.

A future shared builder (also proposed in [analysis.md](analysis.md) critique 4)
would need to preserve exceptions, not force all analyses into one chain:
startup excludes the selected regulator from initial replacements and pin-model
passes, then builds its own replacement/ramp on the isolated fragment;
non-isolating analyses omit isolation. Existing `tests/test_spice_transform.nim`
and `tests/test_analysis_startup.nim` pin these ordering constraints.

*Cost:* requires modelling those exceptions, not just changing signatures.
*Benefit:* types could enforce transform ordering, but would not by themselves
prove model suitability or prevent every ideal-source error.

### R2.2 — Make `ckZone` unreachable from ordinary copper walks *(medium, small)*

Either store authored zone areas outside `PcbLayer.copper` (index them
separately), or provide `iterator conductors(layer)` that skips `ckZone` and
make it the documented way to walk copper, with a test that greps `pcb/`,
`si/`, `fem/` for raw `layer.copper` loops. The first is cleaner; the second
is a one-file change.

### R2.3 — A replace primitive that can't lose net names *(low, small)*

`graph.replaceComponent(nl, old, new, pinMap)` that captures `pin → net`
before disconnecting, so model passes stop needing "snapshot names first".
`spice/transform.replaceComponent` would call it, and could at the same time
pick a free designator (fixes the `U1 → V1` collision noted in
[spice.md](spice.md)).

### R2.4 — Private-by-default fields for the graph types *(low; high churn)*

The textbook fix for "only `graph.nim` writes back-references" is
unexported fields with exported getters. In Nim that means moving the
mutators into `types.nim` (or `include`-ing `graph.nim` there). This touches
every module and the DSL, so it is only worth doing if a back-reference bug
actually appears. A cheaper guard with most of the value: a test that walks a
design after every public transform and checks bidirectional consistency
(`p.net.pins` contains `p`, `c.pins[n].component == c`, …) — an
`assertConsistent(nl)` helper usable in any test.

---

## 3. Global registries with mixed semantics

**What's wrong.** Twelve-plus process-global tables; some raise on collision,
some replace, some append; some take `{.nimcall.}`, one takes closures;
registration often happens as an import side effect.

### R3.1 — One registry contract *(medium)*

Write down, and make every registry follow, one rule set:

| operation | behaviour |
|---|---|
| `register(def)` with a new name | adds |
| `register(def)` with an existing name | **replaces** — the documented override path |
| a *different* name claiming something already owned (quantity, kind) | **raises**, naming both owners |
| `unregister(name)` / `clear*()` | exist on every registry, for tests and hosts |
| `registered*()` | lists names in registration order |

`registerEvaluator` already follows this. `registerBehavioralModel` (kind
already owned by another model), `registerPartFamily`, `registerAnnotation`
(same key, different unit) would gain the collision check. A small generic
`Registry[T]` in a root module would implement it once.

### R3.2 — A `Session` that owns registries *(low; do when the MCP server needs it)*

For one-design-per-process CLI use, globals are fine. The MCP server and any
parallel checker want two designs with different catalogues, roles or
policies in one process. Move registries into a `Session` object with a
process-default instance, keeping today's free procs as wrappers over the
default. `EvalContext` would carry the session. This is the change that makes
"runtime-loadable plugins" coherent too: a plugin registers into a session,
not into the process.

*Cost:* large and cross-cutting. Defer until a concrete second-session need
exists; R3.1 first.

### R3.3 — Make registration explicit where it decides answers *(low)*

Import-time registration of evaluators is what makes "no evaluator produces
X" possible for a valid claim. Keep auto-registration for convenience, but
have `verify.readiness` record which registration modules were loaded and
print them in `--verbose`, and have the "no evaluator produces X" message
say "is `analysis/evaluators/contract_eval` imported?" when the quantity is a
known built-in name. Cheap, and turns the failure mode into an actionable
message.

---

## 4. Large integrating modules

### R4.1 — Split `verify.nim` by concern *(medium)*

Keep a `verify.nim` facade (re-exports, `verifyMain`) and move the bodies:

```
verify/run.nim        readiness, Check, Readiness, exit codes
verify/catalog.nim    describeRoles/Quantities/Annotations, claimingRoles, didYouMean
verify/render.nim     text / JSON / JUnit, renderClaim, marginText
verify/baseline.nim   --baseline diffing
verify/options.nim    VerifyOptions, argument parsing
verify/commands/      bom.nim, layout.nim, constraints.nim (each a subcommand)
```

Each file may still import anything (that is `verify`'s privilege); the split
is about where a new feature lands. The catalog is already consumed by both
CLI and MCP, so it benefits most from being separable.

### R4.2 — Modularise the schematic engine gradually *(low)*

Convert `include` units to real modules from the bottom of the include order
up: `geometry`, `symbols` and `router` take plain data already, so they can
become modules with exported interfaces first. Each conversion makes that
unit independently testable. Stop when the remaining units genuinely share
`LayoutState`; the goal is boundaries where they exist, not zero includes.

### R4.3 — Split `ibis/behave.nim` and `si/constrain.nim` along their seams *(low)*

`behave`: curve conversion / fixture back-solve / coefficient solve /
reconstruction. `constrain`: search algorithm / criteria / report rendering.
Pure moves; do them when next editing those files.

---

## Suggested order

1. **R2.2** — small, closes a documented trap.
2. **R2.1** (phase-typed prep chain) with the shared `prepareFragment`.
3. **R3.1** (one registry contract) and **R4.1** (split `verify`).
4. The rest opportunistically, when the code is next touched or a concrete
   need (second session, ODB++ reader, FEM backend) arrives.
