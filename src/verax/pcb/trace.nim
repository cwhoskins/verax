## Stitching a net's copper into a route, and resolving each run's return
## path.
##
## `pcb/graph`/`pcb/index` answer "what copper is on this net" and "what is
## at this point" -- neither answers "what is *between* these two pins".
## This module is the join: `extractRoutes` collects a net's copper into
## nodes (pin, via, junction, dead end, pour) and edges (one per drawn
## track), then collapses every run of plain, unlabelled copper into a
## single `RouteEdge` -- so a driver feeding two receivers through a Y comes
## back as one shared trunk plus two branches, not two independent
## point-to-point paths that happen to overlap.
##
## Named `trace.nim` rather than `route.nim` to avoid colliding with
## `schematic/router.nim`, which solves an unrelated problem (where to draw a
## wire) with an unrelated algorithm.
##
## **Read-only over a `Pcb`.** Every proc here only calls `copperOn`,
## `hitTest`, `near` and `dielectricBetween` -- never `graph.touch` or any
## mutator -- because `formats/kicad.writePcb`'s byte-exact fast path is
## `pcb.rev == snapshotRev`, and extracting a route is exactly the kind of
## "just looking" operation that must never bump that counter (`pcb/CLAUDE.md`
## on `Pcb.rev`).
##
## **`ckZone` is skipped, `ckFill` is not.** `graph.addZone` pushes one
## `ckZone` record per layer holding the *authored* outline -- not real
## copper, the same trap `fem/extrude.extrudeCopper` already guards against
## (`pcb/CLAUDE.md`'s `Zone.fills` section). Walking it here would double the
## length of every net that has a pour and, worse, treat the pre-clearance,
## pre-thermal-relief outline as if it were the poured copper a signal
## actually returns through.
##
## **A via is a node, never a mid-edge event.** `RouteEdge.vias` is `0` "by
## construction": the only thing that ever marks a layer change is a `Hole`
## tying two `Copper` rings together (`graph.attachPad`), and any node
## carrying a `Hole` is excluded from the degree-2 collapse below on purpose
## -- collapsing through it would silently merge two different physical
## layers, each needing its own `Z0`, into one `RouteSection` that claims a
## single width and layer.
##
## **The degree-2 collapse is what makes the tree mirror branching.** A
## plain node with no pin, no via and no pour, touched by exactly two edges,
## is nothing but where KiCad happened to end one track object and start the
## next (necking under a pad, a manual "break track" edit, a re-route). Only
## a node with three or more edges, or one carrying a pin/via/pour identity,
## survives into the reported graph -- so a straight run stays one edge and
## a Y stays a trunk plus two branches, regardless of how many `ckTrack`
## records KiCad happened to split it into.
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
      ## The layer the node sits on; for a via-tied node, whichever layer its
      ## first-seen ring was read from -- the node itself is layer-less in
      ## the sense that matters (it ties every layer the hole spans), this
      ## is only ever used for "where do I sample from" bookkeeping.
    pin*: Pin
    hole*: Hole
    pour*: Copper
    edges*: seq[RouteEdge]

  ReferenceSide* = enum refAbove, refBelow

  ReferencePath* = object
    ## The return-path claim for one `RouteSection`: which plane, how well
    ## it covers the run, and what dielectric sits between them. `layer ==
    ## nil` is the refusal case -- see `resolveReference`'s three named
    ## refusals below, never a guessed plane.
    layer*: PcbLayer
    net*: Net
    side*: ReferenceSide
    coverage*: float
    gaps*: seq[tuple[fromM, toM: float]]
    height*: float
    er*, tand*: float
    opposite*: ref ReferencePath
      ## The other side, set only when both above and below independently
      ## clear `RouteSpec.minCoverage` -- that is what makes the run a
      ## stripline rather than a microstrip, and `impedance.nim` reads this
      ## field to decide which formula applies.

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
      ## Layer changes strictly inside the edge. Always `0`: a layer change
      ## is exactly what keeps a node from being collapsed away (see the
      ## module doc), so it can never end up mid-edge.

  RouteGraph* = object
    ## The unrooted result of `extractRoutes`: every node and (collapsed)
    ## edge reachable from one connected island of a net's copper, with no
    ## notion yet of which pin is the source. `rootedAt` turns this into a
    ## `RouteTree`; the two share the same node/edge/issue shape because
    ## rooting adds exactly one thing -- `root`, plus which non-tree edges
    ## had to be set aside -- and nothing else about the graph changes.
    net*: Net
    nodes*: seq[RouteNode]
    edges*: seq[RouteEdge]
    issues*: seq[Issue]

  RouteTree* = object
    net*: Net
    root*: RouteNode
    nodes*: seq[RouteNode]
    edges*: seq[RouteEdge]
      ## Tree edges, oriented parent -> child (`.a` is always the node
      ## nearer `root`).
    extra*: seq[RouteEdge]
      ## Edges that would close a loop in the BFS from `root`: reported,
      ## never dropped -- a stitched ring is a legitimate topology, and
      ## silently discarding one of its edges would make the tree lie about
      ## how the net is actually connected.
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
  ## Every `ckLand`/`ckViaPad` shape is a `shPad` flash by construction (both
  ## readers build them that way); `box(s).center` is a defensive fallback
  ## for anything else rather than a raise, on the same "degrade, do not
  ## crash on a shape this module did not expect" reasoning
  ## `arcFrom3Points` already uses for collinear input.
  if s.kind == shPad: s.at else: box(s).center

