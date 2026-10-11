## KiCad `.kicad_pcb` reader/writer: the typed mapping over `sexp.nim`'s
## arena. Byte-exact round trip for an unmodified board; valid (not
## byte-identical) regeneration for an edited one.
##
## `sexp.nim` keeps the whole tree, so fields this module doesn't model
## survive a write verbatim.
##
## **Byte-exact rests on the fast path**: `writePcb` returns the source bytes
## untouched when `pcb.rev == doc.snapshotRev`, so unmapped content never
## matters for an unedited board. Edits are supported only for the classes
## the regenerators below cover; everything else is refused by name.
##
## **Corrupt files**: `sexp.parseSexp` never raises on structural defects;
## `readPcb` refuses anything that isn't exactly one well-formed
## `(kicad_pcb ...)` root. Missing parens typically leave thousands of
## top-level fragments -- which `kicad-cli` may read silently and partially.

import std/[tables, sets, hashes, random, strutils, os]

import ./sexp
import ./kicadfmt
import ./kicadgeom
import ./kicadgen
import ./common
import ../units
import ../geometry
import ../types
import ../graph
import ../../netlist/types as nltypes
import ../../netlist/graph as nlgraph

export common

type
  KicadDoc* = ref object of SexpDoc
    version*: int
      ## e.g. `20241229`; `0` if the file states none.
    generator*: string
    snapshotRev*: int
      ## `Pcb.rev` when `readPcb` finished; `writePcb` compares against it.
    netByCode*: Table[int, Net]
      ## Only for boards with a `(net N "name")` declaration block (version
      ## < `20251028`); newer boards resolve `(net "name")` by name.
    hasNetCodes*: bool
      ## True once any top-level `(net N "name")` declaration was read --
      ## distinguishes a numbered board with only net `0` from a name-only
      ## board, so the writer knows which `(net ...)` shape to emit.
    mapped*: HashSet[int32]
      ## Every source node mapped to a live entity (one per node, not per
      ## wildcard-expanded `Copper`). `writePcb`'s delete sweep marks anything
      ## here but no longer reachable as deleted.
    rngSeed*: int64
      ## `hash(pcb.name)`, the deterministic base for inserted `uuid`s.
    insertCounter*: int

# ---------------------------------------------------------------- small helpers
#
# Node-shape helpers shared with `.kicad_mod` parsing live in `kicadgeom.nim`.

proc readAt(d: SexpDoc, n: int32): tuple[p: Point, rot: Deg] =
  ## `(at x y [rot])`; the angle is absent for zero. KiCad's rotation is
  ## clockwise in the Y-up frame, so it is negated on the way in.
  let rN = arg(d, n, 2)
  (pt(readMm(d, arg(d, n, 0)), -readMm(d, arg(d, n, 1))),
   (if rN >= 0: -readDeg(d, rN) else: deg(0.0)))

proc ensureNet(pcb: Pcb, name: string): Net =
  if pcb.netlist.nets.hasKey(name): return pcb.netlist.nets[name]
  nlgraph.addNet(pcb.netlist, newNet(name))

proc resolveNetRef(pcb: Pcb, doc: KicadDoc, d: SexpDoc, netNode: int32): Net =
  ## `netNode` is `(net N)`, `(net N "name")` or `(net "name")`. Code `0`
  ## and an empty name mean "no net" and return `nil`.
  if netNode < 0: return nil
  let a0 = arg(d, netNode, 0)
  if a0 < 0: return nil
  if d.kind(a0) == skString:
    let nm = d.text(a0)
    return (if nm.len == 0: nil else: ensureNet(pcb, nm))
  var codeF: float
  if not parseNumber(d, a0, codeF): return nil
  let code = int(codeF)
  if code == 0: return nil
  if doc.netByCode.hasKey(code): return doc.netByCode[code]
  # An undeclared code: fall back to the name alongside it, if any, rather
  # than invent a placeholder that could merge with a real net.
  let a1 = arg(d, netNode, 1)
  if a1 >= 0 and d.kind(a1) == skString and d.text(a1).len > 0:
    let net = ensureNet(pcb, d.text(a1))
    doc.netByCode[code] = net
    return net
  nil

# ---------------------------------------------------------------- layers

proc classifyLayer(name, typ: string): tuple[fn: LayerFunction, side: LayerSide] =
  let side =
    if name.startsWith("F."): lsTop
    elif name.startsWith("B."): lsBottom
    elif name.startsWith("In") and name.endsWith(".Cu"): lsInner
    else: lsNone
  let fn =
    case typ
    of "signal", "jumper": lfSignal
    of "power": lfPlane
    of "mixed": lfMixed
    else:
      # `user` layers are told apart by name, not by `typ`.
      if name.endsWith(".Adhes"): lfAdhesive
      elif name.endsWith(".Paste"): lfSolderPaste
      elif name.endsWith(".SilkS"): lfSilkscreen
      elif name.endsWith(".Mask"): lfSolderMask
      elif name.endsWith(".CrtYd"): lfCourtyard
      elif name.endsWith(".Fab"): lfFabrication
      elif name == "Edge.Cuts": lfBoardOutline
      elif name == "Margin": lfKeepout
      elif name.endsWith(".User") or name.startsWith("Dwgs") or name.startsWith("Cmts"):
        lfDocumentation
      elif name == "B.Cu" or name == "F.Cu": lfSignal
      else: lfUnknown
  (fn, side)

proc readLayers(pcb: Pcb, d: SexpDoc, layersNode: int32) =
  ## `(layers)` is already in physical stack order for copper despite
  ## non-monotonic ordinals (`0 F.Cu, 4 In1.Cu, ... 2 B.Cu`), so file order
  ## is stack order.
  for row in d.kids(layersNode):
    if d.kind(row) != skList: continue
    let nameNode = arg(d, row, 0)
    if nameNode < 0: continue
    let name = d.text(nameNode)
    let typNode = arg(d, row, 1)
    let typ = if typNode >= 0: d.text(typNode) else: ""
    let (fn, side) = classifyLayer(name, typ)
    discard addLayer(pcb, newPcbLayer(name, fn, side))

# ---------------------------------------------------------------- stackup + setup

