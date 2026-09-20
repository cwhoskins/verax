## Core data model for a physical printed circuit board.
##
## The electrical side is **not** re-modelled here: a `Pcb` owns a `Netlist`
## from `verax/netlist`, built through the existing `netlist/graph` API, and
## every PCB entity holds a *forward* reference into it (`Copper.net: Net`,
## `Placement.component: Component`, `Copper.pin: Pin`). `netlist/types` is
## untouched and stays geometry-free, so a netlist-only consumer carries none
## of this weight -- while an analysis pass can still walk from a trace to the
## pins it connects in a single hop.
##
## Two lookups are first-class, matching what layout analysis actually asks:
## by **net name** (`Pcb.netCopper`) and by **location**
## (`Pcb.index`, see `verax/pcb/index`).
##
## As everywhere else in this codebase, mutation goes through one module --
## `verax/pcb/graph` -- which is the only place allowed to set the
## back-references and keep the two indexes in step. Every entity carries the
## same open-ended `attrs` bag used by `netlist/types`, so a format module
## never needs to extend this schema.
##
## .. warning:: ODB++ cross-references everything **positionally** -- `FID`
##   feature numbers, `CMP`/`PKG`/`NET` record indexes. `PcbLayer.copper` is
##   therefore kept in source order and must never be re-sorted or deduped,
##   and `Copper.sourceIndex` is only meaningful immediately after a load.
##   `graph.removeCopper` invalidates it.

import std/tables
import ./units
import ./geometry
import ../netlist/types as nltypes

export units, geometry
export nltypes.Netlist, nltypes.Net, nltypes.Component, nltypes.Pin

