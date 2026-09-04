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
import nimcir/netlist
include nimcir/schematic/layout

proc part(designator: string, x, y: float, w = 80.0, h = 80.0): SchematicPart =
  SchematicPart(designator: designator, kind: "resistor", symbol: "resistor",
    bodyW: w, bodyH: h, inkW: w, inkH: 20.0, x: x, y: y)

proc parallelPairNetlist(): Netlist =
  ## RL/RR are grounded legs (singleton placement units); RB/CB form a
  ## parallel two-member composite across `left`/`right` between them --
  ## declared leg, pair, leg so the composite lands *between* two singletons,
  ## exercising the arena's ascending-first-member `topLevel` interleave
  ## directly rather than only the trivial all-singletons-then-composite case.
  result = newNetlist("parallel_pair")
  let left = addNet(result, newNet("left"))
  let right = addNet(result, newNet("right"))
  let gnd = addNet(result, newNet("0", ntGround))
  let rl = addComponent(result, newComponent("RL", kind = "resistor"))
  discard connect(rl, "1", left, ptPassive)
  discard connect(rl, "2", gnd, ptGround)
  let rb = addComponent(result, newComponent("RB", kind = "resistor"))
  discard connect(rb, "1", left, ptPassive)
  discard connect(rb, "2", right, ptPassive)
  let cb = addComponent(result, newComponent("CB", kind = "capacitor"))
  discard connect(cb, "1", left, ptPassive)
  discard connect(cb, "2", right, ptPassive)
  let rr = addComponent(result, newComponent("RR", kind = "resistor"))
  discard connect(rr, "1", right, ptPassive)
  discard connect(rr, "2", gnd, ptGround)

proc constrainedState(nl: Netlist): LayoutState =
  ## `prepare` alone is enough to populate `state.composites` (`planComposites`
  ## runs there) for a guard check, but not enough for `routeScene` to run
  ## without crashing (`state.rots` stays unset). Mirrors `layout(nl,
  ## options)`'s own constrained-policy sequence (`layout.nim`) so a caller
  ## that goes on to route sees the same state a real `layout` call would.
  var options = defaultLayoutOptions()
  options.policy = lpConstrainedLayered
  result = LayoutState(nl: nl, options: options)
  prepare(result)
  forcePlace(result)
  constrainedRefine(result)
  restoreCompositeOffsets(result)
  snapToGrid(result)
  separate(result)
  let group = groupsOf(result)
  packGroups(result, group)
  restoreCompositeOffsets(result)
  result.rots = constrainedRecomputeRotations(result)
  repairTerminalClearance(result)
  restoreCompositeOffsets(result)
  result.rots = constrainedRecomputeRotations(result)
  result.routing = recoverRouting(result)

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

test "translateRoutedComponent refuses to move a composite member":
  var state = constrainedState(parallelPairNetlist())
  let idx = state.idxOf["RB"]
  # Sanity: RB really is recognised as a composite member here, not a leaf --
  # otherwise this test would pass for the wrong reason.
  check state.composites.ownerOf[idx] != idx
  let savedPos = state.pos
  let savedRouting = state.routing
  check not translateRoutedComponent(state, "RB", 40.0, 0.0)
  check state.pos == savedPos
  check state.routing == savedRouting

test "translateRoutedComponent still allows a non-composite (leaf) part":
  var state = constrainedState(parallelPairNetlist())
  check state.routing.ok
  let idx = state.idxOf["RL"]
  check state.composites.ownerOf[idx] == idx
  # A zero-distance move changes nothing, so it must succeed identically --
  # this is specifically checking RL is not refused by the composite-member
  # guard (which does not apply, `ownerOf[idx] == idx`), not that arbitrary
  # moves succeed.
  check translateRoutedComponent(state, "RL", 0.0, 0.0)

test "the composite arena stays depth-1 with topLevel in ascending first-member order":
  let state = constrainedState(parallelPairNetlist())
  var lastFirst = -1
  var sawComposite = false
  for idx in state.composites.topLevel:
    let it = state.composites.items[idx]
    if it.raw < 0:
      sawComposite = true
      # Depth 1: every child of a top-level composite is itself a leaf, never
      # another composite -- Stage 1 registers one kind and never nests.
      for c in it.children:
        check state.composites.items[c].raw >= 0
    let first = rawMembers(state.composites, idx)[0]
    check first > lastFirst
    lastFirst = first
  # RL, [RB+CB], RR: the composite must actually have been recognised, or the
  # ordering check above only exercised leaves.
  check sawComposite
