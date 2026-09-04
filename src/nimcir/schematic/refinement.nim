# import std/[algorithm, math, sets, strutils, tables]
# import ../netlist/types
# import ../netlist/kinds
# import ../netlist/annotations
# import ./scene
# import ./pipeline
#
# include ./geometry
# include ./symbols
# include ./router
# include ./labels
# include ./placement
# include ./constrained
# include ./state
# include ./routing
# include ./finish

type
  LayoutError = enum
    NO_ERROR = 0
    ERROR = -1

proc countbends(x: seq[SchematicWire]): int =
  return foldl(x,a+b.points.len()-2,0) + x.len()-1

proc refineRouting(state: var LayoutState) =
  var wires = state.routing.wires.filterIt(it.kind == wkSignal)
  var netwires = initOrderedTable[string,seq[SchematicWire]]()
  const MovableComponents = ["resistor", "capacitor"]
  for w in mitems(wires):
    if w.points.len() >= 3:
      # Sometimes there is an additional point on a line, just filter them out for now
      for idx in countdown(len(w.points)-2,1):
        if (w.points[idx].x == w.points[idx+1].x and w.points[idx].x == w.points[idx-1].x) or
            (w.points[idx].y == w.points[idx+1].y and w.points[idx].y == w.points[idx-1].y):
          w.points.delete(idx)
          
    if w.net in netwires:
      netwires[w.net].add(w)
    else:
      netwires[w.net] = @[w]
  netwires.sort(proc (x, y: (string, seq[SchematicWire])): int =
    cmp(x[1].countbends(), y[1].countbends())
  )
  # Create an initial list of anchored parts that shouldn't be moved
  var anchors = newSeqOfCap[SchematicPart](state.routing.parts.len())
  for p in state.routing.parts:
    if p.kind notin MovableComponents:
      anchors.add(p)
  # Get the non-power/ground nets connected to the anchored parts
  # and add them to the list of nets to straighten
  for a in anchors:
    for p in a.pins:
      discard
  # Loop through the nets and try to straighten them
  # Regardless of the result add the moved components to the anchored list
  # and add their nets to the next iteration
      
  for n, w in netwires:
    echo n, ": ", w.countbends()
    echo w

proc portObstacle(p: SchematicPort): Obstacle =
  let hw = p.bodyW / 2.0 + routingClearance
  let hh = p.bodyH / 2.0 + routingClearance
  Obstacle(x1: p.x - hw, y1: p.y - hh, x2: p.x + hw, y2: p.y + hh)

proc verifyPartPlacement(part: SchematicPart, state: LayoutState): bool =
  ## True when `part`'s `routingClearance`-inflated body -- the same
  ## inflation `separate` legalizes placement against and the router builds
  ## its obstacle set from -- does not overlap any other part or port already
  ## in `state.routing`. A part sharing `part`'s own designator is excluded
  ## from the comparison, so passing back the part's own (moved) copy checks
  ## it against everything *else* on the sheet. Intended to be called after a
  ## manual part move, to confirm the new position is still legal before it
  ## is accepted.
  let hw = part.bodyW / 2.0 + routingClearance
  let hh = part.bodyH / 2.0 + routingClearance
  let here = Obstacle(x1: part.x - hw, y1: part.y - hh,
                      x2: part.x + hw, y2: part.y + hh)
  var others: seq[SchematicPart]
  for p in state.routing.parts:
    if p.designator != part.designator: others.add p
  for other in obstaclesFor(others):
    if obstaclesOverlap(here, other): return false
  for p in state.routing.ports:
    if obstaclesOverlap(here, portObstacle(p)): return false
  true

