# Design review: data structures and architectural patterns

A descriptive review of how verax is built, one document per submodule, with
an assessment of what each choice buys and what it costs. Written 2026-10-10
against the working tree at `0627b90` (plus uncommitted edits). Nothing here
proposes a plan; where a critique names an alternative it is to make the
trade-off concrete, not to schedule it.

| document | covers |
|---|---|
| [root.md](root.md) | `units`, `eng`, `waveform`, `touchstone`, `verify`, `cli` |
| [netlist.md](netlist.md) | the graph, annotations, DSL, side modules, SPICE format |
| [contract.md](contract.md) | assertions, roles, the planner/evaluator ABI |
| [analysis.md](analysis.md) | analyses, evaluator adapters, reports |
| [spice.md](spice.md) | transforms, device models, ngspice backend, XSPICE |
| [schematic.md](schematic.md) | scene, layout pipeline, writers |
| [pcb.md](pcb.md) | board model, geometry, KiCad I/O, routing/tline |
| [parts.md](parts.md) | part requests and policies |
| [bom.md](bom.md) | BoM collection, catalogue sources, resolution |
| [ibis.md](ibis.md) | IBIS reader and behaviour interpretation |
| [si.md](si.md) | native SI engine, sweeps, constraint derivation |
| [fem.md](fem.md) | field-solver interface and MFEM stage 0 |
| [recommendations.md](recommendations.md) | what to do about the overall strain points (not implemented) |

---

## The patterns that recur everywhere

These show up in nearly every submodule. Each submodule document refers back
here instead of re-explaining them.

### P1. Reference graph with a single mutator module

`netlist/types` and `pcb/types` are both `ref object` graphs with
bidirectional references (`Pin.net` ↔ `Net.pins`, `Copper.layer` ↔
`PcbLayer.copper`), plus name-keyed `OrderedTable`s for lookup. Exactly one
module per graph (`netlist/graph.nim`, `pcb/graph.nim`) is allowed to write the
back-references.

*Buys:* walk from anywhere in one hop; analyses read like the circuit
("this pin's net's other pins"); `OrderedTable` gives deterministic iteration,
which the schematic and report renderers depend on.

*Costs:* the rule is convention, not enforcement — every field is exported
(`*`), so any module can hand-set `Pin.net` and compile. Nim has no `friend`
visibility, but the usual workaround (unexported fields in the type module,
exported getters, mutators in the same module or via `{.used.}` accessor
templates) was not taken. The rule is documented in four places and has
survived so far by discipline.

### P2. Open `attrs: OrderedTable[string, string]` bag, made safe by a registry

Every entity carries a string→string bag. Bare keys are registered
vocabulary (`netlist/annotations`), validated at DSL compile time and at
`readiness`; dotted keys (`role.*`, `kicad.*`, `xspice.*`, `layout.*`,
`bom.*`, `iface.*`, `package.*`…) are owned by a module and never validated.

*Buys:* formats and side modules (packages, pinmux, interfaces, traversal,
layout hints, BoM defaults, role membership) add state without touching the
core types, and that state survives `clone`/`instantiate`/`flatten`/`isolate`
for free. That survival is the real reason this pattern was chosen, and it
works — role membership surviving isolation's rename of ground to `"0"` is the
canonical example.

*Costs:*
- **Stringly-typed storage.** Numbers are serialized with `formatFloat` and
  re-parsed on every read (`annotationFloat` → `parseAnnFloat`). Typed units
  (`20.mohm`) protect the *write*; once stored, every consumer reads a bare
  `float` and the type is gone.
- **Provenance is a sibling key** (`ann.src.<key>`). `setRawAnnotation`
  writes the value without touching the marker, so a value can be replaced
  through the permissive path while a stale `defaulted`/`derived` marker
  stays behind. Only `putRaw` keeps the two in step.
- **Namespaced keys have no schema at all.** Each side module re-implements
  parse/validate for its own prefix (`layouthints`, `traversal`, `packages`,
  `pinmux`, `bomdefaults`, `interfaces`), each with its own small grammar.
  That is six mini-formats, each correct, none shared.

### P3. Runtime registries of data objects carrying proc values

Roles, evaluators, annotations, behavioural models, designator prefixes,
interface defs, package defs, pinmux tables, footprint sources, catalogue
sources, part families, schematic composite kinds. Most are a module-level
`var OrderedTable` populated at module init.

