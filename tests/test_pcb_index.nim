import std/[random, tables, unittest]

import verax/netlist
import verax/pcb

proc bruteForce(l: PcbLayer, b: Box): seq[Copper] =
  ## The definition the grid is supposed to accelerate.
  for c in l.copper:
    if c.box.overlaps(b): result.add(c)

proc sameSet(a, b: seq[Copper]): bool =
  if a.len != b.len: return false
  for c in a:
    if c notin b: return false
  true

proc randomBoard(n: int, seed: int64): Pcb =
  result = newPcb("random")
  let top = addLayer(result, newPcbLayer("F.Cu", lfSignal, lsTop))
  discard addLayer(result, newPcbLayer("B.Cu", lfSignal, lsBottom))
  var r = initRand(seed)
  for i in 0 ..< n:
    let
      x = mm(r.rand(0.0 .. 100.0))
      y = mm(r.rand(0.0 .. 80.0))
      dx = mm(r.rand(0.1 .. 6.0))
      dy = mm(r.rand(0.1 .. 6.0))
    discard addCopper(top, newCopper(ckTrack,
      stroke(polyline([pt(x, y), pt(x + dx, y + dy)]), mm(0.2))))

test "grid queries agree with a brute-force scan":
  let pcb = randomBoard(400, 20260819)
  let top = pcb.layer("F.Cu")
  var r = initRand(7)
  for trial in 0 ..< 200:
    let
      x = mm(r.rand(-10.0 .. 110.0))
      y = mm(r.rand(-10.0 .. 90.0))
      w = mm(r.rand(0.05 .. 25.0))
      h = mm(r.rand(0.05 .. 25.0))
      probe = boxOf(pt(x, y), pt(x + w, y + h))
    check sameSet(query(pcb, top, probe), bruteForce(top, probe))

test "queries return no duplicates for a feature spanning many cells":
  let pcb = newPcb("dupes")
  let top = addLayer(pcb, newPcbLayer("F.Cu", lfSignal, lsTop))
  # 30mm long at a 1mm grid pitch: this feature lives in many buckets.
  let long = addCopper(top, newCopper(ckTrack,
    stroke(polyline([pt(mm(0.0), mm(0.0)), pt(mm(30.0), mm(0.0))]), mm(0.2))))
  let hits = query(pcb, top, boxOf(pt(mm(-5.0), mm(-5.0)), pt(mm(40.0), mm(5.0))))
  check hits.len == 1
  check hits[0] == long

test "oversized features go to the overflow list and are still found":
  let pcb = newPcb("oversized")
  let top = addLayer(pcb, newPcbLayer("F.Cu", lfSignal, lsTop))
  # A 60x60mm pour at a 1mm pitch spans 3721 cells, far past maxCells.
  let pour = addCopper(top, newCopper(ckZone,
    fill(rectPolygon(mm(60.0), mm(60.0), pt(mm(30.0), mm(30.0))))))
  let track = addCopper(top, newCopper(ckTrack,
    stroke(polyline([pt(mm(10.0), mm(10.0)), pt(mm(12.0), mm(10.0))]), mm(0.2))))
  rebuild(pcb)
  check pcb.index.oversized[int32(top.index)].len == 1
  check pcb.index.oversized[int32(top.index)][0] == pour

  let hits = query(pcb, top, boxOf(pt(mm(10.5), mm(9.5)), pt(mm(11.5), mm(10.5))))
  check sameSet(hits, @[pour, track])

