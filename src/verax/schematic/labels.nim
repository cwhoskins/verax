# --- label placement --------------------------------------------------------
# Labels are placed against the finished geometry by first-fit over ordered
# candidate spots; if all collide, the least bad is used (never dropped).

type
  Rect = tuple[x1, y1, x2, y2: float]

  LabelLine = tuple[text: string, size: float, role: LabelRole]

  Side = enum
    sRight, sTop, sLeft, sBottom

proc rectsOverlap(a, b: Rect): bool {.inline.} =
  a.x1 < b.x2 - 1e-9 and b.x1 < a.x2 - 1e-9 and
  a.y1 < b.y2 - 1e-9 and b.y1 < a.y2 - 1e-9

proc partInk(p: SchematicPart): Rect =
  ## The drawn-symbol box in world coords. 90/270 swaps the ink extents (a
  ## rotated resistor's label wants the short side).
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
  ## The ink box of one line: SVG `y` is the baseline; glyphs rise ~0.8 and
  ## drop ~0.2 of `size`.
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
  ## Stack `lines` down from `refTop`, origin `refX` per `anchor`; returns
  ## labels and their union ink box.
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
  ## Candidate top-left anchors around ink rect `ik`: four sides in `order`,
  ## then the corners.
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