proc verifyWireRouting(wire: SchematicWire, state: LayoutState): bool =
  ## True when `wire` -- a candidate manually re-routed net polyline, in
  ## scene coordinates -- conflicts with no other visual component in
  ## `state.routing`: none of its segments enters the interior of any part's
  ## or port's inflated body, threads a rail/ground terminal's drawn glyph
  ## ink, or touches another net's wire under the router's hard cross-net
  ## rule (no collinear touch, not even end-to-end, and at least
  ## `wireMinSeparation` of centreline separation wherever a parallel run's
  ## projections overlap). Other wires of `wire.net` are excluded: they are
  ## `wire`'s own branches, not another visual component, and the within-net
  ## no-positive-overlap invariant is the router's own concern when it grows
  ## a net's tree, not this check's. Intended to be called after a wire is
  ## manually re-routed, to confirm the new path is still legal before it is
  ## accepted.
  var obstacles = obstaclesFor(state.routing.parts)
  for p in state.routing.ports: obstacles.add portObstacle(p)
  var glyphs: seq[OccSeg]
  for w in state.routing.wires:
    for g in terminalGlyphSegments(w):
      glyphs.add g
  for k in 0 ..< wire.points.high:
    let a = wire.points[k]
    let b = wire.points[k + 1]
    if segBlocked(a, b, obstacles): return false
    for g in glyphs:
      if segmentsTouch(a, b, g.a, g.b): return false
    for other in state.routing.wires:
      if other.net == wire.net: continue
      for j in 0 ..< other.points.high:
        if collinearClosed(a, b, other.points[j], other.points[j + 1]): return false
        if parallelTooClose(a, b, other.points[j], other.points[j + 1]): return false
  true

proc translateRoutedComponent(state: var LayoutState, designator: string,
                              dx, dy: float): bool =
  ## Moves the already-placed-and-routed part `designator` by (`dx`, `dy`)
  ## and rebuilds the sheet's routing against the new position: every signal
  ## wire, every rail/ground stub ("power port"), and every fallback
  ## marker -- the anchor `finishLabels` later hangs a net-name label off of,
  ## since `LayoutState` itself carries no realized `SchematicLabel`s to move.
  ## `state.pos` is what `routeScene` reads for a part's centre;
  ## `state.routing.parts[i].x`/`y` is only a routed *snapshot* of it, so
  ## this writes the move there rather than into the routed copy directly.
  ##
  ## The move commits only when the fresh routing both completes in full
  ## (`RoutingState.ok`) and the moved part's new, `routingClearance`-inflated
  ## body clears every other part and port (`verifyPartPlacement`). A
  ## complete route does not by itself rule that out -- routing legality is
  ## about wires, never about a body sitting on top of another one -- so it is
  ## checked separately; `verifyWireRouting` is not, since a wire the router
  ## just emitted has already satisfied it by construction (the router's own
  ## obstacle/occupancy rules are the same primitives that proc checks). On
  ## either failure `state.pos` and `state.routing` are restored to exactly
  ## what they were and the move is refused, so a caller never has to tell
  ## "rejected" apart from "applied, then undone".
  ##
  ## Moves one part at a time: a member of a constrained-layout composite unit
  ## moved alone would leave its partner behind rather than translating as one
  ## rigid body, so a composite member is refused outright rather than
  ## silently breaking `restoreCompositeOffsets`' canonical-offset invariant.
  ## Moving a whole composite is outside this proc's scope.
  if designator notin state.idxOf: return false
  let idx = state.idxOf[designator]
  if state.options.policy == lpConstrainedLayered and
     state.composites.ownerOf[idx] != idx:
    return false
  let savedPos = state.pos[idx]
  let savedRouting = state.routing

  state.pos[idx] = Point(x: savedPos.x + dx, y: savedPos.y + dy)
  let rerouted = routeScene(state, withFallbacks = true)
  state.routing = rerouted

  var moved: SchematicPart
  var found = false
  for p in rerouted.parts:
    if p.designator == designator:
      moved = p
      found = true
      break

  if rerouted.ok and found and verifyPartPlacement(moved, state):
    return true

  state.pos[idx] = savedPos
  state.routing = savedRouting
  false

