# `pcb/` — the physical board

Layers, stack-up, copper, holes, placements, outline and zones; a spatial
index; KiCad board/footprint/DRU I/O; board synthesis from a netlist; routing
trees, closed-form impedance, transmission lines and vias. Imports `netlist`
(and `touchstone` for `tline`).

## Data structures

| type | shape | notes |
|---|---|---|
| `Pcb` | `ref`; owns a `Netlist`; `layers: OrderedTable` (insertion order = physical stack order), `stackup`, `outline`, `placements`, `zones`, `holes`, interned `apertures`, `netCopper` (net **name** → copper), `index`, `origin`, `attrs`, `source: RootRef`, `rev` | |
| `PcbLayer` | `ref`; name (key, never ordinal), function, side, index/copperIndex, `negative`, `refLayer`, `copper: seq` (source order, never resorted), `shapes`, `pcb` back-ref, `rev` | |
| `Copper` | `ref`; `CopperKind` (track/land/viaPad/zone/fill/other), `shape`, cached `box`, `layer`, forward refs `net`/`pin`/`hole`, `negative`, `sourceIndex`, `rev` | one record per conductive feature |
| `Zone` | outline + per-layer `areas` (authored, `ckZone`) + `fills` (derived, `ckFill`) | empty `fills` = "not answerable" |
| `Hole` | kind/viaKind, `drillDia` vs `finishedDia`, span `fromLayer..toLayer`, `pads`, `net`/`pin` | |
| `Placement` | designator, `component` (or nil), footprint, pose, side, flags, courtyard/body/height, `lands: pin → seq[Copper]`, `sections` for multi-channel packages | |
| `Stackup`/`StackEntry`/`StackMaterial` | ordered entries, thickness, εr, tanδ | |
| `Nm` = `distinct int64`; `Deg` = `distinct float64` | canonical frame: X right, Y up, CCW positive | lengths in analysis are plain `float` metres |
| `Curve` (variant seg/arc), `Path`, `Polygon` (CCW outer, CW holes), `Shape` (variant stroke/fill/pad/text), `Aperture` (`ref` variant, interned) | geometry | arcs canonical as centre + radius + start + signed sweep |
| `SpatialIndex` | uniform grid `Table[(layer, cx, cy), seq[Copper]]` + per-layer `oversized` list + `dirty` | rebuilt lazily |
| `RouteGraph`/`RouteTree`/`RouteEdge`/`RouteSection` | trace topology with reference-plane resolution | read-only over a `Pcb` |
| `KicadDoc` (`ref object of SexpDoc`) | source bytes + `SNode` slices `(offset, length)` + `snapshotRev` + flags | stored in `Pcb.source` |

## Patterns

**Own the netlist, reference forward.** A `Pcb` owns a `Netlist`; PCB
entities point into it (`Copper.net`, `Placement.component`) and the netlist
never points back, so `netlist/types` stays geometry-free.

**Single mutator module with revision stamping.** `pcb/graph.nim` is the only
writer of back-references, caches (`box`) and indexes, and `touch` bumps
`Pcb.rev` and stamps the entity's `rev`. Writers compare revs to decide what
to regenerate.

**Two lookups, both first-class.** By net name (`netCopper`) and by location
(`index`: candidate query, then exact `hitTest`).

**Integer nanometres for geometry, floats for physics.** Exact equality and
hashing on board coordinates; physics in SI floats.

**Byte-exact round trip by verbatim emission.** The KiCad reader keeps every
s-expression as a slice of the source; untouched nodes are copied byte for
byte; a bounded set of edits (tracks, vias, nets, zone scalars, footprint
pose/reference/pad nets) is regenerated; everything else is **refused by
name**. A fast path returns the source bytes when `rev` hasn't moved.

**Synthesise by quoting.** A board generated from a netlist splices each
footprint's real `.kicad_mod` bytes and edits only pose/reference/pad nets —
it never invents KiCad graphics syntax.

**Refuse rather than fall back.** Empty zone fills, missing reference planes,
a reference change across a via, an unfilled pour — each is a named issue, not
a default.

## What this buys

- **No second electrical model.** Layout analyses walk from a trace to the
  pins it connects in one hop, using the same `Net` objects as simulation.
- **Safe editing of real boards.** The verbatim round trip means verax can
  route/rip-up/re-net a KiCad board without reformatting it or losing
  anything it doesn't understand — the refusal list is what makes that a
  guarantee rather than a hope.
- **Coordinate exactness.** `Nm` avoids the float-equality bugs that plague
  geometry code, and the single canonical frame localises the Y-flip to the
  reader.
- **Format independence by construction.** `Pcb.source: RootRef` lets a
  format keep round-trip state without `pcb` importing the format.

## Critique

1. **`ckZone` records live in the copper list that every walk iterates.**
   `addZone` pushes the authored outline onto each layer's `copper` so it
   indexes, and every consumer (`trace.extractRoutes`, `fem/extrude`) must
   remember to skip `ckZone` or double-count copper. It is documented in three
   CLAUDE files. Storing authored areas outside `PcbLayer.copper` (or behind an
   iterator that skips them by default) would retire the trap.

2. **`Placement` has two modes encoded by nullity.** 1:1 → `component` set,
   `sections` empty; multi-channel package → `component` nil, `sections`
   filled, and `addLand` reinterprets pin names as package pad ids. Every
   consumer (`bom.nim`, `placementOf`) carries a fallback branch. A variant,
   or always populating `sections` (with one entry in the 1:1 case), would
   make the shape uniform.

3. **`netCopper` is keyed by net name while `Copper.net` is a reference.**
   The netlist can rename a net (`graph.renameNet`) without `pcb` knowing.
   Nothing renames nets on a board-owned netlist today, so it holds by
   circumstance.

4. **Revision stamping relies on discipline.** Fields are exported; a direct
   write that skips `graph.touch` leaves `rev` stale and lets `writePcb` take
   the byte-copy fast path over a changed board. The KiCad writer does
   cross-check regenerated tracks/vias against source bytes as a safety net,
   but only for kinds it regenerates.

5. **Positional invariants on `seq`s.** `PcbLayer.copper` must never be
   re-sorted or deduplicated (ODB++ `FID`s are positional), and
   `Copper.sourceIndex` is valid only right after load. An ordinal that
   silently invalidates on mutation is fragile; the ODB++ reader that needs it
   isn't written yet.

6. **Two BoM models.** `pcb/bom.nim` (`BomLine` from board-file properties)
   and `bom/` (`BomLine` from the netlist and catalogues) share field names by
   convention ("Field names follow `pcb/bom.BomLine` without importing it")
   and reconciling them is declared a non-goal. Reasonable now; a reader
   meeting two `BomLine` types will not expect it.

7. **Lengths as plain `float` metres alongside `Nm`.** Settled by decision,
   and conversion is centralised, but it means `pcb` has one exact unit type
   and one bare-float convention side by side.

8. **`trace.rootedAt` flips an edge's ends but not its `sections`.**
   Consumers walking from the root must re-order (`si/board.orderedSections`
   does). A data structure whose orientation is half-applied is an easy one
   to misuse.

## Things that look odd but are right

- Layers are keyed by name, never by ordinal: KiCad v9 renumbered layer IDs.
- KiCad has no explicit outline; it is stitched from `Edge.Cuts` including
  footprint-owned items, within a tolerance.
- A via is a route *node*, never a mid-edge event: a section must have one
  layer, width and Z0.
- `rlgc` is deliberately non-causal; `causalLine` is the form `si/` fits.