proc readStackup(pcb: Pcb, d: SexpDoc, stackupNode: int32) =
  for entry in d.kidsNamed(stackupNode, "layer"):
    let nameNode = arg(d, entry, 0)
    let name = if nameNode >= 0: d.text(nameNode) else: ""
    let typChild = d.child(entry, "type")
    let typText = if typChild >= 0: d.text(arg(d, typChild, 0)) else: ""
    let thickChild = d.child(entry, "thickness")
    let thickness = if thickChild >= 0: readMm(d, arg(d, thickChild, 0)) else: nm(0)
    let layerRef = pcb.layer(name)
    var kind: StackEntryKind
    if layerRef != nil and layerRef.isCopper: kind = seCopper
    elif typText == "core" or typText == "prepreg": kind = seDielectric
    else:
      let lt = typText.toLowerAscii
      if "solder mask" in lt: kind = seSolderMask
      elif "solder paste" in lt: kind = seSolderPaste
      elif "silk" in lt: kind = seSilkscreen
      else: kind = seOther
    var e = newStackEntry(kind, name, thickness)
    e.layer = layerRef
    let matChild = d.child(entry, "material")
    if matChild >= 0:
      var mat = newStackMaterial(d.text(arg(d, matChild, 0)))
      let epsChild = d.child(entry, "epsilon_r")
      if epsChild >= 0: discard parseNumber(d, arg(d, epsChild, 0), mat.epsilonR)
      let lossChild = d.child(entry, "loss_tangent")
      if lossChild >= 0: discard parseNumber(d, arg(d, lossChild, 0), mat.lossTangent)
      e.material = mat
    let colorChild = d.child(entry, "color")
    if colorChild >= 0: e.attrs["kicad.color"] = d.text(arg(d, colorChild, 0))
    discard addStackEntry(pcb, e)
  let cfChild = d.child(stackupNode, "copper_finish")
  if cfChild >= 0: pcb.stackup.copperFinish = d.text(arg(d, cfChild, 0))

proc readSetup(pcb: Pcb, d: SexpDoc, setupNode: int32) =
  let stackupNode = d.child(setupNode, "stackup")
  if stackupNode >= 0: readStackup(pcb, d, stackupNode)
  let auxNode = d.child(setupNode, "aux_axis_origin")
  if auxNode >= 0:
    pcb.origin = pt(readMm(d, arg(d, auxNode, 0)), -readMm(d, arg(d, auxNode, 1)))

# ---------------------------------------------------------------- nets

proc readNetDecl(pcb: Pcb, doc: KicadDoc, d: SexpDoc, node: int32) =
  ## A top-level `(net N "name")` declaration (version < `20251028`). Code
  ## `0` is "no net" and is never registered.
  var codeF: float
  if not parseNumber(d, arg(d, node, 0), codeF): return
  doc.hasNetCodes = true
  let code = int(codeF)
  if code == 0: return
  let nameNode = arg(d, node, 1)
  let name = if nameNode >= 0: d.text(nameNode) else: ""
  doc.netByCode[code] = ensureNet(pcb, name)

# ---------------------------------------------------------------- tracks

proc mark(doc: KicadDoc, node: int32) {.inline.} =
  doc.mapped.incl(node)

proc readSegment(pcb: Pcb, doc: KicadDoc, d: SexpDoc, node: int32) =
  let startChild = d.child(node, "start")
  let endChild = d.child(node, "end")
  let widthChild = d.child(node, "width")
  let layerChild = d.child(node, "layer")
  if startChild < 0 or endChild < 0 or layerChild < 0: return
  let layerName = d.text(arg(d, layerChild, 0))
  let l = pcb.layer(layerName)
  if l == nil: return
  let a = readXy(d, startChild)
  let b = readXy(d, endChild)
  let width = if widthChild >= 0: readMm(d, arg(d, widthChild, 0)) else: nm(0)
  var c = newCopper(ckTrack, stroke(path(@[seg(a, b)]), width))
  let netChild = d.child(node, "net")
  discard addCopper(l, c)
  setNet(c, resolveNetRef(pcb, doc, d, netChild))
  c.attrs["kicad.node"] = $node
  let uuidChild = d.child(node, "uuid")
  if uuidChild >= 0: c.attrs["kicad.uuid"] = raw(d, arg(d, uuidChild, 0))
  mark(doc, node)

proc readArcTrack(pcb: Pcb, doc: KicadDoc, d: SexpDoc, node: int32) =
  let startChild = d.child(node, "start")
  let midChild = d.child(node, "mid")
  let endChild = d.child(node, "end")
  let widthChild = d.child(node, "width")
  let layerChild = d.child(node, "layer")
  if startChild < 0 or midChild < 0 or endChild < 0 or layerChild < 0: return
  let layerName = d.text(arg(d, layerChild, 0))
  let l = pcb.layer(layerName)
  if l == nil: return
  let a = readXy(d, startChild)
  let m = readXy(d, midChild)
  let b = readXy(d, endChild)
  let width = if widthChild >= 0: readMm(d, arg(d, widthChild, 0)) else: nm(0)
  var curve: Curve
  try:
    curve = arcFrom3Points(a, m, b)
  except GeometryError:
    curve = seg(a, b)   # degenerate arc: fall back rather than raise (see the module's GeometryError trap)
  var c = newCopper(ckTrack, stroke(path(@[curve]), width))
  let netChild = d.child(node, "net")
  discard addCopper(l, c)
  setNet(c, resolveNetRef(pcb, doc, d, netChild))
  c.attrs["kicad.node"] = $node
  # `arcFrom3Points` is float trig, so re-deriving `(mid)` isn't bit-exact;
  # stash the source text for reuse when the shape is unchanged.
  c.attrs["kicad.arc.mid"] = raw(d, midChild)
  let uuidChild = d.child(node, "uuid")
  if uuidChild >= 0: c.attrs["kicad.uuid"] = raw(d, arg(d, uuidChild, 0))
  mark(doc, node)

