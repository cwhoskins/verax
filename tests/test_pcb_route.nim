## `verax/pcb/trace`: stitching a net's copper into a route. Each test builds
## only the copper it needs, since stray copper is what breaks fixtures here.

import std/[tables, unittest]

import verax/netlist
import verax/pcb

proc hasIssue(issues: seq[Issue], kind: string): bool =
  for i in issues:
    if i.kind == kind: return true
  false

proc addTrack(l: PcbLayer, a, b: Point, w = mm(0.2), net: Net = nil): Copper =
  result = addCopper(l, newCopper(ckTrack, stroke(polyline([a, b]), w)))
  if net != nil: setNet(result, net)

proc addPad(pcb: Pcb, place: Placement, l: PcbLayer, pinName: string, at: Point,
           net: Net): Copper =
  let ap = internAperture(pcb, Aperture(name: "r400", kind: akCircle, dia: mm(0.4)))
  result = addCopper(l, newCopper(ckLand, pad(ap, at)))
  setNet(result, net)
  addLand(place, pinName, result)

proc twoPinBoard(): tuple[pcb: Pcb, top: PcbLayer, net: Net, p1, p2: Pin] =
  let pcb = newPcb("route")
  let top = addLayer(pcb, newPcbLayer("F.Cu", lfSignal, lsTop))
  let net = addNet(pcb.netlist, newNet("SIG", ntSignal))
  let u1 = addComponent(pcb.netlist, newComponent("U1", kind = "conn"))
  let u2 = addComponent(pcb.netlist, newComponent("U2", kind = "conn"))
  discard connect(u1, "1", net, ptOutput)
  discard connect(u2, "1", net, ptInput)
  let pl1 = addPlacement(pcb, newPlacement("U1"))
  let pl2 = addPlacement(pcb, newPlacement("U2"))
  bindComponent(pl1, u1)
  bindComponent(pl2, u2)
  discard addPad(pcb, pl1, top, "1", pt(mm(0.0), mm(0.0)), net)
  discard addPad(pcb, pl2, top, "1", pt(mm(10.0), mm(0.0)), net)
  (pcb, top, net, u1.pins["1"], u2.pins["1"])

test "a straight two-segment run collapses to one edge":
  let (pcb, top, net, p1, p2) = twoPinBoard()
  discard addTrack(top, pt(mm(0.0), mm(0.0)), pt(mm(5.0), mm(0.0)), net = net)
  discard addTrack(top, pt(mm(5.0), mm(0.0)), pt(mm(10.0), mm(0.0)), net = net)

  let graphs = extractRoutes(pcb, net)
  check graphs.len == 1
  check graphs[0].edges.len == 1
  check graphs[0].edges[0].sections.len == 1
  check graphs[0].edges[0].sections[0].copper.len == 2

  let tree = rootedAt(graphs[0], p1)
  check tree.root != nil
  check tree.root.pin == p1
  let path = pathTo(tree, p2)
  check path.len == 1

test "a Y gives one trunk and two branches, the trunk shared":
  let pcb = newPcb("y")
  let top = addLayer(pcb, newPcbLayer("F.Cu", lfSignal, lsTop))
  let net = addNet(pcb.netlist, newNet("SIG", ntSignal))
  let drv = addComponent(pcb.netlist, newComponent("U1"))
  let r1 = addComponent(pcb.netlist, newComponent("U2"))
  let r2 = addComponent(pcb.netlist, newComponent("U3"))
  discard connect(drv, "1", net, ptOutput)
  discard connect(r1, "1", net, ptInput)
  discard connect(r2, "1", net, ptInput)
  let pd = addPlacement(pcb, newPlacement("U1"))
  let p1 = addPlacement(pcb, newPlacement("U2"))
  let p2 = addPlacement(pcb, newPlacement("U3"))
  bindComponent(pd, drv)
  bindComponent(p1, r1)
  bindComponent(p2, r2)
  discard addPad(pcb, pd, top, "1", pt(mm(0.0), mm(0.0)), net)
  discard addPad(pcb, p1, top, "1", pt(mm(10.0), mm(10.0)), net)
  discard addPad(pcb, p2, top, "1", pt(mm(10.0), mm(-10.0)), net)
  # trunk
  discard addTrack(top, pt(mm(0.0), mm(0.0)), pt(mm(5.0), mm(0.0)), net = net)
  # branches, off the same junction point
  discard addTrack(top, pt(mm(5.0), mm(0.0)), pt(mm(10.0), mm(10.0)), net = net)
  discard addTrack(top, pt(mm(5.0), mm(0.0)), pt(mm(10.0), mm(-10.0)), net = net)

  let graphs = extractRoutes(pcb, net)
  check graphs.len == 1
  check graphs[0].edges.len == 3
  # One real junction (degree 3, no pin/via/pour) survives the degree-2
  # collapse.
  var junctions = 0
  for n in graphs[0].nodes:
    if n.kind == rnJunction: inc junctions
  check junctions == 1

  let tree = rootedAt(graphs[0], drv.pins["1"])
  check tree.edges.len == 3                # trunk -> junction, then 2 branches
  let path1 = pathTo(tree, r1.pins["1"])
  let path2 = pathTo(tree, r2.pins["1"])
  check path1.len == 2
  check path2.len == 2
  check path1[0] == path2[0]                # the shared trunk edge

