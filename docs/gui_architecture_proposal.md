# GUI architecture — proposal

**Status: proposal. Nothing here is accepted.** This is a survey of one way to
put a graphical front end on verax, written so the trade-offs are visible
before any of it is committed to. It records a direction, not a decision.

`architecture.md` describes the library as it is. This describes a surface that
does not exist yet and names the pieces verax would have to grow to support it.

---

## 1. What this is trying to cover

One front end, chosen once, expected to last. The use cases it should still fit
a decade from now:

- graphically compose a schematic — place parts, draw nets;
- edit schematic layout (placement, rotation, sheet organisation) and re-save it;
- run simulations and view results;
- view DRC / readiness reports, cross-linked to the schematic;
- eventually: drive bench hardware and view captured results;
- eventually: view PCB layout (copper, holes, outline).

No single **GUI toolkit** is optimal across a report viewer, a node editor, a
PCB canvas and an instrument dashboard. What gets standardised is the **shell,
the transport, and the language split** — the canvas-heavy surfaces will always
carry their own rendering layer inside that shell.

---

## 2. The constraint that drives the shape

A browser-only WebAssembly app cannot do three things this list requires:

- talk to bench instruments in any general way (WebSerial / WebUSB are
  Chrome-only, permission-gated, and reach neither GPIB/VISA/PXI nor vendor
  driver DLLs);
- spawn `ngspice`;
- read and write the user's design files without a save-picker dance.

Simulation, file I/O and hardware all live **engine-side**. So the architecture
is forced into two pieces:

> **verax stays the engine, running as a local process. The GUI is a front end
> that talks to it over a local transport.**

This is the load-bearing decision. It is the one part of the proposal that
every use case on the list depends on, because SPICE, files and instruments all
sit behind it.

---

## 3. Proposed stack

| Layer | Proposed | Rationale | Alternative considered |
|---|---|---|---|
| **Engine** | verax, unchanged in spirit, plus a `verax serve` mode | Already the thing that owns the netlist, the registries, ngspice and (later) instrument drivers. | — |
| **Transport** | JSON-RPC over stdio first; WebSocket when streaming is needed | stdio is trivial to host from a desktop shell; WebSocket buys live sim progress and live instrument data, and lets the same front end later reach a *remote* engine. | Raw HTTP (no server-push); gRPC (heavier, codegen). |
| **App shell** | Tauri (Rust + system webview) | Native file r/w, spawns/embeds the engine, hosts native instrument drivers as Rust sidecars later. ~3–10 MB. | Electron — more mature, Node's `serialport` ecosystem, but ~100 MB and a second JS runtime. |
| **Front-end framework** | One reactive framework — Svelte or Solid | The "single framework". Covers every non-canvas surface uniformly: reports, DRC lists, forms, dashboards. Leaner than React. | React (largest ecosystem); egui/wgpu (native+wasm from one Rust codebase, strong for tool UIs and dashboards, weak for report-style layout, second large language). |
| **Canvas surfaces** | A dedicated 2D/WebGL layer (PixiJS or hand-rolled Canvas2D) for the schematic editor and PCB view | The PCB view is the long-term performance risk — thousands of primitives — so plan for GPU rendering there from the start. | SVG (fine for the current static schematic, does not scale to a PCB). |
| **Algorithm reuse in the front end** | verax's pure layers compiled to WebAssembly, loaded *inside* the shell | See §4. | Reimplement layout / DRC / evaluation in TypeScript — guarantees drift. |

None of this adds a runtime dependency to the verax library itself. A
`verax serve` entry point and a WASM build target are new *packages / build
outputs*, the way the `python/` front end is kept a separate package.

---

## 4. What WebAssembly is for here

Not the whole app — a **library inside the front end**.

The editing loop — drag a part, re-run `layout()`, re-run DRC, redraw — must run
at 60 fps with no round-trip to the engine process. Compiling verax's pure
layers to WASM makes that possible without reimplementing them in TypeScript.
The engine process still owns simulation, files and hardware.

