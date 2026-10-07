## `.kicad_mod` library footprint reader. Importing it registers a
## `FootprintSource` (opt-in per import).
##
## A `.kicad_mod` is one `(footprint ...)` node (no `(at)`, plus
## `(version)`/`(generator)`); shared node parsing is in `kicadgeom.nim`.
## This adds a search path and reads pad layer tokens raw (no board to
## expand against). **Y-flip and angle-negate at the boundary**, as
## `kicad.readPcb` does, or rotated pads silently mirror.

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
  ## The directories tried, in order, for a `"Lib:Name"` spec -- exported so
  ## `footprint_unresolved` can say where it looked.
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
  # Layer tokens stay raw; never expanded here.
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
  ## Silk/fab/courtyard only; `fp_text` is skipped (nothing here needs
  ## text).
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
  ## Reads one `.kicad_mod` file, refusing by name anything but a single
  ## well-formed `(footprint ...)` node (no partial reads).
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
  ## A `spec` containing `/` or ending `.kicad_mod` is a literal path;
  ## otherwise `"Lib:Name"` resolves to `<dir>/Lib.pretty/Name.kicad_mod` over
  ## `footprintSearchDirs()`, first match wins. Returns `nil` when not found
  ## ("not mine"); a real parse failure in `readFootprintFile` still raises.
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
      # Keep `"Lib:Name"` as asked (the file names itself without the
      # library): `kicadgen` needs that spelling for KiCad to resolve it.
      result.name = spec
      return

registerFootprintSource(FootprintSource(name: "kicad", resolve: resolveFootprint))
