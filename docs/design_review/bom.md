# `bom/` — compiling a bill of materials

Which orderable part each component is: collect one item per physical part,
resolve it against registered catalogue sources, roll up into lines, render
text/CSV/JSON, and lock decisions across runs. Imports `netlist` and `units`
only — never `pcb`, `spice` or `contract` — and is not in the verification
path.

## Data structures

| type | shape | notes |
|---|---|---|
| `PartFamily` | resistor/capacitor/inductor/ferrite (parametric), other (needs MPN), notAPart (simulation-only) | from a runtime `kind → family` table |
| `BomItem` | `ref`; designators (printed) vs members (every section path) vs component refs; family, `value` (SI, NaN if not parametric), ratings (NaN unknown), dielectric/package/footprint/caseCode, mpn/manufacturer/partNumber kept apart, quantity, DNP/excluded, assumptions, issues | one per physical part; a dual op-amp is one item |
| `Candidate` | `ref`; an orderable part from a source; NaN for unknown ratings; `Availability` with `-1` for unknown stock/MOQ | callers get copies |
| `PartQuery` | parametric search; every float NaN = "no requirement"; `manufacturers` is a hint, never a filter | `newPartQuery` exists because the zero value is wrong |
| `CatalogSource` | `ref`; name + nullable **closure** procs `search`/`lookup` | registration order = resolution order |
| `Resolution` | item, chosen, alternates, candidate count, `locked`, `signature`, issues | |
| `LockEntry` | signature → mpn/manufacturer (+ designators for humans only) | |
| `BomLine` / `BomResult` | rolled-up lines over resolutions; whole-BoM issues | |

## Patterns

**Pipeline of pure stages over plain data:** collect (netlist → items) →
resolve (items × sources → resolutions) → roll up (→ lines) → render. Each
stage returns findings on the objects themselves (`BomItem.issues`,
`Resolution.issues`, `BomResult.issues`), never in side lists.

**One definition of a match.** `source.matches` is the only place a
candidate is compared with a query; a stated minimum rejects a candidate that
leaves the rating unknown.

**Opt-in source registry.** Nothing registers on import; sources are closures
because they carry state (a loaded catalogue, later credentials and caches).
The offline JSON catalogue is strict and all-or-nothing.

**Requirement-keyed lockfile.** The lock key (`signature`) is the
*requirement*, never the designator, so a lock survives renumbering; a lock
wins only while its part is still a non-obsolete candidate. The JSON report
*is* the next run's lockfile.

**Unknown ≠ zero.** NaN for floats, `-1` for stock/MOQ, so an unknown stock
never triggers a low-stock finding and an unknown tolerance never passes a
maximum.

## What this buys

- **Deterministic, reviewable procurement.** Ranking is explicit (lifecycle,
  preferred manufacturer, exact value, stock, MPN), the lock makes reruns
  stable, and every gap filled by a `bom:` default is an `Assumption`.
- **Safe extensibility.** A distributor API can be added as another
  `CatalogSource` without touching resolution or rendering.
- **No dependency on the board.** A BoM can be compiled from a design before
  any layout exists.

## Critique

1. **`collectLeaves` is duplicated from `pcb/assemble.nim`** with the comment
   "`bom/` can't import `pcb/`". It is a pure netlist walk; the layering rule
   the rest of the codebase follows (README P8) would move it down into
   `netlist/graph` rather than copy it. Two copies of "what is a leaf part"
   can drift (e.g. on how a package section or a generated designator is
   treated).
   **Fixed 2026-10-10:** both now call `netlist/graph.leafComponents`.

2. **Absence is NaN/`-1`, while the netlist it reads from uses
   `AnnValue`.** Collection converts provenance-carrying values into bare
   floats; provenance survives only as the `assumptions` list for `bom:`
   defaults. Whether a rating was authored, derived by a `parts` policy, or
   defaulted is not visible on a `BomItem`.
   **Fixed 2026-10-10 (R1/R5):** `BomItem` ratings are `Stated[float]` and JSON carries `requirement.sources`; `Candidate`/`PartQuery`/`Availability` use `Option` instead of NaN/`-1`.

3. **Source procs are closures, footprint sources and every other registry
   are `{.nimcall.}`.** The reason (sources carry state) is good; it is also
   the one registry where a plugin is a closure, which matters for the
   "runtime-loadable plugins" goal (closures don't cross a dynamic-library
   boundary as easily).

4. **Global source registry** (`var registry: seq[CatalogSource]`) shared by
   every BoM compiled in the process; `clearCatalogSources` is the test
   escape hatch. A `BomContext` passed through `compileBom` would let two
   compilations with different catalogues coexist (e.g. in the MCP server).

5. **Two `BomLine` types** (here and `pcb/bom.nim`) with fields aligned by
   convention. Declared a non-goal to reconcile; a reader will still trip on
   it.

6. **Linear scan of a whole-file catalogue.** Explicitly chosen (stdlib-only,
   no SQLite) and fine for house catalogues; it is the first thing a network
   source with a cache will want to replace.

7. **`bom:` defaults are partially honoured.** `series` and `derating` are
   collected but not read by the resolver. A default that is accepted and
   ignored is a quiet version of the problem the rest of the tool is built
   to avoid; the CLAUDE file says so, the report does not.

## Things that look odd but are right

- `value` is parsed only for the four parametric families: elsewhere it is a
  model name, and `1N4148` is lexically an RKM value.
- `partNumber` is never copied into `mpn`; it may be a house number.
- A candidate's *whole* tolerance band must fit inside the item's, not just
  its nominal.
- `caseCodeOf` reads a footprint name only when the imperial code sits beside
  its metric twin — `0603` is both a real imperial and a real metric size.
