## Stitching a net's copper into a route, and resolving each run's return
## path. `extractRoutes` collects a net's copper into nodes (pin, via,
## junction, dead end, pour) and edges (one per track), then collapses runs
## of plain copper, so a Y comes back as one trunk plus two branches. (Not
## `route.nim`, to avoid confusion with `schematic/router.nim`.)
##
## **Read-only over a `Pcb`**: never `touch` or a mutator, or `writePcb`'s
## byte-exact fast path (`pcb.rev == snapshotRev`) would break.
##
## **`ckZone` is skipped, `ckFill` is not.** `ckZone` is the authored
## outline, not copper: walking it would double-count and treat the
## pre-clearance outline as the return path.
##
## **A via is a node, never a mid-edge event.** Any node carrying a `Hole`
## is excluded from the degree-2 collapse, since collapsing would merge two
## layers (each needing its own `Z0`) into one section. Hence
## `RouteEdge.vias` is always `0`.
##
## **The degree-2 collapse** removes only pin-less, via-less, pour-less
## nodes touched by exactly two edges (where KiCad split a track object), so
## the graph mirrors real branching regardless of how tracks were split.
import std/[tables, sets, math]

import ./units
import ./geometry
import ./types
import ./graph
import ./index
import ../netlist/issue

export types, issue

type
  RouteNodeKind* = enum
    rnPin, rnVia, rnJunction, rnEnd, rnPour

  RouteNode* = ref object
    kind*: RouteNodeKind
    at*: Point
    layer*: PcbLayer
      ## The node's layer; for a via-tied node, the first-seen ring's layer
      ## (bookkeeping only -- the node spans every layer the hole does).
    pin*: Pin
    hole*: Hole
    pour*: Copper
    edges*: seq[RouteEdge]

  ReferenceSide* = enum refAbove, refBelow

  ReferencePath* = object
    ## The return-path claim for one `RouteSection`. `layer == nil` is a
    ## refusal (see `resolveReference`), never a guessed plane.
    layer*: PcbLayer
    net*: Net
    side*: ReferenceSide
    coverage*: float
    gaps*: seq[tuple[fromM, toM: float]]
    height*: float
    er*, tand*: float
    opposite*: ref ReferencePath
      ## The other side, set only when both sides clear `minCoverage`: a
      ## stripline. `impedance.nim` picks its formula from this.

  RouteSection* = object
    copper*: seq[Copper]
    layer*: PcbLayer
    width*: Nm
    length*: float
      ## Metres, exact -- see `geometry.length`.
    reference*: ReferencePath

  RouteEdge* = ref object
    a*, b*: RouteNode
    sections*: seq[RouteSection]
    length*: float
    vias*: int
      ## Layer changes inside the edge: always `0` (see module doc).

  RouteGraph* = object
    ## The unrooted result of `extractRoutes`: nodes and collapsed edges of
    ## one connected island of a net's copper. `rootedAt` adds a `root`.
    net*: Net
    nodes*: seq[RouteNode]
    edges*: seq[RouteEdge]
    issues*: seq[Issue]

  RouteTree* = object
    net*: Net
    root*: RouteNode
    nodes*: seq[RouteNode]
    edges*: seq[RouteEdge]
      ## Tree edges, oriented parent -> child (`.a` nearer `root`).
    extra*: seq[RouteEdge]
      ## Edges that would close a loop: reported, never dropped (a stitched
      ## ring is legitimate topology).
    issues*: seq[Issue]

  RouteSpec* = object
    joinTol*: Nm
    includePours*: bool
    sampleStep*: Nm
    minCoverage*: float

proc defaultRouteSpec*(): RouteSpec =
  RouteSpec(joinTol: um(1.0), includePours: true, sampleStep: mm(0.5),
            minCoverage: 0.9)

# ---------------------------------------------------------------- small helpers

proc idOf(n: RouteNode): uint {.inline.} = cast[uint](n)
proc idOf(c: Copper): uint {.inline.} = cast[uint](c)
proc idOf(e: RouteEdge): uint {.inline.} = cast[uint](e)
proc idOf(h: Hole): uint {.inline.} = cast[uint](h)

proc padCentre(s: Shape): Point =
  ## `ckLand`/`ckViaPad` shapes are `shPad` flashes by construction;
  ## `box(s).center` is a defensive fallback, not a raise.
  if s.kind == shPad: s.at else: box(s).center