type
  PcbError* = object of CatchableError
    ## Raised on graph-consistency violations, e.g. a duplicate layer name or
    ## reference designator within the same `Pcb`.

  LayerFunction* = enum
    lfUnknown, lfSignal, lfPlane, lfMixed, lfDielectric,
    lfSolderMask, lfSolderPaste, lfSilkscreen, lfAdhesive,
    lfCourtyard, lfAssembly, lfFabrication, lfDocumentation,
    lfBoardOutline, lfKeepout, lfDrill, lfRout

  LayerSide* = enum
    lsTop, lsInner, lsBottom, lsNone

  CopperKind* = enum
    ckTrack
      ## Stroked path on a routing layer.
    ckLand
      ## Pad / ODB++ toeprint belonging to a component pin.
    ckViaPad
      ## Annular ring of a via.
    ckZone
      ## Authored pour or plane, one per layer of a `Zone`.
    ckFill
      ## Filled surface not attributable to any of the above.
    ckOther

  HoleKind* = enum
    hkPlated, hkNonPlated, hkVia

  ViaKind* = enum
    vkNone, vkThrough, vkBlind, vkBuried, vkMicro

  MountKind* = enum
    mkUnknown, mkSmt, mkThroughHole, mkPressFit, mkOther

  BoardSide* = enum
    bsTop, bsBottom

  StackEntryKind* = enum
    seCopper, seDielectric, seSolderMask, seSolderPaste, seSilkscreen,
    seCoverlay, seOther

  GridKey* = tuple[layer: int32, cx, cy: int32]

  SpatialIndex* = ref object
    ## Uniform-grid location index over copper. Algorithms live in
    ## `verax/pcb/index`; only the storage is declared here so `Pcb` can
    ## hold one without a circular import.
    cell*: Nm
      ## Grid pitch. 1 mm by default.
    origin*: Point
    buckets*: Table[GridKey, seq[Copper]]
    oversized*: Table[int32, seq[Copper]]
      ## Per-layer overflow for shapes spanning more than `maxCells` cells --
      ## a board-sized plane would otherwise land in every bucket, which is
      ## the one real failure mode of a uniform grid on PCB data.
    maxCells*: int
    dirty*: bool
      ## Set by `verax/pcb/graph` on any mutation; `index.rebuild` clears it.

  StackMaterial* = ref object
    name*: string
    epsilonR*: float
    lossTangent*: float
    attrs*: OrderedTable[string, string]

  StackEntry* = ref object
    kind*: StackEntryKind
    layer*: PcbLayer
      ## `nil` for dielectric entries -- they have no graphic layer.
    name*: string
      ## e.g. `"F.Cu"`, `"dielectric 1"`.
    thickness*: Nm
    material*: StackMaterial
    copperWeight*: float
      ## oz/ft^2. `0` means unknown.
    attrs*: OrderedTable[string, string]

  Stackup* = ref object
    ## Physical build-up, top to bottom. Both source formats make this
    ## optional in practice (KiCad omits the block on real boards, ODB++
    ## spreads it over matrix rows plus layer attributes), so a reader may
    ## leave per-entry thickness zero and fill only `totalThickness`.
    entries*: seq[StackEntry]
    totalThickness*: Nm
    copperFinish*: string
    attrs*: OrderedTable[string, string]
    rev*: int
      ## Whole-block granularity, deliberately **not** per-`StackEntry`:
      ## `(setup (stackup))` is a block whose child order *is* the physical
      ## stack (finding 3), so a per-entry override could let entries be
      ## reordered in the model without the written block reflecting it --
      ## the KiCad writer refuses on any stackup edit regardless (see the
      ## refusal table in `formats/kicad.nim`), which is what this field is
      ## actually for: detecting that an edit happened, not describing it.

  PcbLayer* = ref object
    name*: string
      ## Canonical source name (`"F.Cu"`, `"top"`) and the lookup key. Layers
      ## are keyed by name and **never** by ordinal: KiCad renumbered every
      ## layer ID in v9 (`B.Cu` went 31 -> 2), and ODB++ `ROW` numbers are
      ## explicitly allowed to be non-sequential.
    function*: LayerFunction
    side*: LayerSide
    index*: int
      ## Position in `Pcb.layers` order, which is physical stack order.
    copperIndex*: int
      ## 0-based among copper layers; `-1` when not copper.
    negative*: bool
      ## ODB++ `POLARITY=NEGATIVE`: features on this layer are *clearances*,
      ## not copper. Ignoring this inverts the meaning of every feature on a
      ## typical plane layer.
    refLayer*: PcbLayer
      ## For mask/paste/silk: the copper layer it belongs to (ODB++ `REF`).
    copper*: seq[Copper]
      ## Copper features in source order -- see the ordinal warning above.
    shapes*: seq[Shape]
      ## Non-copper graphics: silkscreen, mask, paste, fabrication, docs.
      ## Mutate only through `graph.addShape`/`setShape`/`removeShape` --
      ## direct `seq` access (how this field was written before a format
      ## writer existed) cannot be dirty-tracked, and `formats/kicad.writePcb`
      ## does not regenerate graphics at all (see `Copper.rev` below), so an
      ## edit that bypasses those three procs is invisible to the writer and
      ## silently kept stale on the next write.
    pcb*: Pcb
    attrs*: OrderedTable[string, string]
    rev*: int
      ## Stamped by `graph.touch(pcb, layer)` on every mutation that reaches
      ## this layer (a copper add/remove, a shape edit). Compared against
      ## `KicadDoc.snapshotRev` by `writePcb` to decide whether the layer's
      ## graphics changed since the read -- and since the writer cannot
      ## regenerate graphics, a change here is exactly what turns into a
      ## refusal rather than a silently-stale write.

  Copper* = ref object
    ## One conductive (or, when `negative`, clearance-defining) feature.
    kind*: CopperKind
    shape*: Shape
    box*: Box
      ## Cached bounding box, maintained by `verax/pcb/graph`.
    layer*: PcbLayer
    net*: Net
      ## `verax/netlist` net, or `nil` for no net.
    pin*: Pin
      ## Set on `ckLand`: the pin this land serves.
    hole*: Hole
      ## Set on `ckViaPad` and on plated-through lands.
    negative*: bool
      ## This feature *erases* copper (ODB++ polarity `N`).
    sourceIndex*: int
      ## Ordinal within `layer.copper` as read (ODB++ `FID` feature number).
    attrs*: OrderedTable[string, string]
    rev*: int
      ## See `PcbLayer.rev`. `formats/kicad.nim`'s correctness net compares a
      ## regenerated `(segment)`/`(arc)`/`(via)` against this rather than
      ## trusting `rev` alone, so a direct field write that bypassed
      ## `graph.touch` is still caught -- but `rev` is still what decides
      ## *whether to run that comparison at all* on the fast path.

  Zone* = ref object
    ## An authored copper pour, plane, or keepout/rule area.
    ##
    ## The *authored* outline (`outline`, `areas`) and the *derived* fill
    ## (`fills`) are both modelled, and are not the same claim: `outline` is
    ## what the design says to pour, `fills` is what a router or `kicad-cli`
    ## actually poured after clearances, thermal reliefs and priority against
    ## other zones -- KiCad's `filled_polygon`, ODB++'s `SNT PLN` surface.
    ## `fills` is empty on an unfilled board (nothing has run a fill pass)
    ## and on a keepout (nothing is ever poured there); a caller must treat
    ## empty as "not answerable" and never as "no copper", exactly as
    ## `fem/extrude.extrudeZones` does -- meshing `outline` as if it were
    ## `fills` would model a solid slab where the real board has a Swiss
    ## cheese of clearances and thermal spokes, the class of wrong answer
    ## that looks plausible.
    name*: string
    net*: Net
    isKeepout*: bool
    priority*: int
    outline*: Polygon
      ## Layer-independent, as drawn.
    layers*: seq[PcbLayer]
      ## Multi-layer zones are normal in both formats.
    areas*: seq[Copper]
      ## One `ckZone` record per layer, holding the *authored* outline --
      ## see `graph.addZone`'s "one hazard" note on why `extrudeCopper` must
      ## skip these rather than meshing them as if they were real copper.
    fills*: seq[Copper]
      ## Derived fill geometry: one `ckFill`/`shFill` record per filled
      ## polygon a reader found, added through `graph.addZoneFill` so each
      ## lands in `Pcb.netCopper` and the spatial index exactly like any
      ## other copper feature -- a plane-shape or return-path query should
      ## not have to know a fill came from a zone rather than a track.
    attrs*: OrderedTable[string, string]
    rev*: int

  Hole* = ref object
    ## A drilled hole: via, plated component hole, or non-plated mounting
    ## hole.
    ##
    ## This unifies two very different encodings. KiCad states the span
    ## directly. ODB++ has no hole record at all -- holes are ordinary pad
    ## features on a `TYPE=DRILL` layer, classified by the matrix row's
    ## `START_NAME`/`END_NAME`, the `.drill` attribute, and the layer's
    ## `tools` file keyed by the feature's dcode. `finishedDia` is separate
    ## from `drillDia` because ODB++ `tools` distinguishes them.
    kind*: HoleKind
    viaKind*: ViaKind
    at*: Point
    drillDia*: Nm
      ## As-drilled diameter, or slot width when `isSlot`.
    finishedDia*: Nm
      ## After plating. `0` means unknown.
    isSlot*: bool
    slotEnd*: Point
    fromLayer*: PcbLayer
      ## Inclusive copper span, top-most first.
    toLayer*: PcbLayer
    net*: Net
    pin*: Pin
      ## Set for a component through-hole pin.
    pads*: seq[Copper]
      ## The `ckViaPad`/`ckLand` rings this hole ties together.
    tool*: string
      ## ODB++ `.bit` / tool number.
    attrs*: OrderedTable[string, string]
    rev*: int

  Placement* = ref object
    ## A component instance placed on the board.
    designator*: string
      ## Key in `Pcb.placements`; matches `Component.designator`.
    component*: Component
      ## `verax/netlist` component, or `nil` for a board-only footprint
      ## (fiducials, tooling, logo art).
    footprint*: string
      ## `"Lib:Name"` in KiCad, the `PKG` name in ODB++.
    at*: Point
    rot*: Deg
    side*: BoardSide
    mount*: MountKind
    doNotPopulate*: bool
    excludeFromBom*: bool
    courtyard*: Polygon
    bodyBox*: Box
      ## ODB++ `PKG` bounding box, else derived from the courtyard.
    height*: Nm
      ## ODB++ `.comp_height`. `0` means unknown.
    lands*: OrderedTable[string, seq[Copper]]
      ## Pin name -> its copper, which may span several layers.
    sections*: OrderedTable[string, Component]
      ## Section name -> the netlist component that is that section, for a
      ## multi-channel package. Empty for the 1:1 case, where `component` is
      ## the whole part. When this is populated `component` is deliberately
      ## nil: a dual op-amp *is* no single netlist component.
    holes*: seq[Hole]
    pcb*: Pcb
    attrs*: OrderedTable[string, string]
      ## KiCad `property` nodes / ODB++ `PRP` records and `BOM DATA` block.
      ## This is where per-part BoM data from the board file lands.
    rev*: int

  Outline* = ref object
    ## Board boundary and cutouts.
    ##
    ## ODB++ hands this over directly as the step `profile`. KiCad has no
    ## explicit outline at all: it must be stitched from `Edge.Cuts` graphics
    ## with a tolerance, **including items owned by footprints** -- scanning
    ## only top-level graphics produces a wrong outline.
    boundary*: Polygon
    pieces*: seq[Polygon]
      ## More than one for a panel or a deliberately disjoint board.
    stitchTolerance*: Nm
    attrs*: OrderedTable[string, string]
    rev*: int
      ## A re-stitched outline is written back as a unit, not per-piece --
      ## KiCad has no outline node to modify in the first place (it is
      ## stitched from `Edge.Cuts` graphics), so any edit here is out of
      ## scope for `formats/kicad.writePcb` regardless of `rev`; the field
      ## exists so `touch` has somewhere to record the change happened at
      ## all, for whichever format eventually does write it back (ODB++'s
      ## `profile` is a direct node, unlike KiCad's stitched one).

  Pcb* = ref object
    name*: string
    netlist*: Netlist
      ## The electrical model, built with `verax/netlist/graph`.
    layers*: OrderedTable[string, PcbLayer]
      ## Keyed by name; **insertion order is physical stack order**.
    stackup*: Stackup
    outline*: Outline
    placements*: OrderedTable[string, Placement]
    zones*: seq[Zone]
    holes*: seq[Hole]
    apertures*: OrderedTable[string, Aperture]
      ## Interned pad shapes, shared rather than duplicated per pad.
    netCopper*: OrderedTable[string, seq[Copper]]
      ## Net **name** -> every copper feature on it. Answers "give me every
      ## trace on GND" in one hash lookup.
      ##
      ## .. note:: ODB++ net names are not unique -- the spec says they are
      ##   "for reference only", each `NET` record is a distinct net even on a
      ##   collision, and the reserved `$NONE$` repeats with *mutually
      ##   disconnected* meaning. A reader must synthesise unique names and
      ##   keep the raw one in `attrs` before registering here.
    index*: SpatialIndex
    origin*: Point
      ## Source-file datum, retained for round-tripping. KiCad's
      ## `(setup (aux_axis_origin x y))`; `nm(0), nm(0)` when the source
      ## states none.
    attrs*: OrderedTable[string, string]
    source*: RootRef
      ## Opaque, format-owned round-trip state -- a parsed `KicadDoc`
      ## (`formats/kicad.nim`) today, an eventual ODB++ equivalent later.
      ## `pcb/` never reads this field; only the format module that set it
      ## downcasts it back. Same type-erasure move, for the same layering
      ## reason, as `contract/evaluate.EvalContext.scratch`: `pcb/graph` must
      ## not gain an edge to a format module just to hold onto what that
      ## module needs to write the board back out.
    rev*: int
      ## Monotonic mutation counter, incremented by `graph.touch` on every
      ## change and stamped into the mutated entity's own `rev` at the same
      ## time -- so "has `e` changed since time T" is just `e.rev > T`, which
      ## also identifies an entity *created* since T for free, with no
      ## separate flag: a brand-new `Placement` has `rev` set to whatever
      ## `pcb.rev` became at the moment it was added, which is by
      ## construction greater than the `T` any earlier snapshot recorded.
      ## `formats/kicad.readPcb` snapshots this value at the end of a read
      ## (`KicadDoc.snapshotRev`) and `writePcb` compares against it to
      ## decide whether anything changed at all -- `pcb.rev == snapshotRev`
      ## is the fast path that skips the whole regenerate-and-compare walk
      ## and just copies the original bytes.

