## `.kicad_mod` library footprint reader: turns a land-pattern library entry
## into a `pcb/footprint.Footprint`, and registers itself as a
## `FootprintSource` so `findFootprint` picks it up the moment this module is
## imported -- opt-in per import, the rule everywhere else in this codebase.
##
## A `.kicad_mod` file *is* a single `(footprint ...)` node -- the same node
## `formats/kicad.readFootprint` already parses out of a board, minus `(at)`
## (a library part has no board position) and plus `(version)`/`(generator)`.
## `formats/kicadgeom.nim` is where the node-shape knowledge both readers
## need actually lives; this module only adds the two things a *library*
## reader needs that a *board* reader does not: a search path, and reading a
## pad's layer tokens **raw** rather than expanded (there is no target `Pcb`
## yet to expand a wildcard against -- see `pcb/footprint.nim`'s doc comment).
##
## **Y-flip and angle-negate at the boundary**, exactly as `kicad.readPcb`
## does (`readXy`/`readDeg` from `kicadgeom`, applied at every coordinate this
## module reads). Getting this wrong silently mirrors every rotated pad and
## every rotated footprint that uses this one -- the corpus regression
## `kicad.nim`'s own doc comment on `readXy`/`readAt` exists to prevent.

import std/[os, strutils]

import ./sexp
import ./kicadgeom
import ./common
import ../units
import ../geometry
import ../types
import ../footprint

# ---------------------------------------------------------------- search path

proc footprintSearchDirs*(): seq[string] =
  ## The directories `resolveFootprint` tries, in order, for a `"Lib:Name"`
  ## spec -- exported so a caller building a `footprint_unresolved` message
  ## (`pcb/assemble.nim`) can say exactly what was tried rather than "no
  ## footprint provider resolved this", which names a symptom, not a place to
  ## look next.
  let vp = getEnv("VERAX_FOOTPRINT_PATH")
  if vp.len > 0:
    for p in vp.split(':'):
      if p.len > 0: result.add p
  let k10 = getEnv("KICAD10_FOOTPRINT_DIR")
  if k10.len > 0: result.add k10
  let k9 = getEnv("KICAD9_FOOTPRINT_DIR")
  if k9.len > 0: result.add k9
  result.add "/usr/share/kicad/footprints"

# ---------------------------------------------------------------- pads

proc readModPad(d: SexpDoc, padNode: int32): FootprintPad =
  result.id = d.text(arg(d, padNode, 0))
  let typText = d.text(arg(d, padNode, 1))
  result.padType =
    case typText
    of "thru_hole": ptThruHole
    of "np_thru_hole": ptNpThruHole
    of "connect": ptConnect
    else: ptSmd
  result.aperture = buildAperture(d, padNode)
  let atChild = d.child(padNode, "at")
  if atChild >= 0:
    result.at = pt(readMm(d, arg(d, atChild, 0)), -readMm(d, arg(d, atChild, 1)))
    let rN = arg(d, atChild, 2)
    if rN >= 0: result.rot = -readDeg(d, rN)
  # Layer tokens are kept raw -- see the module doc comment. Only the
  # decoded string is wanted here, never an expansion against a `Pcb`.
  let layersChild = d.child(padNode, "layers")
  if layersChild >= 0:
    for ln in d.kids(layersChild):
      if d.kind(ln) == skString: result.layers.add d.text(ln)
  let drillChild = d.child(padNode, "drill")
  if drillChild >= 0 and result.padType in {ptThruHole, ptNpThruHole}:
    let a0 = arg(d, drillChild, 0)
    if a0 >= 0:
      if d.kind(a0) == skAtom and d.text(a0) == "oval":
        let wv = readMm(d, arg(d, drillChild, 1))
        let hv = readMm(d, arg(d, drillChild, 2))
        result.drillDia = (if wv < hv: wv else: hv)
      else:
        result.drillDia = readMm(d, a0)
    let offChild = d.child(drillChild, "offset")
    if offChild >= 0:
      result.drillOffset = pt(readMm(d, arg(d, offChild, 0)),
                              -readMm(d, arg(d, offChild, 1)))

# ---------------------------------------------------------------- graphics