proc noReferencePath(): ReferencePath =
  ## The "not found" value: `layer == nil`, every number `NaN` (never a
  ## confident zero height).
  ReferencePath(layer: nil, side: refAbove, coverage: 0.0, height: NaN,
                er: NaN, tand: NaN)

proc identityRank(n: RouteNode): int =
  ## Which identity wins when two nodes merge: pin > via > pour > junction,
  ## so merging never downgrades a node.
  case n.kind
  of rnPin: 3
  of rnVia: 2
  of rnPour: 1
  of rnJunction, rnEnd: 0

type
  Merger = object
    ## Union-find over `RouteNode` identity, keyed by pointer address.
    byId: Table[uint, RouteNode]
    redirect: Table[uint, uint]

proc register(m: var Merger, n: RouteNode) =
  m.byId[idOf(n)] = n

proc find(m: var Merger, id: uint): uint =
  ## Union-find root lookup with path compression. Without it, a net merging
  ## into one clump (a ground plane's vias and pours) builds long redirect
  ## chains and extraction goes quadratic.
  result = id
  var path: seq[uint] = @[]
  while m.redirect.hasKey(result):
    path.add(result)
    result = m.redirect[result]
  for p in path:
    m.redirect[p] = result

proc resolve(m: var Merger, n: RouteNode): RouteNode =
  m.byId[find(m, idOf(n))]

proc union(m: var Merger, a, b: RouteNode) =
  let ra = find(m, idOf(a))
  let rb = find(m, idOf(b))
  if ra == rb: return
  let na = m.byId[ra]
  let nb = m.byId[rb]
  if identityRank(na) >= identityRank(nb):
    m.redirect[rb] = ra
    if na.pin == nil and nb.pin != nil: na.pin = nb.pin
    if na.hole == nil and nb.hole != nil: na.hole = nb.hole
    if na.pour == nil and nb.pour != nil: na.pour = nb.pour
    if na.kind == rnJunction and nb.kind != rnJunction: na.kind = nb.kind
  else:
    m.redirect[ra] = rb
    if nb.pin == nil and na.pin != nil: nb.pin = na.pin
    if nb.hole == nil and na.hole != nil: nb.hole = na.hole
    if nb.pour == nil and na.pour != nil: nb.pour = na.pour
    if nb.kind == rnJunction and na.kind != rnJunction: nb.kind = na.kind

proc keyOf(l: PcbLayer, p: Point): tuple[layer: int, x, y: int64] =
  (l.index, p.x.raw, p.y.raw)

# ---------------------------------------------------------------- reference path

proc pointAtLength(p: Path, s: float): Point =
  ## The point `s` metres along `p`. Clamps past either end: the caller's
  ## step arithmetic overshoots by rounding error routinely.
  if p.curves.len == 0:
    return pt(nm(0), nm(0))
  var remaining = s
  for i, c in p.curves:
    let clen = length(c)
    if remaining <= clen or i == p.curves.high:
      let f = (if clen > 1e-12: clamp(remaining / clen, 0.0, 1.0) else: 0.0)
      case c.kind
      of cvSeg:
        return pt(c.a.x + nm(int64(round((c.b.x - c.a.x).raw.float * f))),
                   c.a.y + nm(int64(round((c.b.y - c.a.y).raw.float * f))))
      of cvArc:
        return pointOnArc(c, c.startAngle + c.sweep * f)
    remaining -= clen
  endPoint(p.curves[^1])

proc sampleSection(sec: RouteSection, stepMetres: float): seq[Point] =
  ## Points roughly `stepMetres` apart along the section, sampled per
  ## `Copper` piece (tracks needn't share a direction; only the points
  ## matter).
  for c in sec.copper:
    let plen = length(c.shape.path)
    if plen <= 1e-12:
      result.add(startPoint(c.shape.path.curves[0]))
      continue
    let n = max(1, int(round(plen / stepMetres)))
    for i in 0 .. n:
      result.add(pointAtLength(c.shape.path, plen * i.float / n.float))

proc gapsFrom(hits: seq[bool], stepMetres: float): seq[tuple[fromM, toM: float]] =
  var i = 0
  while i < hits.len:
    if not hits[i]:
      let startM = i.float * stepMetres
      var j = i
      while j < hits.len and not hits[j]: inc j
      result.add((fromM: startM, toM: (j - 1).float * stepMetres))
      i = j
    else:
      inc i