test "a via splits an edge and produces an rnVia node":
  let pcb = newPcb("via")
  let top = addLayer(pcb, newPcbLayer("F.Cu", lfSignal, lsTop))
  let bot = addLayer(pcb, newPcbLayer("B.Cu", lfSignal, lsBottom))
  let net = addNet(pcb.netlist, newNet("SIG", ntSignal))
  let u1 = addComponent(pcb.netlist, newComponent("U1"))
  let u2 = addComponent(pcb.netlist, newComponent("U2"))
  discard connect(u1, "1", net, ptOutput)
  discard connect(u2, "1", net, ptInput)
  let pl1 = addPlacement(pcb, newPlacement("U1"))
  let pl2 = addPlacement(pcb, newPlacement("U2"))
  bindComponent(pl1, u1)
  bindComponent(pl2, u2)
  discard addPad(pcb, pl1, top, "1", pt(mm(0.0), mm(0.0)), net)
  discard addPad(pcb, pl2, bot, "1", pt(mm(10.0), mm(0.0)), net)

  discard addTrack(top, pt(mm(0.0), mm(0.0)), pt(mm(5.0), mm(0.0)), net = net)
  discard addTrack(bot, pt(mm(5.0), mm(0.0)), pt(mm(10.0), mm(0.0)), net = net)

  let hole = newHole(hkVia, pt(mm(5.0), mm(0.0)), mm(0.3))
  setSpan(hole, top, bot)
  hole.net = net
  discard addHole(pcb, hole)
  let viaAp = internAperture(pcb, Aperture(name: "via600", kind: akCircle, dia: mm(0.6)))
  let ringTop = addCopper(top, newCopper(ckViaPad, pad(viaAp, pt(mm(5.0), mm(0.0)))))
  setNet(ringTop, net)
  attachPad(hole, ringTop)
  let ringBot = addCopper(bot, newCopper(ckViaPad, pad(viaAp, pt(mm(5.0), mm(0.0)))))
  setNet(ringBot, net)
  attachPad(hole, ringBot)

  let graphs = extractRoutes(pcb, net)
  check graphs.len == 1
  check graphs[0].edges.len == 2             # via keeps the two layers separate
  var vias = 0
  for n in graphs[0].nodes:
    if n.kind == rnVia:
      inc vias
      check n.hole == hole
  check vias == 1

test "endpoints 0.5um apart join, 5um apart do not":
  block joins:
    let pcb = newPcb("tol-join")
    let top = addLayer(pcb, newPcbLayer("F.Cu", lfSignal, lsTop))
    let net = addNet(pcb.netlist, newNet("SIG", ntSignal))
    discard addTrack(top, pt(mm(0.0), mm(0.0)), pt(mm(5.0), mm(0.0)), net = net)
    # Offset 500nm, inside the default 1um `joinTol`.
    let offset = pt(mm(5.0), mm(0.0)) + pt(nm(500), nm(0))
    discard addTrack(top, offset, pt(mm(10.0), mm(0.0)), net = net)
    let graphs = extractRoutes(pcb, net)
    check graphs.len == 1
    check graphs[0].edges.len == 1

  block doesNotJoin:
    let pcb = newPcb("tol-nojoin")
    let top = addLayer(pcb, newPcbLayer("F.Cu", lfSignal, lsTop))
    let net = addNet(pcb.netlist, newNet("SIG", ntSignal))
    discard addTrack(top, pt(mm(0.0), mm(0.0)), pt(mm(5.0), mm(0.0)), net = net)
    # Offset 5um, outside the default 1um `joinTol`.
    let offset = pt(mm(5.0), mm(0.0)) + pt(nm(5000), nm(0))
    discard addTrack(top, offset, pt(mm(10.0), mm(0.0)), net = net)
    let graphs = extractRoutes(pcb, net)
    check graphs.len == 2
    for g in graphs:
      check hasIssue(g.issues, "route_disconnected")

