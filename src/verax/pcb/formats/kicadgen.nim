## From-scratch `.kicad_pcb` synthesis, for a board with no KiCad source
## (`pcb.source == nil`, from `pcb/assemble.nim`). Produces text only;
## `kicad.nim` imports it, never the reverse.
##
## **Footprints are spliced, not regenerated**: `Footprint.source` holds the
## library's verbatim bytes, and this edits four things via the `sexp.nim`
## primitives -- `(at)` (inserted), `(layer)`, the `Reference` value, and
## each pad's `(net ...)`. KiCad's graphics syntax can't be reproduced by
## rule.
##
## **Footprints are re-resolved at render time** (`findFootprint`), not
## carried on `Placement`, keeping `Pcb` free of footprint data.
## `writeBoard` runs `assemble` just before, so sources are registered.
##
## **Net codes are always declared** (`(net N "name")`), the universally
## understood form.

import std/[algorithm, strutils, tables]

import ./sexp
import ./kicadfmt
import ./common
import ../units
import ../geometry
import ../types
import ../graph
import ../footprint

proc lastChild(d: SexpDoc, n: int32): int32 =
  result = -1
  for c in d.kids(n): result = c

proc spliceFootprintNode(p: Placement, netOf: Table[string, int]): string =
  let fp = findFootprint(p.footprint)
  if fp == nil:
    raise newException(PcbFormatError,
      "kicadgen: footprint '" & p.footprint & "' for placement '" &
      p.designator & "' could not be re-resolved at write time -- the " &
      "source that produced it (e.g. `import verax/pcb/formats/kicadmod`) " &
      "must still be registered when `writeBoard` runs, immediately after " &
      "`assemble`")
  var d = parseSexp(fp.source, p.designator)
  let root = d.roots[0]

  # the `Reference` property's value.
  for propNode in d.kidsNamed(root, "property"):
    if d.text(arg(d, propNode, 0)) == "Reference":
      let valNode = arg(d, propNode, 1)
      if valNode >= 0: markDirty(d, valNode, escapeKicadString(p.designator))

  # `(layer ...)`: front/back (always present in a library footprint).
  let layerChild = d.child(root, "layer")
  let wantLayer = "(layer " & escapeKicadString(if p.side == bsBottom: "B.Cu" else: "F.Cu") & ")"
  if layerChild >= 0: markDirty(d, layerChild, wantLayer)

  # `(at ...)`: inserted (a library part has none), right after `(layer)`.
  let wantAt = "(at " & formatAt(p.at, -p.rot) & ")"
  let atChild = d.child(root, "at")
  if atChild >= 0:
    markDirty(d, atChild, wantAt)
  elif layerChild >= 0:
    markInserted(d, layerChild, wantAt)
  else:
    markInserted(d, lastChild(d, root), wantAt)

  # Each pad's `(net N "name")`: inserted, or replaced if the source already
  # has one.
  for padNode in d.kidsNamed(root, "pad"):
    let padId = d.text(arg(d, padNode, 0))
    var netName = ""
    if p.lands.hasKey(padId):
      for c in p.lands[padId]:
        if c.net != nil: (netName = c.net.name; break)
    let code = netOf.getOrDefault(netName, 0)
    let wantNet = "(net " & $code & " " & escapeKicadString(netName) & ")"
    let netChild = d.child(padNode, "net")
    if netChild >= 0: markDirty(d, netChild, wantNet)
    else: markInserted(d, lastChild(d, padNode), wantNet)

  render(d, fastPath = false)

# ---------------------------------------------------------------- layers/setup

const LayerId = {
  "F.Cu": 0, "B.Cu": 2,
  "F.Mask": 1, "B.Mask": 3, "F.SilkS": 5, "B.SilkS": 7,
  "F.Adhes": 9, "B.Adhes": 11, "F.Paste": 13, "B.Paste": 15,
  "Edge.Cuts": 25, "Margin": 27, "B.CrtYd": 29, "F.CrtYd": 31,
  "B.Fab": 33, "F.Fab": 35,
}.toTable
  ## KiCad >= 6 layer ordinals. Inner copper layers take the even numbers
  ## `4, 6, 8, ...` in stack order.

proc layerId(name: string, innerOrdinal: var int): int =
  if LayerId.hasKey(name): return LayerId[name]
  result = innerOrdinal
  innerOrdinal += 2

proc renderLayers(pcb: Pcb): string =
  result = "\t(layers\n"
  var innerOrdinal = 4
  for _, l in pcb.layers:
    let typ = if l.isCopper: "signal" else: "user"
    result &= "\t\t(" & $layerId(l.name, innerOrdinal) & " " &
              escapeKicadString(l.name) & " " & typ & ")\n"
  result &= "\t)\n"

