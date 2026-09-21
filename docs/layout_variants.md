# Layout variants: the forward design for place-and-route over one subcircuit's several layouts

`pcb/variant.nim` committed the **data model** for "this subcircuit has more
than one real board layout" — `LayoutVariant`/`VariantPlacement`/
`VariantRoute`/`VariantConstraints`, a registry keyed by `Netlist.name`, and
`attrs["layout.variant"]` as the instance -> variant binding
(`netlist/layouthints.nim`'s `variant` key). It committed **no algorithm**:
`selectVariant` and `instantiateVariant` both raise "not implemented", by
name, rather than returning a plausible-looking first match. This document
is what a later stage reads before writing either proc's real body, so the
decisions already made do not get relitigated and the one real obstacle this
stage ran into — OpenSCAD footprint bodies — is recorded with the reasoning
that ruled it out, not just the conclusion.

## Why the data model shipped ahead of the algorithm

Four things had to be decided to make the *types* right, and each is cheap
to get wrong in a way that only surfaces once a real placer exists and
starts producing boards nobody can explain:

- **A variant is keyed by the subcircuit's `Netlist.name`, not by the
  instance that uses it.** `verify.nim` and `schematic/render.keepFullSchematic`
  already draw a block instanced twice once, for the same reason: identity
  lives at the template, and a layout is a property of the template's
  *shape*, not of any one place it is used. Keying by instance would mean
  two identical instances of one subcircuit could silently diverge in
  layout for no topological reason, and a variant registered against one
  instance would need re-registering against every other.
- **A variant computes nothing.** `LayoutVariant` is plain data, the
  `PackageDef`/`PartPinmux` shape (`netlist/packages.nim`,
  `netlist/pinmux.nim`) rather than the `RoleDef` shape (a role expands
  itself; a package or a pinmux table just states facts a checker reads).
  That is what keeps the door open to reading a variant from a file later —
  a KiCad `.kicad_mod`-like on-disk format for "this subcircuit, laid out
  this way" — without a rewrite, and it is why there are **no built-ins**:
  every variant is a specific board's specific layout, the same reason
  there is no generic multi-channel package.
- **The binding is a `layout.*` attr, not a `pcb/` field.** `pcb/` must not
  gain an edge *from* `netlist/` (the dependency order is `netlist -> pcb`,
  never the reverse), and an instance states which variant it wants long
  before any `Pcb` exists to hold that fact. `netlist/layouthints.nim`
  already owns exactly this shape for `side`/`mirror`/`power`; `variant`
  joins it rather than becoming a fourth mechanism, with one real
  difference: a variant name is an open string a `designs/lib/` module
  invents, not a closed set this module could enumerate the way
  `left`/`right`/`auto` is, so `parseLayoutVariant` accepts "any non-empty
  string" instead of mapping to an enum, and the DSL's
  `layout: variant = "compact"` takes a string literal rather than a bare
  ident.
- **`selectVariant`/`instantiateVariant` raise, naming what was asked and
  what exists, rather than stubbing a plausible answer.** A stub that
  returned the first registered variant regardless of
  `VariantConstraints` would compile, run, and produce a board that *looks*
  chosen rather than one that was — the same failure mode
  `verify.nim`'s own doc comment documents for `spice/models.expandSourceImpedance`
  (an ideal source silently reading as a dead short at AC, until a PDN
  check that should have failed passed every time). A caller reading the
  raise today gets told exactly what a real policy will need to rank:
  the registered variants, which ones already satisfy the stated
  constraints, and which constraint eliminated the rest.

## What a real `selectVariant`/`instantiateVariant` still needs

Left open on purpose, because none of it is a data-model question:

- **A ranking policy** over the variants `fits(v, c)` already narrows to —
  fewest copper layers, smallest extent, best courtyard utilisation, or a
  caller-supplied scoring function. `VariantConstraints` states hard
  requirements only (`maxCopperLayers`, `maxExtent`, `requireSide`); nothing
  here states a preference between two variants that both fit.
- **`instantiateVariant`'s actual placer-and-router work**: transforming
  `VariantPlacement`/`VariantRoute`/`Hole` entries from the subcircuit-local
  frame into board coordinates at `(at, rot, side)`, mirroring geometry for
  `side == bsBottom`, and — the part that makes this a real placer, not a
  copy — collision-checking against whatever else already occupies the
  target `Pcb` before stamping anything down. A version that copied
  geometry in blindly would produce a board that *looks* routed while
  silently overlapping or mis-siding whatever it landed on, exactly the
  failure `instantiateVariant`'s own doc comment names as the reason it
  raises instead.
- **Where variants come from.** Authored by hand in a design's own
  `designs/lib/` module today (`registerLayoutVariant`, the same
  `designs/lib/opamps.nim`-owns-the-catalogue pattern `packages.nim`
  documents); nothing yet extracts one from an already-routed board
  (`pcb/formats/kicad.readPcb` plus a subcircuit-boundary-detection pass
  that does not exist), which is the more useful direction in practice —
  "reuse this block's layout from a board that already has it" — and a
  larger piece of work than this stage's data model needed to settle.

## The OpenSCAD obstacle, and why it is not picked up this stage

OpenSCAD was the obvious candidate for "author a footprint's 3D body once,
reuse it everywhere this library places one" — verax is explicitly a
non-GUI library, and a footprint's copper is already handled by
`pcb/footprint.nim`/`pcb/formats/kicadmod.nim`; only the mechanical body (a
connector shell, a heatsink, a through-hole part's real 3D shape) is
missing. It does not fit, and the reason is worth recording rather than
rediscovering the next time someone reaches for it.

**OpenSCAD's outputs carry no pad identity.** Its export formats are a mesh
(STL/3MF) or, via `projection()`, a flattened 2D outline (SVG/DXF). Neither
carries a channel by which "this triangle/this polygon is pad 1, that one is
the courtyard" survives the export — a mesh is an undifferentiated pile of
triangles, and a flattened projection is an undifferentiated pile of edges.
Pad identity is exactly what `pcb/graph.addLand` and
`PackageDef.pins` join a physical land to a netlist pin *on*
(`FootprintPad.id`, matched against a component's pin names or a package's
pad-id map). A footprint source that could not report which polygon is
which pad could still draw a pretty picture and could not place a single
real connection — it would be strictly worse than the `.kicad_mod` reader
this stage shipped, not an alternative to it. (`openscad` is also not
installed on this machine, which is a second, unrelated reason it was not
exercised here, but not the reason it is ruled out.)

**The workable shape, for when this is picked up.** Split the two questions
OpenSCAD conflates for a mechanical part: verax owns a Nim-side pad table
(ids, apertures, positions — exactly `pcb/footprint.FootprintPad`, already
built) and OpenSCAD owns only the 3D body **solid**, with no pad-identity
claim of its own. A `FootprintSource` registers a `resolve` that returns a
`Footprint` whose `pads`/`courtyard`/`bodyBox` come from wherever the pad
table is authored (by hand, or by a future reader of some other CAD format
that *does* carry pad identity) and whose `height`/an eventual 3D-body
reference comes from an OpenSCAD `.scad` file compiled to a mesh purely for
visualisation or mechanical-fit checking, never consulted for connectivity.
This is exactly the split `verax` being a non-GUI library already implies:
geometry the tool *reasons about* (pads, courtyard, a bounding box) is
typed data with a registry and a join key; geometry the tool only *displays
or fits mechanically* is an opaque asset handed to something else. Nothing
in `pcb/footprint.FootprintSource`'s shape needs to change to add this --
`registerFootprintSource` with no built-in source registered was the whole
point, so an OpenSCAD-backed source is a new module, not a new mechanism.