proc noReferencePath(): ReferencePath =
  ## The "not found" value: `layer == nil` is what a caller tests, but every
  ## numeric field is `NaN` too, on the house rule that not-found is `NaN`
  ## and never a confident zero (`CLAUDE.md`) -- a stripline whose `height`
  ## silently read `0.0` because no plane was found would look like a
  ## perfectly matched zero-dielectric line instead of an unanswered
  ## question.
  ReferencePath(layer: nil, side: refAbove, coverage: 0.0, height: NaN,
                er: NaN, tand: NaN)

proc identityRank(n: RouteNode): int =
  ## Which identity wins when two nodes turn out to be the same physical
  ## point. A pin outranks a via outranks a pour outranks a plain junction,
  ## because a pin is the most specific claim a node can carry and a bare
  ## junction is the least -- merging never *downgrades* what a node is
  ## known to be.
  case n.kind
  of rnPin: 3
  of rnVia: 2
  of rnPour: 1
  of rnJunction, rnEnd: 0

type
  Merger = object
    ## Union-find over `RouteNode` identity, keyed by pointer address (a
    ## `RouteNode` has no natural key of its own before it is merged with
    ## anything). `find`/`resolve` are plain iterative lookups with no path
    ## compression: per-net node counts are small enough that this is not
    ## worth the extra bookkeeping, and skipping it keeps `union` a five-line
    ## proc with nothing to get subtly wrong.
    byId: Table[uint, RouteNode]
    redirect: Table[uint, uint]

proc register(m: var Merger, n: RouteNode) =
  m.byId[idOf(n)] = n

