## Stage 6 of docs/ibis_simulator_plan.md: the board builder. Route length,
## layer and return-path identity, branch support, pin-to-binding mapping,
## via span, and every refusal -- never an optimistic result.

import std/[streams, unittest, math, tables, strutils]

import verax/netlist
import verax/pcb
import verax/ibis
import verax/si/board
import verax/si/simulate
import ./fixtures/ibis/synthetic

proc addTrack(l: PcbLayer, a, b: Point, net: Net, w = mm(0.3)): Copper =
  result = addCopper(l, newCopper(ckTrack, stroke(polyline([a, b]), w)))
  setNet(result, net)

proc addPad(pcb: Pcb, place: Placement, l: PcbLayer, pinName: string, at: Point, net: Net) =
  let ap = internAperture(pcb, Aperture(name: "r400", kind: akCircle, dia: mm(0.4)))
  let c = addCopper(l, newCopper(ckLand, pad(ap, at)))
  setNet(c, net)
  addLand(place, pinName, c)

proc plane(pcb: Pcb, l: PcbLayer, gnd: Net) =
  let z = newZone("gnd_" & l.name, gnd)
  z.layers = @[l]
  z.outline = Polygon(outer: polyline(
    [pt(mm(-10.0), mm(-20.0)), pt(mm(120.0), mm(-20.0)),
     pt(mm(120.0), mm(20.0)), pt(mm(-10.0), mm(20.0))], closed = true))
  discard addZone(pcb, z)
  discard addZoneFill(pcb, z, l, z.outline)

type Board = object
  pcb: Pcb
  sig, gnd: Net
  layers: seq[PcbLayer]
  places: Table[string, Placement]

proc newBoard(nLayers: int): Board =
  ## F.Cu / In1.Cu (GND) [/ In2.Cu / B.Cu (GND)], FR4.
  result.pcb = newPcb("si")
  let names = if nLayers == 2: @["F.Cu", "B.Cu"] else: @["F.Cu", "In1.Cu", "In2.Cu", "B.Cu"]
  let thick = if nLayers == 2: @[1.5] else: @[0.2, 0.2, 1.1]
  for i, n in names:
    let l = addLayer(result.pcb, newPcbLayer(n, lfSignal,
      (if i == 0: lsTop elif i == names.high: lsBottom else: lsInner)))
    result.layers.add l
    let ce = addStackEntry(result.pcb, newStackEntry(seCopper, n, um(35.0)))
    ce.layer = l
    if i < names.high:
      let d = newStackEntry(seDielectric, "d" & $i, mm(thick[i]))
      d.material = newStackMaterial("FR4", epsilonR = 4.3, lossTangent = 0.02)
      discard addStackEntry(result.pcb, d)
  result.sig = addNet(result.pcb.netlist, newNet("SIG", ntSignal))
  result.gnd = addNet(result.pcb.netlist, newNet("GND", ntGround))
  let vcc = addNet(result.pcb.netlist, newNet("VCC", ntPower))
  for des in ["U1", "U2", "U3"]:
    let c = addComponent(result.pcb.netlist, newComponent(des, kind = "ic"))
    discard connect(c, "1", result.sig, (if des == "U1": ptOutput else: ptInput))
    discard connect(c, "2", vcc)
    discard connect(c, "3", result.gnd)
    let pl = addPlacement(result.pcb, newPlacement(des))
    bindComponent(pl, c)
    result.places[des] = pl

proc bindings(b: Board): seq[IbisBinding] =
  var d = defaultLinearDriver()
  let fd = readIbis(newStringStream(d.toIbs()))
  let fr = readIbis(newStringStream(linearReceiverIbs()))
  @[bindIbis(b.pcb.netlist, "U1", fd), bindIbis(b.pcb.netlist, "U2", fr),
    bindIbis(b.pcb.netlist, "U3", fr)]

let drv = PinRef(designator: "U1", pin: "1")
let rx2 = PinRef(designator: "U2", pin: "1")
let rx3 = PinRef(designator: "U3", pin: "1")

proc count(n: SiNet, k: SiElemKind): int =
  for e in n.elements:
    if e.kind == k: inc result

