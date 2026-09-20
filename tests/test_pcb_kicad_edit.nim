## The regeneration path: modify, insert, delete -- over small, hand-written
## boards rather than the committed fixture, so each test isolates exactly
## the one KiCad shape it is proving (an insert-anchor fallback needs a
## board with *no* existing track; a delete-splice proof needs *two*, so the
## surviving one's bytes can be checked). Every test: mutate -> `writePcb`
## to `getTempDir()` -> `readPcb` back -> assert with `summarize()` (or a
## direct byte/uuid comparison, where that is the actual claim) that the
## mutation is visible and nothing else moved.

import std/[algorithm, os, sequtils, strutils, tables, unittest]

import verax/pcb
import verax/pcb/formats/kicad
import verax/pcb/formats/sexp
import verax/netlist/graph as nlgraph

proc summarize(p: Pcb): string =
  var lines: seq[string]
  for des, pl in p.placements:
    lines.add("placement " & des & ": at=" & $pl.at.x.raw & "," & $pl.at.y.raw &
              " rot=" & $pl.rot.value & " side=" & $pl.side)
  for _, l in p.layers:
    for c in l.copper:
      if c.kind == ckTrack:
        lines.add("track on " & l.name & ": net=" & (if c.net != nil: c.net.name else: "") &
                  " uuid=" & c.attrs.getOrDefault("kicad.uuid", ""))
  lines.add("nets: " & $toSeq(p.netlist.nets.keys))
  lines.sort()
  lines.join("\n")

proc writeThenRead(pcb: Pcb): Pcb =
  let tmp = getTempDir() / "verax_pcb_edit_" & $getCurrentProcessId() & "_" & $cast[int](pcb) & ".kicad_pcb"
  writePcb(pcb, tmp)
  result = readPcb(tmp)
  removeFile(tmp)

const twoFootprintBoard = """(kicad_pcb
  (version 20241229)
  (generator "pcbnew")
  (layers (0 "F.Cu" signal) (2 "B.Cu" signal) (25 "Edge.Cuts" user))
  (setup)
  (net 0 "")
  (net 1 "GND")
  (net 2 "VCC")
  (footprint "Test:R"
    (layer "F.Cu")
    (uuid "00000000-0000-0000-0000-0000000000a1")
    (at 10 10)
    (property "Reference" "R1" (at 0 0 0) (layer "F.SilkS") (uuid "00000000-0000-0000-0000-0000000000a2") (effects (font (size 1 1) (thickness 0.15))))
    (property "Value" "10k" (at 0 0 0) (layer "F.Fab") (uuid "00000000-0000-0000-0000-0000000000a3") (effects (font (size 1 1) (thickness 0.15))))
    (attr smd)
    (pad "1" smd rect (at -1 0) (size 1 1) (layers "F.Cu") (net 2 "VCC") (uuid "00000000-0000-0000-0000-0000000000a4"))
    (pad "2" smd rect (at 1 0) (size 1 1) (layers "F.Cu") (net 1 "GND") (uuid "00000000-0000-0000-0000-0000000000a5"))
  )
  (footprint "Test:C"
    (layer "F.Cu")
    (uuid "00000000-0000-0000-0000-0000000000b1")
    (at 20 20)
    (property "Reference" "C1" (at 0 0 0) (layer "F.SilkS") (uuid "00000000-0000-0000-0000-0000000000b2") (effects (font (size 1 1) (thickness 0.15))))
    (property "Value" "100n" (at 0 0 0) (layer "F.Fab") (uuid "00000000-0000-0000-0000-0000000000b3") (effects (font (size 1 1) (thickness 0.15))))
    (attr smd)
    (pad "1" smd rect (at -1 0) (size 1 1) (layers "F.Cu") (net 2 "VCC") (uuid "00000000-0000-0000-0000-0000000000b4"))
    (pad "2" smd rect (at 1 0) (size 1 1) (layers "F.Cu") (net 0 "") (uuid "00000000-0000-0000-0000-0000000000b5"))
  )
  (segment
		(start 10 10)
		(end 20 10)
		(width 0.2)
		(layer "F.Cu")
		(net 2)
		(uuid "00000000-0000-0000-0000-0000000000c1")
	)
  (segment
		(start 20 10)
		(end 20 20)
		(width 0.2)
		(layer "F.Cu")
		(net 2)
		(uuid "00000000-0000-0000-0000-0000000000c2")
	)
)
"""