proc find(m: var Merger, id: uint): uint =
  ## Union-find root lookup **with path compression**: every id visited on
  ## the way to the root is repointed straight at it before returning. Without
  ## this, a net whose copper all merges into one big clump (a ground plane's
  ## thousands of vias, all tied through one `Hole`-sharing pass and then a
  ## pour) builds a `redirect` chain one union deeper per merge, and the
  ## `resolve` call every raw edge and every node needs at the end of
  ## `extractRoutes` walks that whole chain -- turning one busy net's
  ## extraction quadratic in its own node count. Measured on `GND` in
  ## `video.kicad_pcb` (the single busiest net in the `nimble traces` demo
  ## corpus -- 1372 copper features, almost all of it merging into one
  ## clump through shared vias and a handful of pours): `extractRoutes`
  ## dropped from 4.9s to 2.5s once this landed, in isolation from every
  ## other fix this stage made (see `sampleSideReference`'s own doc comment
  ## for the rest of that board's story, and why this alone was nowhere
  ## near enough) -- the same superlinear blow-up `SpatialIndex.oversized`
  ## exists to prevent on the geometry side, here on the union-find side
  ## instead.
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
  ## The point `s` metres along `p`'s centreline. Clamps past either end
  ## rather than raising -- a rounding-sized overshoot from the caller's own
  ## step arithmetic is a certainty, not an edge case, and refusing over a
  ## few nanometres of float error would be worse than the tiny inaccuracy
  ## of clamping.
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
  ## Points along the section's centreline roughly `stepMetres` apart,
  ## sampled independently per `Copper` piece rather than as one continuous
  ## parametrisation -- `sec.copper` is already in walk order but individual
  ## tracks are not guaranteed to share a consistent start/end direction, and
  ## what a reference-plane coverage check needs is *which points to test*,
  ## not a single monotonic arc-length axis across the whole run.
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
  ## Walks `graph.copperLayers` outward from `sectionLayer` in one direction
  ## (`side = -1` toward the top, `+1` toward the bottom), stopping at the
  ## first candidate whose coverage clears `minCoverage`. When nothing ever
  ## clears it, returns the *best* candidate seen so it can still be reported
  ## with its gaps rather than as a bare "not found" -- a plane at 40%
  ## coverage under a trace is a real defect worth naming, not the same
  ## answer as no plane existing at all.
  ##
  ## **Two things below are load-bearing, not optimisations to lose in a
  ## future cleanup; both were measured against the real KiCad demo corpus,
  ## not guessed.** First: a `candidates()` bounding-box pre-check against
  ## the section's own extent, before touching a single sample, so the
  ## entirely ordinary case -- this candidate layer has no relevant fill
  ## anywhere nearby at all, true for most of a signal net's non-plane
  ## layers -- costs one bounded query instead of `samples.len` of them.
  ## Second, and the larger of the two: `fillCache`, threaded in from
  ## `extractRoutes` and shared across *every* section of *every* net in one
  ## call, so a real ground or power pour's outline -- easily thousands of
  ## vertices once clearances and thermal reliefs are cut around every pad
  ## on a busy board -- is flattened once (`geometry.flattenPolygon`) rather
  ## than once per sample point tested against it
  ## (`geometry.contains(Polygon, Point)`'s ordinary contract, the right one
  ## for a handful of point tests and the wrong one here). Measured summed
  ## over every one of `video.kicad_pcb`'s 588 nets (per `rf_analysis_plan.md`,
  ## 4 copper layers, ~7900 segments): 162.7s with neither fix, 159.6s with
  ## only the bounding-box pre-check (`Merger.find`'s path compression was
  ## already in place for both of those two numbers), 12.4s with the flatten
  ## cache added on top -- the box check alone bought almost nothing on this
  ## board; the flatten cache is what actually made the sweep viable, by
  ## roughly 13x.
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
  ## The three refusals named in `pcb/CLAUDE.md`, in the order they are
  ## checked: no plane on either side at all (`route_no_reference`); zones
  ## exist but every one of them has an empty `fills` -- an unfilled board,
  ## where `ckZone`'s authored outline is deliberately still not used as a
  ## substitute (`reference_unfilled`); and a plane found but under
  ## `minCoverage`, reported with its gaps rather than silently accepted
  ## (`route_return_gap`).
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
    # Both sides clear coverage: a stripline. The nearer plane (by
    # dielectric height) is reported as primary and the far one as
    # `.opposite`, which is what lets `impedance.nim` tell a stripline from
    # an asymmetric one without either side being an arbitrary pick.
    var oa, ob: ref ReferencePath
    new(oa); oa[] = belowRp
    new(ob); ob[] = aboveRp
    aboveRp.opposite = oa
    belowRp.opposite = ob
    let primary = (if aboveRp.height <= belowRp.height: aboveRp else: belowRp)
    return (primary, issues)

  if aboveOk: return (aboveRp, issues)
  if belowOk: return (belowRp, issues)

  # Neither side clears the threshold but at least one found a *real*
  # candidate layer -- report it, with gaps, rather than refusing outright.
  # The comparison must exclude a nil-layer side entirely rather than
  # comparing its `0.0` placeholder coverage against a real (also possibly
  # `0.0`) candidate's: a single-sided board has one direction with no
  # copper layer to search at all, and `0.0 >= 0.0` would otherwise pick the
  # phantom side and dereference a `nil` layer below.
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
  ## Splits a contracted chain of track `Copper` into uniform runs: a new
  ## section starts wherever width changes (layer cannot change mid-chain --
  ## see the module doc on why a via always survives as a node).
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
  ## §2's whole algorithm: collect -> node -> edge -> collapse -> split into
  ## connected islands. See the module doc for the two decisions that shape
  ## it (`ckZone` skipped, a via is a node) and `resolveReference`'s doc for
  ## the return-path half.
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
      discard  ## the authored outline, not copper -- see the module doc.
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
  # `hitTest` applies the exact `geometry.contains` predicate, so a track
  # ending inside a pad rather than at its flash centre -- the normal case
  # -- still resolves.
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
  # Every pad/via ring sharing one `Hole` is the same physical connection
  # point seen from each layer it spans -- the only structural marker a
  # layer change happened.
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
  # Only genuinely dangling ends (exactly one track touches this exact
  # point, and pass 1 found no pad/via/pour there) are worth searching --
  # a real junction of several tracks meeting exactly is not "unjoined".
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
  # A closed ring of nothing but pass-through nodes has no anchor at all --
  # vanishingly rare (copper touching no pin, via or pour anywhere), but a
  # second unrestricted pass turns it into a self-loop edge instead of
  # silently dropping it.
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
  # Shared for the whole net, not per edge or per section: the same
  # ground/power pour is very often *the* reference plane for every run on
  # this net, and `sampleSideReference`'s own doc comment has the measured
  # cost of re-flattening it once per sample instead of once per net.
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
  ## BFS from the node carrying pin `p`. A `route_open` refusal (`p` reaches
  ## no copper on this net -- an empty tree, `root == nil`) rather than a
  ## crash: the pin the caller named is exactly what a wiring mistake is
  ## most likely to have broken.
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
  ## Convenience: extract, then root at `source` in whichever resulting
  ## island actually reaches it. A pin unreachable from *any* island (no
  ## copper at all, not merely a different one) gets the identical
  ## `route_open` refusal `rootedAt` gives for a pin missing from a single
  ## graph -- one failure shape regardless of which way the pin turned out
  ## to be unreachable.
  for g in extractRoutes(pcb, net, spec):
    for n in g.nodes:
      if n.pin == source:
        return rootedAt(g, source)
  RouteTree(net: net, root: nil,
    issues: @[newIssue("route_open", sevWarning,
      "no copper on net '" & net.name & "' reaches the requested pin",
      net = net, pins = @[source])])

proc pathTo*(t: RouteTree, p: Pin): seq[RouteEdge] =
  ## root -> `p`, as an ordered list of tree edges. Empty when `t` was never
  ## rooted (`root == nil`) or `p` is not in this tree -- the same "answer
  ## honestly, do not raise on a plausible caller question" shape every
  ## other lookup in `pcb/graph` and `pcb/index` uses.
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
