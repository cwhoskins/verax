## Renderer-neutral schematic scene: the pure-data middle layer between a
## `Netlist` and its SVG/JSON renderings.
##
## Placement and routing (see `layout.nim`) read the netlist graph and produce
## one of these; the writers (`svg.nim`, `json.nim`) consume it. No SVG, no
## DOM and no JSON types live here -- the scene is the contract both sides
## agree on, which is what keeps placement/routing testable without a renderer
## and renderers swappable without touching layout. Everything is in world
## units (floats); the SVG writer owns pixels and colours.

type
  Point* = object
    x*, y*: float

  BundleMember* = object
    ## One declared pin/port that a merged bundle pin, port or wire stands
    ## for. `name` is the drawn member name (a `connectPort` pin name or an
    ## `nl.ports` key), `net` the scalar member net it lowered to. Empty
    ## everywhere except on a collapsed bus/interface (`schematic/bundles.nim`).
    name*, net*: string

  PinMark* = enum
    ## What a renderer draws *at* a pin beyond the wire. `pmNone` is ordinal 0
    ## and the zero value on purpose: every pre-field `SchematicPin` and every
    ## archive written before this field are unchanged, and the writer emits
    ## `mark` only when it is not this. Set only on a collapsed subsheet
    ## array's representative pin (`schematic/arrays.nim`).
    pmNone
    pmBusBar    ## a short thick perpendicular tick: N members, one shared net
    pmBusSlash  ## a diagonal slash: N members, N distinct nets, one drawn wire
    pmForkCap   ## 2-3 diverging prongs: an irregular binding across members

  SchematicPin* = object
    ## One pin of a placed part, at an absolute world position, carrying the
    ## net name it connects to ("" when unconnected).
    name*: string
    x*, y*: float
    net*: string
    members*: seq[BundleMember]
      ## Non-empty only on a merged bundle pin or a collapsed subsheet array's
      ## representative pin. For a bundle: the N declared member (name, net)
      ## pairs the one drawn pin collapses, `net` above then the bundle's
      ## scene identity (`Bundle.display`). For an array pin: one entry per
      ## array member, `name` the member *designator* and `net` its binding
      ## ("" when that member leaves the port open).
    mark*: PinMark
      ## A glyph drawn at the pin beyond its wire; `pmNone` (the zero value)
      ## for every ordinary pin. See `schematic/arrays.nim`.
    tag*: string
      ## Text drawn beside a marked array pin: `"cs[1:8]"` for `pmBusSlash`,
      ## `"3*8"` for `pmForkCap`; "" otherwise.

  WireKind* = enum
    ## `wkBus`/`wkInterface`/`wkChain` are appended so existing ordinals -- and
    ## every archived scene -- are unchanged. Width (`SchematicWire.members.len`)
    ## says a wire collapses more than one net; kind says what the net *is*.
    ## `wkChain` is the collapsed link chain of a repeated subsheet array: its
    ## two endpoints are two pins of the *same* representative part and
    ## `members` carries the N-1 link net names it stands for -- the same "one
    ## wire, several nets" reading a collapsed bundle has. `svg` draws it as a
    ## smooth curve; scene, routing and JSON keep the routed orthogonal points,
    ## exactly as the 4-unit chamfer does.
    wkSignal, wkGround, wkSupply, wkBus, wkInterface, wkChain

  SchematicPart* = object
    designator*: string
      ## The netlist reference designator, and a **join key** -- `finish`/
      ## `routing`/`placement` all key on it, so it is never rewritten.
    label*: string
      ## The visible label when it differs from `designator`: `"U10A"` for a
      ## section of a multi-channel package, `""` otherwise. Renderers draw
      ## `label` when non-empty, else `designator`.
    kind*: string
    name*: string
    value*: string
    symbol*: string
      ## Which symbol the SVG writer draws: "resistor", "capacitor",
      ## "inductor", "diode", "passive", "voltage_source", "current_source",
      ## "source4", "transistor", or "box".
    isBox*: bool
    bodyW*, bodyH*: float
      ## Pin-to-pin extents in world units: the rectangle the pins sit on, and
      ## what the separation and routing-obstacle rects are built from. For a
      ## symbol this is usually larger than the drawn ink (a resistor is
      ## 80 x 80 here but its zigzag is only 80 x 20 -- see `inkW`/`inkH`). For
      ## a box the pins jut out: the *drawn* rectangle is inset from this by
      ## `layout.boxStub` on every side, and each pin connects to it by a stub.
    inkW*, inkH*: float
      ## The extent of the *drawn* symbol at rotation 0 -- for a symbol part
      ## much smaller than the pin-to-pin `bodyW`/`bodyH`. `layout`'s label
      ## pass measures designator/value offsets from this so text sits close to
      ## the visible glyph rather than out at the pin span; obstacle and
      ## separation rects are unaffected. A 90/270 rotation swaps the two.
    x*, y*: float
    rotation*: float
      ## One of 0, 90, 180, 270 degrees. `layout` picks it for an eligible
      ## square two-terminal part as the orientation that minimises its pins'
      ## distance to their net-mates -- so it fixes both the pin axis and which
      ## end each pin takes; a one-net part instead simply faces its lone
      ## net-mate (see `layout`'s leaf-snap pass). The SVG writer rotates the
      ## body by this angle around the part centre; the part's labels are
      ## placed by `layout` outside the rotated group and stay upright.
      ## Always 0 for boxes and for non-two-terminal symbols.
    pins*: seq[SchematicPin]
    count*: int
      ## `>= 2` only on the representative of a collapsed subsheet array: how
      ## many instances this one box stands for. 0 (the zero value)
      ## everywhere else. `designator` stays the representative's own -- it is
      ## a join key `finish`/`routing`/`placement` all key on and is never
      ## rewritten; the *drawn* text is `label` ("X1..X8"), exactly as a
      ## package section's "U10A" is. See `schematic/arrays.nim`.
    members*: seq[string]
      ## The collapsed instances' designators, in graph insertion order; empty
      ## on every other part. `members[0] == designator`.

  SchematicWire* = object
    net*: string
    kind*: WireKind
    members*: seq[string]
      ## Member net names, in `nl.nets` order; empty for a scalar wire. A
      ## collapsed bus/interface route has `members.len >= 2` and `net` set to
      ## the bundle's scene identity; a recoloured-only wire keeps `net` and
      ## leaves this empty.
    points*: seq[Point]
      ## Axis-aligned polyline. Two wires of the *same* net may share a vertex
      ## (and may continue straight through one), but never overlap along a
      ## positive-length collinear segment. Two wires of *different* nets may
      ## cross perpendicularly, but never touch collinearly -- not even
      ## end-to-end -- and keep at least `wireMinSeparation` (8 world units) of
      ## centreline separation wherever they run parallel and their
      ## projections overlap (see `layout.nim`).

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
    ## A free-standing piece of text. `layout` places every one of these
    ## against the finished wire and body geometry (see its label pass); the
    ## SVG writer only renders them. `x` is the SVG text origin interpreted per
    ## `anchor`, `y` is the text baseline.
    text*: string
    x*, y*: float
    anchor*: TextAnchor
    size*: float
      ## Font size in world units. `<= 0` means "use the writer's default".
    role*: LabelRole
    owner*: string
      ## The owning part's designator for `lrDesignator`/`lrValue`; "" for a
      ## net or rail label.

  PortDirection* = enum
    pdUnspecified, pdInput, pdOutput, pdBidir

  SchematicPort* = object
    ## One entry of the netlist's `ports` table, drawn as an Altium-style
    ## port symbol where its net meets the sheet edge. The connecting stub is
    ## a plain `wkSignal` `SchematicWire` on `net`, not carried here.
    name*: string
      ## The published port name, which need not be the net's own name.
    net*: string
    dir*: PortDirection
    x*, y*: float
      ## Body centre, in world units.
    bodyW*, bodyH*: float
    rotation*: float
      ## 0 -- body extends to the right of its connection point (an output or
      ## bidirectional port); 180 -- body extends to the left (an input or an
      ## unspecified port). Never any other value.
    members*: seq[BundleMember]
      ## Non-empty only on a merged bundle port: the declared member
      ## (name, net) pairs. `net` above is then `Bundle.display`.

  FallbackKind* = enum
    ## `fbUnrouted` is ordinal 0 and the zero value on purpose: every
    ## pre-field `SchematicFallback` and every archive written before this
    ## field are unchanged, and the writer only emits `kind` when it is not
    ## this.
    fbUnrouted     ## a route failed: dashed amber, open-circle cap
    fbNetLabel     ## deliberately connected by name (a bus/interface broken
                   ## out across three-plus endpoints, or an unroutable
                   ## bundle): solid teal, chevron cap

  SchematicFallback* = object
    ## One pin whose signal net could not be routed as a real wire: a net with
    ## a single dangling pin, or a net whose route failed under the hard
    ## occupancy rules. It is drawn as a short dashed amber/orange stub leaving
    ## the pin, capped with an open-endpoint marker, with the exact net name
    ## labelled at the pin. A fallback is a marker of intent, never
    ## connectivity: it never joins the occupancy set, never produces a
    ## junction, and cannot steer or be steered by another net's route.
    ## `points` is the stub polyline from the pin outward; when even the short
    ## stub has no room (`points.len == 0`), the fallback is zero-space -- no
    ## wire, only the marker and label at the pin.
    kind*: FallbackKind
      ## `fbUnrouted` (the zero value) unless this is a deliberate net-label
      ## tag. `diagnostics` refuses to diagnose an `fbNetLabel` record: the
      ## scene never reserved a channel for it, so "blocked by occupancy"
      ## would be a false alarm.
    bundle*: string
      ## The owning bundle's scene identity (`Bundle.display`) for an
      ## `fbNetLabel` record; "" otherwise.
    net*: string
      ## The exact net name, used verbatim for the fallback's label.
    part*: string
      ## The owning part's designator; "" for a port connection point.
    pin*: string
      ## The pin name; "" for a port connection point.
    x*, y*: float
      ## The pin position: the marker and label anchor.
    ex*, ey*: float
      ## The pin's outward unit escape direction (one of ±x / ±y), used by
      ## the label pass to keep the fallback name off the side the stub
      ## leaves from.
    points*: seq[Point]
      ## The dashed stub polyline from the pin outward; empty for a
      ## zero-space fallback.

  Schematic* = object
    ## The renderable view of one netlist level: placed parts, per-net wires,
    ## junction dots, net labels and interface ports, plus the world-space
    ## bounding box.
    title*: string
    parts*: seq[SchematicPart]
    wires*: seq[SchematicWire]
    junctions*: seq[SchematicJunction]
    labels*: seq[SchematicLabel]
    ports*: seq[SchematicPort]
    fallbacks*: seq[SchematicFallback]
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
