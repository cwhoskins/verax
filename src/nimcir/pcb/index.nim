## Location lookup over a board's copper.
##
## A uniform grid: every `Copper` carries a cached bounding box, and the index
## buckets feature references by grid cell, per layer. Build once after a load
## and rebuild after mutation -- `nimcir/pcb/graph` sets `dirty` on every
## change, and every query here rebuilds automatically when it is set.
##
## A board-sized plane would otherwise land in every bucket, which is the one
## real degradation mode of a uniform grid on PCB data, so any feature
## spanning more than `SpatialIndex.maxCells` cells goes into a per-layer
## `oversized` list that every query on that layer also scans.
##
## `query`, `queryPoint` and `near` return bounding-box **candidates**.
## `hitTest` applies the exact geometric predicates from `nimcir/pcb/geometry`
## on top. Do not mistake a candidate list for a hit list.

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
  ## Adds one feature. `c.box` and `c.layer` must already be set, which
  ## `graph.addCopper` guarantees.
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
  ## Discards and refills the index from the current graph. Called
  ## automatically by the queries below whenever `dirty` is set.
  if pcb.index == nil:
    pcb.index = newSpatialIndex()
  let ix = pcb.index
  ix.buckets.clear()
  ix.oversized.clear()
  # Anchor the grid at the board so cell indices stay small and positive-ish.
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
  ## Every feature on `layer` whose bounding box may overlap `b`. Results are
  ## de-duplicated (a feature spans several cells) but **not** exact.
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
  ## Features that actually cover `p`, using the exact `geometry.contains`
  ## predicates. Negative-polarity features are returned like any other --
  ## the caller decides whether they add or remove copper.
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
  ## The net of the closest copper feature within `maxDist`, or `nil`. The
  ## everyday "what am I probing here?" question.
  for c in near(pcb, layer, p, maxDist):
    if c.net != nil: return c.net
  nil

proc copperInBox*(pcb: Pcb, layer: PcbLayer, b: Box): seq[Copper] =
  ## Features genuinely intersecting `b`, filtering candidates down by an
  ## exact test at the box corners and centre plus a bounding-box overlap.
  ## Sufficient for region selection; a true polygon-clip test is a separate
  ## concern.
  for c in candidates(pcb, layer, b):
    if b.contains(c.box) or c.box.contains(b):
      result.add(c)
    elif contains(c.shape, b.center) or b.contains(c.box.center):
      result.add(c)
    elif c.box.overlaps(b):
      result.add(c)