proc readVia(pcb: Pcb, doc: KicadDoc, d: SexpDoc, node: int32) =
  let atChild = d.child(node, "at")
  let sizeChild = d.child(node, "size")
  let drillChild = d.child(node, "drill")
  let layersChild = d.child(node, "layers")
  if atChild < 0 or sizeChild < 0 or drillChild < 0 or layersChild < 0: return
  let at = readXy(d, atChild)
  let dia = readMm(d, arg(d, sizeChild, 0))
  let drillDia = readMm(d, arg(d, drillChild, 0))
  var layerNames: seq[string]
  for ln in d.kids(layersChild):
    if d.kind(ln) == skString: layerNames.add(d.text(ln))
  if layerNames.len < 1: return
  let fromLayer = pcb.layer(layerNames[0])
  let toLayer = pcb.layer(layerNames[^1])
  var viaKind = vkThrough
  if d.child(node, "blind") >= 0: viaKind = vkBlind
  if d.child(node, "micro") >= 0: viaKind = vkMicro
  var h = newHole(hkVia, at, drillDia)
  h.finishedDia = stated(drillDia, annImported)
  h.viaKind = viaKind
  discard addHole(pcb, h)
  setSpan(h, fromLayer, toLayer)
  let netChild = d.child(node, "net")
  let net = resolveNetRef(pcb, doc, d, netChild)
  h.net = net
  for l in spanLayers(pcb, h):
    let aperture = internAperture(pcb, Aperture(name: "via_pad", kind: akCircle, dia: dia))
    var c = newCopper(ckViaPad, pad(aperture, at))
    discard addCopper(l, c)
    setNet(c, net)
    attachPad(h, c)
    c.attrs["kicad.node"] = $node
  h.attrs["kicad.node"] = $node
  let uuidChild = d.child(node, "uuid")
  if uuidChild >= 0: h.attrs["kicad.uuid"] = raw(d, arg(d, uuidChild, 0))
  mark(doc, node)

# ---------------------------------------------------------------- footprints + pads

proc footprintTransform(p: Placement): Transform =
  ## KiCad: `absolute = fp.at + Rotate(local, +fp.angle)`, no mirror term --
  ## a side flip is already baked into local coordinates and layer names.
  Transform(origin: p.at, rot: p.rot, mirrorX: false)

proc readPad(pcb: Pcb, doc: KicadDoc, d: SexpDoc, padNode: int32, p: Placement) =
  let padName = d.text(arg(d, padNode, 0))
  let aperture = internAperture(pcb, buildAperture(d, padNode))
  let atChild = d.child(padNode, "at")
  var localAt = pt(nm(0), nm(0))
  var localRot = deg(0.0)
  if atChild >= 0:
    localAt = pt(readMm(d, arg(d, atChild, 0)), -readMm(d, arg(d, atChild, 1)))
    let rN = arg(d, atChild, 2)
    if rN >= 0: localRot = -readDeg(d, rN)
  let t = footprintTransform(p)
  let boardPos = apply(t, localAt)
  let boardRot = localRot + p.rot
  let netChild = d.child(padNode, "net")
  let net = resolveNetRef(pcb, doc, d, netChild)
  let padLayers = expandPadLayers(pcb, d, padNode)
  var producedAnything = false
  for l in padLayers:
    if not l.isCopper: continue
    var c = newCopper(ckLand, pad(aperture, boardPos, boardRot))
    discard addCopper(l, c)
    setNet(c, net)
    c.attrs["kicad.node"] = $padNode
    addLand(p, padName, c)
    producedAnything = true
  # Through-hole drilling.
  let padTypeNode = arg(d, padNode, 1)
  let padType = if padTypeNode >= 0: d.text(padTypeNode) else: ""
  let drillChild = d.child(padNode, "drill")
  if drillChild >= 0 and (padType == "thru_hole" or padType == "np_thru_hole"):
    let a0 = arg(d, drillChild, 0)
    var drillDia = nm(0)
    if a0 >= 0:
      if d.kind(a0) == skAtom and d.text(a0) == "oval":
        let wN = arg(d, drillChild, 1)
        let hN = arg(d, drillChild, 2)
        let wv = readMm(d, wN)
        let hv = readMm(d, hN)
        drillDia = (if wv < hv: wv else: hv)
      else:
        drillDia = readMm(d, a0)
    var h = newHole((if padType == "np_thru_hole": hkNonPlated else: hkPlated), boardPos, drillDia)
    h.net = net
    h.attrs["kicad.node"] = $padNode
    addPlacementHole(p, h)
    if p.lands.hasKey(padName):
      for c in p.lands[padName]:
        attachPad(h, c)
    producedAnything = true
  # `mark` only when a live entity resulted. A paste-only SMD pad has no
  # copper or drill and no `pcb/types` entity; marking it would make the
  # delete sweep remove it on the first edit.
  if producedAnything: mark(doc, padNode)

# Forward declaration: `readFootprint` needs it for footprint-owned
# graphics; implemented with the outline-stitching code below.
proc processGraphicNode(pcb: Pcb, doc: KicadDoc, d: SexpDoc, node: int32,
                         t: Transform, edgeCurves: var seq[Curve])

proc readFootprint(pcb: Pcb, doc: KicadDoc, d: SexpDoc, node: int32,
                    edgeCurves: var seq[Curve]) =
  let libName = d.text(arg(d, node, 0))
  let layerChild = d.child(node, "layer")
  let footLayerName = if layerChild >= 0: d.text(arg(d, layerChild, 0)) else: "F.Cu"
  let side = if footLayerName.startsWith("B."): bsBottom else: bsTop
  let atChild = d.child(node, "at")
  var atPt = pt(nm(0), nm(0))
  var rot = deg(0.0)
  if atChild >= 0:
    (atPt, rot) = readAt(d, atChild)

  var designator = ""
  var valueText = ""
  var propNodes: seq[tuple[key: string, node: int32]]
  for propNode in d.kidsNamed(node, "property"):
    let key = d.text(arg(d, propNode, 0))
    let valNode = arg(d, propNode, 1)
    let val = if valNode >= 0: d.text(valNode) else: ""
    propNodes.add((key, propNode))
    if key == "Reference": designator = val
    elif key == "Value": valueText = val

  # Designator collisions are real (`""`, `REF**`): `addPlacement` raises on
  # duplicates, so synthesise a unique key and keep the raw one.
  var uniqueDes = designator
  if uniqueDes.len == 0 or pcb.placements.hasKey(uniqueDes):
    let base = if designator.len > 0: designator else: "REF**"
    var k = 1
    while pcb.placements.hasKey(base & "#" & $k): inc k
    uniqueDes = base & "#" & $k

  var p = newPlacement(uniqueDes, libName)
  p.at = atPt
  p.rot = rot
  p.side = side
  if designator != uniqueDes: p.attrs["kicad.reference"] = designator
  # `kicad.Value`, not `value`: KiCad's Value property isn't always a
  # component value in the registry's sense ("STM32F103" on an IC), so it
  # stays in the unvalidated `kicad.*` namespace rather than being guessed.
  if valueText.len > 0: p.attrs["kicad.Value"] = valueText
  # The literal Reference text as read. A rename is detected at write time
  # by comparing it with `attrs["kicad.reference"]` (or `designator`).
  # There's no `renamePlacement`: set `attrs["kicad.reference"]` and `touch`.
  p.attrs["kicad.node.refText"] = designator
  for (key, propNode) in propNodes:
    if key != "Reference" and key != "Value":
      let valNode = arg(d, propNode, 1)
      p.attrs["kicad.prop." & key] = (if valNode >= 0: d.text(valNode) else: "")

  let attrChild = d.child(node, "attr")
  if attrChild >= 0:
    for a in d.kids(attrChild):
      if d.kind(a) == skAtom:
        case d.text(a)
        of "through_hole": p.mount = mkThroughHole
        of "smd": p.mount = mkSmt
        of "exclude_from_bom": p.excludeFromBom = true
        of "dnp": p.doNotPopulate = true
        else: discard
  if d.child(node, "locked") >= 0: p.attrs["kicad.locked"] = "yes"

  p.attrs["kicad.node"] = $node
  discard addPlacement(pcb, p)
  mark(doc, node)

  var comp = pcb.netlist.components.getOrDefault(uniqueDes)
  if comp == nil:
    comp = nlgraph.addComponent(pcb.netlist, newComponent(uniqueDes, name = libName, kind = "footprint"))
  bindComponent(p, comp)

  for padNode in d.kidsNamed(node, "pad"):
    readPad(pcb, doc, d, padNode, p)

  let t = footprintTransform(p)
  for gNode in d.kids(node):
    if d.head(gNode) in ["fp_line", "fp_rect", "fp_circle", "fp_arc", "fp_poly", "fp_text"]:
      processGraphicNode(pcb, doc, d, gNode, t, edgeCurves)