test "the index rebuilds itself after a mutation":
  let pcb = newPcb("dirty")
  let top = addLayer(pcb, newPcbLayer("F.Cu", lfSignal, lsTop))
  let a = addCopper(top, newCopper(ckTrack,
    stroke(polyline([pt(mm(0.0), mm(0.0)), pt(mm(5.0), mm(0.0))]), mm(0.2))))
  rebuild(pcb)
  check not pcb.index.dirty
  check query(pcb, top, boxOf(pt(mm(0.0), mm(0.0)), pt(mm(1.0), mm(1.0)))).len == 1

  # Adding marks the index stale, and the next query refreshes it.
  let b = addCopper(top, newCopper(ckTrack,
    stroke(polyline([pt(mm(0.0), mm(0.5)), pt(mm(5.0), mm(0.5))]), mm(0.2))))
  check pcb.index.dirty
  check query(pcb, top, boxOf(pt(mm(0.0), mm(0.0)), pt(mm(1.0), mm(1.0)))).len == 2
  check not pcb.index.dirty

  removeCopper(top, b)
  check query(pcb, top, boxOf(pt(mm(0.0), mm(0.0)), pt(mm(1.0), mm(1.0)))) == @[a]

  # Moving a feature re-boxes it and moves it in the grid.
  setShape(a, stroke(polyline([pt(mm(50.0), mm(50.0)), pt(mm(55.0), mm(50.0))]), mm(0.2)))
  check query(pcb, top, boxOf(pt(mm(0.0), mm(0.0)), pt(mm(1.0), mm(1.0)))).len == 0
  check query(pcb, top, boxOf(pt(mm(50.0), mm(49.9)), pt(mm(51.0), mm(50.1)))).len == 1

test "hitTest is exact where a bounding-box query is only a candidate list":
  let pcb = newPcb("exact")
  let top = addLayer(pcb, newPcbLayer("F.Cu", lfSignal, lsTop))
  # A diagonal track: its bounding box covers the corner, the copper doesn't.
  discard addCopper(top, newCopper(ckTrack,
    stroke(polyline([pt(mm(0.0), mm(0.0)), pt(mm(10.0), mm(10.0))]), mm(0.2))))
  let corner = pt(mm(9.5), mm(0.5))
  check queryPoint(pcb, top, corner).len == 1
  check hitTest(pcb, top, corner).len == 0
  check hitTest(pcb, top, pt(mm(5.0), mm(5.0))).len == 1

test "queries are scoped to one layer":
  let pcb = newPcb("layers")
  let top = addLayer(pcb, newPcbLayer("F.Cu", lfSignal, lsTop))
  let bot = addLayer(pcb, newPcbLayer("B.Cu", lfSignal, lsBottom))
  let here = pt(mm(1.0), mm(1.0))
  discard addCopper(top, newCopper(ckTrack,
    stroke(polyline([pt(mm(0.0), mm(1.0)), pt(mm(5.0), mm(1.0))]), mm(0.4))))
  discard addCopper(bot, newCopper(ckTrack,
    stroke(polyline([pt(mm(0.0), mm(1.0)), pt(mm(5.0), mm(1.0))]), mm(0.4))))
  check hitTest(pcb, top, here).len == 1
  check hitTest(pcb, bot, here).len == 1
  check query(pcb, boxOf(here, here)).len == 2

test "near returns features in distance order and nearestNet answers the probe question":
  let pcb = newPcb("probe")
  let nl = pcb.netlist
  let top = addLayer(pcb, newPcbLayer("F.Cu", lfSignal, lsTop))
  let sda = addNet(nl, newNet("SDA", ntSignal))
  let scl = addNet(nl, newNet("SCL", ntSignal))

  let far = addCopper(top, newCopper(ckTrack,
    stroke(polyline([pt(mm(0.0), mm(3.0)), pt(mm(10.0), mm(3.0))]), mm(0.2))))
  setNet(far, scl)
  let close = addCopper(top, newCopper(ckTrack,
    stroke(polyline([pt(mm(0.0), mm(1.0)), pt(mm(10.0), mm(1.0))]), mm(0.2))))
  setNet(close, sda)

  let probe = pt(mm(5.0), mm(1.5))
  let ranked = near(pcb, top, probe, mm(5.0))
  check ranked.len == 2
  check ranked[0] == close
  check ranked[1] == far
  check nearestNet(pcb, top, probe, mm(5.0)).name == "SDA"
  check near(pcb, top, probe, mm(0.1)).len == 0
  check nearestNet(pcb, top, probe, mm(0.1)) == nil
