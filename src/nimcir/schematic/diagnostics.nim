# --- fallback reroute diagnostic --------------------------------------------
# A *final-scene* diagnostic, deliberately not a historical replay: it takes
# the finished `Schematic` (the one archived beside the SVG), rebuilds the
# router's inputs from the scene alone -- obstacles from part/port bodies,
# occupancy from the emitted wires, escape seeds from part pins and ports,
# rail/ground identity from wire kind -- and re-runs `routeNet` for one
# fallback net against that final geometry. The answer is therefore "could
# this net route as a tree in the scene that was actually drawn", not "why
# did it fail at the exact moment the original layout first tried it". The
# occupancy seen by the reroute is the complete final set, and no placement
# feedback move is attempted, so a net that the original layout fell back on
# may (or may not) route here -- either answer is information, and the
# limitation is stated rather than hidden.

type
  RerouteBlockKind* = enum
    ## What a final-scene reroute names as the first-order blocker of an
    ## unreachable pin's escape point.
    rbObstacle
      ## An inflated part/port body blocks the escape point or every edge out
      ## of it -- placement left no routing channel there.
    rbOccupancy
      ## The final scene's own emitted wires block the route (a collinear
      ## touch or a too-close parallel run against a foreign net, or a
      ## same-net collinear overlap).
    rbEscapeSeed
      ## A foreign pin/port's fixed escape stub blocks the route's first hop.

  FallbackReroute* = object
    ## The result of re-routing one fallback net against a finished scene's
    ## final geometry (see the module note above).
    net*: string
      ## The exact fallback net name.
    pins*: int
      ## How many route endpoints the net has in the scene (part pins plus
      ## interface-port connection points). 0 means the net has no endpoint;
      ## 1 means a single dangling pin, which `layout` always draws as a
      ## fallback but never treats as a routing failure.
    routed*: bool
      ## Whether `routeNet` can connect every endpoint as a real tree under
      ## the final occupancy. `true` for a dangling single pin.
    failPin*: int
      ## The index of the first unreachable endpoint when `routed` is false;
      ## -1 otherwise.
    failPart*: string
      ## The owning part's designator of the unreachable endpoint; "" for a
      ## port connection point.
    failPinName*: string
      ## The unreachable pin's name; "" for a port connection point.
    failX*, failY*: float
      ## The unreachable endpoint's world position.
    blockKind*: RerouteBlockKind
      ## The first-order blocker classification when `routed` is false.
    blockDetail*: string
      ## A short human-readable expansion of `blockKind`, including the
      ## offending net or owner name where the scene identifies one.
    polys*: seq[seq[Point]]
      ## When `routed`, the polylines `routeNet` would emit for the net in
      ## the final scene.

proc classifyBlock(a, b: Point, netName: string,
                   occ, seeds, glyphs: seq[OccSeg]):
    tuple[kind: RerouteBlockKind, net: string] =
  ## Which occupancy/seed rule blocks the axis-aligned edge `a`-`b` for
  ## `netName`, together with the offending net. Mirrors `edgeAllowed`;
  ## Its caller invokes this only after `edgeAllowed` rejects the edge.
  for s in occ:
    if s.net == netName:
      if collinearOverlap(a, b, s.a, s.b): return (rbOccupancy, s.net)
    elif collinearClosed(a, b, s.a, s.b) or parallelTooClose(a, b, s.a, s.b):
      return (rbOccupancy, s.net)
  for s in seeds:
    if collinearOverlap(a, b, s.a, s.b): return (rbEscapeSeed, s.net)
  for g in glyphs:
    if segmentsTouch(a, b, g.a, g.b): return (rbOccupancy, g.net)
  doAssert false, "schematic diagnostic: rejected edge has no blocker"
  (rbOccupancy, "")

