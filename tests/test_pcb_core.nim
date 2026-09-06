import std/[tables, unittest]

import nimcir/netlist
import nimcir/pcb

proc twoLayerBoard(): Pcb =
  ## A minimal but complete board: two copper layers plus mask, a stack-up,
  ## one net, one resistor placed with two lands, a track and a via.
  result = newPcb("demo")
  let nl = result.netlist

  let top = addLayer(result, newPcbLayer("F.Cu", lfSignal, lsTop))
  let bot = addLayer(result, newPcbLayer("B.Cu", lfSignal, lsBottom))
  let mask = addLayer(result, newPcbLayer("F.Mask", lfSolderMask, lsTop))
  mask.refLayer = top

  discard addStackEntry(result, newStackEntry(seCopper, "F.Cu", um(35.0)))
  let core = newStackEntry(seDielectric, "dielectric 1", mm(1.51))
  core.material = newStackMaterial("FR4", epsilonR = 4.5, lossTangent = 0.02)
  discard addStackEntry(result, core)
  discard addStackEntry(result, newStackEntry(seCopper, "B.Cu", um(35.0)))
  result.stackup.entries[0].layer = top
  result.stackup.entries[2].layer = bot

  let vout = addNet(nl, newNet("VOUT", ntSignal))
  let r1 = addComponent(nl, newComponent("R1", kind = "resistor"))
  discard connect(r1, "1", vout, ptPassive)
  discard connect(r1, "2", addNet(nl, newNet("GND", ntGround)), ptPassive)

  let place = addPlacement(result, newPlacement("R1", "Resistor_SMD:R_0402"))
  place.at = pt(mm(10.0), mm(10.0))
  place.mount = mkSmt
  bindComponent(place, r1)

  let padAp = internAperture(result, Aperture(name: "rect0.5x0.6",
                                              kind: akRect, w: mm(0.5), h: mm(0.6)))
  let land1 = addCopper(top, newCopper(ckLand, pad(padAp, pt(mm(9.5), mm(10.0)))))
  let land2 = addCopper(top, newCopper(ckLand, pad(padAp, pt(mm(10.5), mm(10.0)))))
  addLand(place, "1", land1)
  addLand(place, "2", land2)

  let track = addCopper(top, newCopper(ckTrack,
    stroke(polyline([pt(mm(9.5), mm(10.0)), pt(mm(2.0), mm(10.0))]), mm(0.25))))
  setNet(track, vout)

  let hole = newHole(hkVia, pt(mm(2.0), mm(10.0)), mm(0.3))
  hole.finishedDia = mm(0.25)
  setSpan(hole, top, bot)
  hole.net = vout
  discard addHole(result, hole)
  let ring = addCopper(top, newCopper(ckViaPad,
    pad(internAperture(result, Aperture(name: "r600", kind: akCircle, dia: mm(0.6))),
        pt(mm(2.0), mm(10.0)))))
  attachPad(hole, ring)

test "the board graph is walkable in both directions":
  let pcb = twoLayerBoard()

  # Down: board -> layer -> copper -> net -> pin -> component.
  let top = pcb.layer("F.Cu")
  check top.index == 0
  check top.copperIndex == 0
  check top.copper.len == 4
  let land = top.copper[0]
  check land.kind == ckLand
  check land.layer == top
  check land.layer.pcb == pcb
  check land.pin != nil
  check land.pin.component.designator == "R1"
  check land.net.name == "VOUT"

  # Up: netlist net -> its copper, and netlist component -> its placement.
  let vout = pcb.netlist.nets["VOUT"]
  check pcb.copperOn(vout).len == 3      # land 1, the track, and the via ring
  let place = pcb.placementOf(pcb.netlist.components["R1"])
  check place != nil
  check place.footprint == "Resistor_SMD:R_0402"
  check place.lands["1"][0] == land
  check place.lands.len == 2

test "copper is indexed by net name, and the index survives mutation":
  let pcb = twoLayerBoard()
  check pcb.copperOn("VOUT").len == 3
  check pcb.copperOn("VOUT", "F.Cu").len == 3
  check pcb.copperOn("VOUT", "B.Cu").len == 0
  check pcb.copperOn("GND").len == 1
  check pcb.copperOn("does-not-exist").len == 0

  # Re-pointing a feature moves it between buckets.
  let track = pcb.layer("F.Cu").copper[2]
  check track.kind == ckTrack
  setNet(track, pcb.netlist.nets["GND"])
  check pcb.copperOn("VOUT").len == 2
  check pcb.copperOn("GND").len == 2

  # Removing it drops it from the name index entirely.
  removeCopper(pcb.layer("F.Cu"), track)
  check pcb.copperOn("GND").len == 1
  check pcb.layer("F.Cu").copper.len == 3

