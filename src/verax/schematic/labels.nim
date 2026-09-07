# --- label placement --------------------------------------------------------
# Designator/value text (and net + rail names) is placed here, against the
# finished wire and body geometry, rather than at fixed offsets in `svg.nim`.
# The search is a first-fit over a small ordered set of candidate spots around
# the thing being named; if every candidate collides, candidate 0 is used
# anyway, so the pass is total and a label is never dropped.

type
  Rect = tuple[x1, y1, x2, y2: float]

  LabelLine = tuple[text: string, size: float, role: LabelRole]

  Side = enum
    sRight, sTop, sLeft, sBottom

proc rectsOverlap(a, b: Rect): bool {.inline.} =
  a.x1 < b.x2 - 1e-9 and b.x1 < a.x2 - 1e-9 and
  a.y1 < b.y2 - 1e-9 and b.y1 < a.y2 - 1e-9

proc partInk(p: SchematicPart): Rect =
  ## The drawn-symbol box in world coords. A 90/270 rotation swaps the ink
  ## extents: only square-bodied two-terminal symbols rotate, so their pins
  ## still land, but a resistor's zigzag becomes tall and thin -- which is
  ## exactly why the label then wants the (short) side, not the (long) end.
  var w = p.inkW
  var h = p.inkH
  if abs(p.rotation - 90.0) < 1e-9 or abs(p.rotation - 270.0) < 1e-9:
    swap(w, h)
  (p.x - w / 2.0, p.y - h / 2.0, p.x + w / 2.0, p.y + h / 2.0)

proc portBody(p: SchematicPort): Rect {.inline.} =
  (p.x - p.bodyW / 2.0, p.y - p.bodyH / 2.0,
   p.x + p.bodyW / 2.0, p.y + p.bodyH / 2.0)

proc textWidth(s: string, size: float): float {.inline.} =
  float(s.len) * glyphAspect * size

proc lineBox(originX, baseline: float, s: string, anchor: TextAnchor,
             size: float): Rect =
  ## The ink box of one rendered line. SVG `y` is the baseline; monospace
  ## glyphs rise ~0.8*size above it and drop ~0.2*size below.
  let w = textWidth(s, size)
  let x1 = case anchor
           of taStart: originX
           of taMiddle: originX - w / 2.0
           of taEnd: originX - w
  (x1, baseline - 0.8 * size, x1 + w, baseline + 0.2 * size)

proc blockHeight(lines: seq[LabelLine]): float =
  for i, ln in lines:
    result += ln.size
    if i > 0: result += labelLineGap

proc layoutBlock(lines: seq[LabelLine], refX, refTop: float,
                 anchor: TextAnchor, owner: string):
    tuple[labels: seq[SchematicLabel], box: Rect] =
  ## Stack `lines` downward from `refTop`, each line's origin at `refX` read
  ## per `anchor`. Returns the labels and the union of their ink boxes.
  var y = refTop
  result.box = (Inf, Inf, -Inf, -Inf)
  for ln in lines:
    let baseline = y + 0.8 * ln.size
    let lb = lineBox(refX, baseline, ln.text, anchor, ln.size)
    result.labels.add SchematicLabel(text: ln.text, x: refX, y: baseline,
      anchor: anchor, size: ln.size, role: ln.role, owner: owner)
    result.box = (min(result.box.x1, lb.x1), min(result.box.y1, lb.y1),
                  max(result.box.x2, lb.x2), max(result.box.y2, lb.y2))
    y = baseline + 0.2 * ln.size + labelLineGap

proc candidatesAround(ik: Rect, h: float, order: seq[Side]):
    seq[tuple[refX, refTop: float, anchor: TextAnchor]] =
  ## Candidate top-left anchors for a block of height `h` around ink rect `ik`,
  ## the four sides in `order` first, then the four corners.
  let cx = (ik.x1 + ik.x2) / 2.0
  for s in order:
    case s
    of sRight:  result.add (ik.x2 + labelGap, (ik.y1 + ik.y2) / 2.0 - h / 2.0, taStart)
    of sLeft:   result.add (ik.x1 - labelGap, (ik.y1 + ik.y2) / 2.0 - h / 2.0, taEnd)
    of sTop:    result.add (cx, ik.y1 - labelGap - h, taMiddle)
    of sBottom: result.add (cx, ik.y2 + labelGap, taMiddle)
  result.add (ik.x2 + labelGap, ik.y1 - labelGap - h, taStart)   # top-right
  result.add (ik.x2 + labelGap, ik.y2 + labelGap, taStart)       # bottom-right
  result.add (ik.x1 - labelGap, ik.y1 - labelGap - h, taEnd)     # top-left
  result.add (ik.x1 - labelGap, ik.y2 + labelGap, taEnd)         # bottom-left