proc boxOfPoints(pts: seq[Point]): Box =
  result = emptyBox()
  for p in pts: result.extendTo(p)

proc sampleSideReference(pcb: Pcb, sectionLayer: PcbLayer, samples: seq[Point],
                         net: Net, side: int, minCoverage: float,
                         fillCache: var Table[uint, FlattenedPolygon]
                         ): tuple[layer: PcbLayer, coverage: float, hits: seq[bool]] =
  ## Walks copper layers outward from `sectionLayer` (`side = -1` up, `+1`
  ## down), stopping at the first whose coverage clears `minCoverage`. If
  ## none does, returns the best seen, so a partially covered plane is
  ## reported with its gaps rather than as absent.
  ##
  ## Two load-bearing optimisations: a bounding-box pre-check per candidate
  ## (most layers have no fill nearby), and `fillCache`, shared across every
  ## section and net, so each pour outline is flattened once rather than per
  ## sample -- the cache alone made a full-board sweep ~13x faster.
  let layers = copperLayers(pcb)
  var bestLayer: PcbLayer = nil
  var bestCov = -1.0
  var bestHits: seq[bool] = @[]
  let sBox = boxOfPoints(samples)
  var idx = sectionLayer.copperIndex + side
  while idx >= 0 and idx < layers.len:
    let cand = layers[idx]
    var relevant: seq[Copper] = @[]
    for c in candidates(pcb, cand, sBox):
      if c.kind == ckFill and c.net != nil and c.net != net:
        relevant.add(c)
    var coverage = 0.0
    var hits = newSeq[bool](samples.len)
    if relevant.len > 0:
      for c in relevant:
        if not fillCache.hasKey(idOf(c)):
          fillCache[idOf(c)] = flattenPolygon(c.shape.poly)
      for i, p in samples:
        for c in relevant:
          if contains(fillCache[idOf(c)], p):
            hits[i] = true
            break
      var covered = 0
      for h in hits:
        if h: inc covered
      coverage = covered.float / hits.len.float
    if coverage > bestCov:
      bestCov = coverage
      bestLayer = cand
      bestHits = hits
    if coverage >= minCoverage:
      break
    idx += side
  (bestLayer, max(bestCov, 0.0), bestHits)