**What compiles to WASM cleanly:** `netlist`, `schematic` (layout + scene +
JSON), `contract`, and the pure-graph parts of `analysis` (DRC/DFM, topology,
io checks). These are Nim standard library only.

**What does not:** anything reaching `osproc` — today exactly four files
(`cli.nim`, `verify.nim`, `spice/ngspice.nim`, `spice/xspice/build.nim`). The
WASM build is a new entry module importing the pure submodules by path, never
the `analysis` umbrella (which transitively pulls in `spice/ngspice` and thus
`osproc`).

**Nim-on-WASM notes:** `--mm:orc`, no threads unless pthreads is opted into,
file I/O goes through an in-memory FS that must be bridged explicitly to the
host. Release size for the pure surface is plausibly ~150–400 KB gzipped.

**In-browser simulation** (linking `libngspice` compiled to WASM, called over
Nim FFI instead of spawned as a process) is possible and has precedent
(eecircuit, ngspice.wasm) but is a separate, larger commitment. It is not on
the critical path: *viewing* simulation results is just charting a data array
and needs no WASM at all.

---

## 5. The `.nim` / `.json` split

### 5.1 What is authoritative

| File | Source of truth for | Who writes it |
|---|---|---|
| `design.nim` | the **design** — topology, part values, typed annotations, roles, assertions, environment | the author (text), or structured edits (see §6) |
| `design.layout.json` | the **graphical layout** — positions, rotations, manual pin routing, sheet assignment | the GUI, freely |

This matches verax's existing grain: the schematic scene is already a derived
visual artifact, and `designator` is already a stable join key that is never
rewritten in place.

### 5.2 Data flow

```
design.nim ──compile + run──▶ design model  (topology + values + annotations
                                              + roles + assertions + environment)
                                    │
                                    │  held in memory by `verax serve`,
                                    │  recompiled on file change,
                                    │  READ-ONLY to the GUI
                                    ▼
                              GUI renders  model ⊕ layout.json
                                    ▲
                                    │  positions / rotations / manual routing
                                    │  keyed to design entities by stable id
                              design.layout.json   (GUI writes this freely)
```

Simulation, DRC and readiness all run against the in-memory model. No
per-interaction compilation; the design is recompiled only when `design.nim`
changes on disk (~1–3 s with verax pre-installed as a library — a save-reload
cost, not a keystroke cost).

### 5.3 Keying the layout file

The layout file must reference design entities by a **stable opaque id**, not by
designator or net name — otherwise a rename in `design.nim` orphans every
placement. verax keys the scene on `designator` today, which is fine for a
scene that is regenerated and discarded but not for a layout file meant to
outlive many edits. Proposed addition: an optional stable `id` per component
and net, assignable from the DSL or auto-assigned and round-tripped.

### 5.4 What the model needs that verax cannot yet serialise

Nothing serialises the contract layer today:

| Data | Serialisation today |
|---|---|
| netlist topology + values | `netlist/formats/spice.nim`, `formats/common.nim` |
| schematic *scene* (visual) | `schematic/json.nim` — full round-trip |
| typed annotations (`esr = 100.mohm`), roles, assertions, environment | **none — Nim DSL only** |

SPICE round-trips topology but drops every typed annotation and the whole
contract layer. The proposal needs a canonical design-model format (JSON)
covering all of it, plus a runtime loader that reproduces the compile-time
`spec:` validation as load-time validation (the annotation vocabulary is
already a registry, so this is mechanical).

`Design` itself is already plain data (`contract/design.nim`): a `Netlist`, an
`OrderedTable` of role instances, a `seq[Assertion]`. `Assertion` /
`Expectation` are clean variant objects. The two things that do not serialise:

- `ExpectKind.ekPredicate` — carries a compiled Nim proc. A GUI-authored design
  omits these or references a named built-in predicate.
- custom user evaluators / roles — stay compiled in. Serving designs as data is
  a prerequisite step toward the deferred runtime-extensibility goal, not a
  conflict with it.

---

## 6. Simulation results: how they reach the frontend

Two different things travel under "simulation results," and verax already
keeps them apart on purpose.

