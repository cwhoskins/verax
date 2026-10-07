## Renderer-neutral schematic scene: the pure-data contract between layout
## (`layout.nim`) and the writers (`svg.nim`, `json.nim`). No SVG, DOM or
## JSON types here, so layout is testable without a renderer. World units
## throughout; the SVG writer owns pixels and colours.

type
  Point* = object
    x*, y*: float

  BundleMember* = object
    ## One declared pin/port a merged bundle pin, port or wire stands for:
    ## `name` the drawn member name, `net` the scalar net it lowered to.
    name*, net*: string

  PinMark* = enum
    ## What a renderer draws at a pin beyond the wire. `pmNone` is ordinal 0
    ## and the zero value, so older archives are unchanged and the writer
    ## omits it. Set only on an array representative's pin.
    pmNone
    pmBusBar    ## a short thick perpendicular tick: N members, one shared net
    pmBusSlash  ## a diagonal slash: N members, N distinct nets, one drawn wire
    pmForkCap   ## 2-3 diverging prongs: an irregular binding across members

  SchematicPin* = object
    ## One pin of a placed part, at an absolute world position, with its net
    ## name ("" when unconnected).
    name*: string
    x*, y*: float
    net*: string
    members*: seq[BundleMember]
      ## Only on a merged bundle pin (the member (name, net) pairs; `net` is
      ## then `Bundle.display`) or an array representative's pin (one entry
      ## per member: designator and binding, "" when open).
    mark*: PinMark
      ## A glyph at the pin beyond its wire; `pmNone` for ordinary pins.
    tag*: string
      ## Text beside a marked array pin (`"cs[1:8]"`, `"3*8"`); "" otherwise.

  WireKind* = enum
    ## New kinds are appended so archived ordinals stay valid. Width
    ## (`members.len`) says a wire collapses several nets; kind says what the
    ## net is. `wkChain`: an array's collapsed link chain between two pins of
    ## the representative (`svg` draws it curved). `wkPowerLink`: a
    ## ground/rail composite's internal fanout, drawn like `wkSignal` -- not
    ## `wkGround`/`wkSupply`, which would add a misplaced glyph.
    wkSignal, wkGround, wkSupply, wkBus, wkInterface, wkChain, wkPowerLink

  SchematicPart* = object
    designator*: string
      ## The netlist designator: a **join key** for `finish`/`routing`/
      ## `placement`, never rewritten.
    label*: string
      ## The visible label when it differs from `designator` (`"U10A"`,
      ## `"X1..X8"`); `""` otherwise.
    kind*: string
    name*: string
    value*: string
    symbol*: string
      ## Which symbol the SVG writer draws: "resistor", "capacitor",
      ## "inductor", "diode", "passive", "voltage_source", "current_source",
      ## "source4", "transistor", or "box".
    isBox*: bool
    bodyW*, bodyH*: float
      ## Pin-to-pin extents in world units, from which separation and obstacle
      ## rects are built. A symbol's drawn ink is smaller (`inkW`/`inkH`); a
      ## box's drawn rectangle is inset by `layout.boxStub`, with pin stubs.
    inkW*, inkH*: float
      ## Extent of the drawn symbol at rotation 0; label offsets are measured
      ## from it. Swapped at 90/270.
    x*, y*: float
    rotation*: float
      ## 0, 90, 180 or 270, chosen by `layout` for a square two-terminal part
      ## to minimise pin-to-net-mate distance. The SVG writer rotates the body;
      ## labels stay upright. Always 0 for boxes and other symbols.
    mirror*: bool
      ## Reflected about the part's vertical axis, after `rotation`. Boxes
      ## only: `layout` bakes it into slot coordinates, so no SVG transform is
      ## needed. Asymmetric symbols would need a real transform (and for a
      ## horizontal two-terminal symbol mirror-X equals `rotate(180)`).
    pins*: seq[SchematicPin]
    count*: int
      ## `>= 2` only on an array representative: how many instances it stands
      ## for; 0 elsewhere. `designator` stays the representative's own.
    members*: seq[string]
      ## The collapsed instances' designators in insertion order
      ## (`members[0] == designator`); empty elsewhere.

  SchematicWire* = object
    net*: string
    kind*: WireKind
    members*: seq[string]
      ## Member net names in `nl.nets` order; empty for a scalar wire. A
      ## collapsed bus route has `members.len >= 2` and `net` = the bundle's
      ## scene identity.
    points*: seq[Point]
      ## Axis-aligned polyline. Same-net wires may share a vertex but never a
      ## positive-length collinear segment. Different-net wires may cross
      ## perpendicularly but never touch collinearly and keep
      ## `wireMinSeparation` when parallel.

  SchematicJunction* = object
    net*: string
    x*, y*: float

  TextAnchor* = enum
    taStart, taMiddle, taEnd

  LabelRole* = enum
    lrNet          ## a signal net's name, placed near one of its pins
    lrDesignator   ## a part's reference designator ("R1")
    lrValue        ## a part's value ("10k")
    lrRail         ## a supply-rail net name, placed at the rail stub

  SchematicLabel* = object
    ## Free-standing text, placed by `layout`'s label pass and only rendered
    ## by the SVG writer. `x` is the origin per `anchor`; `y` the baseline.
    text*: string
    x*, y*: float
    anchor*: TextAnchor
    size*: float
      ## Font size in world units. `<= 0` means "use the writer's default".
    role*: LabelRole
    owner*: string
      ## The owning part's designator for `lrDesignator`/`lrValue`; "" for
      ## net/rail labels.

  PortDirection* = enum
    pdUnspecified, pdInput, pdOutput, pdBidir

  SchematicPort* = object
    ## One `ports` entry, drawn as a port symbol where its net meets the
    ## sheet edge. Its stub is a plain `wkSignal` wire.
    name*: string
      ## The published port name, which need not be the net's own name.
    net*: string
    dir*: PortDirection
    x*, y*: float
      ## Body centre, in world units.
    bodyW*, bodyH*: float
    rotation*: float
      ## 0: body extends right (output/bidirectional); 180: left
      ## (input/unspecified).
    members*: seq[BundleMember]
      ## Only on a merged bundle port: member (name, net) pairs; `net` is then
      ## `Bundle.display`.

  FallbackKind* = enum
    ## `fbUnrouted` is ordinal 0 and the zero value, so older archives are
    ## unchanged and the writer omits it.
    fbUnrouted     ## a route failed: dashed amber, open-circle cap
    fbNetLabel     ## deliberately connected by name (a bus/interface broken
                   ## out across three-plus endpoints, or an unroutable
                   ## bundle): solid teal, chevron cap

  SchematicFallback* = object
    ## One pin whose net couldn't be routed (a dangling single pin, or a
    ## failed route): a short dashed stub with an open-end marker and the net
    ## name. A marker of intent, never connectivity -- it doesn't join
    ## occupancy or steer other routes. Empty `points` means zero-space
    ## (marker and label only).
    kind*: FallbackKind
      ## `fbUnrouted` unless a deliberate net-label tag. `diagnostics` skips
      ## `fbNetLabel` records (no channel was ever reserved).
    bundle*: string
      ## The owning bundle's `display` for `fbNetLabel`; "" otherwise.
    net*: string
      ## The exact net name, used verbatim for the fallback's label.
    part*: string
      ## The owning part's designator; "" for a port connection point.
    pin*: string
      ## The pin name; "" for a port connection point.
    x*, y*: float
      ## The pin position: the marker and label anchor.
    ex*, ey*: float
      ## The pin's outward escape direction (±x/±y); the label pass keeps the
      ## name off that side.
    points*: seq[Point]
      ## The dashed stub from the pin outward; empty when zero-space.

  SchematicDivider* = object
    ## The power band's dashed dividing rule (`state.enforcePowerBand`).
    ## Additive to schema version 1: absent when no unit is power-classified.
    y*: float
      ## The rule's y; everything at or below it is the power section.
    x1*, x2*: float
      ## Horizontal extent, from the finished scene bounds.
    label*: string
      ## Caption at the left end ("POWER"); "" for none. Not a
      ## `SchematicLabel`, so never placed by the label pass.

  Schematic* = object
    ## The renderable view of one netlist level, plus its world bounding box.
    title*: string
    parts*: seq[SchematicPart]
    wires*: seq[SchematicWire]
    junctions*: seq[SchematicJunction]
    labels*: seq[SchematicLabel]
    ports*: seq[SchematicPort]
    fallbacks*: seq[SchematicFallback]
    dividers*: seq[SchematicDivider]
      ## Power-band rules; empty with no power-classified unit.
    minX*, minY*, maxX*, maxY*: float

proc `+`*(a, b: Point): Point {.inline.} = Point(x: a.x + b.x, y: a.y + b.y)
proc `-`*(a, b: Point): Point {.inline.} = Point(x: a.x - b.x, y: a.y - b.y)
proc `*`*(p: Point, s: float): Point {.inline.} = Point(x: p.x * s, y: p.y * s)
proc `*`*(s: float, p: Point): Point {.inline.} = p * s
proc `+=`*(a: var Point, b: Point) {.inline.} =
  a.x += b.x
  a.y += b.y
proc `-=`*(a: var Point, b: Point) {.inline.} =
  a.x -= b.x
  a.y -= b.y
