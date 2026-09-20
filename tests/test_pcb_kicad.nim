## Semantic round-trip and reader-invariant tests for
## `verax/pcb/formats/kicad`. Deliberately a *different* proof than
## `tests/test_pcb_sexp.nim`'s byte comparison, which never looks at the
## typed model at all -- a reader that mapped nothing would still pass that
## one. Here, `readPcb` -> `writePcb` -> `readPcb` again is compared through
## `summarize`, the `render(x): string` helper idiom `test_netlist_spice.nim`
## already uses for the same reason: a failure diffs as readable text
## instead of an opaque model comparison.

import std/[os, sequtils, strutils, tables, unittest]

import verax/pcb
import verax/pcb/formats/kicad

const FixturePath = "tests/fixtures/trim.kicad_pcb"

proc summarize(p: Pcb): string =
  ## Everything `test_pcb_kicad_edit.nim` and this file need to compare,
  ## rendered as text rather than as a struct comparison -- see this file's
  ## own doc comment for why.
  var lines: seq[string]
  lines.add("layers: " & toSeq(p.layers.keys).join(","))
  for _, l in p.layers:
    var kinds: CountTable[CopperKind]
    for c in l.copper: kinds.inc(c.kind)
    if l.copper.len > 0:
      var parts: seq[string]
      for k, n in kinds: parts.add($k & "=" & $n)
      lines.add("copper[" & l.name & "]: " & parts.join(","))
  lines.add("nets: " & toSeq(p.netlist.nets.keys).join(","))
  for h in p.holes:
    lines.add("hole: at=" & $h.at.x.raw & "," & $h.at.y.raw &
              " drill=" & $h.drillDia.raw & " kind=" & $h.viaKind &
              " span=" & (if h.fromLayer != nil: h.fromLayer.name else: "?") &
              ".." & (if h.toLayer != nil: h.toLayer.name else: "?"))
  for des, pl in p.placements:
    lines.add("placement " & des & ": footprint=" & pl.footprint &
              " at=" & $pl.at.x.raw & "," & $pl.at.y.raw &
              " rot=" & $pl.rot.value & " side=" & $pl.side &
              " mount=" & $pl.mount)
    for pinName, cs in pl.lands:
      lines.add("  land " & pinName & ": " & $cs.len & " copper")
  for z in p.zones:
    lines.add("zone " & z.name & ": net=" & (if z.net != nil: z.net.name else: "") &
              " priority=" & $z.priority & " layers=" &
              (block:
                var ns: seq[string]
                for l in z.layers: ns.add(l.name)
                ns.join(",")) &
              " outlinePts=" & $flatten(z.outline.outer).len &
              " fills=" & $z.fills.len)
  if p.stackup != nil:
    for e in p.stackup.entries:
      lines.add("stack " & e.name & ": thickness=" & $e.thickness.raw)
  lines.add("outline boundary pts: " & $flatten(p.outline.boundary.outer).len)
  lines.join("\n")

proc roundtripSummary(pcb: Pcb): string =
  let tmp = getTempDir() / "verax_pcb_kicad_test.kicad_pcb"
  writePcb(pcb, tmp)
  let reread = readPcb(tmp)
  removeFile(tmp)
  summarize(reread)

test "readPcb -> writePcb -> readPcb agrees on the trimmed fixture":
  let pcb = readPcb(FixturePath)
  check summarize(pcb) == roundtripSummary(pcb)

test "a structurally unbalanced board is refused by name and line":
  # The finding-2 shape, distilled: a missing `(` (here, before
  # `filter_ratio`) closes the root one paren early, and the real content
  # that follows -- exactly as `(footprint ...)` follows line 627 in
  # RoyalBlue54L-Feather.kicad_pcb -- becomes a second top-level form.
  # A single occurrence with nothing following it would just leave one
  # stray trailing `)`, absorbed harmlessly (see `test_pcb_sexp.nim`); it is
  # the trailing content that turns this into a refusal.
  let bad = "(kicad_pcb\n\t(version 20241229)\n\t(general\n\t\t(curved_edges no)filter_ratio 0.9)\n\t)\n)\n(net_tie_pad_groups)\n"
  let tmp = getTempDir() / "verax_pcb_kicad_bad.kicad_pcb"
  writeFile(tmp, bad)
  defer: removeFile(tmp)
  var raised = false
  try:
    discard readPcb(tmp)
  except PcbFormatError as e:
    raised = true
    check "top-level form" in e.msg
    check "line" in e.msg
  check raised