proc resolveReference(pcb: Pcb, sec: RouteSection, net: Net, spec: RouteSpec,
                      fillCache: var Table[uint, FlattenedPolygon]
                      ): tuple[path: ReferencePath, issues: seq[Issue]] =
  ## Three named refusals, in order: no plane on either side
  ## (`route_no_reference`); zones exist but none is filled
  ## (`reference_unfilled` -- the outline is never substituted); a plane
  ## below `minCoverage`, reported with its gaps (`route_return_gap`).
  var issues: seq[Issue]
  if sec.layer == nil or sec.copper.len == 0:
    return (noReferencePath(), issues)
  let stepMetres = toMetres(spec.sampleStep)
  let samples = sampleSection(sec, stepMetres)
  if samples.len == 0:
    return (noReferencePath(), issues)

  let above = sampleSideReference(pcb, sec.layer, samples, net, -1, spec.minCoverage, fillCache)
  let below = sampleSideReference(pcb, sec.layer, samples, net, +1, spec.minCoverage, fillCache)

  proc toRp(side: ReferenceSide, r: tuple[layer: PcbLayer, coverage: float, hits: seq[bool]]): ReferencePath =
    if r.layer == nil: return noReferencePath()
    let dl = dielectricBetween(pcb, sec.layer, r.layer)
    var height, erSum, tandSum, wSum = 0.0
    for e in dl:
      let t = toMetres(e.thickness)
      height += t
      if e.material != nil:
        erSum += e.material.epsilonR * t
        tandSum += e.material.lossTangent * t
        wSum += t
    ReferencePath(layer: r.layer, net: net, side: side, coverage: r.coverage,
                  gaps: gapsFrom(r.hits, stepMetres), height: height,
                  er: (if wSum > 0: erSum / wSum else: NaN),
                  tand: (if wSum > 0: tandSum / wSum else: NaN))

  let aboveOk = above.layer != nil and above.coverage >= spec.minCoverage
  let belowOk = below.layer != nil and below.coverage >= spec.minCoverage

  if above.layer == nil and below.layer == nil:
    var hasZones = false
    var anyFilled = false
    for z in pcb.zones:
      hasZones = true
      if z.fills.len > 0: anyFilled = true
    if hasZones and not anyFilled:
      issues.add(newIssue("reference_unfilled", sevWarning,
        "net '" & net.name & "': the board has zones but none carry a fill " &
        "-- run a fill pass before a return path can be resolved (an " &
        "authored zone outline is not treated as copper)", net = net))
    else:
      issues.add(newIssue("route_no_reference", sevWarning,
        "net '" & net.name & "': no copper plane on either side of " &
        sec.layer.name & " to serve as a return path", net = net))
    return (noReferencePath(), issues)

  var aboveRp = toRp(refAbove, above)
  var belowRp = toRp(refBelow, below)

  if aboveOk and belowOk:
    # Both sides clear: a stripline. The nearer plane (by dielectric height)
    # is primary, the far one `.opposite`.
    var oa, ob: ref ReferencePath
    new(oa); oa[] = belowRp
    new(ob); ob[] = aboveRp
    aboveRp.opposite = oa
    belowRp.opposite = ob
    let primary = (if aboveRp.height <= belowRp.height: aboveRp else: belowRp)
    return (primary, issues)

  if aboveOk: return (aboveRp, issues)
  if belowOk: return (belowRp, issues)

  # Neither side clears but one found a real layer: report it with gaps.
  # Exclude a nil-layer side outright -- on a single-sided board `0.0 >= 0.0`
  # would pick the phantom side.
  var winner: tuple[rp: ReferencePath, layer: PcbLayer, coverage: float]
  if above.layer != nil and (below.layer == nil or above.coverage >= below.coverage):
    winner = (aboveRp, above.layer, above.coverage)
  else:
    winner = (belowRp, below.layer, below.coverage)
  issues.add(newIssue("route_return_gap", sevWarning,
    "net '" & net.name & "': reference plane on " & winner.layer.name &
    " covers only " & $(round(winner.coverage * 1000.0) / 10.0) &
    "% of the run under " & sec.layer.name, net = net))
  (winner.rp, issues)

# ---------------------------------------------------------------- extraction

proc buildSections(chain: seq[Copper]): seq[RouteSection] =
  ## Splits a chain of track `Copper` into uniform runs, a new section per
  ## width change (layer can't change mid-chain).
  var i = 0
  while i < chain.len:
    let w = chain[i].shape.width
    let lyr = chain[i].layer
    var segCopper: seq[Copper] = @[]
    var segLen = 0.0
    var j = i
    while j < chain.len and chain[j].shape.width == w and chain[j].layer == lyr:
      segCopper.add(chain[j])
      segLen += length(chain[j].shape.path)
      inc j
    result.add(RouteSection(copper: segCopper, layer: lyr, width: w, length: segLen))
    i = j

