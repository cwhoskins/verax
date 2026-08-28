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

  SchematicPin* = object
    ## One pin of a placed part, at an absolute world position, carrying the
    ## net name it connects to ("" when unconnected).
    name*: string
    x*, y*: float
    net*: string

  WireKind* = enum
    wkSignal, wkGround, wkSupply

  SchematicPart* = object
    designator*: string
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

  SchematicWire* = object
    net*: string
    kind*: WireKind
    points*: seq[Point]
      ## Axis-aligned polyline. Two distinct wires may share a vertex and may
      ## cross perpendicularly, but never overlap along a positive-length
      ## collinear segment (see `layout.nim`).

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