test "a KiCad Y-down coordinate becomes Y-up, and a rotation flips sign with it":
  let src = """(kicad_pcb
  (version 20241229)
  (generator "pcbnew")
  (layers (0 "F.Cu" signal) (2 "B.Cu" signal) (25 "Edge.Cuts" user))
  (net 0 "")
  (footprint "Test:Part"
    (layer "F.Cu")
    (uuid "00000000-0000-0000-0000-000000000001")
    (at 10 5 -90)
    (property "Reference" "U1" (at 0 0 0) (layer "F.SilkS") (uuid "00000000-0000-0000-0000-000000000002") (effects (font (size 1 1) (thickness 0.15))))
    (property "Value" "part" (at 0 0 0) (layer "F.Fab") (uuid "00000000-0000-0000-0000-000000000003") (effects (font (size 1 1) (thickness 0.15))))
    (attr smd)
  )
)
"""
  let tmp = getTempDir() / "verax_pcb_kicad_yflip.kicad_pcb"
  writeFile(tmp, src)
  defer: removeFile(tmp)
  let pcb = readPcb(tmp)
  let p = pcb.placements["U1"]
  check p.at.x.raw == mm(10.0).raw
  check p.at.y.raw == mm(-5.0).raw    # KiCad Y-down 5 -> canonical Y-up -5
  check p.rot.value == 90.0            # KiCad -90 -> canonical +90

test "copper layers are added top to bottom though KiCad ordinals are not monotonic":
  let src = """(kicad_pcb
  (version 20241229)
  (generator "pcbnew")
  (layers
    (0 "F.Cu" signal)
    (4 "In1.Cu" signal)
    (6 "In2.Cu" signal)
    (2 "B.Cu" signal)
  )
  (net 0 "")
)
"""
  let tmp = getTempDir() / "verax_pcb_kicad_layerorder.kicad_pcb"
  writeFile(tmp, src)
  defer: removeFile(tmp)
  let pcb = readPcb(tmp)
  let cu = copperLayers(pcb)
  check cu.len == 4
  check cu[0].name == "F.Cu"
  check cu[1].name == "In1.Cu"
  check cu[2].name == "In2.Cu"
  check cu[3].name == "B.Cu"

test "a board outline is stitched from Edge.Cuts owned by footprints as well as the board":
  let src = """(kicad_pcb
  (version 20241229)
  (generator "pcbnew")
  (layers (0 "F.Cu" signal) (25 "Edge.Cuts" user))
  (net 0 "")
  (gr_line (start 0 0) (end 10 0) (stroke (width 0.1) (type solid)) (layer "Edge.Cuts") (uuid "00000000-0000-0000-0000-000000000010"))
  (gr_line (start 10 0) (end 10 10) (stroke (width 0.1) (type solid)) (layer "Edge.Cuts") (uuid "00000000-0000-0000-0000-000000000011"))
  (footprint "Test:Part"
    (layer "F.Cu")
    (uuid "00000000-0000-0000-0000-000000000012")
    (at 0 0)
    (property "Reference" "U1" (at 0 0 0) (layer "F.SilkS") (uuid "00000000-0000-0000-0000-000000000013") (effects (font (size 1 1) (thickness 0.15))))
    (attr smd)
    (fp_line (start 10 10) (end 0 10) (stroke (width 0.1) (type solid)) (layer "Edge.Cuts") (uuid "00000000-0000-0000-0000-000000000014"))
    (fp_line (start 0 10) (end 0 0) (stroke (width 0.1) (type solid)) (layer "Edge.Cuts") (uuid "00000000-0000-0000-0000-000000000015"))
  )
)
"""
  let tmp = getTempDir() / "verax_pcb_kicad_outline.kicad_pcb"
  writeFile(tmp, src)
  defer: removeFile(tmp)
  let pcb = readPcb(tmp)
  let pts = flatten(pcb.outline.boundary.outer)
  # A closed 10x10 square, stitched from two board-level and two
  # footprint-owned Edge.Cuts segments.
  check pts.len >= 4
  let bb = box(pcb.outline.boundary)
  check abs(bb.width.raw - mm(10.0).raw) < 1000
  check abs(bb.height.raw - mm(10.0).raw) < 1000