# ---------------------------------------------------------------- graphics + outline

proc graphicWidth(d: SexpDoc, node: int32): Nm =
  let strokeChild = d.child(node, "stroke")
  if strokeChild >= 0:
    let wChild = d.child(strokeChild, "width")
    if wChild >= 0: return readMm(d, arg(d, wChild, 0))
  let widthChild = d.child(node, "width")   # pre-stroke-block KiCad
  if widthChild >= 0: return readMm(d, arg(d, widthChild, 0))
  nm(0)

proc shapeFromGraphic(d: SexpDoc, node: int32, t: Transform): Shape =
  let w = graphicWidth(d, node)
  var tcurves: seq[Curve]
  for c in graphicCurves(d, node): tcurves.add(apply(t, c))
  if d.head(node) in ["gr_poly", "fp_poly"]:
    Shape(kind: shFill, poly: Polygon(outer: path(tcurves, closed = true)))
  else:
    Shape(kind: shStroke, path: path(tcurves), width: w)

proc textShapeFromGraphic(d: SexpDoc, node: int32, t: Transform): Shape =
  let atChild = d.child(node, "at")
  var origin = pt(nm(0), nm(0))
  var angle = deg(0.0)
  if atChild >= 0: (origin, angle) = readAt(d, atChild)
  let textNode = arg(d, node, 0)
  let text = if textNode >= 0: d.text(textNode) else: ""
  var height = mm(1.0)
  var thickness = mm(0.15)
  let effChild = d.child(node, "effects")
  if effChild >= 0:
    let fontChild = d.child(effChild, "font")
    if fontChild >= 0:
      let sizeChild = d.child(fontChild, "size")
      if sizeChild >= 0: height = readMm(d, arg(d, sizeChild, 0))
      let thickChild = d.child(fontChild, "thickness")
      if thickChild >= 0: thickness = readMm(d, arg(d, thickChild, 0))
  Shape(kind: shText, origin: apply(t, origin), text: text, height: height,
        thickness: thickness, angle: angle + t.rot)

proc processGraphicNode(pcb: Pcb, doc: KicadDoc, d: SexpDoc, node: int32,
                         t: Transform, edgeCurves: var seq[Curve]) =
  let layerName = graphicNodeLayer(d, node)
  if layerName == "Edge.Cuts":
    for c in graphicCurves(d, node): edgeCurves.add(apply(t, c))
    return
  let l = pcb.layer(layerName)
  if l == nil: return
  let shp =
    if d.head(node) in ["gr_text", "fp_text"]: textShapeFromGraphic(d, node, t)
    else: shapeFromGraphic(d, node, t)
  addShape(l, shp)

proc reverseCurve(c: Curve): Curve =
  case c.kind
  of cvSeg: seg(c.b, c.a)
  of cvArc: arc(c.center, c.radius, c.startAngle + c.sweep, -c.sweep)

proc closeEnough(a, b: Point, tol: Nm): bool =
  abs(a.x - b.x) <= tol and abs(a.y - b.y) <= tol

proc stitchLoops(curves: seq[Curve], tol: Nm): seq[seq[Curve]] =
  ## Greedy nearest-endpoint chaining of the unordered `Edge.Cuts` bag: grow
  ## a chain from either end until nothing attaches within `tol`, then start
  ## another. Quadratic, fine at outline scale.
  var remaining = curves
  while remaining.len > 0:
    var chain = @[remaining[0]]
    remaining.delete(0)
    var progress = true
    while progress and remaining.len > 0:
      progress = false
      let tailPt = endPoint(chain[^1])
      let headPt = startPoint(chain[0])
      for i in 0 ..< remaining.len:
        let c = remaining[i]
        if closeEnough(startPoint(c), tailPt, tol):
          chain.add(c); remaining.delete(i); progress = true; break
        elif closeEnough(endPoint(c), tailPt, tol):
          chain.add(reverseCurve(c)); remaining.delete(i); progress = true; break
        elif closeEnough(endPoint(c), headPt, tol):
          chain.insert(c, 0); remaining.delete(i); progress = true; break
        elif closeEnough(startPoint(c), headPt, tol):
          chain.insert(reverseCurve(c), 0); remaining.delete(i); progress = true; break
    result.add(chain)

proc forceOrientation(p: Path, ccw: bool): Path =
  if (signedArea(p) > 0) != ccw: reversed(p) else: p