proc extractRoutes*(pcb: Pcb, net: Net, spec = defaultRouteSpec()): seq[RouteGraph] =
  ## Collect -> node -> edge -> collapse -> split into connected islands.
  result = @[]
  if pcb == nil or net == nil: return

  var tracks, pads, pours: seq[Copper]
  for c in copperOn(pcb, net):
    case c.kind
    of ckTrack: tracks.add(c)
    of ckLand, ckViaPad: pads.add(c)
    of ckFill:
      if spec.includePours: pours.add(c)
    of ckZone, ckOther:
      discard  ## the authored outline, not copper
  if tracks.len == 0 and pads.len == 0 and pours.len == 0: return

  var m: Merger
  var byKey = initTable[tuple[layer: int, x, y: int64], RouteNode]()
  var trackTouch = initTable[tuple[layer: int, x, y: int64], int]()

  proc trackNode(l: PcbLayer, p: Point): RouteNode =
    let k = keyOf(l, p)
    trackTouch[k] = trackTouch.getOrDefault(k) + 1
    if byKey.hasKey(k): return byKey[k]
    result = RouteNode(kind: rnJunction, at: p, layer: l)
    byKey[k] = result
    m.register(result)

  type RawEdge = tuple[copper: Copper, a, b: RouteNode]
  var rawEdges: seq[RawEdge] = @[]
  for t in tracks:
    let (p0, p1) = endpoints(t.shape)
    rawEdges.add((copper: t, a: trackNode(t.layer, p0), b: trackNode(t.layer, p1)))

  var padNodeOf = initTable[uint, RouteNode]()
  for c in pads:
    let n = RouteNode(at: padCentre(c.shape), layer: c.layer,
                      kind: (if c.kind == ckLand: rnPin else: rnVia),
                      pin: c.pin, hole: c.hole)
    padNodeOf[idOf(c)] = n
    m.register(n)

  var pourNodeOf = initTable[uint, RouteNode]()
  for c in pours:
    let n = RouteNode(at: box(c.shape).center, layer: c.layer, kind: rnPour, pour: c)
    pourNodeOf[idOf(c)] = n
    m.register(n)

  # --- union pass 1: pad/via/pour capture -------------------------------
  # `hitTest` uses exact containment, so a track ending inside a pad (not
  # at its centre) still resolves.
  for k, n in byKey:
    if n.layer == nil: continue
    var landHit, viaHit, fillHit: Copper
    for c in hitTest(pcb, n.layer, n.at):
      if c.net != net: continue
      case c.kind
      of ckLand:
        if landHit == nil: landHit = c
      of ckViaPad:
        if viaHit == nil: viaHit = c
      of ckFill:
        if fillHit == nil: fillHit = c
      else: discard
    if landHit != nil and padNodeOf.hasKey(idOf(landHit)):
      m.union(n, padNodeOf[idOf(landHit)])
    elif viaHit != nil and padNodeOf.hasKey(idOf(viaHit)):
      m.union(n, padNodeOf[idOf(viaHit)])
    elif fillHit != nil and pourNodeOf.hasKey(idOf(fillHit)):
      m.union(n, pourNodeOf[idOf(fillHit)])

  # --- union pass 2: layer tie ------------------------------------------
  # Rings sharing one `Hole` are one connection point -- the only marker of
  # a layer change.
  var byHole = initTable[uint, RouteNode]()
  for c in pads:
    if c.hole == nil: continue
    let n = padNodeOf[idOf(c)]
    let hk = idOf(c.hole)
    if byHole.hasKey(hk):
      m.union(byHole[hk], n)
    else:
      byHole[hk] = n

  # --- union pass 3: tolerance sweep -------------------------------------
  # Only truly dangling ends (one track, no pad/via/pour) are searched.
  for k, n in byKey:
    if m.resolve(n).kind != rnJunction: continue
    if trackTouch.getOrDefault(k) != 1: continue
    if n.layer == nil: continue
    for c in near(pcb, n.layer, n.at, spec.joinTol):
      if c.net != net or c.kind != ckTrack: continue
      let (q0, q1) = endpoints(c.shape)
      for q in [q0, q1]:
        let qk = keyOf(n.layer, q)
        if qk == k or not byKey.hasKey(qk): continue
        if distance(n.at, q) <= spec.joinTol.raw.float:
          m.union(n, byKey[qk])

  # --- resolve raw edges, and every created node, to their final identity
  var finalRaw: seq[RawEdge] = @[]
  for e in rawEdges:
    finalRaw.add((copper: e.copper, a: m.resolve(e.a), b: m.resolve(e.b)))

  var allNodes: seq[RouteNode] = @[]
  var seenIds = initHashSet[uint]()
  for _, n in byKey:
    let r = m.resolve(n)
    if not seenIds.containsOrIncl(idOf(r)): allNodes.add(r)
  for _, n in padNodeOf:
    let r = m.resolve(n)
    if not seenIds.containsOrIncl(idOf(r)): allNodes.add(r)
  for _, n in pourNodeOf:
    let r = m.resolve(n)
    if not seenIds.containsOrIncl(idOf(r)): allNodes.add(r)

  var degree = initTable[uint, int]()
  for e in finalRaw:
    degree[idOf(e.a)] = degree.getOrDefault(idOf(e.a)) + 1
    degree[idOf(e.b)] = degree.getOrDefault(idOf(e.b)) + 1

  for n in allNodes:
    if n.kind == rnJunction and degree.getOrDefault(idOf(n)) == 1:
      n.kind = rnEnd

  proc isPassThrough(n: RouteNode): bool =
    n.kind == rnJunction and degree.getOrDefault(idOf(n)) == 2

  var adj = initTable[uint, seq[int]]()
  for i, e in finalRaw:
    adj.mgetOrPut(idOf(e.a), @[]).add(i)
    adj.mgetOrPut(idOf(e.b), @[]).add(i)

  var usedEdge = newSeq[bool](finalRaw.len)
  var edges: seq[RouteEdge] = @[]

  proc otherEnd(e: RawEdge, n: RouteNode): RouteNode =
    (if e.a == n: e.b else: e.a)

  proc walkChain(start: RouteNode, firstIdx: int) =
    var chainCopper: seq[Copper] = @[finalRaw[firstIdx].copper]
    usedEdge[firstIdx] = true
    var cur = otherEnd(finalRaw[firstIdx], start)
    var prevIdx = firstIdx
    while isPassThrough(cur):
      var nextIdx = -1
      for idx in adj.getOrDefault(idOf(cur), @[]):
        if idx != prevIdx and not usedEdge[idx]:
          nextIdx = idx
          break
      if nextIdx < 0: break
      chainCopper.add(finalRaw[nextIdx].copper)
      usedEdge[nextIdx] = true
      cur = otherEnd(finalRaw[nextIdx], cur)
      prevIdx = nextIdx
    let sections = buildSections(chainCopper)
    var totalLen = 0.0
    for s in sections: totalLen += s.length
    edges.add(RouteEdge(a: start, b: cur, sections: sections, length: totalLen, vias: 0))

  for n in allNodes:
    if isPassThrough(n): continue
    for idx in adj.getOrDefault(idOf(n), @[]):
      if not usedEdge[idx]:
        walkChain(n, idx)
  # A closed ring of pass-through nodes has no anchor; a second pass turns
  # it into a self-loop edge instead of dropping it.
  for n in allNodes:
    for idx in adj.getOrDefault(idOf(n), @[]):
      if not usedEdge[idx]:
        walkChain(n, idx)

  var finalNodes: seq[RouteNode] = @[]
  for n in allNodes:
    if isPassThrough(n): continue
    n.edges = @[]
    finalNodes.add(n)
  for e in edges:
    e.a.edges.add(e)
    if e.b != e.a: e.b.edges.add(e)

  # --- per-edge issues: a run into a pour, and every section's reference
  var edgeIssues = initTable[uint, seq[Issue]]()
  # Shared per net: the same pour is usually the reference for every run.
  var fillCache = initTable[uint, FlattenedPolygon]()
  for e in edges:
    var eis: seq[Issue] = @[]
    if e.a.kind == rnPour or e.b.kind == rnPour:
      eis.add(newIssue("route_through_pour", sevInfo,
        "net '" & net.name & "': a run terminates in a copper pour, which " &
        "is not a transmission line and is not characterized", net = net))
    for i in 0 ..< e.sections.len:
      let (rp, refIssues) = resolveReference(pcb, e.sections[i], net, spec, fillCache)
      e.sections[i].reference = rp
      eis.add(refIssues)
    edgeIssues[idOf(e)] = eis

  # --- connected components: never merge across islands ------------------
  var adjNodeToEdges = initTable[uint, seq[RouteEdge]]()
  for e in edges:
    adjNodeToEdges.mgetOrPut(idOf(e.a), @[]).add(e)
    if e.b != e.a: adjNodeToEdges.mgetOrPut(idOf(e.b), @[]).add(e)

  var visited = initHashSet[uint]()
  var components: seq[tuple[nodes: seq[RouteNode], edges: seq[RouteEdge]]] = @[]
  for n in finalNodes:
    if visited.contains(idOf(n)): continue
    var compNodes: seq[RouteNode] = @[]
    var compEdges: seq[RouteEdge] = @[]
    var seenEdgeIds = initHashSet[uint]()
    var queue = @[n]
    visited.incl(idOf(n))
    var qi = 0
    while qi < queue.len:
      let cur = queue[qi]; inc qi
      compNodes.add(cur)
      for e in adjNodeToEdges.getOrDefault(idOf(cur), @[]):
        if not seenEdgeIds.containsOrIncl(idOf(e)):
          compEdges.add(e)
        let other = (if e.a == cur: e.b else: e.a)
        if not visited.contains(idOf(other)):
          visited.incl(idOf(other))
          queue.add(other)
    components.add((compNodes, compEdges))

  for comp in components:
    var compIssues: seq[Issue] = @[]
    for e in comp.edges:
      compIssues.add(edgeIssues.getOrDefault(idOf(e), @[]))
    result.add(RouteGraph(net: net, nodes: comp.nodes, edges: comp.edges, issues: compIssues))

  if result.len > 1:
    for g in result.mitems:
      g.issues.add(newIssue("route_disconnected", sevWarning,
        "net '" & net.name & "': copper splits into " & $result.len &
        " disconnected islands and is returned as that many separate " &
        "results rather than merged", net = net))

