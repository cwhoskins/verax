## Location lookup over a board's copper: a per-layer uniform grid bucketing
## each feature's cached bounding box. `graph` sets `dirty` on any change and
## queries rebuild automatically.
##
## Features spanning more than `maxCells` cells (a plane) go into a
## per-layer `oversized` list scanned by every query.
##
## `query`, `queryPoint` and `near` return bounding-box **candidates**;
## `hitTest` applies exact geometry. Don't confuse the two.

import std/[algorithm, math, tables, sets]
import ./units
import ./geometry
import ./types
import ./graph

export types

proc cellOf(ix: SpatialIndex, v, origin: Nm): int32 =
  int32(floor((v - origin).raw.float / ix.cell.raw.float))

proc cellRange(ix: SpatialIndex, b: Box): tuple[x0, y0, x1, y1: int32] =
  (cellOf(ix, b.lo.x, ix.origin.x), cellOf(ix, b.lo.y, ix.origin.y),
   cellOf(ix, b.hi.x, ix.origin.x), cellOf(ix, b.hi.y, ix.origin.y))

proc insert*(ix: SpatialIndex, c: Copper) =
  ## Adds one feature (`c.box` and `c.layer` set by `graph.addCopper`).
  if c == nil or c.layer == nil or c.box.isEmpty: return
  let
    layerKey = int32(c.layer.index)
    r = cellRange(ix, c.box)
    nx = int(r.x1 - r.x0) + 1
    ny = int(r.y1 - r.y0) + 1
  if nx * ny > ix.maxCells:
    if not ix.oversized.hasKey(layerKey):
      ix.oversized[layerKey] = @[]
    ix.oversized[layerKey].add(c)
    return
  for cx in r.x0 .. r.x1:
    for cy in r.y0 .. r.y1:
      let k: GridKey = (layerKey, cx, cy)
      if not ix.buckets.hasKey(k):
        ix.buckets[k] = @[]
      ix.buckets[k].add(c)

proc rebuild*(pcb: Pcb) =
  ## Rebuilds the index from the graph; queries call it when `dirty`.
  if pcb.index == nil:
    pcb.index = newSpatialIndex()
  let ix = pcb.index
  ix.buckets.clear()
  ix.oversized.clear()
  # Anchor the grid at the board so cell indices stay small.
  let bb = boardBox(pcb)
  ix.origin = if bb.isEmpty: pt(nm(0), nm(0)) else: bb.lo
  for _, l in pcb.layers:
    for c in l.copper:
      insert(ix, c)
  ix.dirty = false

proc ensureFresh(pcb: Pcb) {.inline.} =
  if pcb.index == nil or pcb.index.dirty:
    rebuild(pcb)

proc candidates*(pcb: Pcb, layer: PcbLayer, b: Box): seq[Copper] =
  ## Features on `layer` whose box may overlap `b`; deduplicated, **not**
  ## exact.
  if layer == nil or b.isEmpty: return
  ensureFresh(pcb)
  let
    ix = pcb.index
    layerKey = int32(layer.index)
    r = cellRange(ix, b)
  var seen = initHashSet[uint]()
  for cx in r.x0 .. r.x1:
    for cy in r.y0 .. r.y1:
      let k: GridKey = (layerKey, cx, cy)
      if not ix.buckets.hasKey(k): continue
      for c in ix.buckets[k]:
        if not c.box.overlaps(b): continue
        let id = cast[uint](c)
        if seen.containsOrIncl(id): continue
        result.add(c)
  if ix.oversized.hasKey(layerKey):
    for c in ix.oversized[layerKey]:
      if not c.box.overlaps(b): continue
      let id = cast[uint](c)
      if seen.containsOrIncl(id): continue
      result.add(c)

proc query*(pcb: Pcb, layer: PcbLayer, b: Box): seq[Copper] =
  ## Bounding-box candidates on one layer. See `hitTest` for exact results.
  candidates(pcb, layer, b)

proc query*(pcb: Pcb, b: Box): seq[Copper] =
  ## Bounding-box candidates across every layer.
  for _, l in pcb.layers:
    result.add(candidates(pcb, l, b))

proc queryPoint*(pcb: Pcb, layer: PcbLayer, p: Point): seq[Copper] =
  ## Candidates whose bounding box contains `p`.
  candidates(pcb, layer, Box(lo: p, hi: p))

proc hitTest*(pcb: Pcb, layer: PcbLayer, p: Point): seq[Copper] =
  ## Features actually covering `p` (exact `geometry.contains`). Negative
  ## features are included; the caller decides what they mean.
  for c in queryPoint(pcb, layer, p):
    if contains(c.shape, p):
      result.add(c)

proc near*(pcb: Pcb, layer: PcbLayer, p: Point, maxDist: Nm): seq[Copper] =
  ## Features within `maxDist` of `p`, exactly measured, nearest first.
  let limit = maxDist.raw.float
  var scored: seq[tuple[d: float, c: Copper]]
  for c in candidates(pcb, layer, Box(lo: p, hi: p).expand(maxDist)):
    let d = distanceTo(c.shape, p)
    if d <= limit:
      scored.add((d, c))
  scored.sort(proc (a, b: tuple[d: float, c: Copper]): int =
    cmp(a.d, b.d))
  for s in scored: result.add(s.c)

proc nearestNet*(pcb: Pcb, layer: PcbLayer, p: Point, maxDist: Nm): Net =
  ## The net of the closest copper within `maxDist`, or `nil`.
  for c in near(pcb, layer, p, maxDist):
    if c.net != nil: return c.net
  nil

proc copperInBox*(pcb: Pcb, layer: PcbLayer, b: Box): seq[Copper] =
  ## Features intersecting `b`: candidates filtered by an exact test at the
  ## box corners and centre plus box overlap. Not a true polygon clip.
  for c in candidates(pcb, layer, b):
    if b.contains(c.box) or c.box.contains(b):
      result.add(c)
    elif contains(c.shape, b.center) or b.contains(c.box.center):
      result.add(c)
    elif c.box.overlaps(b):
      result.add(c)
