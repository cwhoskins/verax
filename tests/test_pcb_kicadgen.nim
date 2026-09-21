## The strong check on `formats/kicadgen.nim`: assemble a board, write it,
## **read it back with `kicad.readPcb`**, and assert the two `Pcb`s agree.
## Generate -> parse -> compare is the only check that proves the emitter
## and the reader agree about the same file -- either one alone can be
## "plausible looking" and still wrong.

import std/[os, sets, tables, tempfiles, unittest]

import verax/netlist
import verax/netlist/annotations
import verax/pcb
import verax/pcb/assemble
import verax/pcb/formats/kicad

proc rectPad(id: string, x: float): FootprintPad =
  FootprintPad(id: id, padType: ptSmd,
              aperture: Aperture(name: "rect0.5x0.6", kind: akRect, w: mm(0.5), h: mm(0.6)),
              at: pt(mm(x), mm(0.0)), layers: @["F.Cu", "F.Mask", "F.Paste"])

proc fakeTwoPin(name: string): Footprint =
  var fp = Footprint(name: name, mount: mkSmt)
  fp.pads.add rectPad("1", -0.5)
  fp.pads.add rectPad("2", 0.5)
  fp.courtyard = rectPolygon(mm(1.6), mm(0.8))
  fp.source = "(footprint \"" & name & "\"\n\t(layer \"F.Cu\")\n" &
    "\t(attr smd)\n" &
    "\t(property \"Reference\" \"REF**\" (at 0 -1 0) (layer \"F.SilkS\") " &
    "(effects (font (size 1 1) (thickness 0.15))))\n" &
    "\t(pad \"1\" smd rect (at -0.5 0) (size 0.5 0.6) (layers \"F.Cu\" \"F.Mask\" \"F.Paste\"))\n" &
    "\t(pad \"2\" smd rect (at 0.5 0) (size 0.5 0.6) (layers \"F.Cu\" \"F.Mask\" \"F.Paste\"))\n" &
    ")"
  fp

registerFootprintSource(FootprintSource(name: "kicadgen-test-fake",
  resolve: proc (spec: string): Footprint =
    if spec == "Test:TwoPin": fakeTwoPin(spec) else: nil))

proc flatDivider(): Netlist =
  result = newNetlist("kicadgen_divider")
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

test "assemble -> write -> readPcb agrees on placements, nets, layers and outline":
  let (built, issues, _) = assemble(flatDivider())
  check issues.len == 0
  let tmp = genTempPath("verax_kicadgen_", ".kicad_pcb")
  defer: removeFile(tmp)
  writePcb(built, tmp)

  let read = readPcb(tmp)

  # Placement count and designators.
  check read.placements.len == built.placements.len
  var builtDes, readDes: HashSet[string]
  for k in built.placements.keys: builtDes.incl k
  for k in read.placements.keys: readDes.incl k
  check builtDes == readDes

  # Pad-to-net assignment, per placement.
  for des, bp in built.placements:
    let rp = read.placements[des]
    check rp.lands.len == bp.lands.len
    for pinName, cs in bp.lands:
      check rp.lands.hasKey(pinName)
      check cs.len == rp.lands[pinName].len
      for i in 0 ..< cs.len:
        let wantNet = if cs[i].net != nil: cs[i].net.name else: ""
        let gotNet = if rp.lands[pinName][i].net != nil: rp.lands[pinName][i].net.name else: ""
        check wantNet == gotNet

  # Layer names and order.
  var builtLayers, readLayers: seq[string]
  for _, l in built.layers: builtLayers.add l.name
  for _, l in read.layers: readLayers.add l.name
  check builtLayers == readLayers

  # Outline extent.
  let b1 = box(built.outline.boundary)
  let b2 = box(read.outline.boundary)
  check abs(toMm(width(b1)) - toMm(width(b2))) < 1e-6
  check abs(toMm(height(b1)) - toMm(height(b2))) < 1e-6

test "an assembled board with no resolved footprints still writes a valid, empty board":
  let nl = newNetlist("no_footprints")
  let a = addNet(nl, newNet("A"))
  let b = addNet(nl, newNet("B"))
  let r = addComponent(nl, newComponent("R1", kind = "resistor"))
  discard connect(r, "1", a, ptPassive)
  discard connect(r, "2", b, ptPassive)
  let (built, issues, _) = assemble(nl)
  check issues.len == 1
  check built.placements.len == 0
  let tmp = genTempPath("verax_kicadgen_empty_", ".kicad_pcb")
  defer: removeFile(tmp)
  writePcb(built, tmp)
  let read = readPcb(tmp)
  check read.placements.len == 0
  check read.layers.len == built.layers.len
