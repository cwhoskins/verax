## `pcb/assemble.nim`: netlist -> blank `Pcb`, with a fake `FootprintSource`
## so tests don't depend on an installed KiCad library.

import std/[strutils, tables, unittest]

import verax/netlist
import verax/netlist/annotations
import verax/pcb
import verax/pcb/assemble

# ---------------------------------------------------------------- a fake source

proc rectPad(id: string, x: float): FootprintPad =
  FootprintPad(id: id, padType: ptSmd,
              aperture: Aperture(name: "rect0.5x0.6", kind: akRect, w: mm(0.5), h: mm(0.6)),
              at: pt(mm(x), mm(0.0)), layers: @["F.Cu", "F.Mask", "F.Paste"])

proc fakeTwoPin(name: string): Footprint =
  var fp = Footprint(name: name, mount: mkSmt)
  fp.pads.add rectPad("1", -0.5)
  fp.pads.add rectPad("2", 0.5)
  fp.courtyard = rectPolygon(mm(1.6), mm(0.8))
  fp.bodyBox = rectPolygon(mm(1.0), mm(0.5)).box
  fp

proc fakeHeader(name: string): Footprint =
  var fp = Footprint(name: name, mount: mkThroughHole)
  var p1 = FootprintPad(id: "1", padType: ptThruHole,
                        aperture: Aperture(name: "circle1", kind: akCircle, dia: mm(1.5)),
                        at: pt(mm(0.0), mm(0.0)), layers: @["*.Cu"], drillDia: mm(0.8))
  var p2 = p1
  p2.id = "2"
  p2.at = pt(mm(2.54), mm(0.0))
  fp.pads.add p1
  fp.pads.add p2
  fp.courtyard = rectPolygon(mm(4.0), mm(2.0))
  fp

registerFootprintSource(FootprintSource(name: "test-fake",
  resolve: proc (spec: string): Footprint =
    case spec
    of "Test:TwoPin": fakeTwoPin(spec)
    of "Test:Header": fakeHeader(spec)
    else: nil))

# ---------------------------------------------------------------- fixtures

proc flatDivider(): Netlist =
  result = newNetlist("flat_divider")
  let vin = addNet(result, newNet("VIN"))
  let mid = addNet(result, newNet("MID"))
  let gnd = addNet(result, newNet("GND"))
  let r1 = addComponent(result, newComponent("R1", kind = "resistor"))
  discard connect(r1, "1", vin, ptPassive)
  discard connect(r1, "2", mid, ptPassive)
  setAnnotation(r1, "footprint", "Test:TwoPin")
  let r2 = addComponent(result, newComponent("R2", kind = "resistor"))
  discard connect(r2, "1", mid, ptPassive)
  discard connect(r2, "2", gnd, ptPassive)
  setAnnotation(r2, "footprint", "Test:TwoPin")

proc hierarchicalDesign(): Netlist =
  ## X1 instances a two-resistor child; `X1.U1`'s footprint should resolve
  ## and bind, matching `hierName("X1", "U1")`.
  var child = newNetlist("child")
  let a = addNet(child, newNet("A"))
  let b = addNet(child, newNet("B"))
  addPort(child, "A", a)
  addPort(child, "B", b)
  let u1 = addComponent(child, newComponent("U1", kind = "resistor"))
  discard connect(u1, "1", a, ptPassive)
  discard connect(u1, "2", b, ptPassive)
  setAnnotation(u1, "footprint", "Test:TwoPin")

  result = newNetlist("hier_design")
  let top = addNet(result, newNet("TOP"))
  let bot = addNet(result, newNet("BOT"))
  var globals: OrderedTable[string, Net]
  discard instantiate(result, "X1", child, @[top, bot], globals)

test "layers: full stack top to bottom, right functions and sides":
  let (pcb, _, _) = assemble(flatDivider())
  var names: seq[string]
  for _, l in pcb.layers: names.add l.name
  check names == @["F.Cu", "B.Cu", "F.Paste", "B.Paste", "F.Mask", "B.Mask",
                   "F.SilkS", "B.SilkS", "F.CrtYd", "B.CrtYd", "F.Fab",
                   "B.Fab", "Edge.Cuts"]
  check pcb.layer("F.Cu").function == lfSignal
  check pcb.layer("F.Cu").side == lsTop
  check pcb.layer("B.Cu").side == lsBottom
  check pcb.layer("Edge.Cuts").function == lfBoardOutline
  check pcb.layer("F.Cu").index == 0
  check pcb.layer("B.Cu").index == 1