test "source ordinals are contiguous after load and renumber on removal":
  let pcb = twoLayerBoard()
  let top = pcb.layer("F.Cu")
  for i, c in top.copper:
    check c.sourceIndex == i
  removeCopper(top, top.copper[0])
  for i, c in top.copper:
    check c.sourceIndex == i

test "duplicate layer names and designators raise PcbError":
  let pcb = newPcb("dup")
  discard addLayer(pcb, newPcbLayer("F.Cu", lfSignal, lsTop))
  expect(PcbError):
    discard addLayer(pcb, newPcbLayer("F.Cu", lfSignal, lsTop))

  discard addPlacement(pcb, newPlacement("R1"))
  expect(PcbError):
    discard addPlacement(pcb, newPlacement("R1"))

test "binding a placement to a mismatched component raises":
  let pcb = newPcb("mismatch")
  let c = addComponent(pcb.netlist, newComponent("U1"))
  let p = addPlacement(pcb, newPlacement("R9"))
  expect(PcbError):
    bindComponent(p, c)

test "apertures are interned rather than duplicated":
  let pcb = newPcb("apertures")
  let a = internAperture(pcb, Aperture(name: "r500", kind: akCircle, dia: mm(0.5)))
  let b = internAperture(pcb, Aperture(name: "r500", kind: akCircle, dia: mm(0.5)))
  check a == b
  check pcb.apertures.len == 1

test "hole span classifies vias and enumerates the layers it crosses":
  let pcb = newPcb("span")
  let top = addLayer(pcb, newPcbLayer("F.Cu", lfSignal, lsTop))
  let in1 = addLayer(pcb, newPcbLayer("In1.Cu", lfPlane, lsInner))
  let in2 = addLayer(pcb, newPcbLayer("In2.Cu", lfPlane, lsInner))
  let bot = addLayer(pcb, newPcbLayer("B.Cu", lfSignal, lsBottom))
  check pcb.copperLayers().len == 4
  check bot.copperIndex == 3

  let through = newHole(hkVia, pt(mm(1.0), mm(1.0)), mm(0.3))
  setSpan(through, top, bot)
  check through.viaKind == vkThrough
  check pcb.spanLayers(through).len == 4

  let blind = newHole(hkVia, pt(mm(2.0), mm(1.0)), mm(0.2))
  setSpan(blind, top, in1)
  check blind.viaKind == vkBlind
  check pcb.spanLayers(blind) == @[top, in1]

  let buried = newHole(hkVia, pt(mm(3.0), mm(1.0)), mm(0.2))
  setSpan(buried, in1, in2)
  check buried.viaKind == vkBuried
  check pcb.spanLayers(buried) == @[in1, in2]

test "a hole propagates its net to the pads attached to it":
  let pcb = twoLayerBoard()
  let hole = pcb.holes[0]
  check hole.kind == hkVia
  check hole.viaKind == vkThrough
  check hole.pads.len == 1
  check hole.pads[0].net.name == "VOUT"
  check hole.pads[0].hole == hole
  check hole.finishedDia == mm(0.25)

test "stack-up records physical order, thickness and dielectric material":
  let pcb = twoLayerBoard()
  check pcb.stackup.entries.len == 3
  check pcb.stackup.entries[0].kind == seCopper
  check pcb.stackup.entries[1].kind == seDielectric
  check pcb.stackup.entries[1].material.epsilonR == 4.5
  check pcb.stackup.totalThickness == um(35.0) + mm(1.51) + um(35.0)

  let between = pcb.dielectricBetween(pcb.layer("F.Cu"), pcb.layer("B.Cu"))
  check between.len == 1
  check between[0].name == "dielectric 1"
  check stackEntryFor(pcb, pcb.layer("F.Cu")).thickness == um(35.0)

test "a zone materialises one copper area per layer it covers":
  let pcb = twoLayerBoard()
  let gnd = pcb.netlist.nets["GND"]
  let z = newZone("gnd-pour", gnd)
  z.layers = @[pcb.layer("F.Cu"), pcb.layer("B.Cu")]
  z.outline = Polygon(outer: polyline(
    [pt(mm(0.0), mm(0.0)), pt(mm(20.0), mm(0.0)),
     pt(mm(20.0), mm(20.0)), pt(mm(0.0), mm(20.0))], closed = true))
  discard addZone(pcb, z)

  check z.areas.len == 2
  check z.areas[0].layer.name == "F.Cu"
  check z.areas[1].layer.name == "B.Cu"
  check z.areas[0].kind == ckZone
  check pcb.copperOn("GND").len == 3
  # Winding is normalised on the way in.
  check signedArea(z.outline.outer) > 0