# ---------------------------------------------------------------- rooting

proc rootedAt*(g: RouteGraph, p: Pin): RouteTree =
  ## BFS from the node carrying pin `p`. A pin reaching no copper gets a
  ## `route_open` refusal (empty tree, `root == nil`), not a crash.
  var root: RouteNode = nil
  for n in g.nodes:
    if n.pin == p:
      root = n
      break
  if root == nil:
    return RouteTree(net: g.net, root: nil,
      issues: @[newIssue("route_open", sevWarning,
        "no copper on this net reaches the requested pin", net = g.net,
        pins = @[p])])

  var adjNodeToEdges = initTable[uint, seq[RouteEdge]]()
  for e in g.edges:
    adjNodeToEdges.mgetOrPut(idOf(e.a), @[]).add(e)
    if e.b != e.a: adjNodeToEdges.mgetOrPut(idOf(e.b), @[]).add(e)

  var visited = initHashSet[uint]()
  var usedTreeEdge = initHashSet[uint]()
  var extraSeen = initHashSet[uint]()
  var treeEdges, extra: seq[RouteEdge] = @[]
  var treeNodes = @[root]
  var issues = g.issues
  visited.incl(idOf(root))
  var queue = @[root]
  var qi = 0
  while qi < queue.len:
    let cur = queue[qi]; inc qi
    for e in adjNodeToEdges.getOrDefault(idOf(cur), @[]):
      if e.a == e.b:
        if extraSeen.containsOrIncl(idOf(e)): continue
        extra.add(e)
        issues.add(newIssue("route_loop", sevInfo,
          "net '" & g.net.name & "': a stitched ring closes back on itself",
          net = g.net))
        continue
      let other = (if e.a == cur: e.b else: e.a)
      if not visited.contains(idOf(other)):
        visited.incl(idOf(other))
        treeNodes.add(other)
        queue.add(other)
        let oriented = (if e.a == cur: e
                        else: RouteEdge(a: cur, b: other, sections: e.sections,
                                        length: e.length, vias: e.vias))
        treeEdges.add(oriented)
        usedTreeEdge.incl(idOf(e))
      elif idOf(e) notin usedTreeEdge:
        if extraSeen.containsOrIncl(idOf(e)): continue
        extra.add(e)
        issues.add(newIssue("route_loop", sevInfo,
          "net '" & g.net.name & "': copper forms a loop back to an " &
          "already-reached point rather than a simple tree", net = g.net))
  RouteTree(net: g.net, root: root, nodes: treeNodes, edges: treeEdges,
           extra: extra, issues: issues)

