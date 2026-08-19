## Core data model for a physical printed circuit board.
##
## The electrical side is **not** re-modelled here: a `Pcb` owns a `Netlist`
## from `nimcir/netlist`, built through the existing `netlist/graph` API, and
## every PCB entity holds a *forward* reference into it (`Copper.net: Net`,
## `Placement.component: Component`, `Copper.pin: Pin`). `netlist/types` is
## untouched and stays geometry-free, so a netlist-only consumer carries none
## of this weight -- while an analysis pass can still walk from a trace to the
## pins it connects in a single hop.
##
## Two lookups are first-class, matching what layout analysis actually asks:
## by **net name** (`Pcb.netCopper`) and by **location**
## (`Pcb.index`, see `nimcir/pcb/index`).
##
## As everywhere else in this codebase, mutation goes through one module --
## `nimcir/pcb/graph` -- which is the only place allowed to set the
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
    ## `nimcir/pcb/index`; only the storage is declared here so `Pcb` can
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
      ## Set by `nimcir/pcb/graph` on any mutation; `index.rebuild` clears it.

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
    pcb*: Pcb
    attrs*: OrderedTable[string, string]

  Copper* = ref object
    ## One conductive (or, when `negative`, clearance-defining) feature.
    kind*: CopperKind
    shape*: Shape
    box*: Box
      ## Cached bounding box, maintained by `nimcir/pcb/graph`.
    layer*: PcbLayer
    net*: Net
      ## `nimcir/netlist` net, or `nil` for no net.
    pin*: Pin
      ## Set on `ckLand`: the pin this land serves.
    hole*: Hole
      ## Set on `ckViaPad` and on plated-through lands.
    negative*: bool
      ## This feature *erases* copper (ODB++ polarity `N`).
    sourceIndex*: int
      ## Ordinal within `layer.copper` as read (ODB++ `FID` feature number).
    attrs*: OrderedTable[string, string]

  Zone* = ref object
    ## An authored copper pour, plane, or keepout/rule area.
    ##
    ## Only the *authored* outline is modelled. Derived fill geometry (KiCad
    ## `filled_polygon`, ODB++ `SNT PLN` surfaces) is deliberately out of
    ## scope for now; adding a `fills` field later is purely additive. Until
    ## then, plane-shape, return-path and power-integrity analysis cannot be
    ## answered from this model.
    name*: string
    net*: Net
    isKeepout*: bool
    priority*: int
    outline*: Polygon
      ## Layer-independent, as drawn.
    layers*: seq[PcbLayer]
      ## Multi-layer zones are normal in both formats.
    areas*: seq[Copper]
      ## One `ckZone` record per layer.
    attrs*: OrderedTable[string, string]

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

  Placement* = ref object
    ## A component instance placed on the board.
    designator*: string
      ## Key in `Pcb.placements`; matches `Component.designator`.
    component*: Component
      ## `nimcir/netlist` component, or `nil` for a board-only footprint
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
    holes*: seq[Hole]
    pcb*: Pcb
    attrs*: OrderedTable[string, string]
      ## KiCad `property` nodes / ODB++ `PRP` records and `BOM DATA` block.
      ## This is where per-part BoM data from the board file lands.

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

  Pcb* = ref object
    name*: string
    netlist*: Netlist
      ## The electrical model, built with `nimcir/netlist/graph`.
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
      ## Source-file datum, retained for round-tripping.
    attrs*: OrderedTable[string, string]

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