proc stitchOutline(pcb: Pcb, curves: seq[Curve]) =
  ## Edge.Cuts graphics, **including footprint-owned ones**, become
  ## `Pcb.outline`: the largest closed loop is the boundary, loops inside it
  ## are cutouts, loops outside it are separate pieces.
  if curves.len == 0: return
  let tol = pcb.outline.stitchTolerance
  var paths: seq[Path]
  for chain in stitchLoops(curves, tol): paths.add(path(chain, closed = true))
  if paths.len == 0: return
  var bestIdx = 0
  var bestArea = 0.0
  for i, p in paths:
    let a = abs(signedArea(p))
    if a > bestArea: (bestArea = a; bestIdx = i)
  var boundary: Polygon
  boundary.outer = forceOrientation(paths[bestIdx], true)
  for i, p in paths:
    if i == bestIdx: continue
    let pts = flatten(p)
    let probe = Polygon(outer: boundary.outer)
    if pts.len > 0 and contains(probe, pts[0]):
      boundary.holes.add(forceOrientation(p, false))
    else:
      pcb.outline.pieces.add(Polygon(outer: forceOrientation(p, true)))
  pcb.outline.boundary = boundary

# ---------------------------------------------------------------- zones

proc readPts(d: SexpDoc, ptsNode: int32): seq[Point] =
  if ptsNode < 0: return
  for xyNode in d.kids(ptsNode):
    if d.head(xyNode) == "xy": result.add(readXy(d, xyNode))

proc readZone(pcb: Pcb, doc: KicadDoc, d: SexpDoc, node: int32) =
  let netChild = d.child(node, "net")
  let net = resolveNetRef(pcb, doc, d, netChild)
  let nameChild = d.child(node, "name")
  let zname = if nameChild >= 0: d.text(arg(d, nameChild, 0)) else: ""
  let priorityChild = d.child(node, "priority")
  var priority = 0
  if priorityChild >= 0:
    var v: float
    if parseNumber(d, arg(d, priorityChild, 0), v): priority = int(v)
  var layerNames: seq[string]
  let layerChild = d.child(node, "layer")
  if layerChild >= 0: layerNames.add(d.text(arg(d, layerChild, 0)))
  let layersChild = d.child(node, "layers")
  if layersChild >= 0:
    for ln in d.kids(layersChild):
      if d.kind(ln) == skString: layerNames.add(d.text(ln))
  var layers: seq[PcbLayer]
  for lname in layerNames:
    let l = pcb.layer(lname)
    if l != nil: layers.add(l)
  var outline: Polygon
  let polygonChild = d.child(node, "polygon")
  if polygonChild >= 0:
    let pts = readPts(d, d.child(polygonChild, "pts"))
    if pts.len >= 3: outline = Polygon(outer: polyline(pts, closed = true))
  var z = newZone(zname, net)
  z.isKeepout = d.child(node, "keepout") >= 0
  z.priority = priority
  z.outline = outline
  z.layers = layers
  z.attrs["kicad.node"] = $node
  discard addZone(pcb, z)
  mark(doc, node)
  for fp in d.kidsNamed(node, "filled_polygon"):
    let flChild = d.child(fp, "layer")
    if flChild < 0: continue
    let fl = pcb.layer(d.text(arg(d, flChild, 0)))
    if fl == nil: continue
    let pts = readPts(d, d.child(fp, "pts"))
    if pts.len < 3: continue
    discard addZoneFill(pcb, z, fl, Polygon(outer: polyline(pts, closed = true)))

# ---------------------------------------------------------------- readPcb

proc readPcb*(path: string, step = ""): Pcb =
  ## Reads a KiCad `.kicad_pcb` board. `step` is ignored (single file).
  var doc = KicadDoc()
  let content =
    try: readFile(path)
    except IOError, OSError:
      refuse("kicad.readPcb: cannot open " & path)
  parseSexpInto(doc, content, path)

  if doc.roots.len != 1:
    var extra = ""
    if doc.diagnostics.len > 0:
      extra = " First structural problem noted while parsing: line " &
              $doc.diagnostics[0].line & ": " & doc.diagnostics[0].msg & "."
    refuse("kicad.readPcb: " & path & " has " & $doc.roots.len &
           " top-level forms; a valid board has exactly one, `(kicad_pcb ...)`." &
           extra & " This is the shape of a structurally corrupt file (the " &
           "known example: KiCad's own demo corpus ships one board missing " &
           "349 opening parens) -- refused by name rather than partially read.")
  let root = doc.roots[0]
  if doc.head(root) != "kicad_pcb":
    refuse("kicad.readPcb: " & path & "'s single top-level form is `(" &
           doc.head(root) & " ...)`, not `(kicad_pcb ...)`.")

  let versionNode = doc.child(root, "version")
  if versionNode >= 0:
    var v: float
    if parseNumber(doc, arg(doc, versionNode, 0), v): doc.version = int(v)
  let genNode = doc.child(root, "generator")
  if genNode >= 0: doc.generator = doc.text(arg(doc, genNode, 0))

  var pcb = newPcb(name = path.extractFilename)
  doc.rngSeed = int64(hash(pcb.name))

  let layersNode = doc.child(root, "layers")
  if layersNode >= 0: readLayers(pcb, doc, layersNode)

  let setupNode = doc.child(root, "setup")
  if setupNode >= 0: readSetup(pcb, doc, setupNode)

  var edgeCurves: seq[Curve]
  let identity = Transform(origin: pt(nm(0), nm(0)), rot: deg(0.0))

  for c in doc.kids(root):
    case doc.head(c)
    of "net": readNetDecl(pcb, doc, doc, c)
    of "footprint": readFootprint(pcb, doc, doc, c, edgeCurves)
    of "segment": readSegment(pcb, doc, doc, c)
    of "arc": readArcTrack(pcb, doc, doc, c)
    of "via": readVia(pcb, doc, doc, c)
    of "zone": readZone(pcb, doc, doc, c)
    of "gr_line", "gr_rect", "gr_circle", "gr_arc", "gr_poly", "gr_text":
      processGraphicNode(pcb, doc, doc, c, identity, edgeCurves)
    else: discard   # preserved-only, verbatim through the sexp arena

  stitchOutline(pcb, edgeCurves)

  pcb.source = doc
  # Snapshot `rev` after the read's own mutations, not reset to 0: entities
  # keep the `rev` they were stamped with, and a reset would make every
  # unedited board with silkscreen trip the refusal checks.
  doc.snapshotRev = pcb.rev
  result = pcb

# ---------------------------------------------------------------- writePcb

