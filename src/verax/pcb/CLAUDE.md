# `pcb` submodule

The physical board — layers, stack-up, copper, holes, placements, outline. Depends on `netlist`. Formats are opt-in under `pcb/formats/`.

## Model

- **The electrical model is not duplicated.** A `Pcb` owns a `Netlist`; PCB entities hold **forward references only** (`Copper.net`, `Copper.pin`, `Placement.component`). `netlist/types.nim` stays geometry-free.
- `Placement` ↔ `Component` join on designator (`bindComponent`; `placementOf` reverse). **Multi-channel package exception**: one `Placement`, N section `Component`s via `package.ref`; `Placement.sections[name]` is filled and `Placement.component` is **nil**. `addLand` then treats the pin name as a *package pad id* resolved through the `PackageDef` (unknown pad binds nothing). `bom.nim` and `placementOf` fall back through the `PackageDef`/sections. Hierarchical parts bind with `bindComponent(p, c, path)` (`"X1.U1"`).
- **Two first-class lookups**: by net name (`Pcb.netCopper`, `copperOn`) and by location (`index.nim`, per-layer uniform grid). `query`/`queryPoint`/`near` return bounding-box *candidates*; `hitTest` applies exact geometry — don't confuse them. Features spanning > `maxCells` go to an `oversized` list. Mutations set `index.dirty`; queries rebuild.
- **`units.nim`** — `Nm = distinct int64` nanometres, `Deg = distinct float64`. **Canonical frame: X right, Y up, CCW-positive degrees; islands CCW, holes CW.** KiCad is Y-down — its reader negates Y and angle at the boundary or rotated footprints silently mirror. ODB++ input rounds to the nearest nm.
- **Lengths are plain `float` metres** (`geometry.length`, `units.toMetres`). Settled — don't add a `Metres` type without a concrete case.
- **`geometry.nim`** — `Curve` (no area) vs `Shape` (`shStroke`/`shFill`/`shPad`/`shText`). **Arcs are canonically centre + radius + start angle + signed sweep**; convert at the reader. `Aperture` is a `ref` interned in `Pcb.apertures`; unknown names → `akCustom`.
- **`types.nim`** — entities carry the same `attrs` bag as `netlist`.
- **`graph.nim`** — **the only place allowed to mutate back-references and indexes** (`.pcb`, `.layer`, `.net`, `.pin`, `.hole`, `.pads`, `.lands`, `.box`, `.sourceIndex`, `.index`). `Pcb.rev` is bumped by `graph.touch`, which also stamps the entity's `rev`; a direct field write must `touch` itself.
- **Layers are keyed by name, never ordinal** (KiCad v9 renumbered; ODB++ rows may be non-sequential). **`Pcb.layers` insertion order is physical stack order** — add top to bottom.
- `PcbLayer.copper` is in source order and must never be re-sorted/deduped (ODB++ cross-references positionally). `Copper.sourceIndex` is only valid right after load.
- `Copper.negative`/`PcbLayer.negative`: on negative layers drawn features are *clearances*.
- `Hole.setSpan` derives through/blind/buried. `drillDia` ≠ `finishedDia`.
- **`Zone`**: `outline`/`areas` are *authored*; `fills` are *derived* real copper (`addZoneFill` adds `ckFill` copper). **Empty `fills` means "not answerable", never "no copper"** — refuse rather than fall back to the outline. **`addZone` also pushes a `ckZone` record of the authored outline onto each layer — any copper walk must skip `ckZone`** (`fem/extrude`, `trace.extractRoutes`) or it double-counts.
- **`bom.nim`** — `buildBom` compiles a BoM from board-file data only (KiCad properties, ODB++ `PRP`/`BOM DATA`), trying both naming conventions. `excludeFromBom` dropped; `doNotPopulate` kept on its own line. Catalogue resolution is `verax/bom`'s job.

## Formats

- **`formats/common.nim`** — contract is **path-based**, not `Stream`-based (ODB++ is a directory tree with `.Z` members): `readPcb(path, step = "")`, `writePcb(pcb, path)`. `formats/odbpp.nim` is not written.
- KiCad has **no explicit outline** — stitch `Edge.Cuts` (including footprint-owned items) within `Outline.stitchTolerance`. **ODB++ net names are not unique** (`$NONE$` repeats) — synthesize unique names before registering.

### `formats/kicad.nim` (with `formats/sexp.nim`)

Module doc comments hold the detail; these are the decisions.

