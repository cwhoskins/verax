# `netlist/` — the electrical graph

The foundation every other submodule imports. Owns topology, hierarchy, the
annotation vocabulary, the authoring DSL, a set of attrs-backed side modules,
and the SPICE deck format. Imports only `units` and `eng` from outside itself.

## Data structures

| type | shape | notes |
|---|---|---|
| `Netlist` | `ref`; `nets`, `components`, `children`, `ports`, `models` as `OrderedTable`s; `parent`, `instanceOf` back-refs | one per hierarchy level; `ports` is an ordered subset of `nets` and defines `.SUBCKT` order |
| `Component` | `ref`; `pins: OrderedTable[string, Pin]`, `netlist` back-ref, `subNetlist`, `simModels`, `simDefault`, `kind: string`, `attrs` | `kind` is an open string, not an enum |
| `Net` | `ref`; `pins: seq[Pin]`, `netlist` back-ref, `kind: NetType`, `attrs` | |
| `Pin` | `ref`; `component`, `net`, `hierNet` | `hierNet` only on an instance pin: the port net inside the child |
| `SimReplacement` | `ref`; either declarative (`kind` + `pinNets` by **name**) or a `build` proc | stored on the component, applied only to a clone |
| `Issue` | value object; `kind: string`, `severity`, message, offending `net`/`pins`/`components`, `attrs` | shared by `netlist`, `pcb`, `analysis` |
| `AnnDef` | key, `AnnKind`, SI unit string, allowed `AnnScope`s, doc, aliases, enum `allowed` | the registry row; also reused as a role-parameter descriptor |
| `AnnValue[T]` | `{source: AnnSource, value: T}` | provenance in the return type |
| `Assumption` | entity, key, value, unit, source, detail | the record every simulation produces for what it invented |
| `Bus`, `Interface`, `InterfaceDef`, `Modport`, `RoleClaim` | value views over scalar nets | source of truth is `bus.*`/`iface.*` attrs, the views are recomputed |
| `PackageDef`, `PartPinmux`, `TraversalSpec`, `Environment`, `BomDefaults`, `Layout*` enums | value types for side modules | all persisted as namespaced attrs |

## Patterns

**Bidirectional reference graph, one mutator (README P1).** `graph.nim`
provides `addComponent/addNet/addPin/connect/disconnect/removeComponent/
addChild/addPort/adoptNet/adoptComponent/mergeNets/renameNet/clone/
instantiate`. Each keeps both directions in step and raises
`NetlistError` on a duplicate key.

**Hierarchy by deep clone.** `instantiate` clones the template netlist per
instance; only nets in a caller-supplied `globalNets` table (ground) are
shared by identity. Instance pins carry `hierNet` into the clone, so
`hierNetGroup` can BFS a conductor across any number of boundaries without
flattening. Name lookup (`findNet`/`findComponent`/`findPin`) tries the flat
key first, then descends by `hierSep` (`.`), so the same path string works
before and after `spice/flatten`. `findPin` splits right-to-left because
XSPICE pins are themselves dotted.

**Open attrs + registered vocabulary (README P2).** Bare keys are
registered (`AnnDef`), with a compile-time `const` seed the DSL macro reads
and a runtime table that can grow. Dotted keys belong to a module. Setters
validate type, unit and scope; readers never default.

**Attrs-backed side modules.** `layouthints`, `traversal`, `environment`,
`bomdefaults`, `packages`, `pinmux`, `interfaces` each store state as
namespaced attrs, expose a pure accessor, and a `validate*` returning
`Issue`s. None of them extends `types.nim`.

**Kind classification as a policy-free shared table.** `kinds.nim` answers
"what is this part, electrically" (`classifyConductivity`,
`conductiveExits`, `isPassive`, `isRail`) for both `analysis/io_check` and
`spice/isolate`, which must agree. Designator prefixes for humans and SPICE
device letters are deliberately separate tables.

**Macro DSL that expands only to `graph.nim` calls.** `netlist(...)`/
`subckt(...)` bind bare identifiers as real `let`s (typos are compile
errors); `spec:` is strict (registry-checked at compile time), head-of-
statement `key = value` is permissive. `buildNetlistBody` is exported so
`contract/dsl` reuses it.

**Format modules depend on the core, never the reverse.** `formats/spice`
reads/writes decks, owns `spiceValue`/`parseSpiceMagnitude` and the
kind→device-letter map, and refuses rather than guesses (RKM `2k2`, `A`-line
readback, deck-designator collisions).

## What this buys

- **One graph that every consumer walks the same way**, with no adapter
  layer between authoring, static checks, simulation prep, schematic and
  board. That uniformity is why `pcb` and `contract` can both *own* a
  `Netlist` instead of mirroring it.