test "stackup: copper + dielectric entries, and the invented figure is an Assumption":
  let (pcb, _, assumptions) = assemble(flatDivider())
  check pcb.stackup.entries.len == 3   # F.Cu, dielectric, B.Cu
  check pcb.stackup.entries[0].kind == seCopper
  check pcb.stackup.entries[1].kind == seDielectric
  check pcb.stackup.entries[1].material.epsilonR == 4.5
  check pcb.stackup.entries[1].material.lossTangent == 0.02
  check abs(toMm(pcb.stackup.totalThickness) - 1.6) < 1e-6
  check assumptions.len == 1
  check assumptions[0].key == "totalThickness"
  check assumptions[0].source == annDefaulted

test "outline: a rectangular boundary matching the requested board size":
  var opts = defaultAssembleOptions()
  opts.boardSize = (mm(50.0), mm(40.0))
  let (pcb, _, _) = assemble(flatDivider(), opts)
  let b = box(pcb.outline.boundary)
  check abs(toMm(width(b)) - 50.0) < 1e-6
  check abs(toMm(height(b)) - 40.0) < 1e-6

test "placements: one per part, bound, with lands carrying pin and net":
  let (pcb, issues, _) = assemble(flatDivider())
  check issues.len == 0
  check pcb.placements.len == 2
  let p1 = pcb.placements["R1"]
  check p1.component == pcb.netlist.components["R1"]
  check p1.footprint == "Test:TwoPin"
  check p1.lands.len == 2
  check p1.lands["1"][0].pin == pcb.netlist.components["R1"].pins["1"]
  check p1.lands["1"][0].net.name == "VIN"
  check p1.lands["2"][0].net.name == "MID"
  check p1.courtyard.outer.curves.len > 0

test "grid placement is deterministic and non-overlapping":
  let (pcb1, _, _) = assemble(flatDivider())
  let (pcb2, _, _) = assemble(flatDivider())
  check pcb1.placements["R1"].at == pcb2.placements["R1"].at
  check pcb1.placements["R2"].at == pcb2.placements["R2"].at
  check pcb1.placements["R1"].at != pcb1.placements["R2"].at
  # The placed courtyard boxes don't intersect.
  let e1 = box(pcb1.placements["R1"].courtyard)
  let e2 = box(pcb1.placements["R2"].courtyard)
  let b1 = Box(lo: pcb1.placements["R1"].at + e1.lo, hi: pcb1.placements["R1"].at + e1.hi)
  let b2 = Box(lo: pcb1.placements["R2"].at + e2.lo, hi: pcb1.placements["R2"].at + e2.hi)
  check not overlaps(b1, b2)

test "an unresolved footprint yields footprint_unresolved":
  let nl = newNetlist("unresolved")
  let a = addNet(nl, newNet("A"))
  let b = addNet(nl, newNet("B"))
  let r = addComponent(nl, newComponent("R1", kind = "resistor"))
  discard connect(r, "1", a, ptPassive)
  discard connect(r, "2", b, ptPassive)
  # no footprint stated
  let (pcb, issues, _) = assemble(nl)
  check pcb.placements.len == 0
  check issues.len == 1
  check issues[0].kind == "footprint_unresolved"
  check issues[0].severity == sevError
  check "R1" in issues[0].message

test "a pin with no matching pad yields footprint_pad_unmatched":
  let nl = newNetlist("mismatched")
  let a = addNet(nl, newNet("A"))
  let b = addNet(nl, newNet("B"))
  let c = addNet(nl, newNet("C"))
  let u = addComponent(nl, newComponent("U1", kind = "ic"))
  discard connect(u, "1", a, ptPassive)
  discard connect(u, "2", b, ptPassive)
  discard connect(u, "extra", c, ptPassive)   # a third pin the footprint has no pad for
  setAnnotation(u, "footprint", "Test:TwoPin")   # only two pads, ids "1"/"2"
  let (pcb, issues, _) = assemble(nl)
  check pcb.placements.len == 1
  var kinds: seq[string]
  for i in issues: kinds.add i.kind
  check "footprint_pad_unmatched" in kinds
  var found = false
  for i in issues:
    if i.kind == "footprint_pad_unmatched" and "extra" in i.message: found = true
  check found

test "a two-level hierarchical netlist yields X1.U1-style designators that bind and reverse-look-up":
  let (pcb, issues, _) = assemble(hierarchicalDesign())
  check issues.len == 0
  check pcb.placements.len == 1
  check pcb.placements.hasKey("X1.U1")
  let place = pcb.placements["X1.U1"]
  let inst = pcb.netlist.components["X1"]
  check inst.subNetlist != nil
  let u1 = inst.subNetlist.components["U1"]
  check place.component == u1
  # `placementOf` finds it back via the `Placement.sections` scan
  # (`u1.designator` is "U1", not "X1.U1").
  check placementOf(pcb, u1) == place
  check place.attrs["assembly.path"] == "X1.U1"