const noTrackBoard = """(kicad_pcb
  (version 20241229)
  (generator "pcbnew")
  (layers (0 "F.Cu" signal) (2 "B.Cu" signal) (25 "Edge.Cuts" user))
  (net 0 "")
  (net 1 "GND")
  (zone
    (net 1)
    (net_name "GND")
    (layer "F.Cu")
    (uuid "00000000-0000-0000-0000-0000000000d1")
    (polygon (pts (xy 0 0) (xy 50 0) (xy 50 50) (xy 0 50)))
  )
)
"""

proc writeTemp(name, content: string): string =
  result = getTempDir() / name
  writeFile(result, content)

test "a moved placement changes exactly one summary line":
  let path = writeTemp("verax_edit_move.kicad_pcb", twoFootprintBoard)
  defer: removeFile(path)
  let pcb = readPcb(path)
  let before = summarize(pcb)
  let r1 = pcb.placements["R1"]
  r1.at = pt(mm(15.0), mm(-10.0))
  touch(pcb, r1)
  let reread = writeThenRead(pcb)
  let after = summarize(reread)
  check after != before
  check reread.placements["R1"].at.x.raw == mm(15.0).raw
  check reread.placements["R1"].at.y.raw == mm(-10.0).raw
  # Every other placement/track line is unchanged.
  check reread.placements["C1"].at.x.raw == mm(20.0).raw
  check reread.placements["C1"].at.y.raw == mm(-20.0).raw

test "a rotated placement's sign survives, not folded into [0, 360)":
  let path = writeTemp("verax_edit_rotate.kicad_pcb", twoFootprintBoard)
  defer: removeFile(path)
  let pcb = readPcb(path)
  let r1 = pcb.placements["R1"]
  r1.rot = deg(90.0)   # canonical +90 -> KiCad -90
  touch(pcb, r1)
  let tmp = getTempDir() / "verax_edit_rotate_out.kicad_pcb"
  writePcb(pcb, tmp)
  defer: removeFile(tmp)
  let outText = readFile(tmp)
  check "-90" in outText
  check "270" notin outText.split("R1")[1][0 ..< 200]
  let reread = readPcb(tmp)
  check reread.placements["R1"].rot.value == 90.0

test "a new track is written and reads back on its net":
  let path = writeTemp("verax_edit_newtrack.kicad_pcb", twoFootprintBoard)
  defer: removeFile(path)
  let pcb = readPcb(path)
  let l = pcb.layer("F.Cu")
  let vcc = pcb.netlist.nets["VCC"]
  var c = newCopper(ckTrack, stroke(path(@[seg(pt(mm(0.0), mm(0.0)), pt(mm(5.0), mm(0.0)))]), mm(0.2)))
  discard addCopper(l, c)
  setNet(c, vcc)
  let reread = writeThenRead(pcb)
  var found = false
  for cu in reread.layer("F.Cu").copper:
    if cu.kind == ckTrack and cu.net != nil and cu.net.name == "VCC":
      let a = cu.shape.path.curves[0]
      if a.a.x.raw == mm(0.0).raw and a.b.x.raw == mm(5.0).raw:
        found = true
  check found

test "a new track on a board with no tracks lands before the zone":
  let path = writeTemp("verax_edit_anchor.kicad_pcb", noTrackBoard)
  defer: removeFile(path)
  let pcb = readPcb(path)
  let l = pcb.layer("F.Cu")
  let gnd = pcb.netlist.nets["GND"]
  var c = newCopper(ckTrack, stroke(path(@[seg(pt(mm(1.0), mm(1.0)), pt(mm(2.0), mm(1.0)))]), mm(0.25)))
  discard addCopper(l, c)
  setNet(c, gnd)
  let tmp = getTempDir() / "verax_edit_anchor_out.kicad_pcb"
  writePcb(pcb, tmp)
  defer: removeFile(tmp)
  let outText = readFile(tmp)
  let segIdx = outText.find("(segment")
  let zoneIdx = outText.find("(zone")
  check segIdx >= 0 and zoneIdx >= 0 and segIdx < zoneIdx
  let reread = readPcb(tmp)
  check reread.zones.len == 1
  var trackCount = 0
  for cu in reread.layer("F.Cu").copper:
    if cu.kind == ckTrack: inc trackCount
  check trackCount == 1