- **Hierarchy that survives until it is deliberately destroyed.** Keeping
  instances as real child netlists (rather than flattening at authoring
  time) lets the schematic draw subsheets, the BoM group package sections,
  and evaluators address `XL.U1` — while simulation flattens a clone.
- **Provenance designed in from the start.** `AnnValue[T]` puts the source
  in the return type, so "was this stated?" cannot be forgotten at a call
  site. This is the foundation of the whole assumptions story.
- **Compile-time vocabulary checking** in the place it matters most
  (`spec:`), while keeping the runtime table open.

## Critique

1. **Encapsulation is by convention only.** Every field on every type is
   exported. `graph.nim`'s ownership of back-references is the most
   important invariant in the package and the compiler does not know about
   it. It has held, but each new contributor (human or agent) must be told.

2. **Values are strings.** An `esr` written as `20.mohm` is checked for unit
   at the setter, stored as `"2.000000000e-02"`, and read back as a bare
   `float` by every consumer. The `units.nim` types protect authoring; they
   don't flow through. Each read re-parses (cheap, but the type information
   is gone, and `parseAnnFloat` raising on a malformed stored value is a
   runtime failure far from the write).
   **Fixed 2026-10-10 (R1/R5):** typed accessors return the unit type (`esr(c): AnnValue[Ohms]`, `annotationAs(e, key, T)` checks the registered unit), and a test forbids raw float-key reads in `spice/`/`analysis/`. Storage is still text, deliberately.

3. **Provenance stored as a sibling key** (`ann.src.esr = "defaulted"`)
   can desynchronise. `putRaw` maintains both; `setRawAnnotation` and any
   direct `attrs[...] =` write only the value. A value overwritten through
   the permissive path keeps whatever marker was there.
   **Fixed 2026-10-10 (R1/R5):** `setRawAnnotation` clears the marker; `validateAnnotations` reports an orphaned one. A direct `attrs[...] =` write still bypasses both.

4. **`Component.kind` is an open string consulted by many independent
   tables** — `kinds.conductiveKinds`, `formats/spice.prefixByDeviceKind`,
   `designatorPrefixFor`, the behavioural-model registry, `bom/classify`,
   schematic symbol selection. `tests/test_spice_spellable.nim` exists
   because these can disagree. An open string is the right call for
   extensibility; the cost is that "what kinds exist" has no single answer.

5. **`Issue.kind` is an open string with no registry**, unlike annotation
   keys. Kinds are `const`s scattered across modules (`KindTraversalUnknownPin`,
   `KindBomDefaultUnknownSeries`, …). Nothing catches two modules choosing
   the same kind string with different meanings.

6. **`interfaces.nim` holds contract-flavoured data** (`RoleClaim` with
   `binds`/`params`) so that an interface definition can imply roles without
   `netlist` importing `contract`. It is the minimum leak needed, but it is
   a role concept living below the role layer, encoded as strings.

7. **Name-keyed side tables vs. renames.** `renameNet` rekeys `nets` and
   updates `ports` *values*, but anything outside the netlist keyed by the
   old name (a `Pcb.netCopper` entry, a `Subject`) is not told. Safe today
   because renames happen on simulation clones.

8. **Fixed: `mergeNets` maintains port references.** Same-netlist merges
   preserve port aliases and declaration order, retargeting their values and
   matching owner-instance pins' `hierNet` references to `keep`, so cloning
   remains valid. Cross-netlist destructive merges (flatten's port and ground
   paths) remove consumed child port entries rather than pointing them at
   foreign nets; instance bindings remain intact for traversal until dissolution.
   Pin movement, keep-wins attributes, and nil/self noops are unchanged.

9. **Linear scans in hot-ish paths.** `disconnect` is O(degree);
   `connectedComponents` and `hierNetGroup` use `notin` on a `seq`
   (quadratic in the result). Irrelevant at board scale; worth knowing
   before anything iterates these per net on a large flattened design.

10. **The DSL's permissive head (`key = value` → `attrs`) silently accepts a
    misspelled typed field** (`kidn = "resistor"`). The module doc says so;
    it is the one place the "everything that can be a compile error is one"
    principle is knowingly relaxed.

## Things that look odd but are right

- `SimReplacement.pinNets` holds net **names**, not `Net`s: it is applied
  to a later clone whose `Net` objects are different.
- `designatorPrefixFor` (`FB`) vs `prefixByDeviceKind` (`L`) are separate
  on purpose; deriving one from the other once simulated a bead as a CCCS.
- `deckDesignator` *prepends* the letter (`FB1` → `LFB1`) so designators stay
  unique, and `checkDeckDesignators` raises when prepending collides.
- `temperatureRise` is the one accessor that defaults (to 0, marked
  `annDefaulted`); an unstated rise and a zero rise agree for a part that
  does not dissipate.
