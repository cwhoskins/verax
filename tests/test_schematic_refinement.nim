## `verifyPartPlacement`/`verifyWireRouting` are private move-validators
## over `LayoutState`, kept out of the public `Schematic` API. They're
## reached by `include`, which makes the private symbols local.
##
## Geometry uses the module's constants (`routingClearance`,
## `wireMinSeparation`), so tests survive retuning.

import std/unittest
import verax/netlist
include verax/schematic/layout
import designs/lib/spi_dev

proc part(designator: string, x, y: float, w = 80.0, h = 80.0): SchematicPart =
  SchematicPart(designator: designator, kind: "resistor", symbol: "resistor",
    bodyW: w, bodyH: h, inkW: w, inkH: 20.0, x: x, y: y)

proc parallelPairNetlist(): Netlist =
  ## RL/RR are grounded singleton legs; RB/CB a parallel composite declared
  ## between them, exercising the arena's `topLevel` interleave.
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
  ## `prepare` fills `state.composites` but leaves `state.rots` unset, so this
  ## follows `layout`'s constrained-policy sequence before routing.
  var options = defaultLayoutOptions()
  options.policy = lpConstrainedLayered
  result = LayoutState(nl: nl, options: options)
  prepare(result)
  forcePlace(result)
  constrainedRefine(result)
  restoreCompositeOffsets(result)
  chooseCompositeOrientation(result)
  snapToGrid(result)
  separate(result)
  let group = groupsOf(result)
  packGroups(result, group)
  restoreCompositeOffsets(result)
  constrainedRecomputeRotations(result)
  repairTerminalClearance(result)
  restoreCompositeOffsets(result)
  constrainedRecomputeRotations(result)
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
  # Half-bodies (40) plus routingClearance on each side: the closest R1 can
  # get without overlap.
  let touching = part("R1", 200.0 - 2.0 * (40.0 + routingClearance), 0.0)
  check verifyPartPlacement(touching, st)

test "verifyPartPlacement excludes the part's own prior position":
  var st: LayoutState
  st.routing.parts = @[part("R1", 0.0, 0.0)]
  # R1 against its own unchanged entry doesn't conflict with itself.
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
  # Two branches of one tree may share a run; that's the router's concern.
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
  # A ground stub's last two points draw the ground bars; a signal crossing
  # them is rejected even if it misses the stem.
  st.routing.wires = @[SchematicWire(net: "0", kind: wkGround,
    points: @[Point(x: 0.0, y: 0.0), Point(x: 0.0, y: 40.0)])]
  let throughBars = SchematicWire(net: "n1", kind: wkSignal,
    points: @[Point(x: -20.0, y: 40.0), Point(x: 20.0, y: 40.0)])
  check not verifyWireRouting(throughBars, st)

test "translateRoutedComponent refuses to move a composite member":
  var state = constrainedState(parallelPairNetlist())
  let idx = state.idxOf["RB"]
  # Sanity: RB is a composite member, so the test passes for the right reason.
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
  # A zero move must succeed: RL isn't a composite member, so the guard
  # doesn't apply.
  check translateRoutedComponent(state, "RL", 0.0, 0.0)

test "the composite arena stays depth-1 with topLevel in ascending first-member order":
  let state = constrainedState(parallelPairNetlist())
  var lastFirst = -1
  var sawComposite = false
  for idx in state.composites.topLevel:
    let it = state.composites.items[idx]
    if it.raw < 0:
      sawComposite = true
      # Depth 1: composites never nest.
      for c in it.children:
        check state.composites.items[c].raw >= 0
    let first = rawMembers(state.composites, idx)[0]
    check first > lastFirst
    lastFirst = first
  # The composite was actually recognised.
  check sawComposite

proc piInputNetlist(): Netlist =
  ## Port IN -> pi section (RL shunt, CIN series, RB shunt) -> mcu input. The
  ## semantic walk must reach UIN through the pi, not stop at RL.
  result = newNetlist("pi_input")
  let inn = addNet(result, newNet("IN"))
  let mid = addNet(result, newNet("mid"))
  let gnd = addNet(result, newNet("0", ntGround))
  let rl = addComponent(result, newComponent("RL", kind = "resistor"))
  discard connect(rl, "1", inn, ptPassive)
  discard connect(rl, "2", gnd, ptGround)
  let cin = addComponent(result, newComponent("CIN", kind = "capacitor"))
  discard connect(cin, "1", inn, ptPassive)
  discard connect(cin, "2", mid, ptPassive)
  let rb = addComponent(result, newComponent("RB", kind = "resistor"))
  discard connect(rb, "1", mid, ptPassive)
  discard connect(rb, "2", gnd, ptGround)
  let u = addComponent(result, newComponent("UIN", kind = "mcu"))
  discard connect(u, "IN", mid, ptInput)
  discard connect(u, "OUT", addNet(result, newNet("out")), ptOutput)
  addPort(result, "IN", inn)