proc sceneRouterInputs(s: Schematic):
    tuple[railNets: HashSet[string], obstacles: seq[Obstacle],
          owners: seq[string],
          free: tuple[nodes: seq[Point], adj: seq[seq[int]]],
          occ: seq[OccSeg], seeds, glyphs: seq[OccSeg]] =
  ## Rebuilds everything `routeNet` needs from a finished scene alone. Rail
  ## and ground nets are identified by the kind of their emitted stubs, since
  ## a scene no longer carries the netlist's `Net.kind` annotation. Obstacle
  ## owners are kept in parallel so a diagnosis can name the body that blocks
  ## a pin.
  for w in s.wires:
    if w.kind in {wkGround, wkSupply}: result.railNets.incl w.net

  result.obstacles = obstaclesFor(s.parts)
  for p in s.parts: result.owners.add "part " & p.designator
  for p in s.ports:
    let hw = p.bodyW / 2.0 + routingClearance
    let hh = p.bodyH / 2.0 + routingClearance
    result.obstacles.add Obstacle(x1: p.x - hw, y1: p.y - hh,
                                  x2: p.x + hw, y2: p.y + hh)
    result.owners.add "port " & p.name
  for w in s.wires:
    for k in 0 ..< w.points.high:
      addOcc(result.occ, w.points[k], w.points[k + 1], w.net)

  for p in s.parts:
    for pin in p.pins:
      if pin.net.len == 0 or pin.net in result.railNets: continue
      let pt = Point(x: pin.x, y: pin.y)
      addOcc(result.seeds, pt, pt + escapeDir(p, pt) * routingClearance, pin.net)
  for port in s.ports:
    let onRight = abs(port.rotation) < 1e-9
    let hw = port.bodyW / 2.0
    let conn = Point(x: (if onRight: port.x - hw else: port.x + hw), y: port.y)
    let inward = Point(x: (if onRight: -1.0 else: 1.0), y: 0.0)
    addOcc(result.seeds, conn, conn + inward * routingClearance, port.net)

  var escapeTerminals: seq[Point]
  for seed in result.seeds: escapeTerminals.add seed.b
  for w in s.wires:
    for g in terminalGlyphSegments(w):
      result.glyphs.add g
      escapeTerminals.add g.a
      escapeTerminals.add g.b
  result.free = buildFreeGrid(result.obstacles, escapeTerminals)

proc endpointsFor(s: Schematic, net: string):
    tuple[pins: seq[RoutePin], part: seq[string], pinName: seq[string]] =
  ## The route endpoints for `net` in `s`, in the same order `layout` would
  ## have visited them: part pins in part/pin order, then port connection
  ## points. `part`/`pinName` parallel the endpoints for failure reporting
  ## (both "" for a port).
  for pi, p in s.parts:
    for pin in p.pins:
      if pin.net == net:
        result.pins.add (pt: Point(x: pin.x, y: pin.y), partIdx: pi,
                         esc: Point(), pinName: pin.name)
        result.part.add p.designator
        result.pinName.add pin.name
  for port in s.ports:
    if port.net != net: continue
    let onRight = abs(port.rotation) < 1e-9
    let hw = port.bodyW / 2.0
    let conn = Point(x: (if onRight: port.x - hw else: port.x + hw), y: port.y)
    let inward = Point(x: (if onRight: -1.0 else: 1.0), y: 0.0)
    result.pins.add (pt: conn, partIdx: 0, esc: inward, pinName: "")
    result.part.add ""
    result.pinName.add ""