proc nodeIdOf(attrs: OrderedTable[string, string], key: string): int32 =
  ## `-1` when not a real node: the key is absent (created after the read)
  ## or holds the "" sentinel left once an insert was queued, so a second
  ## `writePcb` doesn't queue it twice.
  if not attrs.hasKey(key): return -1
  let s = attrs[key]
  if s.len == 0: return -1
  try: int32(parseInt(s))
  except ValueError: -1

iterator liveEntityNodes(pcb: Pcb): int32 =
  ## Every source node reachable from a live entity: layer copper, zones
  ## (own node only), holes, placements. A container missed here makes its
  ## nodes look dead and get deleted.
  for _, l in pcb.layers:
    for c in l.copper:
      let n = nodeIdOf(c.attrs, "kicad.node")
      if n >= 0: yield n
  for z in pcb.zones:
    let n = nodeIdOf(z.attrs, "kicad.node")
    if n >= 0: yield n
  for h in pcb.holes:
    let n = nodeIdOf(h.attrs, "kicad.node")
    if n >= 0: yield n
  for _, p in pcb.placements:
    let n = nodeIdOf(p.attrs, "kicad.node")
    if n >= 0: yield n
    for h in p.holes:
      let n2 = nodeIdOf(h.attrs, "kicad.node")
      if n2 >= 0: yield n2

proc liveEntitySet*(pcb: Pcb): HashSet[int32] =
  ## Exported for the round-trip coverage check
  ## (`liveEntities(pcb).len == doc.mapped.len` right after a read).
  for n in liveEntityNodes(pcb): result.incl(n)

proc runDeleteSweep(pcb: Pcb, doc: KicadDoc) =
  let live = liveEntitySet(pcb)
  for n in doc.mapped:
    if n notin live: markDeleted(doc, n)

proc codeForNet(doc: KicadDoc, net: Net): int =
  if net == nil: return 0
  for k, v in doc.netByCode:
    if v == net: return k
  -1

const CanonicalOrder = [
  "version", "generator", "generator_version", "general", "paper",
  "title_block", "layers", "setup", "net", "footprint",
  "gr_line", "gr_rect", "gr_circle", "gr_arc", "gr_poly", "gr_text",
  "gr_text_box", "gr_bbox", "dimension", "image",
  "segment", "arc", "via", "zone", "group",
  "embedded_fonts", "embedded_files",
]

proc classIndex(head: string): int =
  for i, h in CanonicalOrder:
    if h == head: return i
  high(int)