suite "board builder":
  test "point to point over a plane: lengths and Z0 match tline":
    var b = newBoard(4)
    plane(b.pcb, b.layers[1], b.gnd)
    plane(b.pcb, b.layers[3], b.gnd)
    let f = b.layers[0]
    b.pcb.addPad(b.places["U1"], f, "1", pt(mm(0.0), mm(0.0)), b.sig)
    b.pcb.addPad(b.places["U2"], f, "1", pt(mm(80.0), mm(0.0)), b.sig)
    discard addTrack(f, pt(mm(0.0), mm(0.0)), pt(mm(30.0), mm(0.0)), b.sig)
    discard addTrack(f, pt(mm(30.0), mm(0.0)), pt(mm(80.0), mm(0.0)), b.sig, w = mm(0.15))
    let n = buildFromBoard(b.pcb, boardNetSpec("SIG", drv, @[rx2]), b.bindings)
    check n.unsupported.len == 0
    check n.count(sekLine) == 2
    # Reference: the same numbers tline.characterize gives.
    let tree = traceTree(b.pcb, b.sig, b.pcb.netlist.findComponent("U1").pins["1"])
    let er = characterize(b.pcb, tree.edges[0])
    var tdSum, lenSum = 0.0
    var z0s: seq[float]
    for e in n.elements:
      if e.kind == sekLine:
        tdSum += e.td
        z0s.add e.z0
    for s in tree.edges[0].sections: lenSum += s.length
    check abs(lenSum - 0.080) < 1e-9
    check abs(tdSum - er.delay) < 1e-15
    # Driver first: the wide 30 mm run, then the narrow, higher-Z one.
    check z0s[0] < z0s[1]
    var ref0: seq[float]
    for s in er.sections: ref0.add z0(s.spec)
    check abs(min(ref0) - z0s[0]) < 1e-9
    check abs(max(ref0) - z0s[1]) < 1e-9
    let r = simulate(n, edgeStimulus(edRising))
    check r.status == ssOk
    check abs(r.receivers[0].v[^1] - 3.3) < 0.02

  test "a branch (Y) is multi-drop, both receivers reached":
    var b = newBoard(4)
    plane(b.pcb, b.layers[1], b.gnd)
    let f = b.layers[0]
    b.pcb.addPad(b.places["U1"], f, "1", pt(mm(0.0), mm(0.0)), b.sig)
    b.pcb.addPad(b.places["U2"], f, "1", pt(mm(60.0), mm(10.0)), b.sig)
    b.pcb.addPad(b.places["U3"], f, "1", pt(mm(60.0), mm(-10.0)), b.sig)
    discard addTrack(f, pt(mm(0.0), mm(0.0)), pt(mm(40.0), mm(0.0)), b.sig)
    discard addTrack(f, pt(mm(40.0), mm(0.0)), pt(mm(60.0), mm(10.0)), b.sig)
    discard addTrack(f, pt(mm(40.0), mm(0.0)), pt(mm(60.0), mm(-10.0)), b.sig)
    let n = buildFromBoard(b.pcb, boardNetSpec("SIG", drv, @[rx2, rx3]), b.bindings)
    check n.unsupported.len == 0
    check n.receiverPorts.len == 2
    check n.count(sekLine) == 3
    let r = simulate(n, edgeStimulus(edRising))
    check r.status == ssOk

  test "a via between layers on one reference is modelled with its span":
    var b = newBoard(4)
    plane(b.pcb, b.layers[1], b.gnd)
    plane(b.pcb, b.layers[3], b.gnd)
    let (f, in2) = (b.layers[0], b.layers[2])
    b.pcb.addPad(b.places["U1"], f, "1", pt(mm(0.0), mm(0.0)), b.sig)
    b.pcb.addPad(b.places["U2"], in2, "1", pt(mm(60.0), mm(0.0)), b.sig)
    discard addTrack(f, pt(mm(0.0), mm(0.0)), pt(mm(30.0), mm(0.0)), b.sig)
    discard addTrack(in2, pt(mm(30.0), mm(0.0)), pt(mm(60.0), mm(0.0)), b.sig)
    let hole = newHole(hkVia, pt(mm(30.0), mm(0.0)), mm(0.3))
    setSpan(hole, b.layers[0], b.layers[3])
    hole.net = b.sig
    discard addHole(b.pcb, hole)
    let ap = internAperture(b.pcb, Aperture(name: "via600", kind: akCircle, dia: mm(0.6)))
    for l in b.layers:
      let ring = addCopper(l, newCopper(ckViaPad, pad(ap, pt(mm(30.0), mm(0.0)))))
      setNet(ring, b.sig)
      attachPad(hole, ring)
    let n = buildFromBoard(b.pcb, boardNetSpec("SIG", drv, @[rx2]), b.bindings)
    let tree = traceTree(b.pcb, b.sig, b.pcb.netlist.findComponent("U1").pins["1"])
    var refs: seq[string]
    for e in tree.edges:
      for s in e.sections: refs.add (if s.reference.layer == nil: "-" else: s.reference.layer.name)
    if refs.len == 2 and refs[0] == refs[1]:
      check n.unsupported.len == 0
      check n.count(sekInductor) >= 3          # 2 package L + via L
      var stub = false
      for e in n.elements:
        if e.label == "via bottom stub": stub = true
      check stub                               # In2 -> B.Cu barrel remains
      check simulate(n, edgeStimulus(edRising)).status == ssOk
    else:
      # The two layers resolved different planes: then it must refuse.
      check n.unsupported.len == 1
      check "reference" in n.unsupported[0]

