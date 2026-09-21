## KiCad geometry primitives shared by every reader of KiCad's s-expression
## dialect: a board (`formats/kicad.nim`) and a library footprint
## (`formats/kicadmod.nim`) use the **same** `(pad ...)`/`(fp_line ...)`/
## `(at ...)` node shapes -- a `.kicad_mod` file is, byte for byte, the body
## of the `(footprint ...)` node `kicad.readFootprint` already parses, minus
## `(at)` and plus `(version)`/`(generator)`. Two independent copies of
## "how big is a roundrect corner" or "which layer does `*.Cu` expand to"
## would eventually disagree on a ratio or a wildcard, and a pad would land
## somewhere different on the board than it does in the source library --
## the class of divergence that stays invisible until a fab file is wrong.
## So this module holds nothing KiCad-specific beyond parsing the shapes both
## readers already need, and both import it rather than each other.
##
## Every proc here is a pure read off a `sexp.SexpDoc`: no `Pcb` mutation, no
## write-side formatting (`kicadfmt.nim` owns that half). `expandPadLayers`
## is the one exception that *does* take a `Pcb` -- a board pad's wildcard
## layer token (`*.Cu`, `*.Mask`) can only be expanded against a stack that
## is already known, which is exactly the board `kicad.readFootprint` is
## reading into and exactly what a standalone `.kicad_mod` file does not
## have. `formats/kicadmod.nim` therefore keeps a pad's layer tokens raw
## (`FootprintPad.layers`) and leaves their expansion to whichever `Pcb` the
## footprint is eventually placed on (`pcb/assemble.nim`) -- see that
## module's own note on why re-deriving the wildcard grammar there, against a
## `seq[string]` rather than a live `SexpDoc`, is a difference in input shape
## rather than a second copy of this proc.

import std/[tables, sets, strutils, math]

import ./sexp
import ./common
import ../units
import ../geometry
import ../types
import ../graph

proc refuse*(msg: string) {.noreturn.} =
  raise newException(PcbFormatError, msg)

proc readMm*(d: SexpDoc, n: int32): Nm =
  var v: float
  if n < 0 or not parseNumber(d, n, v):
    refuse("kicad: line " & $lineOf(d, n) & ": expected a number, found '" &
           (if n >= 0: raw(d, n) else: "<missing>") & "'")
  mm(v)

proc readDeg*(d: SexpDoc, n: int32): Deg =
  var v: float
  if n < 0 or not parseNumber(d, n, v):
    refuse("kicad: line " & $lineOf(d, n) & ": expected a number, found '" &
           (if n >= 0: raw(d, n) else: "<missing>") & "'")
  deg(v)

proc readXy*(d: SexpDoc, n: int32): Point =
  ## A two-argument coordinate node (`(xy x y)`, `(start x y)`, ...):
  ## KiCad Y-down to canonical Y-up (finding 5 -- exact, `int64` negation).
  pt(readMm(d, arg(d, n, 0)), -readMm(d, arg(d, n, 1)))

proc classifyPadShape(name: string): ApertureKind =
  case name
  of "circle": akCircle
  of "rect": akRect
  of "oval": akOval
  of "roundrect": akRoundRect
  of "trapezoid": akTrapezoid
  of "octagon": akOctagon
  else: akCustom   # includes "custom" and anything this reader does not recognise

proc buildAperture*(d: SexpDoc, padNode: int32): Aperture =
  let shapeNode = arg(d, padNode, 2)
  let shapeName = if shapeNode >= 0: d.text(shapeNode) else: ""
  let kind = classifyPadShape(shapeName)
  let sizeChild = d.child(padNode, "size")
  var w, h: Nm
  if sizeChild >= 0:
    w = readMm(d, arg(d, sizeChild, 0))
    h = readMm(d, arg(d, sizeChild, 1))
  result = Aperture(name: (if shapeName.len > 0: shapeName else: "custom"), kind: kind)
  case kind
  of akCircle: result.dia = w
  of akRect, akOval: (result.w = w; result.h = h)
  of akRoundRect, akChamferRect:
    var ratio = 0.25
    let ratioChild = d.child(padNode, "roundrect_rratio")
    if ratioChild >= 0: discard parseNumber(d, arg(d, ratioChild, 0), ratio)
    result.rw = w
    result.rh = h
    result.corner = (if w < h: w else: h) * ratio
    result.corners = {cnTopRight, cnTopLeft, cnBottomLeft, cnBottomRight}
  of akTrapezoid:
    result.tw = w
    result.th = h
    let deltaChild = d.child(padNode, "rect_delta")
    if deltaChild >= 0:
      result.deltaX = readMm(d, arg(d, deltaChild, 0))
      result.deltaY = readMm(d, arg(d, deltaChild, 1))
  of akOctagon:
    result.ow = w
    result.oh = h
  of akThermal, akPolygon, akCustom:
    discard   # no general polygon reconstruction attempted for a custom pad shape yet