proc renderStackup(pcb: Pcb): string =
  ## Copper and dielectric come from `pcb.stackup.entries`; the mask/paste/
  ## silkscreen lines are cosmetic and synthesized here.
  result = "\t\t(stackup\n"
  result &= "\t\t\t(layer \"F.SilkS\" (type \"Top Silk Screen\"))\n"
  result &= "\t\t\t(layer \"F.Paste\" (type \"Top Solder Paste\"))\n"
  result &= "\t\t\t(layer \"F.Mask\" (type \"Top Solder Mask\") (thickness 0.01))\n"
  if pcb.stackup != nil:
    for e in pcb.stackup.entries:
      let typ = if e.kind == seCopper: "copper" else: "core"
      result &= "\t\t\t(layer " & escapeKicadString(e.name) &
                " (type " & escapeKicadString(typ) &
                ") (thickness " & formatMm(e.thickness) & ")"
      if e.material != nil:
        result &= " (material " & escapeKicadString(e.material.name) &
                  ") (epsilon_r " & $e.material.epsilonR &
                  ") (loss_tangent " & $e.material.lossTangent & ")"
      result &= ")\n"
  result &= "\t\t\t(layer \"B.Mask\" (type \"Bottom Solder Mask\") (thickness 0.01))\n"
  result &= "\t\t\t(layer \"B.Paste\" (type \"Bottom Solder Paste\"))\n"
  result &= "\t\t\t(layer \"B.SilkS\" (type \"Bottom Silk Screen\"))\n"
  result &= "\t\t\t(copper_finish \"None\")\n"
  result &= "\t\t\t(dielectric_constraints no)\n"
  result &= "\t\t)\n"

# ---------------------------------------------------------------- nets

# ---------------------------------------------------------------- graphics

proc renderCurve(c: Curve, layerName: string): string =
  ## One top-level `gr_line`/`gr_arc` per curve of a `shStroke` shape --
  ## needed so `kicad-cli` sees an `Edge.Cuts` outline. Arcs are handled for
  ## future callers.
  case c.kind
  of cvSeg:
    "(gr_line (start " & formatMm(c.a.x) & " " & formatMm(-c.a.y) &
      ") (end " & formatMm(c.b.x) & " " & formatMm(-c.b.y) &
      ") (stroke (width 0.1) (type solid)) (layer " &
      escapeKicadString(layerName) & "))"
  of cvArc:
    let s = startPoint(c)
    let e = endPoint(c)
    let m = pointOnArc(c, c.startAngle + c.sweep * 0.5)
    "(gr_arc (start " & formatMm(s.x) & " " & formatMm(-s.y) &
      ") (mid " & formatMm(m.x) & " " & formatMm(-m.y) &
      ") (end " & formatMm(e.x) & " " & formatMm(-e.y) &
      ") (stroke (width 0.1) (type solid)) (layer " &
      escapeKicadString(layerName) & "))"

proc renderGraphics(pcb: Pcb): string =
  for _, l in pcb.layers:
    for shp in l.shapes:
      case shp.kind
      of shStroke:
        for c in shp.path.curves:
          result &= "\t" & renderCurve(c, l.name) & "\n"
      of shFill:
        var pts: seq[string]
        for c in shp.poly.outer.curves:
          let p0 = startPoint(c)
          pts.add "(xy " & formatMm(p0.x) & " " & formatMm(-p0.y) & ")"
        result &= "\t(gr_poly (pts " & pts.join(" ") &
          ") (stroke (width 0.1) (type solid)) (fill yes) (layer " &
          escapeKicadString(l.name) & "))\n"
      of shPad, shText:
        discard   # not produced on a top-level layer by `pcb/assemble.nim`

proc netCodes(pcb: Pcb): Table[string, int] =
  ## Every copper-carrying net, numbered from 1 in name order, so reruns
  ## are byte-identical.
  var names: seq[string]
  for name in pcb.netCopper.keys: names.add name
  names.sort()
  for i, name in names: result[name] = i + 1

# ---------------------------------------------------------------- top level

proc renderNewPcb*(pcb: Pcb): string =
  ## A complete `(kicad_pcb ...)`: header, layers, stackup, net
  ## declarations, then one spliced `(footprint ...)` per placement.
  let netOf = netCodes(pcb)
  var body = "(kicad_pcb\n"
  body &= "\t(version 20241229)\n"
  body &= "\t(generator \"verax\")\n"
  body &= "\t(generator_version \"0.1\")\n"
  body &= "\t(general\n"
  let thickness = if pcb.stackup != nil: pcb.stackup.totalThickness else: mm(1.6)
  body &= "\t\t(thickness " & formatMm(thickness) & ")\n"
  body &= "\t)\n"
  body &= "\t(paper \"A4\")\n"
  body &= renderLayers(pcb)
  body &= "\t(setup\n"
  body &= renderStackup(pcb)
  body &= "\t\t(pad_to_mask_clearance 0)\n"
  body &= "\t)\n"
  body &= "\t(net 0 \"\")\n"
  var names: seq[string]
  for name in netOf.keys: names.add name
  names.sort(proc (a, b: string): int = cmp(netOf[a], netOf[b]))
  for name in names:
    body &= "\t(net " & $netOf[name] & " " & escapeKicadString(name) & ")\n"
  body &= renderGraphics(pcb)
  for _, p in pcb.placements:
    body &= "\t" & spliceFootprintNode(p, netOf) & "\n"
  body &= ")\n"
  body