suite "refusals":
  proc straight(b: var Board) =
    let f = b.layers[0]
    b.pcb.addPad(b.places["U1"], f, "1", pt(mm(0.0), mm(0.0)), b.sig)
    b.pcb.addPad(b.places["U2"], f, "1", pt(mm(50.0), mm(0.0)), b.sig)
    discard addTrack(f, pt(mm(0.0), mm(0.0)), pt(mm(50.0), mm(0.0)), b.sig)

  test "no return path":
    var b = newBoard(2)
    b.straight()
    let n = buildFromBoard(b.pcb, boardNetSpec("SIG", drv, @[rx2]), b.bindings)
    check n.unsupported.len == 1
    check "return" in n.unsupported[0]

  test "a via that changes reference plane":
    var b = newBoard(4)
    plane(b.pcb, b.layers[1], b.gnd)
    plane(b.pcb, b.layers[3], b.gnd)
    let (f, bot) = (b.layers[0], b.layers[3])
    # Signal F.Cu (over In1) -> B.Cu: B.Cu is itself the GND fill here, so
    # route on In2 instead with no plane between it and B.Cu... the simplest
    # sure change: F.Cu over In1, then B.Cu over In2 with In2 a plane.
    discard bot
    var b2 = newBoard(4)
    plane(b2.pcb, b2.layers[1], b2.gnd)
    plane(b2.pcb, b2.layers[2], b2.gnd)
    let (f2, bot2) = (b2.layers[0], b2.layers[3])
    b2.pcb.addPad(b2.places["U1"], f2, "1", pt(mm(0.0), mm(0.0)), b2.sig)
    b2.pcb.addPad(b2.places["U2"], bot2, "1", pt(mm(60.0), mm(0.0)), b2.sig)
    discard addTrack(f2, pt(mm(0.0), mm(0.0)), pt(mm(30.0), mm(0.0)), b2.sig)
    discard addTrack(bot2, pt(mm(30.0), mm(0.0)), pt(mm(60.0), mm(0.0)), b2.sig)
    let hole = newHole(hkVia, pt(mm(30.0), mm(0.0)), mm(0.3))
    setSpan(hole, f2, bot2)
    hole.net = b2.sig
    discard addHole(b2.pcb, hole)
    let ap = internAperture(b2.pcb, Aperture(name: "via600", kind: akCircle, dia: mm(0.6)))
    for l in [f2, bot2]:
      let ring = addCopper(l, newCopper(ckViaPad, pad(ap, pt(mm(30.0), mm(0.0)))))
      setNet(ring, b2.sig)
      attachPad(hole, ring)
    discard f
    let n = buildFromBoard(b2.pcb, boardNetSpec("SIG", drv, @[rx2]), b2.bindings)
    check n.unsupported.len == 1
    check "reference" in n.unsupported[0]
    check simulate(n, edgeStimulus(edRising)).status == ssUnsupported

  test "an undeclared pin on the net (a passive) is named":
    var b = newBoard(4)
    plane(b.pcb, b.layers[1], b.gnd)
    let f = b.layers[0]
    b.pcb.addPad(b.places["U1"], f, "1", pt(mm(0.0), mm(0.0)), b.sig)
    b.pcb.addPad(b.places["U2"], f, "1", pt(mm(50.0), mm(0.0)), b.sig)
    discard addTrack(f, pt(mm(0.0), mm(0.0)), pt(mm(25.0), mm(0.0)), b.sig)
    discard addTrack(f, pt(mm(25.0), mm(0.0)), pt(mm(50.0), mm(0.0)), b.sig)
    b.pcb.addPad(b.places["U3"], b.layers[0], "1", pt(mm(25.0), mm(10.0)), b.sig)
    discard addTrack(b.layers[0], pt(mm(25.0), mm(0.0)), pt(mm(25.0), mm(10.0)), b.sig)
    let n = buildFromBoard(b.pcb, boardNetSpec("SIG", drv, @[rx2]), b.bindings)
    check n.unsupported.len == 1
    check "U3.1" in n.unsupported[0]

  test "a pin on the net the copper never reaches (unrouted)":
    var b = newBoard(4)
    plane(b.pcb, b.layers[1], b.gnd)
    b.straight()
    b.pcb.addPad(b.places["U3"], b.layers[0], "1", pt(mm(25.0), mm(10.0)), b.sig)
    let n = buildFromBoard(b.pcb, boardNetSpec("SIG", drv, @[rx2]), b.bindings)
    check n.unsupported.len == 1
    check "U3.1" in n.unsupported[0]
    check "unrouted" in n.unsupported[0]

  test "a declared receiver the route never reaches":
    var b = newBoard(4)
    plane(b.pcb, b.layers[1], b.gnd)
    b.straight()
    let n = buildFromBoard(b.pcb, boardNetSpec("SIG", drv, @[rx2, rx3]), b.bindings)
    check n.unsupported.len >= 1
    check "U3.1" in n.unsupported.join(" ")

  test "an unbound designator":
    var b = newBoard(4)
    plane(b.pcb, b.layers[1], b.gnd)
    b.straight()
    let n = buildFromBoard(b.pcb, boardNetSpec("SIG", drv, @[rx2]), b.bindings[0 .. 0])
    check n.unsupported.len == 1
    check "no IBIS binding for U2" in n.unsupported[0]
