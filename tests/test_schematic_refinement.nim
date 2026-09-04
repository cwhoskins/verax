## `verifyPartPlacement`/`verifyWireRouting` (`schematic/refinement.nim`) are
## private move-validators over `LayoutState` -- intentionally not part of the
## public `Schematic` API (see `schematic/CLAUDE.md`: layout/routing state
## "must never be added to public `Schematic`"). Reaching them for testing
## therefore uses `include`, not `import`: splicing `layout.nim`'s source into
## this file's own module makes its private symbols ordinary top-level
## symbols of *this* module, with no change to what the library exports.
##
## Geometry throughout uses the module's own constants (`routingClearance`,
## `wireMinSeparation`) rather than hand-picked numbers, so a test keeps
## meaning if either constant is ever retuned.

import std/unittest
include nimcir/schematic/layout

proc part(designator: string, x, y: float, w = 80.0, h = 80.0): SchematicPart =
  SchematicPart(designator: designator, kind: "resistor", symbol: "resistor",
    bodyW: w, bodyH: h, inkW: w, inkH: 20.0, x: x, y: y)

test "verifyPartPlacement allows a move that clears every other part":
  var st: LayoutState
  st.routing.parts = @[part("R1", 0.0, 0.0), part("R2", 200.0, 0.0)]
  let farAway = part("R1", -300.0, 0.0)
  check verifyPartPlacement(farAway, st)

test "verifyPartPlacement rejects a move that overlaps another part":
  var st: LayoutState
  st.routing.parts = @[part("R1", 0.0, 0.0), part("R2", 200.0, 0.0)]
  let intoR2 = part("R1", 180.0, 0.0)
  check not verifyPartPlacement(intoR2, st)

test "verifyPartPlacement allows two inflated bodies to touch, not overlap":
  var st: LayoutState
  st.routing.parts = @[part("R1", 0.0, 0.0), part("R2", 200.0, 0.0)]
  # Half-bodies (40) plus routingClearance (12) on each side sum to exactly
  # 104 -- the closest R1 can get without a positive-area intersection.
  let touching = part("R1", 200.0 - 2.0 * (40.0 + routingClearance), 0.0)
  check verifyPartPlacement(touching, st)

test "verifyPartPlacement excludes the part's own prior position":
  var st: LayoutState
  st.routing.parts = @[part("R1", 0.0, 0.0)]
  # R1 checked against its own unchanged entry must not conflict with itself.
  check verifyPartPlacement(part("R1", 0.0, 0.0), st)

test "verifyPartPlacement rejects a move that overlaps a port body":
  var st: LayoutState
  st.routing.ports = @[SchematicPort(name: "OUT", net: "vout", dir: pdOutput,
    x: 300.0, y: 0.0, bodyW: 60.0, bodyH: 30.0, rotation: 0.0)]
  check not verifyPartPlacement(part("R1", 300.0, 0.0), st)

test "verifyWireRouting allows a perpendicular crossing":
  var st: LayoutState
  st.routing.wires = @[SchematicWire(net: "n1", kind: wkSignal,
    points: @[Point(x: 0.0, y: 0.0), Point(x: 100.0, y: 0.0)])]
  let crossing = SchematicWire(net: "n2", kind: wkSignal,
    points: @[Point(x: 50.0, y: -20.0), Point(x: 50.0, y: 20.0)])
  check verifyWireRouting(crossing, st)

test "verifyWireRouting rejects a parallel run closer than wireMinSeparation":
  var st: LayoutState
  st.routing.wires = @[SchematicWire(net: "n1", kind: wkSignal,
    points: @[Point(x: 0.0, y: 0.0), Point(x: 100.0, y: 0.0)])]
  let tooClose = SchematicWire(net: "n2", kind: wkSignal,
    points: @[Point(x: 0.0, y: wireMinSeparation - 1.0),
              Point(x: 100.0, y: wireMinSeparation - 1.0)])
  check not verifyWireRouting(tooClose, st)
  let clear = SchematicWire(net: "n2", kind: wkSignal,
    points: @[Point(x: 0.0, y: wireMinSeparation),
              Point(x: 100.0, y: wireMinSeparation)])
  check verifyWireRouting(clear, st)

test "verifyWireRouting rejects a different net touching end-to-end":
  var st: LayoutState
  st.routing.wires = @[SchematicWire(net: "n1", kind: wkSignal,
    points: @[Point(x: 0.0, y: 0.0), Point(x: 100.0, y: 0.0)])]
  let endToEnd = SchematicWire(net: "n2", kind: wkSignal,
    points: @[Point(x: 100.0, y: 0.0), Point(x: 150.0, y: 0.0)])
  check not verifyWireRouting(endToEnd, st)

test "verifyWireRouting ignores collinear overlap with the wire's own net":
  var st: LayoutState
  # Two branches of the same tree may share a run; that invariant belongs to
  # the router growing the tree, not to this move-validator.
  st.routing.wires = @[SchematicWire(net: "n1", kind: wkSignal,
    points: @[Point(x: 0.0, y: 0.0), Point(x: 100.0, y: 0.0)])]
  let sameNet = SchematicWire(net: "n1", kind: wkSignal,
    points: @[Point(x: 20.0, y: 0.0), Point(x: 80.0, y: 0.0)])
  check verifyWireRouting(sameNet, st)

test "verifyWireRouting rejects a path through another part's body":
  var st: LayoutState
  st.routing.parts = @[part("R1", 200.0, 0.0)]
  let throughBody = SchematicWire(net: "n1", kind: wkSignal,
    points: @[Point(x: 100.0, y: 0.0), Point(x: 300.0, y: 0.0)])
  check not verifyWireRouting(throughBody, st)
  let besideBody = SchematicWire(net: "n1", kind: wkSignal,
    points: @[Point(x: 100.0, y: 200.0), Point(x: 300.0, y: 200.0)])
  check verifyWireRouting(besideBody, st)

test "verifyWireRouting rejects a path through a ground stub's terminal glyph":
  var st: LayoutState
  # A ground stub's last two points are what `terminalGlyphSegments` reads to
  # draw the three ground bars; a signal cutting across them must be rejected
  # even though it never touches the stem itself.
  st.routing.wires = @[SchematicWire(net: "0", kind: wkGround,
    points: @[Point(x: 0.0, y: 0.0), Point(x: 0.0, y: 40.0)])]
  let throughBars = SchematicWire(net: "n1", kind: wkSignal,
    points: @[Point(x: -20.0, y: 40.0), Point(x: 20.0, y: 40.0)])
  check not verifyWireRouting(throughBars, st)