proc readModGraphics(d: SexpDoc, node: int32): seq[tuple[layer: string, shape: Shape]] =
  ## Silk/fab/courtyard only -- `fp_text` is skipped: nothing this module
  ## produces (`Footprint.courtyard`/`bodyBox`) needs rendered text, and
  ## `graphicCurves` (the shared helper) has no text-shape counterpart of its
  ## own to call without duplicating `kicad.textShapeFromGraphic`, which nothing
  ## here has a use for yet.
  for gNode in d.kids(node):
    if d.head(gNode) notin ["fp_line", "fp_rect", "fp_circle", "fp_arc", "fp_poly"]:
      continue
    let layerName = graphicNodeLayer(d, gNode)
    if layerName.len == 0: continue
    let curves = graphicCurves(d, gNode)
    if curves.len == 0: continue
    let shape =
      if d.head(gNode) == "fp_poly":
        Shape(kind: shFill, poly: Polygon(outer: path(curves, closed = true)))
      else:
        Shape(kind: shStroke, path: path(curves), width: nm(0))
    result.add (layerName, shape)

proc boundsOf(graphics: seq[tuple[layer: string, shape: Shape]], suffix: string): Box =
  result = emptyBox()
  for g in graphics:
    if g.layer.endsWith(suffix):
      result = union(result, box(g.shape))

# ---------------------------------------------------------------- reader

proc readFootprintNode(d: SexpDoc, node: int32): Footprint =
  result = Footprint(name: d.text(arg(d, node, 0)))
  let attrChild = d.child(node, "attr")
  if attrChild >= 0:
    for a in d.kids(attrChild):
      if d.kind(a) == skAtom:
        case d.text(a)
        of "through_hole": result.mount = mkThroughHole
        of "smd": result.mount = mkSmt
        else: discard
  for padNode in d.kidsNamed(node, "pad"):
    result.pads.add readModPad(d, padNode)
  result.graphics = readModGraphics(d, node)
  let crtydBox = boundsOf(result.graphics, ".CrtYd")
  if not crtydBox.isEmpty:
    result.courtyard = Polygon(outer: polyline(
      [crtydBox.lo, pt(crtydBox.hi.x, crtydBox.lo.y), crtydBox.hi,
       pt(crtydBox.lo.x, crtydBox.hi.y)], closed = true))
  let fabBox = boundsOf(result.graphics, ".Fab")
  result.bodyBox = if not fabBox.isEmpty: fabBox else: crtydBox
  result.source = raw(d, node)

proc readFootprintFile*(path: string): Footprint =
  ## Reads one `.kicad_mod` file. Refuses by name -- the same posture
  ## `kicad.readPcb` takes -- when the file is not a single well-formed
  ## `(footprint ...)` node, rather than partially reading a fragment and
  ## returning a `Footprint` with some of its pads silently missing.
  let doc =
    try: parseSexpFile(path)
    except SexpError as e:
      raise newException(PcbFormatError, "kicadmod: " & e.msg)
  if doc.roots.len != 1 or doc.head(doc.roots[0]) != "footprint":
    raise newException(PcbFormatError,
      "kicadmod: " & path & " is not a single `(footprint ...)` node " &
      "(found " & $doc.roots.len & " top-level form(s))")
  readFootprintNode(doc, doc.roots[0])

proc resolveFootprint*(spec: string): Footprint =
  ## `spec` containing `/` or ending `.kicad_mod` is a literal path (relative
  ## to the current directory, or absolute); otherwise `"Lib:Name"` resolves
  ## to `<dir>/Lib.pretty/Name.kicad_mod` over `footprintSearchDirs()`, first
  ## match wins. Returns `nil` -- never raises -- when nothing on the search
  ## path has the file: that is "not mine" in the `FootprintSource` sense
  ## (see `pcb/footprint.nim`), not a malformed-input refusal, and
  ## `readFootprintFile` is exactly where a real parse failure still raises.
  if spec.len == 0: return nil
  if '/' in spec or spec.endsWith(".kicad_mod"):
    if fileExists(spec):
      result = readFootprintFile(spec)
      result.name = spec   # the path as asked, not the library's own bare name
    return
  let colon = spec.find(':')
  if colon < 0: return nil
  let lib = spec[0 ..< colon]
  let name = spec[colon + 1 .. ^1]
  for dir in footprintSearchDirs():
    let candidate = dir / (lib & ".pretty") / (name & ".kicad_mod")
    if fileExists(candidate):
      result = readFootprintFile(candidate)
      # `"Lib:Name"` as asked, not the bare name the standalone `.kicad_mod`
      # file states for itself (`(footprint "R_0402_1005Metric" ...)`, no
      # library prefix) -- a real board's own `(footprint "Resistor_SMD:R_..."
      # ...)` head always carries the library nickname, and `kicadgen.nim`
      # needs exactly that spelling to splice a placement that a system
      # `fp-lib-table` (and `kicad-cli pcb drc`) will actually resolve.
      result.name = spec
      return

registerFootprintSource(FootprintSource(name: "kicad", resolve: resolveFootprint))
