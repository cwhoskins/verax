# `schematic/` — a deterministic picture of a netlist

A heuristic topology visualiser: `Netlist` → renderer-neutral `Schematic`
scene → self-contained SVG / versioned JSON (with a strict reader), plus the
run-archive layer and an HTML hierarchy browser. Imports only `netlist`. The
largest submodule by line count (~9.5k).

## Data structures

| type | shape | notes |
|---|---|---|
| `Schematic` | flat seqs: `parts`, `wires`, `junctions`, `labels`, `ports`, `fallbacks`, `dividers`, plus bounds | the public contract; everything is placed; writers only render |
| `SchematicPart` | designator (join key, never rewritten), `label` (display), kind/symbol/value, `bodyW/H` (pin span) and `inkW/H` (drawn extent), position, rotation, mirror, pins, `count`/`members` for collapsed arrays | |
| `SchematicPin` | name, position, `net: string`, `members`, `mark: PinMark`, `tag` | nets referenced by **name** |
| `SchematicWire` | net, `WireKind` (signal/ground/supply/bus/interface/chain/power-link), members, polyline | |
| `SchematicFallback` | an unwired pin with its escape and stub | kept **out of** `wires`, occupancy and junctions |
| `Point` | `{x, y: float}` with structural `==`/`hash` | relies on grid snapping for exact equality |
| `LayoutOptions` / `StageId` | 22 stages in a fixed canonical order; options filter membership only | `validateLayoutOptions` rejects combinations that can't produce a scene |
| `LayoutState` / `RoutingState` | **private**; the mutable working set across stages | never exposed in `Schematic` |
| `BundlePlan`, `ArrayPlan`, `CompositePlan`, `PowerPlan` | per-feature plans, each with a zero value meaning "feature absent" | |
| `CompositeKind` | seven `{.nimcall.}` hooks + `orientable`; registered in a `let` whose order is precedence | |

## Patterns

**Pure façade over a staged pipeline.** `layout(nl): Schematic` runs the
enabled stages in canonical order over a private `LayoutState`. Stages can be
disabled (each yields its zero-value plan) but never reordered.

**Determinism as an invariant.** No randomness, no clock; iteration follows
graph insertion order; hash tables are looked up, never iterated unsorted.
Same netlist → byte-identical SVG/JSON.

**Zero-value ⇒ byte-identical output.** Every optional feature (bundles,
arrays, power band, dividers, fallback kinds) has a zero plan, and every
downstream path is guarded on it, so adding a feature cannot move existing
pictures.

**Additive-only scene schema.** `sceneSchemaVersion` stays 1; new enum values
are appended; new enums put the legacy meaning at ordinal 0; new fields are
emitted only when non-default. The JSON reader is strict and also reads the
legacy unversioned form.

**`include`-based composition.** `layout.nim` `include`s 17 units in a
load-bearing order (`geometry` → `symbols` → `router` → … → `diagnostics`),
so private state and helpers stay module-private while living in separate
files. Earlier units take plain-data arguments because they cannot name
later types.

**Strategy registry for motifs.** Composite recognisers (parallel stack,
series chain, pi, tee) are data objects of hooks; adding a motif is a file
plus a registry entry, never a special case in placement or routing.

**Assertions for bugs, outcomes for failures.** Path-integrity violations in
`routeNet` are `doAssert`s; unroutability is a recoverable `RouteOutcome`
that degrades to a drawn fallback marker.

**Diagnostics from the artefact alone.** `diagnoseFallbackNet` rebuilds the
router inputs from a finished scene (including an archived `runNNN.json`) and
re-runs one route to classify the blocker.

## What this buys

- **Stable, diffable output.** Determinism plus zero-value equivalence make
  the scene usable as a regression artefact and keep archive pictures
  comparable across versions.
- **A renderer-neutral scene** with a strict JSON round trip, so other
  front ends (the HTML browser, a future GUI, an MCP client) consume the same
  placed geometry instead of re-running layout.
- **Honest failure in a picture.** A net that could not be routed is drawn
  as a distinct dashed marker, not omitted — the same "silence is not
  approval" stance as the verifier.
- **Feature isolation.** Each plan's zero value means a feature can be
  developed, disabled and tested independently.

## Critique

1. **One ~9k-line compilation unit.** `include` gives file-level
   organisation but not module boundaries: every unit sees every earlier
   unit's private symbols, and nothing stops a later unit reaching into an
   earlier one's internals. The documented workaround — passing plain data
   because earlier units can't name later types — is a symptom of ordering
   pressure that ordinary modules with explicit exported interfaces would
   remove. It also means internal units can only be tested through
   `layout`, or through the `*Report` test hooks added for that purpose.

2. **Rule accretion.** `schematic/CLAUDE.md` is the longest submodule guide,
   and most of it is traps: sibling-clone pin filtering, escape-seed dedupe
   (twice, keyed differently in bundles and arrays), port folding, collapsed-
   bundle decline, the totality `doAssert`. Each is justified; together they
   show a design where features interact through shared occupancy state and
   each interaction is patched where it was found. That is typical of
   heuristic layout engines, and it is where most future regressions will
   come from.

3. **Global-net sibling trap is a netlist-model leak.** Because
   `instantiate` shares the global ground `Net` across every sibling clone,
   `net.pins` on `"0"` contains pins from every instance. The schematic must
   filter by owning-`Netlist` identity "everywhere `net.pins` is walked".
   That is a property of the netlist data model that every graph consumer
   must know; the schematic just hits it most often.

4. **Name-keyed scene.** `SchematicPin.net`, `SchematicWire.net`,
   `Bundle.display` are strings, and `Bundle.display` must be disambiguated
   against every net name (`_iface`, `_bus`, `_2`) because it shares the
   namespace. Typed IDs, or a separate namespace for bundles, would remove
   that collision class.

5. **Float `Point` with structural hashing.** Correct only because every
   coordinate is grid-snapped before it is hashed. A future stage that
   produces an unsnapped coordinate would create near-duplicate keys
   silently.

6. **`LayoutPolicy` is an enum of one value**, kept for a future second
   policy, with a CLI flag that is a no-op. Harmless; it is speculative
   generality the rest of the codebase generally avoids.

7. **Name collision with `pcb`.** Both export a `Point` (float here, `Nm`
   there); a module importing both must qualify. Minor.

## Things that look odd but are right

- `bodyW/H` (pin span) vs `inkW/H` (drawn extent): placement uses one,
  labels the other.
- Fallbacks are not wires: they must never enter occupancy or junctions, or
  a failed route would block a successful one.
- Packing reverts if the result is not smaller — it can only help.
- `designator` is never rewritten for display; `label` carries `U10A` or
  `X1..X8`, because downstream code joins on the designator.
