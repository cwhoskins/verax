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
      ## Body extents in world units. For a box this is the drawn rectangle;
      ## for a symbol it is the pin-to-pin extent used to offset labels.
    x*, y*: float
    rotation*: float
      ## One of 0, 90, 180, 270 degrees. `layout` picks it for an eligible
      ## square two-terminal part as the orientation that minimises its pins'
      ## distance to their net-mates -- so it fixes both the pin axis and which
      ## end each pin takes. The SVG writer rotates the body by this angle
      ## around the part centre and keeps the labels upright. Always 0 for
      ## boxes and for non-two-terminal symbols.
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

  SchematicLabel* = object
    text*: string
    x*, y*: float

  Schematic* = object
    ## The renderable view of one netlist level: placed parts, per-net wires,
    ## junction dots and net labels, plus the world-space bounding box.
    title*: string
    parts*: seq[SchematicPart]
    wires*: seq[SchematicWire]
    junctions*: seq[SchematicJunction]
    labels*: seq[SchematicLabel]
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