- **Checked claims** — pass/fail/not-checked, one line per assertion. This is
  the `Readiness` report the design-model flow (§5) already covers: it is
  built from `AssertionResult`s and **deliberately never carries an
  `AnalysisReport`** — a test pins the report's rendered size so the
  underlying curve cannot leak in.
- **The curve itself** — the Bode plot, the transient trace, the PDN impedance
  sweep behind a claim. That is `AnalysisReport.raw`, a `SimResult`: the full
  simulated data an evaluator measured *from* before collapsing it to a
  `Measurement`. It does not exist in the readiness report at all today, by
  design.

So "view results" is a **second channel**, fetched on demand, not part of the
readiness payload.

### 6.1 What already exists to build this on

`$VERAX_KEEP_RUNS` already archives exactly this data on disk, one directory
per check run: `runNNN.cir` (the deck), `runNNN.raw` (ngspice's rawfile),
`runNNN.log`, `runNNN.svg`/`runNNN.json` (the schematic scene for that
fragment), and one `index.txt` row per run (slot, status, label, analysis,
setup, netlist, plot, real/complex, vector count, point count, bytes, ms).
`ngspice.nim` already parses that rawfile back into a `SimResult` — `.ac`'s
complex-plot layout included.

Two pieces are missing, both additive:

1. **A `SimResult` → JSON encoder.** Nothing writes `SimResult` as JSON today;
   a browser has no business parsing ngspice's ASCII rawfile format directly.
   This mirrors `schematic/json.nim`'s existing precedent for the scene.
2. **A run-id on every check.** `Readiness.checks` groups results by
   `setupKey`, and one `Check`'s constituent claims can come from more than one
   ngspice `run()` call (the loop-gain batching case `verify.nim` already
   describes) — so there is no guaranteed one-to-one mapping today from "the
   check the GUI is showing" to "the `runNNN` slot(s) that produced it." That
   linkage needs threading through before "show curve" can look one up.

### 6.2 The fetch, concretely

`verax serve` runs with `$VERAX_KEEP_RUNS` pointed at a per-session directory
for the life of the connection. The readiness payload (§5) carries run ids
alongside each check; clicking a check sends `{"getCurve": "run014"}` over the
same socket, `serve` parses that run's rawfile (cached in memory by run id,
simple LRU eviction — rawfiles are not small, §6.4), encodes it, and returns
it. Nothing is sent that was not asked for.

### 6.3 Streaming — what's real now and what needs new work

Two different things get called "streaming" here, and only one is available
without touching `spice/ngspice.nim`:

- **Across runs** (a sweep is many complete ngspice invocations): each `run()`
  call already finishes with a full result before the next begins, so pushing
  each point over the socket as it lands — rather than batching all N and
  replying once — is free today. This covers sweep progress.
- **Within one run** (watching a transient develop while ngspice is still
  running it): `ngspice.run` currently treats "a parseable rawfile exists
  after the process exits" as the success signal — it is a batch call, not a
  live tap. True mid-run streaming needs `spice/ngspice.nim` to either tail
  the rawfile as ngspice writes it or drive ngspice's control-mode
  interactively with a callback. Real work, not assumed by this proposal;
  phase 4 (§10) can ship with across-run streaming only and add this later.

### 6.4 Size

A rawfile with `$VERAX_SAVE_CURRENTS` on has been measured at 700 KB–1.9 MB for
one transient run. Sending full-resolution curves unprompted, for every check,
does not scale. Fetch-on-demand (§6.2) answers "don't send what nobody asked to
see"; for very large sweeps, decimating for the initial plot and offering
"full resolution" as an explicit follow-up request answers "don't stall the
socket on one huge payload."

### 6.5 The same shape carries bench data later

Phase 6's hardware testing (§10) wants exactly this pattern: a captured
instrument trace is not a `Measurement`, it is a curve, and correlating
measured against simulated is comparing two of these side by side on one axis.
If captured data is shaped compatibly with `SimResult`'s JSON encoding from the
start, the viewer built for §6.2 does not need a second code path when bench
data arrives.

---