proc resolveInsertAnchor(doc: KicadDoc, root: int32, headToken: string): tuple[after, before: int32] =
  ## The insert-anchor ladder: (1) after the last sibling with the same head;
  ## (2) before the first sibling later in `CanonicalOrder` (e.g. an
  ## unrouted board); (3) `(-1, -1)`: after the root's last child.
  ##
  ## Traps, both guarded: `doc.kids(root)` yields the head atom first, so
  ## non-list children are skipped (else rule 2 anchors on the head token).
  ## Candidates already in `doc.deleted` are skipped -- the delete sweep
  ## runs first, and an insert anchored to a deleted node is never emitted
  ## (e.g. rip up the last segment, add a new one).
  var lastSame: int32 = -1
  for c in doc.kids(root):
    if doc.kind(c) != skList: continue
    if int32(c) in doc.deleted: continue
    if doc.head(c) == headToken: lastSame = c
  if lastSame >= 0: return (lastSame, -1'i32)
  let want = classIndex(headToken)
  for c in doc.kids(root):
    if doc.kind(c) != skList: continue
    if int32(c) in doc.deleted: continue
    if classIndex(doc.head(c)) > want: return (-1'i32, c)
  (-1'i32, -1'i32)

proc lastChildOf(d: SexpDoc, n: int32): int32 =
  ## Rule 3's anchor: the last child of `n`, skipping deleted nodes.
  result = -1
  for c in d.kids(n):
    if int32(c) notin d.deleted: result = c

proc insertAtAnchor(doc: KicadDoc, root: int32, headToken, text: string) =
  let (after, before) = resolveInsertAnchor(doc, root, headToken)
  if after >= 0: markInserted(doc, after, text)
  elif before >= 0: markInsertedBefore(doc, before, text)
  else: markInserted(doc, lastChildOf(doc, root), text)

proc nextUuid(doc: KicadDoc): string =
  ## A quoted v4-shaped UUID, deterministic from `hash(pcb.name) xor
  ## insertCounter`, checked against the read-time set for uniqueness.
  var rng = initRand(doc.rngSeed xor int64(doc.insertCounter))
  inc doc.insertCounter
  var bytes: array[16, uint8]
  for i in 0 ..< 16: bytes[i] = uint8(rand(rng, 255))
  bytes[6] = (bytes[6] and 0x0f'u8) or 0x40'u8
  bytes[8] = (bytes[8] and 0x3f'u8) or 0x80'u8
  var s = ""
  for i, b in bytes:
    s.add(toHex(BiggestInt(b), 2).toLowerAscii)
    if i in [3, 5, 7, 9]: s.add("-")
  "\"" & s & "\""

proc ensureNetCode(pcb: Pcb, doc: KicadDoc, root: int32, net: Net) =
  ## Assigns the next free code and inserts `(net N "name")` for an
  ## undeclared net -- **never renumbers** (that would rewrite every
  ## reference). No-op on a name-only board.
  if net == nil or not doc.hasNetCodes: return
  if codeForNet(doc, net) >= 0: return
  var maxCode = 0
  for k in doc.netByCode.keys: maxCode = max(maxCode, k)
  let code = maxCode + 1
  doc.netByCode[code] = net
  insertAtAnchor(doc, root, "net", "(net " & $code & " " & escapeKicadString(net.name) & ")")

proc trackNetRefText(doc: KicadDoc, net: Net): string =
  ## A track's `(net ...)`: numeric when the board declares codes, else
  ## name-only.
  if doc.hasNetCodes:
    "(net " & $codeForNet(doc, net) & ")"
  else:
    "(net " & escapeKicadString(if net == nil: "" else: net.name) & ")"

proc padNetRefText(doc: KicadDoc, net: Net): string =
  ## A pad always carries the name too, unlike a track.
  if doc.hasNetCodes:
    "(net " & $codeForNet(doc, net) & " " &
      escapeKicadString(if net == nil: "" else: net.name) & ")"
  else:
    "(net " & escapeKicadString(if net == nil: "" else: net.name) & ")"

proc uuidTextFor(attrs: OrderedTable[string, string], doc: KicadDoc): string =
  if attrs.hasKey("kicad.uuid") and attrs["kicad.uuid"].len > 0: attrs["kicad.uuid"]
  else: nextUuid(doc)

# --- track/via regeneration: always regenerate and compare against source
# bytes, independent of `rev`, which also catches a field write that
# bypassed `touch`.

proc regenSegmentText(doc: KicadDoc, c: Copper): string =
  let shp = c.shape
  if shp.kind != shStroke or shp.path.curves.len != 1 or shp.path.curves[0].kind != cvSeg:
    return ""
  let curve = shp.path.curves[0]
  "(segment\n" &
    "\t\t(start " & formatMm(curve.a.x) & " " & formatMm(-curve.a.y) & ")\n" &
    "\t\t(end " & formatMm(curve.b.x) & " " & formatMm(-curve.b.y) & ")\n" &
    "\t\t(width " & formatMm(shp.width) & ")\n" &
    "\t\t(layer " & escapeKicadString(c.layer.name) & ")\n" &
    "\t\t" & trackNetRefText(doc, c.net) & "\n" &
    "\t\t(uuid " & uuidTextFor(c.attrs, doc) & ")\n" &
    "\t)"

proc regenArcText(doc: KicadDoc, c: Copper): string =
  let shp = c.shape
  if shp.kind != shStroke or shp.path.curves.len != 1 or shp.path.curves[0].kind != cvArc:
    return ""
  let curve = shp.path.curves[0]
  let s = startPoint(curve)
  let e = endPoint(curve)
  let midText =
    if c.attrs.hasKey("kicad.arc.mid"): c.attrs["kicad.arc.mid"]
    else:
      # A new arc has no stashed `(mid)`: derive one (not bit-exact with
      # KiCad's writer, but shape-consistent).
      let m = pointOnArc(curve, curve.startAngle + curve.sweep * 0.5)
      "(mid " & formatMm(m.x) & " " & formatMm(-m.y) & ")"
  "(arc\n" &
    "\t\t(start " & formatMm(s.x) & " " & formatMm(-s.y) & ")\n" &
    "\t\t" & midText & "\n" &
    "\t\t(end " & formatMm(e.x) & " " & formatMm(-e.y) & ")\n" &
    "\t\t(width " & formatMm(shp.width) & ")\n" &
    "\t\t(layer " & escapeKicadString(c.layer.name) & ")\n" &
    "\t\t" & trackNetRefText(doc, c.net) & "\n" &
    "\t\t(uuid " & uuidTextFor(c.attrs, doc) & ")\n" &
    "\t)"

proc regenViaText(doc: KicadDoc, h: Hole): string =
  var dia = h.drillDia
  if h.pads.len > 0 and h.pads[0].shape.kind == shPad and h.pads[0].shape.aperture != nil:
    dia = h.pads[0].shape.aperture.dia
  let head =
    case h.viaKind
    of vkBlind: "(via blind\n"
    of vkMicro: "(via micro\n"
    else: "(via\n"
  head &
    "\t\t(at " & formatMm(h.at.x) & " " & formatMm(-h.at.y) & ")\n" &
    "\t\t(size " & formatMm(dia) & ")\n" &
    "\t\t(drill " & formatMm(h.drillDia) & ")\n" &
    "\t\t(layers " & escapeKicadString(if h.fromLayer != nil: h.fromLayer.name else: "") &
      " " & escapeKicadString(if h.toLayer != nil: h.toLayer.name else: "") & ")\n" &
    "\t\t" & trackNetRefText(doc, h.net) & "\n" &
    "\t\t(uuid " & uuidTextFor(h.attrs, doc) & ")\n" &
    "\t)"

proc regenerateTracksAndVias(pcb: Pcb, doc: KicadDoc, root: int32) =
  for _, l in pcb.layers:
    for c in l.copper:
      if c.kind != ckTrack: continue
      let node = nodeIdOf(c.attrs, "kicad.node")
      if node < 0: continue   # a brand-new track: handled by insertNewEntities
      ensureNetCode(pcb, doc, root, c.net)
      let headTok = doc.head(node)
      let text =
        if headTok == "segment": regenSegmentText(doc, c)
        elif headTok == "arc": regenArcText(doc, c)
        else: ""
      if text.len > 0 and text != raw(doc, node): markDirty(doc, node, text)
  for h in pcb.holes:
    if h.kind != hkVia: continue
    let node = nodeIdOf(h.attrs, "kicad.node")
    if node < 0: continue
    ensureNetCode(pcb, doc, root, h.net)
    let text = regenViaText(doc, h)
    if text.len > 0 and text != raw(doc, node): markDirty(doc, node, text)

proc insertNewTracksAndVias(pcb: Pcb, doc: KicadDoc, root: int32) =
  for _, l in pcb.layers:
    for c in l.copper:
      if c.kind != ckTrack or nodeIdOf(c.attrs, "kicad.node") >= 0: continue
      if c.attrs.hasKey("kicad.node"): continue   # already queued (empty-string sentinel)
      let shp = c.shape
      if shp.kind != shStroke or shp.path.curves.len != 1: continue
      ensureNetCode(pcb, doc, root, c.net)
      c.attrs["kicad.uuid"] = nextUuid(doc)
      let headTok = if shp.path.curves[0].kind == cvSeg: "segment" else: "arc"
      let text = if headTok == "segment": regenSegmentText(doc, c) else: regenArcText(doc, c)
      if text.len == 0: continue
      insertAtAnchor(doc, root, headTok, text)
      c.attrs["kicad.node"] = ""   # sentinel: inserted, do not insert again
  for h in pcb.holes:
    if h.kind != hkVia or nodeIdOf(h.attrs, "kicad.node") >= 0: continue
    if h.attrs.hasKey("kicad.node"): continue
    ensureNetCode(pcb, doc, root, h.net)
    h.attrs["kicad.uuid"] = nextUuid(doc)
    let text = regenViaText(doc, h)
    insertAtAnchor(doc, root, "via", text)
    h.attrs["kicad.node"] = ""

# --- footprint / pad field overrides (no whole-node regeneration).

proc regenerateFootprintFields(pcb: Pcb, doc: KicadDoc, root: int32) =
  for _, p in pcb.placements:
    let node = nodeIdOf(p.attrs, "kicad.node")
    if node < 0: continue
    let atChild = doc.child(node, "at")
    if atChild >= 0:
      let want = "(at " & formatAt(p.at, -p.rot) & ")"
      if want != raw(doc, atChild): markDirty(doc, atChild, want)
    let layerChild = doc.child(node, "layer")
    if layerChild >= 0:
      let want = "(layer " & escapeKicadString(if p.side == bsBottom: "B.Cu" else: "F.Cu") & ")"
      if want != raw(doc, layerChild): markDirty(doc, layerChild, want)
    if doc.child(node, "locked") < 0 and p.attrs.getOrDefault("kicad.locked", "") == "yes":
      discard   # adding a fresh `(locked)` flag atom is not attempted this stage
    let wantRef = p.attrs.getOrDefault("kicad.reference", p.designator)
    let hadRef = p.attrs.getOrDefault("kicad.node.refText", wantRef)
    if wantRef != hadRef:
      for propNode in doc.kidsNamed(node, "property"):
        if doc.text(arg(doc, propNode, 0)) == "Reference":
          let valNode = arg(doc, propNode, 1)
          if valNode >= 0:
            let want = escapeKicadString(wantRef)
            if want != raw(doc, valNode): markDirty(doc, valNode, want)
          break
    for pinName, cs in p.lands:
      for c in cs:
        let padNode = nodeIdOf(c.attrs, "kicad.node")
        if padNode < 0: continue
        let netChild = doc.child(padNode, "net")
        if netChild < 0: continue
        ensureNetCode(pcb, doc, root, c.net)
        let want = padNetRefText(doc, c.net)
        if want != raw(doc, netChild): markDirty(doc, netChild, want)

# --- zone scalar overrides (outline/fill polygons are not regenerated).

proc regenerateZoneScalars(pcb: Pcb, doc: KicadDoc, root: int32) =
  for z in pcb.zones:
    let node = nodeIdOf(z.attrs, "kicad.node")
    if node < 0: continue
    ensureNetCode(pcb, doc, root, z.net)
    let netChild = doc.child(node, "net")
    if netChild >= 0:
      let want = "(net " & $codeForNet(doc, z.net) & ")"
      if want != raw(doc, netChild): markDirty(doc, netChild, want)
    let nameChild = doc.child(node, "net_name")
    if nameChild >= 0:
      let want = "(net_name " & escapeKicadString(if z.net == nil: "" else: z.net.name) & ")"
      if want != raw(doc, nameChild): markDirty(doc, nameChild, want)
    let priChild = doc.child(node, "priority")
    if priChild >= 0:
      let want = "(priority " & $z.priority & ")"
      if want != raw(doc, priChild): markDirty(doc, priChild, want)
    let nmChild = doc.child(node, "name")
    if nmChild >= 0 and z.name.len > 0:
      let want = "(name " & escapeKicadString(z.name) & ")"
      if want != raw(doc, nmChild): markDirty(doc, nmChild, want)

# --- refusals

proc checkRefusals(pcb: Pcb, doc: KicadDoc) =
  ## Everything this writer won't synthesize or regenerate, refused by name.
  ## The first offender found is reported.
  for _, p in pcb.placements:
    if nodeIdOf(p.attrs, "kicad.node") < 0 and not p.attrs.hasKey("kicad.node"):
      refuse("writePcb: cannot write a new footprint. Placement '" & p.designator &
             "' was created after the file was read, and this writer regenerates " &
             "only tracks, vias, nets and zones; an existing footprint can be " &
             "moved, rotated, renamed and re-netted in place, but a new one " &
             "cannot be synthesized.")
  for z in pcb.zones:
    if nodeIdOf(z.attrs, "kicad.node") < 0 and not z.attrs.hasKey("kicad.node"):
      refuse("writePcb: cannot write a new zone. Zone '" & z.name & "' was " &
             "created after the file was read; an existing zone's net, name, " &
             "priority and layer can be changed in place, but a new pour " &
             "cannot be synthesized this stage (its outline and fill would " &
             "have to be fabricated with no source to check them against).")
  for _, l in pcb.layers:
    if l.rev > doc.snapshotRev:
      refuse("writePcb: layer '" & l.name & "' has a graphics change (a " &
             "shape added, removed or edited on it) since the file was " &
             "read. `PcbLayer.shapes` (silkscreen, mask, courtyard, " &
             "fabrication) is not regenerated at all by this writer -- " &
             "state the change through a tool that edits KiCad's own " &
             "gr_*/fp_* nodes, or leave the file as read.")
  if pcb.stackup != nil and pcb.stackup.rev > doc.snapshotRev:
    refuse("writePcb: the stack-up changed since the file was read. " &
           "`(setup (stackup))` is a block whose child order is the " &
           "physical stack itself and this writer does not regenerate it " &
           "-- edit the KiCad file directly for a stack-up change.")

proc writePcb*(pcb: Pcb, path: string) =
  ## Writes the board back to `path`: byte-exact if unchanged, otherwise
  ## valid regenerated KiCad (see `checkRefusals` for what's refused).
  if pcb.source == nil and pcb.layers.len > 0:
    # Built, never read (`pcb/assemble.nim`): synthesize the whole file via
    # `kicadgen.renderNewPcb`, splicing real footprint source. An empty
    # placement list still writes (unresolved footprints are reported by
    # `assemble`). `pcb.source` stays nil, so a second call re-synthesizes
    # rather than half-adopting a snapshot no entity is mapped into.
    writeFile(path, renderNewPcb(pcb))
    return
  if not (pcb.source of KicadDoc):
    refuse("kicad.writePcb: '" & pcb.name & "' has no KiCad source to " &
           "write back to -- it was not produced by kicad.readPcb (or its " &
           "source was cleared). This stage regenerates an edited board; " &
           "it does not author a brand-new one from nothing.")
  let doc = KicadDoc(pcb.source)
  if pcb.rev == doc.snapshotRev:
    writeFile(path, render(doc, fastPath = true))
    return
  checkRefusals(pcb, doc)
  let root = doc.roots[0]
  runDeleteSweep(pcb, doc)
  regenerateTracksAndVias(pcb, doc, root)
  regenerateFootprintFields(pcb, doc, root)
  regenerateZoneScalars(pcb, doc, root)
  insertNewTracksAndVias(pcb, doc, root)
  writeFile(path, render(doc, fastPath = false))