proc traceTree*(pcb: Pcb, net: Net, source: Pin, spec = defaultRouteSpec()): RouteTree =
  ## Extract, then root at `source` in whichever island reaches it. An
  ## unreachable pin gets the same `route_open` refusal as `rootedAt`.
  for g in extractRoutes(pcb, net, spec):
    for n in g.nodes:
      if n.pin == source:
        return rootedAt(g, source)
  RouteTree(net: net, root: nil,
    issues: @[newIssue("route_open", sevWarning,
      "no copper on net '" & net.name & "' reaches the requested pin",
      net = net, pins = @[source])])

proc pathTo*(t: RouteTree, p: Pin): seq[RouteEdge] =
  ## root -> `p` as ordered tree edges; empty when unrooted or `p` isn't in
  ## the tree.
  if t.root == nil: return @[]
  var byParent = initTable[uint, seq[RouteEdge]]()
  for e in t.edges:
    byParent.mgetOrPut(idOf(e.a), @[]).add(e)
  var stack = @[(node: t.root, path: newSeq[RouteEdge]())]
  while stack.len > 0:
    let (n, path) = stack.pop()
    if p != nil and n.pin == p:
      return path
    for e in byParent.getOrDefault(idOf(n), @[]):
      var np = path
      np.add(e)
      stack.add((node: e.b, path: np))
  @[]