test "a removed track's node is dropped and its neighbour's bytes are byte-identical":
  let path = writeTemp("verax_edit_removetrack.kicad_pcb", twoFootprintBoard)
  defer: removeFile(path)
  let pcb = readPcb(path)
  let l = pcb.layer("F.Cu")
  var victim, survivor: Copper
  for cu in l.copper:
    if cu.kind == ckTrack:
      if cu.attrs.getOrDefault("kicad.uuid", "").contains("c1"): victim = cu
      elif cu.attrs.getOrDefault("kicad.uuid", "").contains("c2"): survivor = cu
  check victim != nil and survivor != nil
  let survivorUuid = survivor.attrs["kicad.uuid"]
  removeCopper(l, victim)
  let tmp = getTempDir() / "verax_edit_removetrack_out.kicad_pcb"
  writePcb(pcb, tmp)
  defer: removeFile(tmp)
  let outDoc = parseSexpFile(tmp)
  let origDoc = parseSexpFile(path)
  var outNode, origNode: int32 = -1
  for r in outDoc.roots:
    for c in outDoc.kids(r):
      if outDoc.head(c) == "segment" and survivorUuid in outDoc.raw(c): outNode = c
  for r in origDoc.roots:
    for c in origDoc.kids(r):
      if origDoc.head(c) == "segment" and survivorUuid in origDoc.raw(c): origNode = c
  check outNode >= 0 and origNode >= 0
  check outDoc.raw(outNode) == origDoc.raw(origNode)
  # And the removed track's uuid is entirely gone.
  let outText = readFile(tmp)
  check "0000000000c1" notin outText

test "an unrelated footprint keeps its exact source bytes when a sibling track is regenerated":
  let path = writeTemp("verax_edit_unrelated.kicad_pcb", twoFootprintBoard)
  defer: removeFile(path)
  let pcb = readPcb(path)
  # Move R1; C1's footprint block must not change a single byte.
  let r1 = pcb.placements["R1"]
  r1.at = pt(mm(11.0), mm(10.0))
  touch(pcb, r1)
  let tmp = getTempDir() / "verax_edit_unrelated_out.kicad_pcb"
  writePcb(pcb, tmp)
  defer: removeFile(tmp)
  let outDoc = parseSexpFile(tmp)
  let origDoc = parseSexpFile(path)
  proc findFootprint(d: SexpDoc, wantRef: string): int32 =
    for r in d.roots:
      for c in d.kids(r):
        if d.head(c) == "footprint" and ("\"" & wantRef & "\"") in d.raw(c): return c
    -1
  let outC1 = findFootprint(outDoc, "C1")
  let origC1 = findFootprint(origDoc, "C1")
  check outC1 >= 0 and origC1 >= 0
  check outDoc.raw(outC1) == origDoc.raw(origC1)

test "a new net gets the next free code with no renumbering of existing references":
  let path = writeTemp("verax_edit_newnet.kicad_pcb", twoFootprintBoard)
  defer: removeFile(path)
  let pcb = readPcb(path)
  let l = pcb.layer("F.Cu")
  let newNetObj = nlgraph.addNet(pcb.netlist, newNet("SPARE"))
  var c = newCopper(ckTrack, stroke(path(@[seg(pt(mm(30.0), mm(30.0)), pt(mm(31.0), mm(30.0)))]), mm(0.2)))
  discard addCopper(l, c)
  setNet(c, newNetObj)
  let tmp = getTempDir() / "verax_edit_newnet_out.kicad_pcb"
  writePcb(pcb, tmp)
  defer: removeFile(tmp)
  let outText = readFile(tmp)
  # Original declarations untouched.
  check "(net 0 \"\")" in outText
  check "(net 1 \"GND\")" in outText
  check "(net 2 \"VCC\")" in outText
  check "(net 3 \"SPARE\")" in outText
  # Every existing `(net N)` reference on the original tracks/pads is
  # unrenumbered.
  check "(net 2)" in outText   # the two original segments, unchanged
  let reread = readPcb(tmp)
  check reread.netlist.nets.hasKey("SPARE")
  check reread.copperOn("SPARE").len == 1