test "constrainedTopology walks through a pi composite to the sink it feeds":
  let st = constrainedState(piInputNetlist())
  let plan = st.composites
  # All three pi members are one pool item -- fails if recognition regressed.
  let pRL = plan.poolOf[st.idxOf["RL"]]
  let pCIN = plan.poolOf[st.idxOf["CIN"]]
  let pRB = plan.poolOf[st.idxOf["RB"]]
  check pRL == pCIN and pCIN == pRB
  let topo = constrainedTopology(st.comps, st.idxOf, plan, ArrayPlan())
  check topo.layers[pCIN] < topo.layers[plan.poolOf[st.idxOf["UIN"]]]

# --- post-route port refinement (refinement.nim) ----------------------------

proc strapSheet(): Netlist =
  ## A sub-sheet whose interface lands in the edge columns: `clk` a
  ## pass-through strap (two ports, one net), plus an input and an output.
  result = newNetlist("STRAP")
  let clk = addNet(result, newNet("clk"))
  let a = addNet(result, newNet("a"))
  let y = addNet(result, newNet("y"))
  let gnd = addNet(result, newNet("0", ntGround))
  let u = addComponent(result, newComponent("U1", kind = "buffer"))
  discard connect(u, "CLK", clk, ptInput)
  discard connect(u, "A", a, ptInput)
  discard connect(u, "Y", y, ptOutput)
  discard connect(u, "GND", gnd, ptGround)
  addPort(result, "clk_in", clk)
  addPort(result, "clk_out", clk)
  addPort(result, "a_in", a)
  addPort(result, "y_out", y)

proc sceneScoreOf(s: Schematic): tuple[fallbacks, bends: int, length: float] =
  result.fallbacks = s.fallbacks.len
  for w in s.wires:
    if w.kind == wkChain: continue
    result.bends += wireBends(w.points)
    result.length += wireLength(w.points)

test "wireBends ignores collinear interior points and zero-length hops":
  check wireBends(@[Point(x: 0.0, y: 0.0), Point(x: 20.0, y: 0.0),
                    Point(x: 40.0, y: 0.0)]) == 0
  check wireBends(@[Point(x: 0.0, y: 0.0), Point(x: 40.0, y: 0.0),
                    Point(x: 40.0, y: 40.0)]) == 1
  check wireBends(@[Point(x: 0.0, y: 0.0), Point(x: 40.0, y: 0.0),
                    Point(x: 40.0, y: 0.0), Point(x: 80.0, y: 0.0)]) == 0

test "betterThan is strict lexicographic: fallbacks, then bends, then length":
  check betterThan((fallbacks: 0, bends: 5, length: 100.0),
                   (fallbacks: 1, bends: 0, length: 10.0))
  check betterThan((fallbacks: 0, bends: 3, length: 999.0),
                   (fallbacks: 0, bends: 4, length: 10.0))
  check betterThan((fallbacks: 0, bends: 3, length: 100.0),
                   (fallbacks: 0, bends: 3, length: 101.0))
  check not betterThan((fallbacks: 0, bends: 3, length: 100.0),
                       (fallbacks: 0, bends: 3, length: 100.0))

test "portTargets ranks a net's long horizontal run above a short one":
  var rs: RoutingState
  rs.ports = @[SchematicPort(name: "P_IN", net: "sig", dir: pdInput,
    x: -100.0, y: 0.0, bodyW: 60.0, bodyH: 24.0)]
  rs.wires = @[
    SchematicWire(net: "sig", kind: wkSignal, points: @[
      Point(x: -70.0, y: 0.0), Point(x: -70.0, y: -160.0),
      Point(x: 200.0, y: -160.0), Point(x: 200.0, y: 240.0),
      Point(x: 240.0, y: 240.0)]),
    SchematicWire(net: "other", kind: wkSignal, points: @[
      Point(x: 0.0, y: 320.0), Point(x: 400.0, y: 320.0)])]
  let t = portTargets(rs)
  check "sig" in t
  check t["sig"][0] == -160.0     # 270-unit run beats the 40-unit run
  check t["sig"].len <= portRefineCandidates

test "refinePortPlacement straightens SPI_DEV's strap wires":
  var off = defaultLayoutOptions()
  off.stages.excl lsPortRefine
  let before = sceneScoreOf(layout(spiDev(), off))
  let after = sceneScoreOf(layout(spiDev()))       # default: lsPortRefine on
  check after.fallbacks == 0
  check after.bends < before.bends
  check after.length <= before.length + 1e-6

test "refinePortPlacement never worsens a scene it touches":
  for nl in [strapSheet(), piInputNetlist(), spiDev()]:
    var off = defaultLayoutOptions()
    off.stages.excl lsPortRefine
    let a = sceneScoreOf(layout(nl, off))
    let b = sceneScoreOf(layout(nl))
    check b.fallbacks <= a.fallbacks
    check not betterThan(a, b)          # b is at least as good as a

test "refinePortPlacement is deterministic":
  check layout(spiDev()) == layout(spiDev())
  check layout(strapSheet()) == layout(strapSheet())

test "refinePortPlacement respects the raw-size ceiling":
    # feedbackMaxParts 0 trips the gate, so the pass is a no-op.
  var gated = defaultLayoutOptions()
  gated.feedbackMaxParts = 0
  var off = gated
  off.stages.excl lsPortRefine
  check layout(spiDev(), gated) == layout(spiDev(), off)