proc blockReason(pin: RoutePin, parts: seq[SchematicPart],
                 escapeNodes: seq[Point], failIdx: int,
                 obstacles: seq[Obstacle], owners: seq[string],
                 free: tuple[nodes: seq[Point], adj: seq[seq[int]]],
                 occ, seeds, glyphs: seq[OccSeg], netName: string):
    tuple[kind: RerouteBlockKind, detail: string] =
  ## A first-order explanation of why the failed pin's escape point is
  ## unreachable. Honest about its depth: it inspects the pin's own escape
  ## point and its first-hop edges only -- a failure that lives deeper in the
  ## grid is reported as occupancy without guessing a specific occupant.
  let d =
    if pin.esc.x != 0.0 or pin.esc.y != 0.0: pin.esc
    else: escapeDir(parts[pin.partIdx], pin.pt)
  let e = pin.pt + d * routingClearance

  const eps = 1e-9
  for i, o in obstacles:
    if e.x > o.x1 + eps and e.x < o.x2 - eps and
       e.y > o.y1 + eps and e.y < o.y2 - eps:
      return (rbObstacle,
        "escape point lies inside the inflated body of " & owners[i])

  var obstacleCount = 0
  var occupancyCount = 0
  var seedCount = 0
  var occupancyNet = ""
  var seedNet = ""
  var allowed = 0

  proc consider(n: Point) =
    if sameCoord(e.x, n.x) and sameCoord(e.y, n.y): return
    if not (sameCoord(e.x, n.x) or sameCoord(e.y, n.y)): return
    if segBlocked(e, n, obstacles):
      inc obstacleCount
      return
    if not edgeAllowed(e, n, netName, occ, seeds, glyphs):
      let blk = classifyBlock(e, n, netName, occ, seeds, glyphs)
      if blk.kind == rbOccupancy:
        inc occupancyCount
        if occupancyNet.len == 0: occupancyNet = blk.net
      elif blk.kind == rbEscapeSeed:
        inc seedCount
        if seedNet.len == 0: seedNet = blk.net
      return
    inc allowed

  for j, node in escapeNodes:
    if j != failIdx: consider(node)
  for node in free.nodes: consider(node)

  if allowed > 0:
    return (rbOccupancy,
      "no route in the free grid under the final occupancy rules " &
      "(the escape point itself can leave)")
  if occupancyCount > 0 or seedCount > 0:
    if occupancyCount > 0 and seedCount == 0:
      return (rbOccupancy,
        "every escape edge is blocked by the final occupancy" &
        (if occupancyNet.len > 0: " (nearest offender: net \"" & occupancyNet & "\")" else: ""))
    if seedCount > 0 and occupancyCount == 0:
      return (rbEscapeSeed,
        "every escape edge threads a foreign escape seed" &
        (if seedNet.len > 0: " (net \"" & seedNet & "\")" else: ""))
    return (rbOccupancy,
      "every escape edge is blocked by occupancy or a foreign escape seed")
  return (rbObstacle,
    "every escape edge is blocked by an inflated body " &
    "(placement left no routing channel out of this pin)")

proc diagnoseFallbackNet*(s: Schematic, net: string): FallbackReroute =
  ## Re-routes one fallback net against `s`'s final geometry and reports
  ## whether it would route and, if not, which endpoint is blocked and by
  ## what. This is the final-scene diagnostic described at the top of this
  ## section -- not a replay of the original layout's routing order.
  let ep = endpointsFor(s, net)
  result.net = net
  result.pins = ep.pins.len
  result.failPin = -1

  if ep.pins.len < 2:
    result.routed = true
    if ep.pins.len == 0:
      result.blockDetail = "no endpoints in this scene"
    else:
      result.blockDetail = "single dangling pin; not a routing failure"
    return

  let ctx = sceneRouterInputs(s)
  var escapeNodes: seq[Point]
  for p in ep.pins:
    let d =
      if p.esc.x != 0.0 or p.esc.y != 0.0: p.esc
      else: escapeDir(s.parts[p.partIdx], p.pt)
    escapeNodes.add p.pt + d * routingClearance

  var occ = ctx.occ
  let ro = routeNet(ep.pins, s.parts, ctx.obstacles, ctx.free, occ, net,
                    ctx.seeds, ctx.glyphs)
  result.routed = ro.ok
  result.polys = ro.polys
  if ro.ok: return

  result.failPin = ro.failPin
  if ro.failPin >= 0 and ro.failPin < ep.pins.len:
    let fi = ro.failPin
    result.failPart = ep.part[fi]
    result.failPinName = ep.pinName[fi]
    result.failX = ep.pins[fi].pt.x
    result.failY = ep.pins[fi].pt.y
    (result.blockKind, result.blockDetail) =
      blockReason(ep.pins[fi], s.parts, escapeNodes, fi, ctx.obstacles,
                  ctx.owners, ctx.free, ctx.occ, ctx.seeds, ctx.glyphs, net)

proc diagnoseFallbackNets*(s: Schematic, nets: seq[string]): seq[FallbackReroute] =
  ## `diagnoseFallbackNet` over each net, in the given order.
  for net in nets: result.add diagnoseFallbackNet(s, net)

proc diagnoseAllFallbacks*(s: Schematic): seq[FallbackReroute] =
  ## Diagnoses every distinct fallback net in `s`, in first-appearance order.
  var seen = initHashSet[string]()
  var nets: seq[string]
  for f in s.fallbacks:
    if f.net notin seen:
      seen.incl f.net
      nets.add f.net
  diagnoseFallbackNets(s, nets)