## 7. Open decision: how graphical topology edits reach the `.nim`

"Graphically compose a schematic" means adding a component or drawing a net in
the GUI — a **design** change, which by §5.1 must land in `design.nim`. Three
ways, not yet chosen:

**A — GUI edits layout only.** Topology and intent are edited as text in
`design.nim` (a side-by-side pane, recompile on save). The GUI is a layout
editor + design viewer + sim/DRC/test front end. Zero round-tripping risk; not
"graphically compose".

**B — GUI performs structured edits on the `.nim` AST.** Adding a part appends a
`component` block; changing a value rewrites one `value = "…"`; comments,
computed values, loops and custom evaluators are preserved. Possible with Nim's
`compiler/parser` + `renderer`, but Nim ships no round-tripping formatter, so
this is real and ongoing work, and procedural constructs (a loop generating N
identical stages) can never be edited graphically — only appended alongside.

**C — Two tiers of design file.**
- *Declarative* designs are authored as the data model directly; the GUI reads
  **and writes** them fully, no compilation. Most boards.
- *Procedural* designs are `.nim`, compiled, and the GUI treats the emitted
  model as **read-only** — layout and simulate, but topology edits happen in
  code.

The `.nim` stays "the true design" wherever a design chooses to be code; the
GUI simply does not pretend to graphically edit code.

**Leaning:** start with **A**, architect for **C**. Ship the layout editor +
viewer + sim/DRC front end against read-only compiled models first — most of
the value, none of the round-tripping risk. If graphical topology authoring
proves essential, add it as tier C (a native declarative document), not as
`.nim` code generation. Reserve **B** only if every design must be both `.nim`
*and* fully graphically editable — the highest-cost path and the one most
likely to fight the toolchain.

---

## 8. Editor integration — `verax serve` as a language server

The same process that compiles a design for the canvas can serve editor tooling
for the `.nim` source. The readiness report is already "diagnostics on a
design"; an LSP is that, delivered per-edit and anchored to source locations,
built almost entirely from logic verax already has.

It does not replace the generic Nim language server. Run both: `nimlangserver`
handles the language (types, goto-definition, generic compile errors),
`verax serve` handles the domain.

| Capability | Backed by |
|---|---|
| Diagnostics for registry-level problems — "no evaluator produces `z_ripple`", "unknown role", "claim nobody can check", "NOT CHECKED: capability `capSpiceAc` not offered" | the `verify` readiness pipeline, run per edit against the emitted model |
| Completion — role names, quantity names, `spec:` annotation keys, role parameters | the catalog registries (`describeRoles` / `describeQuantities` / `describeAnnotations`) the CLI already introspects |
| Hover — role → its expansion; quantity → what produces it and in what units; annotation key → its type | `previewRole`, `previewRoleDelta` |
| Code actions — "did you mean `z_max_in_band`"; "add the missing `.pct` unit to this claim" | `didYouMean`, `claimLint` |

**New requirement: source-position mapping.** Today an `Assertion` carries its
evaluator's name but no `LineInfo`, and an `AssertionResult` cannot be traced
back even to its setup key. To anchor a diagnostic on the `require` or `role`
line that caused it, the `contract/dsl` macros must stamp `lineInfoObj` onto
assertions, roles and components and thread it through `Design`. Additive,
well-contained, and the same infrastructure that structured AST edits
(option 7B) would need.

**Open shape:** whether this is a distinct `verax serve --lsp` mode or just an
extra method set on the same socket the canvas front end already uses.

**Payoff:** one `verax serve` process, one compile pipeline, three consumers —
the schematic canvas, the readiness view, and the editor. The model that draws
the schematic is the model that lints the code.

---

## 9. What verax would have to grow (framework-independent)

These are needed under any front-end choice:

1. **`verax serve`** — the transport endpoint. stdio JSON-RPC minimally; add
   WebSocket for streaming sim progress and live instrument data. Factored so
   the pure report-rendering core of `verify` is reachable without the
   process-spawning shell.
2. **Design-model serialisation** — a canonical JSON form of `Design` (netlist +
   annotations + roles + assertions + environment) with a strict runtime
   loader / validator.