test "an unrecognised pad shape becomes akCustom rather than an error":
  let src = """(kicad_pcb
  (version 20241229)
  (generator "pcbnew")
  (layers (0 "F.Cu" signal))
  (net 0 "")
  (footprint "Test:Part"
    (layer "F.Cu")
    (uuid "00000000-0000-0000-0000-000000000020")
    (at 0 0)
    (property "Reference" "U1" (at 0 0 0) (layer "F.SilkS") (uuid "00000000-0000-0000-0000-000000000021") (effects (font (size 1 1) (thickness 0.15))))
    (attr smd)
    (pad "1" smd weirdshape (at 0 0) (size 1 1) (layers "F.Cu") (uuid "00000000-0000-0000-0000-000000000022"))
  )
)
"""
  let tmp = getTempDir() / "verax_pcb_kicad_padshape.kicad_pcb"
  writeFile(tmp, src)
  defer: removeFile(tmp)
  let pcb = readPcb(tmp)
  let p = pcb.placements["U1"]
  let land = p.lands["1"][0]
  check land.shape.kind == shPad
  check land.shape.aperture.kind == akCustom

test "a zone's filled polygons land in Zone.fills and in the net index":
  let src = """(kicad_pcb
  (version 20241229)
  (generator "pcbnew")
  (layers (0 "F.Cu" signal))
  (net 0 "")
  (net 1 "GND")
  (zone
    (net 1)
    (net_name "GND")
    (layer "F.Cu")
    (uuid "00000000-0000-0000-0000-000000000030")
    (polygon (pts (xy 0 0) (xy 10 0) (xy 10 10) (xy 0 10)))
    (filled_polygon (layer "F.Cu") (pts (xy 1 1) (xy 9 1) (xy 9 9) (xy 1 9)))
  )
)
"""
  let tmp = getTempDir() / "verax_pcb_kicad_zonefill.kicad_pcb"
  writeFile(tmp, src)
  defer: removeFile(tmp)
  let pcb = readPcb(tmp)
  check pcb.zones.len == 1
  let z = pcb.zones[0]
  check z.fills.len == 1
  check z.fills[0].kind == ckFill
  check pcb.netCopper.hasKey("GND")
  check z.fills[0] in pcb.netCopper["GND"]

test "a KiCad 10 board with no net declarations still resolves nets by name":
  let src = """(kicad_pcb
  (version 20260206)
  (generator "pcbnew")
  (layers (0 "F.Cu" signal))
  (segment (start 0 0) (end 1 1) (width 0.2) (layer "F.Cu") (net "VCC") (uuid "00000000-0000-0000-0000-000000000040"))
)
"""
  let tmp = getTempDir() / "verax_pcb_kicad_namenet.kicad_pcb"
  writeFile(tmp, src)
  defer: removeFile(tmp)
  let pcb = readPcb(tmp)
  check pcb.netlist.nets.hasKey("VCC")
  check pcb.copperOn("VCC").len == 1

test "RoyalBlue54L-Feather-shaped corruption is refused by readPcb":
  let src = "(kicad_pcb\n\t(version 20241229)\n\t(general\n\t\t(curved_edges no)filter_ratio 0.9)\n\t)\n\t(uuid \"x\")\n)\n(footprint \"stray\")\n"
  let tmp = getTempDir() / "verax_pcb_kicad_corrupt.kicad_pcb"
  writeFile(tmp, src)
  defer: removeFile(tmp)
  var raised = false
  try:
    discard readPcb(tmp)
  except PcbFormatError:
    raised = true
  check raised