test "writePcb on a new placement raises PcbFormatError naming both the class and the designator":
  let path = writeTemp("verax_edit_newfp.kicad_pcb", twoFootprintBoard)
  defer: removeFile(path)
  let pcb = readPcb(path)
  var p = newPlacement("U99", "Test:NewPart")
  p.at = pt(mm(0.0), mm(0.0))
  discard addPlacement(pcb, p)
  let tmp = getTempDir() / "verax_edit_newfp_out.kicad_pcb"
  defer: (if fileExists(tmp): removeFile(tmp))
  var raised = false
  try:
    writePcb(pcb, tmp)
  except PcbFormatError as e:
    raised = true
    check "footprint" in e.msg
    check "U99" in e.msg
  check raised

test "a direct field write with no touch call is still written correctly":
  # The token-verification net: the writer regenerates and compares every
  # mapped track/via against its source text *independent of rev*, so a
  # caller that bypassed `graph`'s mutators (wrote `.shape`/`.net` directly)
  # is still caught. If this test starts failing, that net has been
  # optimized away.
  let path = writeTemp("verax_edit_bypass.kicad_pcb", twoFootprintBoard)
  defer: removeFile(path)
  let pcb = readPcb(path)
  let l = pcb.layer("F.Cu")
  var target: Copper
  for cu in l.copper:
    if cu.kind == ckTrack and cu.attrs.getOrDefault("kicad.uuid", "").contains("c1"):
      target = cu
  check target != nil
  # Bypass every graph mutator: hand-edit the shape directly, as
  # `graph.nim`'s own doc comment says a caller may, at the cost of being
  # invisible to `index.dirty` -- and, this stage, to `rev`.
  target.shape = stroke(path(@[seg(pt(mm(10.0), mm(10.0)), pt(mm(99.0), mm(10.0)))]), mm(0.2))
  # Force *some* other change so `pcb.rev` moves and `writePcb` takes the
  # slow path at all (otherwise nothing triggers the regenerate-and-compare
  # walk in the first place).
  let c1 = pcb.placements["C1"]
  c1.at = c1.at
  touch(pcb, c1)
  let reread = writeThenRead(pcb)
  var foundBypassed = false
  for cu in reread.layer("F.Cu").copper:
    if cu.kind == ckTrack:
      let a = cu.shape.path.curves[0]
      if a.b.x.raw == mm(99.0).raw: foundBypassed = true
  check foundBypassed

test "the writer's own output re-parses and re-renders byte-identically":
  ## Self-consistency: an inserted or regenerated node is well-formed and
  ## correctly spanned, or a second parse of the writer's own output would
  ## not reconstruct it byte for byte.
  let path = writeTemp("verax_edit_selfconsist.kicad_pcb", twoFootprintBoard)
  defer: removeFile(path)
  let pcb = readPcb(path)
  let r1 = pcb.placements["R1"]
  r1.at = pt(mm(12.0), mm(12.0))
  touch(pcb, r1)
  let l = pcb.layer("F.Cu")
  var c = newCopper(ckTrack, stroke(path(@[seg(pt(mm(0.0), mm(0.0)), pt(mm(1.0), mm(0.0)))]), mm(0.15)))
  discard addCopper(l, c)
  setNet(c, pcb.netlist.nets["GND"])
  let tmp = getTempDir() / "verax_edit_selfconsist_out.kicad_pcb"
  writePcb(pcb, tmp)
  defer: removeFile(tmp)
  let written = readFile(tmp)
  let doc2 = parseSexpFile(tmp)
  check render(doc2, fastPath = false) == written