3. **Stable entity ids** — optional opaque id per component and net, for the
   layout file to key on.
4. **Manual-placement schema** — a representation of "this coordinate is pinned
   by a human, do not re-flow it" that survives a fresh `layout()` run. The
   scene JSON round-trips full scenes already (`sceneSchemaVersion 1`); what is
   missing is the pinned/derived distinction. Additive to the schema.
5. **A streaming result format** — see §6.3; distinct from the batched
   `AnalysisReport`.
6. **WASM build target** — a new entry module + nimble task, importing the pure
   submodules only.
7. **Source-location metadata** — `lineInfoObj` stamped onto assertions, roles
   and components by the DSL macros and threaded through `Design`, so
   diagnostics (§8) and structured edits (option 7B) can anchor to source.
8. **`SimResult` → JSON encoder** — see §6.1.
9. **Run-id linkage from `Check` to its `runNNN` archive slot(s)** — see §6.1.

---

## 10. Phasing

| Phase | Deliverable | verax work |
|---|---|---|
| 0 | Web viewer over the existing schematic JSON + `runFULL.html` model. No shell, no WASM. Confirms the UX is worth building. | none |
| 1 | Tauri shell + `verax serve` (stdio). Open a `.nim` design, view schematic + DRC/readiness, fetch and view a check's curve on demand (§6.1, §6.2). Read-only. | §9.1, §9.2, §9.8, §9.9 |
| 2 | `verax serve` also speaks LSP — registry diagnostics, completion, hover on the design `.nim`, in any editor. Shares phase 1's compile pipeline. | §9.7 |
| 3 | Layout editor. Drag / rotate / assign sheets; persist `design.layout.json`. WASM `layout()` + DRC for instant feedback. | §9.3, §9.4, §9.6 |
| 4 | Live simulation — WebSocket transport, across-run sweep streaming (§6.3); mid-run streaming is a stretch goal, not required for this phase. | §9.5, WebSocket |
| 5 | Graphical topology authoring — tier C declarative documents (per §7). | design-model write path |
| 6 | Hardware testing — Rust instrument sidecars, test-sequence UI, measured-vs-simulated correlation reusing the §6.2 curve viewer (§6.5). | instrument layer |
| 7 | PCB layout view — GPU canvas over `pcb/` data. | `pcb/` readers |

Each phase is usable on its own. Nothing after phase 1 is on the critical path
for the others except where the table's "verax work" column says so.

---

## 11. Rejected alternatives

- **Browser-only WASM app** — cannot reach hardware, cannot spawn ngspice,
  cannot save files cleanly. Fails three use cases outright.
- **Qt / C++** (the KiCad path) — a decade-long maintenance burden for a solo
  project.
- **Pure browser + File System Access API** — Chrome-only, and still needs the
  local engine for everything that matters.
- **Nim-native GUI** (nimx, owlkettle) — one language, but the ecosystem is too
  thin to bet ten years on.
- **`.nim` code generation from a graphical model** (option 7B as the primary
  path) — round-tripping generated code loses comments, computed values and
  procedural structure; fragile against the Nim toolchain.

---

## 12. Open questions

- Is single-file-compile latency (~1–3 s) acceptable as the design-edit refresh
  cost, or does phase 1 need an incremental path? It bounds LSP feedback
  latency too.
- Does the design model serialise from a *compiled run* of the `.nim` (the
  binary emits it) or from static analysis of the source? The former is
  simpler and always correct; it requires running the design.
- WebSocket vs. stdio for phase 1 — is "same front end against a remote engine"
  worth pulling forward?
- Tauri vs. Electron — does the near-term need for Node's `serialport`
  ecosystem outweigh Tauri's footprint and sidecar model?
- Does the layout file stay one-file-per-design, or one-per-sheet for large
  hierarchical designs?
- Does `verax serve` keep fetched `SimResult`s cached only in memory, or also
  rely on `$VERAX_KEEP_RUNS`'s on-disk archive surviving a `serve` restart —
  and if the latter, what evicts old session directories?