test "a loop reports route_loop and lands in extra":
  let pcb = newPcb("loop")
  let top = addLayer(pcb, newPcbLayer("F.Cu", lfSignal, lsTop))
  let net = addNet(pcb.netlist, newNet("SIG", ntSignal))
  let u1 = addComponent(pcb.netlist, newComponent("U1"))
  discard connect(u1, "1", net, ptOutput)
  let pl1 = addPlacement(pcb, newPlacement("U1"))
  bindComponent(pl1, u1)
  discard addPad(pcb, pl1, top, "1", pt(mm(0.0), mm(0.0)), net)

  let j1 = pt(mm(5.0), mm(0.0))
  let j2 = pt(mm(10.0), mm(5.0))
  let j3 = pt(mm(5.0), mm(10.0))
  discard addTrack(top, pt(mm(0.0), mm(0.0)), j1, net = net)   # trunk into the ring
  discard addTrack(top, j1, j2, net = net)
  discard addTrack(top, j2, j3, net = net)
  discard addTrack(top, j3, j1, net = net)                     # closes the ring

  let graphs = extractRoutes(pcb, net)
  check graphs.len == 1
  let tree = rootedAt(graphs[0], u1.pins["1"])
  check tree.extra.len == 1
  check hasIssue(tree.issues, "route_loop")
  check tree.extra[0].a == tree.extra[0].b       # the ring collapsed to a self-loop

test "a pour node refuses characterization by name":
  let pcb = newPcb("pour")
  let top = addLayer(pcb, newPcbLayer("F.Cu", lfSignal, lsTop))
  let net = addNet(pcb.netlist, newNet("GND", ntGround))
  let u1 = addComponent(pcb.netlist, newComponent("U1"))
  discard connect(u1, "1", net, ptPower)
  let pl1 = addPlacement(pcb, newPlacement("U1"))
  bindComponent(pl1, u1)
  discard addPad(pcb, pl1, top, "1", pt(mm(0.0), mm(0.0)), net)

  let z = newZone("gnd", net)
  z.layers = @[top]
  z.outline = Polygon(outer: polyline(
    [pt(mm(3.0), mm(-3.0)), pt(mm(9.0), mm(-3.0)),
     pt(mm(9.0), mm(3.0)), pt(mm(3.0), mm(3.0))], closed = true))
  discard addZone(pcb, z)
  discard addZoneFill(pcb, z, top, z.outline)

  # The track's far end lands inside the fill -- no pad drawn there at all.
  discard addTrack(top, pt(mm(0.0), mm(0.0)), pt(mm(6.0), mm(0.0)), net = net)

  let graphs = extractRoutes(pcb, net)
  check graphs.len == 1
  var pourNodes = 0
  for n in graphs[0].nodes:
    if n.kind == rnPour: inc pourNodes
  check pourNodes == 1
  check hasIssue(graphs[0].issues, "route_through_pour")

test "ckZone records are ignored while ckFill is not":
  let pcb = newPcb("zone-vs-fill")
  let top = addLayer(pcb, newPcbLayer("F.Cu", lfSignal, lsTop))
  let net = addNet(pcb.netlist, newNet("GND", ntGround))
  let z = newZone("gnd", net)
  z.layers = @[top]
  z.outline = Polygon(outer: polyline(
    [pt(mm(0.0), mm(0.0)), pt(mm(20.0), mm(0.0)),
     pt(mm(20.0), mm(20.0)), pt(mm(0.0), mm(20.0))], closed = true))
  discard addZone(pcb, z)             # pushes one ckZone record -- not copper
  discard addZoneFill(pcb, z, top, z.outline)   # the real, derived fill

  check pcb.copperOn("GND").len == 2   # both are in the net index...
  let graphs = extractRoutes(pcb, net)
  check graphs.len == 1                # ...but only the fill became a node
  check graphs[0].nodes.len == 1
  check graphs[0].nodes[0].kind == rnPour