- **Byte-exact round trip via verbatim emission**: every `sexp` node is an `(offset, length)` slice of the source; untouched nodes are copied. KiCad's `Prettify()` can't be reproduced by rule.
- **`sexp.parseSexp` never raises** on structural defects (stray `)` is gap content); **`kicad.readPcb` refuses by name** anything that isn't exactly one well-formed `(kicad_pcb ...)` root. (The shipped `RoyalBlue54L-Feather` demo is corrupt and `kicad-cli` silently reads ~1% of it — don't trust its exit code.)
- Source is held in `Pcb.source: RootRef` (type-erased, like `EvalContext.scratch`) plus `attrs["kicad.node"]`; no wrapper type, so `writePcb`'s signature holds. `(uuid)` is not copied into `attrs`.
- **Fast path**: `writePcb` returns source bytes untouched when `pcb.rev == KicadDoc.snapshotRev`.
- **Regenerated on edit**: `segment`/`arc`/`via` (whole node, modify and insert), `net` declarations (insert-only, never renumber), footprint `at`/`layer`/`Reference` value/pad `net`, zone `net`/`net_name`/`priority`/`name`. **Refused by name**: new footprints/pads on a sourced board, any `PcbLayer.shapes` edit, new zones, stack-up edits. On a sourced board: route, re-route, rip up, re-net, re-pour, move — don't create or reshape components.
- **Insertion-anchor traps** (guarded in `resolveInsertAnchor` — keep the guards): skip candidates already `markDeleted` (an insert anchored to a deleted node is never emitted); `doc.kids(root)` yields the head atom first — skip non-list children.
- Placement designator collisions are real (`""`, `REF**`): the reader synthesizes `REF**#1`… and keeps the literal in `attrs["kicad.reference"]`/`attrs["kicad.node.refText"]`. Rename by setting `attrs["kicad.reference"]` (no `renamePlacement`).
- **KiCad ≥ `20251028` may have no net codes** (`(net "name")` only). `KicadDoc.hasNetCodes` records whether codes were declared at all; every write-side net formatter branches on it.

### Schematic → board (`footprint.nim`, `formats/kicadmod.nim`, `formats/kicadgeom.nim`, `formats/kicadgen.nim`, `assemble.nim`, `variant.nim`)

- **`footprint.nim`** — `Footprint`/`FootprintPad` (pad `id` = the `addLand`/`PackageDef.pins` join key) and a `FootprintSource` registry (first resolver wins, **no built-in source**). `Footprint.source` holds the `.kicad_mod` node's verbatim bytes — a synthesized board *quotes* real footprints, never invents KiCad graphics syntax. `FootprintPad.layers` are raw tokens (`*.Cu`); expansion happens when placed.
- **`kicadgeom.nim`** — geometry helpers shared by the board and library readers so they can't diverge.
- **`kicadmod.nim`** — `.kicad_mod` → `Footprint`, same Y/angle flip; registers itself on import. `"Lib:Name"` → `<dir>/Lib.pretty/Name.kicad_mod` over `$VERAX_FOOTPRINT_PATH`, `$KICAD10_FOOTPRINT_DIR`/`$KICAD9_FOOTPRINT_DIR`, `/usr/share/kicad/footprints`.
- **`assemble.nim`** — blank `Pcb` from a `Netlist`: standard layers, synthesized FR4 stack-up, rectangular outline, deterministic grid placement (sorted by designator). **Every synthesized figure is an `Assumption`.** **Does not flatten** (no edge to `spice`) — walks the hierarchy itself, naming leaves `hierName("X1", "U1")`. Footprint resolution: part's `footprint` → `PackageDef.footprint` → `footprint_unresolved` (`sevError`, never skipped). Pad/pin mismatches → `footprint_pad_unmatched` (warning). `writeBoard` imports the KiCad writer directly (the hub still doesn't export it).
- **`writePcb` synthesis branch**: `pcb.source == nil` with ≥ 1 layer → `kicadgen.renderNewPcb` (splicing each footprint's source, editing only `at`/`layer`/`Reference`/pad `net`). `pcb.source` stays nil, so a second write re-synthesizes; to edit the result, `readPcb` the written file.
- **`variant.nim`** — data model only (no placer/router/policy). `LayoutVariant` keyed by `Netlist.name` (the template). Instance binding is `attrs["layout.variant"]` on the netlist side. `selectVariant`/`instantiateVariant` **raise** naming what was asked and what exists — no stubs that look like they work.

## Routing and transmission lines (`trace.nim`, `impedance.nim`, `tline.nim`)

Read-only over a `Pcb`; register no contract quantities yet.

- `extractRoutes` keeps `ckTrack`/`ckLand`/`ckViaPad`/`ckFill` and discards `ckZone`/`ckOther` in one `case`.
- **A via is a node, never a mid-edge event** — nodes carrying a `Hole` are excluded from the degree-2 collapse (a section must have one layer/width/Z0). `RouteEdge.vias` is 0 by construction.
- The degree-2 collapse removes only pin-less, via-less, pour-less nodes with exactly two edges, so a Y comes back as trunk + two branches and a fragmented run as one edge.
- No reference plane: `route_no_reference`; zones exist but `fills` empty: `reference_unfilled` (different fixes).
- `impedance.nim` is closed-form quasi-static (Hammerstad-Jensen, IPC-2141), no dispersion — a few percent off a field solver is expected.
- `TlineSpec.roughness` (default 0 → loss is a lower bound) and `rho` (annealed Cu at 20 °C) are recorded as `Assumption`s when defaulted.