proc expandPadLayers*(pcb: Pcb, d: SexpDoc, padNode: int32): seq[PcbLayer] =
  ## Wildcard layer-token expansion (`*.Cu`, `*.Mask`, ...) against `pcb`'s
  ## already-built layer stack. Takes a live `Pcb` because a wildcard cannot
  ## be resolved without one -- `formats/kicadmod.nim` reads a pad's layer
  ## tokens raw instead, for exactly that reason (see this module's doc
  ## comment).
  let layersChild = d.child(padNode, "layers")
  if layersChild < 0: return
  var seen: HashSet[string]
  for ln in d.kids(layersChild):
    if d.kind(ln) != skString: continue
    let name = d.text(ln)
    if name == "*.Cu":
      for l in copperLayers(pcb):
        if l.name notin seen: (seen.incl(l.name); result.add(l))
    elif name.startsWith("*."):
      let suffix = name[1 .. ^1]
      for _, l in pcb.layers:
        if l.name.endsWith(suffix) and l.name notin seen:
          seen.incl(l.name); result.add(l)
    else:
      let l = pcb.layer(name)
      if l != nil and l.name notin seen:
        seen.incl(l.name); result.add(l)

proc graphicNodeLayer*(d: SexpDoc, node: int32): string =
  let lc = d.child(node, "layer")
  if lc >= 0: d.text(arg(d, lc, 0)) else: ""

proc graphicCurves*(d: SexpDoc, node: int32): seq[Curve] =
  ## The geometry of one graphics node, in the frame it was written --
  ## board coordinates for a top-level `gr_*`, footprint-local for an
  ## `fp_*` (its caller applies a `Transform` afterwards).
  case d.head(node)
  of "gr_line", "fp_line":
    let s = d.child(node, "start")
    let e = d.child(node, "end")
    if s >= 0 and e >= 0: result.add(seg(readXy(d, s), readXy(d, e)))
  of "gr_rect", "fp_rect":
    let s = d.child(node, "start")
    let e = d.child(node, "end")
    if s >= 0 and e >= 0:
      let a = readXy(d, s)
      let c = readXy(d, e)
      let b = pt(c.x, a.y)
      let dd = pt(a.x, c.y)
      result.add(seg(a, b)); result.add(seg(b, c))
      result.add(seg(c, dd)); result.add(seg(dd, a))
  of "gr_circle", "fp_circle":
    let ctr = d.child(node, "center")
    let e = d.child(node, "end")
    if ctr >= 0 and e >= 0:
      let c = readXy(d, ctr)
      let ep = readXy(d, e)
      result.add(circleCurve(c, nm(int64(round(distance(c, ep))))))
  of "gr_arc", "fp_arc":
    let s = d.child(node, "start")
    let m = d.child(node, "mid")
    let e = d.child(node, "end")
    if s >= 0 and m >= 0 and e >= 0:
      try: result.add(arcFrom3Points(readXy(d, s), readXy(d, m), readXy(d, e)))
      except GeometryError: discard   # zero-radius arc: drop rather than raise
  of "gr_poly", "fp_poly":
    let ptsChild = d.child(node, "pts")
    if ptsChild >= 0:
      var pts: seq[Point]
      for xyNode in d.kids(ptsChild):
        if d.head(xyNode) == "xy": pts.add(readXy(d, xyNode))
      result.add(polyline(pts, closed = true).curves)
  else: discard