*Buys:* the stated product goal — ship compiled, let users add roles and
evaluators without recompiling — stays reachable. Built-ins use the same path
as user code (tests pin this for roles), so user extensions are first-class.

*Costs:*
- **Import has side effects.** Importing `contract_eval` or `spice/models`
  registers things; forgetting the import changes runtime answers ("no
  evaluator produces X") rather than failing to compile. `verify.nim`
  imports `contract_eval` unconditionally precisely because of this.
- **Process-global mutable state**, not thread-safe, shared by every design
  checked in one process and across tests (hence the various
  `clear*`/`register*Builtins` procs).
- **Inconsistent registry semantics.** Some raise on collision
  (`registerEvaluator` across names), some silently replace
  (`registerRole`, `registerAnnotation`, `registerBehavioralModel`), some
  append (`registerCatalogSource`). Some take `{.nimcall.}` procs (roles,
  evaluators, behavioural models, footprint sources), some closures
  (catalogue sources). Each choice is defensible locally; together they mean a
  plugin author learns a different contract per registry.

### P4. Type-erased scratch slot to avoid a dependency edge

`EvalContext.scratch: Table[string, RootRef]` and `Pcb.source: RootRef`.
An owner declares `ref object of RootObj`, stores under a dotted key it owns,
and downcasts on the way out.

*Buys:* `contract` never imports `analysis` or `pcb`; `pcb` never imports its
format modules. The per-run lifetime of `scratch` is what makes the shared
`.op` cache correct by construction (the old module-level cache was not).

*Costs:* the downcast is unchecked at compile time; a key collision or a wrong
type is a runtime `ObjectConversionDefect`. With two or three owners this is
fine; it does not scale to many.

### P5. Plain data at boundaries; names, not references, across clones

`Assertion.subjects` are names; `SimReplacement.pinNets` are net *names*;
`Pcb.netCopper` is keyed by net name; the schematic scene is entirely
string-keyed. Wherever a structure must outlive a `clone`, it holds names.

*Buys:* assertions and replacements are serializable, comparable and survive
cloning, flattening and isolation; a hierarchical path string (`XL.U1`) works
before and after `flatten` because `findNet`/`findComponent` try the flat
key first.

*Costs:* name-keyed side tables go stale on rename. `graph.renameNet` updates
the netlist but nothing re-keys `Pcb.netCopper`; `Design` subjects naming a
net are resolved again at every use. This is deliberate and mostly harmless
because the renaming passes run on clones, but it is an invariant held by
where renames happen, not by the types.

### P6. Clone, then a pipeline of in-place transforms whose order is load-bearing

`materializeSimNetlist → flattenForSim → expandPinModels → isolateNets →
expandCapacitorParasitics → expandSourceImpedance → probe → write`. The
schematic layout is the same shape (22 named stages, filter but never
reorder).

*Buys:* each pass is small and testable; the design netlist is never mutated
(invariant 2 in `architecture.md`); the order is documented with the reason
for each position.

*Costs:* every intermediate is the same type (`Netlist`), so nothing stops a
caller from running passes in the wrong order — the failures are physical
(an op-amp reaching the deck as `U1`, a rail reading 0 Ω) rather than type
errors. Each analysis re-assembles the chain by hand, which is why
`analysis/CLAUDE.md` carries "model-pass order around isolation" as a rule
for authors. A phase-typed wrapper (`FlatNetlist`, `IsolatedFragment`) is the
textbook alternative; it was not taken, and the cost of that is paid in
documentation and review attention.

### P7. Honest absence — but represented six different ways

The codebase is consistent in *refusing to invent* a value, and inconsistent
in how it spells "absent":

| idiom | where |
|---|---|
| `AnnValue[T]{source, value}` with `annAbsent` | `netlist/annotations` |
| `Option[T]` | `contract/evaluate` accessors |
| `NaN` for floats, `-1` for ints | `bom`, measurements, `waveform`, `si` figures |
| `present: bool` beside the value | `ibis` `ModelParam`, `ModelSpec`, `SiSupply`, `DiffReceiver.hasVdiff` |
| per-field presence arrays/sets | `ibis.Triplet.present`, `PinEntry.present: set[PinRlc]` |
| `0` / `""` meaning "unknown" | `pcb` (`finishedDia`, `height`, `copperWeight`), `fem.Material`, `parts.CapRequest.working`, `bomdefaults` |

`NaN` doubles as "measured and never happened" (a meaningful result:
`z_antiresonance` with no peak) and "not stated" — `verdict` treats both as
not-evaluated, which is right for claims but means the two cannot be told
apart downstream. The zero-means-unknown cases are the weakest: `0 Ω`,
`0 nm` and `0 W` are physically meaningful values in places.

**Addressed 2026-10-10 (R5):** root `stated.nim` defines `Stated[T]` (`AnnValue` is now an alias), NaN is reserved for "measured, not found", and the zero/NaN/`-1`-as-unknown boundaries in `fem`, `parts`, `pcb`, `bomdefaults`, `bom` and the `si` presence flags became `Stated`/`Option`. IBIS's `present` flags stay (format-faithful).

### P8. Strict layering, kept by moving things down or up

Dependency rules are stated and largely hold (checked by grepping imports):
`contract` imports only `netlist`; `si` has no `spice` edge; `bom` has no
`pcb` edge (it duplicates `collectLeaves` rather than take one). Shared
types move down (`Issue` into `netlist`, `waveform` below `analysis` and
`si`, `Assumption` into `netlist/annotations`).

Drift found (all four fixed 2026-10-10 — `spice` now reaches the schematic writer through a hook installed by `run_archive.nim`; `touchstone/` and `bom`'s real edges are in the docs; the template files are gone):
- **`spice/ngspice.nim` imports `../schematic`** (whole hub) to write
  per-run SVG/JSON into the run archive. `schematic/CLAUDE.md` acknowledges
  the consumer, but `CLAUDE.md`'s dependency order and `architecture.md`'s
  diagram describe `schematic` as a leaf. The practical effect is that every
  simulation-backed analysis links the 9k-line layout engine.
- **`touchstone/` is a root-level submodule** used by `pcb/tline` and `si`,
  absent from the dependency order in `CLAUDE.md` and the table in
  `architecture.md`.
- `CLAUDE.md` lists `netlist/parts <- bom`; `bom` does not import `parts`.
- `src/verax.nim` and `src/verax/submodule.nim` are the nimble project
  template (`proc add(x, y: int)`, `initSubmodule`). Harmless, but
  `import verax` currently yields an `add` proc.

---

## Overall assessment

**What is unusually good.** The architecture is organised around one
invariant — *silence must never read as approval* — and the data structures
genuinely serve it: `EvalStatus` has four states not two; `Assumption` is a
record, not prose, and travels with every result; planning is pure and
separate from running; evaluators are batch-shaped so "one simulation per
setup" is a planner property. The rationale for most decisions is written
next to the code, usually with the measured failure that motivated it. Few
codebases of this size can say why each field exists.

**Where the structure is under strain.**

1. **Stringly-typed core** (P2, P5). The flexibility is real, but numbers,
   units, conditions (`Assertion.condition: OrderedTable[string,string]`),
   role params, provenance and setup keys are all strings. Type safety exists
   at the authoring edge and largely stops there. *(Addressed 2026-10-10,
   R1: spec-derived setup keys, evaluator-declared conditions and units,
   typed annotation reads, provenance side door closed.)*
2. **Conventions carrying invariants the types could carry** (P1, P6).
   "Only graph.nim mutates", "flatten before model passes", "skip `ckZone` in
   copper walks", "setup key must include everything the run reads" — each is
   enforced by documentation and tests, not by construction.
3. **Global registries with mixed semantics** (P3). Fine for one process
   checking one design; awkward for a long-lived front end (e.g. the Python binding), parallel checking, or a
   test suite that mutates registries.
4. **Large integrating modules.** `verify.nim` (1.5k lines: runner, catalog,
   BoM, layout, SI constraints, baseline, three renderers) and
   `schematic/layout.nim` (17 `include`d files forming one ~9k-line
   compilation unit) are where new features land by default.
5. **Absence spelled six ways** (P7). *(Addressed 2026-10-10, R5: `Stated[T]`.)*

None of these is a defect today; several are the price of deliberate choices
(runtime extensibility, stdlib-only, survivable attrs). They are where the
next class of silent wrong answer is most likely to come from.