test "non-copper layers hold graphics and point back at their copper layer":
  let pcb = twoLayerBoard()
  let mask = pcb.layer("F.Mask")
  check not mask.isCopper
  check mask.copperIndex == -1
  check mask.refLayer == pcb.layer("F.Cu")
  mask.shapes.add(fill(rectPolygon(mm(0.6), mm(0.7), pt(mm(9.5), mm(10.0)))))
  check mask.shapes.len == 1
  check box(mask.shapes[0]).center == pt(mm(9.5), mm(10.0))

test "board extent falls back to copper when no outline is stitched yet":
  let pcb = twoLayerBoard()
  let bb = boardBox(pcb)
  check not bb.isEmpty
  check bb.lo.x <= mm(2.0)
  check bb.hi.x >= mm(10.5)

  pcb.outline.boundary = Polygon(outer: polyline(
    [pt(mm(0.0), mm(0.0)), pt(mm(30.0), mm(0.0)),
     pt(mm(30.0), mm(20.0)), pt(mm(0.0), mm(20.0))], closed = true))
  check boardBox(pcb) == boxOf(pt(mm(0.0), mm(0.0)), pt(mm(30.0), mm(20.0)))

# --- multi-channel packages -----------------------------------------

import nimcir/netlist/packages

proc dualPackDef(): PackageDef =
  result = newPackageDef("PCB_NE5532", [
    (id: "1", section: "A", logical: "OUT"),
    (id: "2", section: "A", logical: "IN-"),
    (id: "3", section: "A", logical: "IN+"),
    (id: "4", section: "",  logical: "V-"),
    (id: "5", section: "B", logical: "IN+"),
    (id: "6", section: "B", logical: "IN-"),
    (id: "7", section: "B", logical: "OUT"),
    (id: "8", section: "",  logical: "V+")], partNumber = "NE5532",
    footprint = "SOIC-8")
  try: registerPackage(result)
  except CatchableError: result = packageDef("PCB_NE5532")

proc packagedBoard(): (Pcb, Component, Component) =
  let def = dualPackDef()
  let pcb = newPcb("packaged")
  let nl = pcb.netlist
  let outB = addNet(nl, newNet("outB", ntSignal))
  let gnd = addNet(nl, newNet("0", ntGround))
  let a = addComponent(nl, newComponent("OA1", kind = "opamp", partNumber = "NE5532"))
  let b = addComponent(nl, newComponent("OA2", kind = "opamp", partNumber = "NE5532"))
  discard connect(a, "OUT", addNet(nl, newNet("outA", ntSignal)), ptOutput)
  discard connect(b, "OUT", outB, ptOutput)
  a.attrs["package.ref"] = "U10"
  a.attrs["package.section"] = "A"
  a.attrs["package.def"] = def.name
  b.attrs["package.ref"] = "U10"
  b.attrs["package.section"] = "B"
  b.attrs["package.def"] = def.name
  (pcb, a, b)

test "a placement binds two sections by package.ref and leaves component nil":
  let (pcb, a, b) = packagedBoard()
  let p = addPlacement(pcb, newPlacement("U10", "SOIC-8"))
  bindComponent(p, a)
  bindComponent(p, b)
  check p.component == nil
  check p.sections.len == 2
  check p.sections["A"] == a
  check p.sections["B"] == b
  check placementOf(pcb, a) == p
  check placementOf(pcb, b) == p

test "a genuine designator mismatch still raises":
  let (pcb, a, _) = packagedBoard()
  a.attrs.del("package.ref")            # no packaging -> plain designator join
  let p = addPlacement(pcb, newPlacement("U11"))
  expect(PcbError):
    bindComponent(p, a)

test "pad 7 on an NE5532 resolves to section B's OUT":
  let (pcb, a, b) = packagedBoard()
  let top = addLayer(pcb, newPcbLayer("F.Cu", lfSignal, lsTop))
  let p = addPlacement(pcb, newPlacement("U10", "SOIC-8"))
  bindComponent(p, a)
  bindComponent(p, b)
  let padAp = internAperture(pcb, Aperture(name: "r500", kind: akCircle, dia: mm(0.5)))
  let pad7 = addCopper(top, newCopper(ckLand, pad(padAp, pt(mm(1.0), mm(1.0)))))
  addLand(p, "7", pad7)
  check pad7.pin == b.pins["OUT"]
  check pad7.net == b.pins["OUT"].net
  # an undeclared pad id binds nothing rather than guessing
  let pad99 = addCopper(top, newCopper(ckLand, pad(padAp, pt(mm(2.0), mm(1.0)))))
  addLand(p, "99", pad99)
  check pad99.pin == nil
