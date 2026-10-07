## Core data model for a physical printed circuit board.
##
## The electrical side is not re-modelled: a `Pcb` owns a `Netlist`, and PCB
## entities hold forward references into it (`Copper.net`, `Copper.pin`,
## `Placement.component`). `netlist/types` stays geometry-free.
##
## Two first-class lookups: by net name (`Pcb.netCopper`) and by location
## (`Pcb.index`). All mutation goes through `verax/pcb/graph`. Entities carry
## the same open `attrs` bag as `netlist/types`.
##
## .. warning:: ODB++ cross-references **positionally** (`FID`, record
##   indexes), so `PcbLayer.copper` stays in source order -- never re-sort or
##   dedup -- and `Copper.sourceIndex` is valid only right after a load
##   (`graph.removeCopper` invalidates it).

import std/tables
import ./units
import ./geometry
import ../netlist/types as nltypes

export units, geometry
export nltypes.Netlist, nltypes.Net, nltypes.Component, nltypes.Pin

type
  PcbError* = object of CatchableError
    ## Raised on graph-consistency violations (e.g. duplicate layer name or
    ## designator).

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
    ## Uniform-grid location index over copper; storage only (algorithms in
    ## `verax/pcb/index`).
    cell*: Nm
      ## Grid pitch. 1 mm by default.
    origin*: Point
    buckets*: Table[GridKey, seq[Copper]]
    oversized*: Table[int32, seq[Copper]]
      ## Per-layer overflow for shapes spanning more than `maxCells` cells, so
      ## a board-sized plane doesn't land in every bucket.
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
    ## Physical build-up, top to bottom. Often partial in source files, so a
    ## reader may fill only `totalThickness`.
    entries*: seq[StackEntry]
    totalThickness*: Nm
    copperFinish*: string
    attrs*: OrderedTable[string, string]
    rev*: int
      ## Whole-block, not per-entry: KiCad's stackup child order *is* the
      ## stack, and the writer refuses any stackup edit -- this only detects
      ## that one happened.

  PcbLayer* = ref object
    name*: string
      ## Canonical source name and lookup key. **Never key by ordinal**: KiCad
      ## v9 renumbered layer IDs and ODB++ rows may be non-sequential.
    function*: LayerFunction
    side*: LayerSide
    index*: int
      ## Position in `Pcb.layers` order, which is physical stack order.
    copperIndex*: int
      ## 0-based among copper layers; `-1` when not copper.
    negative*: bool
      ## ODB++ `POLARITY=NEGATIVE`: features are clearances, not copper.
    refLayer*: PcbLayer
      ## For mask/paste/silk: the copper layer it belongs to (ODB++ `REF`).
    copper*: seq[Copper]
      ## Copper features in source order (see the ordinal warning).
    shapes*: seq[Shape]
      ## Non-copper graphics. Mutate only through `graph.addShape`/`setShape`/
      ## `removeShape`, or the KiCad writer can't see the edit.
    pcb*: Pcb
    attrs*: OrderedTable[string, string]
    rev*: int
      ## Stamped by `graph.touch` on any mutation reaching this layer. A
      ## change after the read makes `writePcb` refuse (it can't regenerate
      ## graphics) rather than write stale data.

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
      ## See `PcbLayer.rev`. The KiCad writer also compares regenerated
      ## tracks/vias against source bytes, catching writes that bypassed
      ## `touch`; `rev` decides whether that comparison runs.

  Zone* = ref object
    ## An authored copper pour, plane, or keepout/rule area.
    ##
    ## `outline`/`areas` are what the design says to pour; `fills` is what a
    ## fill pass actually poured (after clearances and thermals). `fills` is
    ## empty on an unfilled board or a keepout: treat empty as "not
    ## answerable", never "no copper", and never mesh `outline` as if poured.
    name*: string
    net*: Net
    isKeepout*: bool
    priority*: int
    outline*: Polygon
      ## Layer-independent, as drawn.
    layers*: seq[PcbLayer]
      ## Multi-layer zones are normal in both formats.
    areas*: seq[Copper]
      ## One `ckZone` record per layer holding the authored outline; copper
      ## walks must skip these.
    fills*: seq[Copper]
      ## Derived fill: one `ckFill` per filled polygon, added via
      ## `graph.addZoneFill` so it indexes like any other copper.
    attrs*: OrderedTable[string, string]
    rev*: int

  Hole* = ref object
    ## A drilled hole: via, plated component hole, or non-plated hole. KiCad
    ## states the span; ODB++ encodes holes as pad features on a drill layer.
    ## `finishedDia` is separate from `drillDia` because ODB++ distinguishes
    ## them.
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
      ## (fiducials, logos).
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
      ## Section name -> netlist component, for a multi-channel package;
      ## `component` is then nil. Empty in the 1:1 case.
    holes*: seq[Hole]
    pcb*: Pcb
    attrs*: OrderedTable[string, string]
      ## KiCad `property` / ODB++ `PRP` and `BOM DATA`: per-part BoM data
      ## from the board file.
    rev*: int

  Outline* = ref object
    ## Board boundary and cutouts.
    ##
    ## Board boundary and cutouts. ODB++ provides it as the step `profile`;
    ## KiCad must be stitched from `Edge.Cuts` with a tolerance, **including
    ## footprint-owned items**.
    boundary*: Polygon
    pieces*: seq[Polygon]
      ## More than one for a panel or a deliberately disjoint board.
    stitchTolerance*: Nm
    attrs*: OrderedTable[string, string]
    rev*: int
      ## Records that the outline changed. The KiCad writer can't write an
      ## outline back (it's stitched), so any edit is out of scope there.

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
      ## Net **name** -> every copper feature on it.
      ##
      ## .. note:: ODB++ net names aren't unique (`$NONE$` repeats with
      ##   disconnected meaning); readers synthesise unique names and keep the
      ##   raw one in `attrs`.
    index*: SpatialIndex
    origin*: Point
      ## Source-file datum for round-tripping (KiCad's `aux_axis_origin`);
      ## `nm(0), nm(0)` if none.
    attrs*: OrderedTable[string, string]
    source*: RootRef
      ## Opaque, format-owned round-trip state (a `KicadDoc`), downcast only
      ## by the format module that set it, so `pcb/` needs no edge to formats.
    rev*: int
      ## Monotonic mutation counter. `graph.touch` bumps it and stamps the
      ## entity's own `rev`, so "changed or created since T" is `e.rev > T`.
      ## `writePcb` takes the byte-copy fast path when `pcb.rev ==
      ## KicadDoc.snapshotRev`.

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