proc newSpatialIndex*(cell = mm(1.0), maxCells = 256): SpatialIndex =
  SpatialIndex(cell: cell, origin: pt(nm(0), nm(0)), maxCells: maxCells,
               dirty: true)

proc newStackMaterial*(name: string, epsilonR = 0.0, lossTangent = 0.0): StackMaterial =
  StackMaterial(name: name, epsilonR: epsilonR, lossTangent: lossTangent)

proc newStackEntry*(kind: StackEntryKind, name: string, thickness = nm(0)): StackEntry =
  StackEntry(kind: kind, name: name, thickness: thickness)

proc newStackup*(): Stackup = Stackup()

proc newPcbLayer*(name: string, function = lfUnknown, side = lsNone): PcbLayer =
  PcbLayer(name: name, function: function, side: side, index: -1, copperIndex: -1)

proc newCopper*(kind: CopperKind, shape: Shape): Copper =
  Copper(kind: kind, shape: shape, box: box(shape), sourceIndex: -1)

proc newZone*(name = "", net: Net = nil): Zone =
  Zone(name: name, net: net)

proc newHole*(kind: HoleKind, at: Point, drillDia: Nm): Hole =
  Hole(kind: kind, at: at, drillDia: drillDia,
       viaKind: (if kind == hkVia: vkThrough else: vkNone))

proc newPlacement*(designator: string, footprint = ""): Placement =
  Placement(designator: designator, footprint: footprint, side: bsTop,
            bodyBox: emptyBox())

proc newOutline*(stitchTolerance = um(10.0)): Outline =
  Outline(stitchTolerance: stitchTolerance)

proc newPcb*(name = "", netlist: Netlist = nil): Pcb =
  result = Pcb(name: name,
               netlist: (if netlist == nil: newNetlist(name) else: netlist),
               stackup: newStackup(),
               outline: newOutline(),
               index: newSpatialIndex(),
               origin: pt(nm(0), nm(0)))

proc isCopper*(f: LayerFunction): bool {.inline.} =
  f in {lfSignal, lfPlane, lfMixed}

proc isCopper*(l: PcbLayer): bool {.inline.} =
  l != nil and l.function.isCopper
