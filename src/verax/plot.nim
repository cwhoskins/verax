## SVG line plots for reports: linear/log axes, 1-2-5 ticks with
## engineering-prefix labels, limit lines, measured-point markers, and
## stacked panels sharing an x axis (a Bode plot is two). **Presentation
## only** -- nothing reads values back out of an SVG.
##
## At the package root, below everything that draws curves, and stdlib-only
## (imports only `eng`). Colours are CSS custom properties (`--vx-s1` ...)
## with light-mode fallbacks, so an embedding page can restyle or theme
## them; the categorical order is fixed and never cycled (slot 9+ reuses
## the last slot -- callers cap series instead).
##
## Every panel carries `data-xmap`/`data-ymap` (`left,right,lo,hi,log`) and
## each line `data-name`, so a page script can turn a pointer position back
## into values for a crosshair readout.

import std/[algorithm, math, strutils]
import ./eng

type
  Scale* = enum
    scLinear, scLog

  Axis* = object
    label*: string
    unit*: string
    scale*: Scale
    lo*, hi*: float
      ## Explicit range; `NaN` (the default via `axis`) means auto.

  Series* = object
    name*: string
    x*, y*: seq[float]
    slot*: int
      ## Categorical colour slot, 0-based. Follows the entity, not its rank.

  LimitKind* = enum
    lkMin   ## values below `value` fail
    lkMax   ## values above `value` fail
    lkLine  ## a reference line with no failing side

  Limit* = object
    kind*: LimitKind
    value*: float
    label*: string
    banded*: bool
      ## Applies only over `xFrom .. xTo` (a claim judged over a band);
      ## otherwise across the whole plot.
    xFrom*, xTo*: float

  VLine* = object
    ## A vertical reference: a measured frequency, an `at_f` condition.
    x*: float
    label*: string

  Marker* = object
    x*, y*: float
    label*: string
    slot*: int

  Plot* = object
    title*: string
    xAxis*, yAxis*: Axis
    series*: seq[Series]
    limits*: seq[Limit]
    markers*: seq[Marker]
    vlines*: seq[VLine]
    height*: int
      ## Panel height in px; 0 = default.

const
  plotWidth* = 720
  defaultPanelHeight = 260
  maxPlotPoints* = 2000
  padTop = 30
  padBottom = 42
  padLeft = 70
  padRightPlain = 20
  padRightLabels = 100
  seriesFallback = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4",
                    "#008300", "#4a3aa7", "#e34948"]
    ## The reference categorical order (light mode); `--vx-s1..8` override.

proc axis*(label: string, unit = "", scale = scLinear): Axis =
  Axis(label: label, unit: unit, scale: scale, lo: NaN, hi: NaN)

# --- data reduction -----------------------------------------------------

proc decimate*(x, y: seq[float], maxPoints = maxPlotPoints):
    tuple[x, y: seq[float]] =
  ## Min/max bucket decimation: each bucket keeps its lowest and highest
  ## point in order, so peaks and ringing survive. Inputs at or under
  ## `maxPoints` come back unchanged.
  let n = min(x.len, y.len)
  if n <= maxPoints or maxPoints < 4:
    return (x[0 ..< n], y[0 ..< n])
  let buckets = maxPoints div 2
  for b in 0 ..< buckets:
    let a = b * n div buckets
    let e = (b + 1) * n div buckets
    if e <= a: continue
    var iMin, iMax = -1
    for i in a ..< e:
      if not y[i].isNaN:
        if iMin < 0 or y[i] < y[iMin]: iMin = i
        if iMax < 0 or y[i] > y[iMax]: iMax = i
    if iMin < 0:
      result.x.add x[a]; result.y.add NaN   # keep the gap
      continue
    for i in (if iMin <= iMax: [iMin, iMax] else: [iMax, iMin]):
      if result.x.len > 0 and result.x[^1] == x[i] and result.y[^1] == y[i]:
        continue
      result.x.add x[i]; result.y.add y[i]

# --- ticks --------------------------------------------------------------

proc niceStep(span: float, target: int): float =
  let raw = span / float(max(target, 1))
  let mag = pow(10.0, floor(log10(raw)))
  let f = raw / mag
  let m = if f <= 1.0: 1.0 elif f <= 2.0: 2.0 elif f <= 5.0: 5.0 else: 10.0
  m * mag

proc linearTicks*(lo, hi: float, target = 6): seq[float] =
  ## 1-2-5 steps covering `[lo, hi]`, endpoints included when they land on
  ## a step. Values within 1e-9 of a step snap to it (no `-0.0000001`).
  if not (hi > lo) or lo.classify in {fcInf, fcNegInf, fcNan}: return @[lo]
  let step = niceStep(hi - lo, target)
  var v = ceil(lo / step - 1e-9) * step
  while v <= hi + step * 1e-9:
    result.add (if abs(v) < step * 1e-9: 0.0 else: v)
    v += step

proc logTicks*(lo, hi: float): tuple[major, minor: seq[float]] =
  ## Decades as majors; under two decades the 2 and 5 multiples are majors
  ## too. Minors are the other integer multiples, when the axis is not too
  ## dense to show them.
  if not (lo > 0.0 and hi > lo): return (@[lo], @[])
  let d0 = int(floor(log10(lo) + 1e-9))
  let d1 = int(ceil(log10(hi) - 1e-9))
  let decades = d1 - d0
  let step = max(1, decades div 8)
  for d in d0 .. d1:
    for m in 1 .. 9:
      let v = float(m) * pow(10.0, float(d))
      if v < lo * (1 - 1e-9) or v > hi * (1 + 1e-9): continue
      if m == 1 and (d - d0) mod step == 0: result.major.add v
      elif decades < 2 and m in [2, 5]: result.major.add v
      elif decades <= 6: result.minor.add v

# --- ranges -------------------------------------------------------------

proc finiteRange(vals: seq[float], positive: bool): (float, float) =
  var lo = Inf
  var hi = -Inf
  for v in vals:
    if v.isNaN or v.classify in {fcInf, fcNegInf}: continue
    if positive and v <= 0.0: continue
    lo = min(lo, v); hi = max(hi, v)
  (lo, hi)

proc resolveRange(a: Axis, vals: seq[float], pad: bool): (float, float) =
  var (lo, hi) = finiteRange(vals, a.scale == scLog)
  if not a.lo.isNaN: lo = a.lo
  if not a.hi.isNaN: hi = a.hi
  if lo > hi:   # no data
    return (if a.scale == scLog: (1.0, 10.0) else: (0.0, 1.0))
  case a.scale
  of scLog:
    if hi <= lo * 1.0001:
      lo /= 2; hi *= 2
    if a.lo.isNaN: lo = pow(10.0, floor(log10(lo) + 1e-9))
    if a.hi.isNaN: hi = pow(10.0, ceil(log10(hi) - 1e-9))
    if hi <= lo: hi = lo * 10
  of scLinear:
    if hi - lo <= abs(hi) * 1e-9 + 1e-300:
      let d = (if hi == 0.0: 1.0 else: abs(hi) * 0.1)
      lo -= d; hi += d
    elif pad:
      let step = niceStep(hi - lo, 6)
      if a.lo.isNaN: lo = floor(lo / step + 1e-9) * step
      if a.hi.isNaN: hi = ceil(hi / step - 1e-9) * step
  (lo, hi)

# --- rendering ----------------------------------------------------------

proc fmtNum(v: float): string = formatFloat(v, ffDecimal, 2)

proc esc(s: string): string =
  s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;"))

proc seriesColour*(slot: int): string =
  let i = clamp(slot, 0, seriesFallback.high)
  "var(--vx-s" & $(i + 1) & "," & seriesFallback[i] & ")"

const
  inkPrimary = "var(--vx-ink,#0b0b0b)"
  inkSecondary = "var(--vx-ink2,#52514e)"
  inkMuted = "var(--vx-muted,#898781)"
  gridColour = "var(--vx-grid,#e1e0d9)"
  baseColour = "var(--vx-base,#c3c2b7)"
  surface = "var(--vx-surface,#fcfcfb)"
  critical = "var(--vx-critical,#d03b3b)"
  fontStack = "system-ui,-apple-system,'Segoe UI',sans-serif"

type Mapper = object
  a, b: float     # pixel range
  lo, hi: float   # value range
  log: bool

proc map(m: Mapper, v: float): float =
  if m.log:
    m.a + (log10(v) - log10(m.lo)) / (log10(m.hi) - log10(m.lo)) * (m.b - m.a)
  else:
    m.a + (v - m.lo) / (m.hi - m.lo) * (m.b - m.a)

proc mapAttr(m: Mapper): string =
  fmtNum(m.a) & "," & fmtNum(m.b) & "," & $m.lo & "," & $m.hi & "," &
    (if m.log: "1" else: "0")

proc tickSig(ticks: seq[float]): int =
  ## Significant digits that keep adjacent tick labels distinct: a 5.000 V
  ## rail with 2 mV steps needs four, not `eng`'s default three.
  result = 3
  if ticks.len < 2: return
  let step = abs(ticks[1] - ticks[0])
  var big = 0.0
  for t in ticks: big = max(big, abs(t))
  if step > 0 and big > 0:
    result = clamp(int(ceil(log10(big / step) - 1e-9)) + 1, 3, 7)

proc tickLabel(v: float, unit: string, sig = 3): string =
  if v == 0.0: "0" else: eng(v, unit, sig)

proc renderPanel(p: Plot, top: int, showX: bool, labelsRight: bool,
                 xr: (float, float), showLegend = true): string =
  let h = if p.height > 0: p.height else: defaultPanelHeight
  let padRight = if labelsRight: padRightLabels else: padRightPlain
  let pl = float(padLeft)
  let pr = float(plotWidth - padRight)
  let pt = float(top + padTop)
  let pb = float(top + h - padBottom)
  var yvals: seq[float]
  for s in p.series:
    for v in s.y: yvals.add v
  for l in p.limits: yvals.add l.value
  for m in p.markers: yvals.add m.y
  let (ylo, yhi) = resolveRange(p.yAxis, yvals, pad = true)
  let mx = Mapper(a: pl, b: pr, lo: xr[0], hi: xr[1], log: p.xAxis.scale == scLog)
  let my = Mapper(a: pb, b: pt, lo: ylo, hi: yhi, log: p.yAxis.scale == scLog)
  var o = ""
  o.add "<g class=\"vx-panel\" data-xmap=\"" & mapAttr(mx) & "\" data-ymap=\"" &
        mapAttr(my) & "\" data-xunit=\"" & esc(p.xAxis.unit) &
        "\" data-yunit=\"" & esc(p.yAxis.unit) & "\">\n"
  # title + legend
  if p.title.len > 0:
    o.add "<text x=\"" & fmtNum(pl) & "\" y=\"" & $(top + 18) &
          "\" font-size=\"13\" font-weight=\"600\" fill=\"" & inkPrimary &
          "\">" & esc(p.title) & "</text>\n"
  if showLegend and p.series.len >= 2:
    var lx = pr
    for i in countdown(p.series.high, 0):
      let s = p.series[i]
      let w = float(s.name.len) * 6.5 + 26
      lx -= w
      o.add "<line x1=\"" & fmtNum(lx) & "\" y1=\"" & $(top + 14) & "\" x2=\"" &
            fmtNum(lx + 14) & "\" y2=\"" & $(top + 14) & "\" stroke=\"" &
            seriesColour(s.slot) & "\" stroke-width=\"2\" stroke-linecap=\"round\"/>"
      o.add "<text x=\"" & fmtNum(lx + 18) & "\" y=\"" & $(top + 18) &
            "\" font-size=\"11\" fill=\"" & inkSecondary & "\">" & esc(s.name) &
            "</text>\n"
  # grid + y ticks
  if my.log:
    let (major, minor) = logTicks(ylo, yhi)
    for v in minor:
      let y = fmtNum(my.map(v))
      o.add "<line x1=\"" & fmtNum(pl) & "\" x2=\"" & fmtNum(pr) & "\" y1=\"" & y &
            "\" y2=\"" & y & "\" stroke=\"" & gridColour & "\" stroke-width=\"0.5\"/>\n"
    for v in major:
      let y = fmtNum(my.map(v))
      o.add "<line x1=\"" & fmtNum(pl) & "\" x2=\"" & fmtNum(pr) & "\" y1=\"" & y &
            "\" y2=\"" & y & "\" stroke=\"" & gridColour & "\" stroke-width=\"1\"/>\n"
      o.add "<text x=\"" & fmtNum(pl - 6) & "\" y=\"" & y &
            "\" dy=\"4\" text-anchor=\"end\" font-size=\"11\" fill=\"" & inkMuted &
            "\" style=\"font-variant-numeric:tabular-nums\">" &
            esc(tickLabel(v, p.yAxis.unit)) & "</text>\n"
  else:
    let yt = linearTicks(ylo, yhi)
    let ysig = tickSig(yt)
    for v in yt:
      let y = fmtNum(my.map(v))
      o.add "<line x1=\"" & fmtNum(pl) & "\" x2=\"" & fmtNum(pr) & "\" y1=\"" & y &
            "\" y2=\"" & y & "\" stroke=\"" & gridColour & "\" stroke-width=\"1\"/>\n"
      o.add "<text x=\"" & fmtNum(pl - 6) & "\" y=\"" & y &
            "\" dy=\"4\" text-anchor=\"end\" font-size=\"11\" fill=\"" & inkMuted &
            "\" style=\"font-variant-numeric:tabular-nums\">" &
            esc(tickLabel(v, p.yAxis.unit, ysig)) & "</text>\n"
  # x ticks
  var xmajor: seq[float]
  if mx.log:
    let (major, minor) = logTicks(xr[0], xr[1])
    xmajor = major
    for v in minor:
      let x = fmtNum(mx.map(v))
      o.add "<line x1=\"" & x & "\" x2=\"" & x & "\" y1=\"" & fmtNum(pt) &
            "\" y2=\"" & fmtNum(pb) & "\" stroke=\"" & gridColour &
            "\" stroke-width=\"0.5\"/>\n"
  else:
    xmajor = linearTicks(xr[0], xr[1], 8)
  let xsig = if mx.log: 3 else: tickSig(xmajor)
  for v in xmajor:
    let x = fmtNum(mx.map(v))
    o.add "<line x1=\"" & x & "\" x2=\"" & x & "\" y1=\"" & fmtNum(pt) &
          "\" y2=\"" & fmtNum(pb) & "\" stroke=\"" & gridColour &
          "\" stroke-width=\"1\"/>\n"
    if showX:
      o.add "<text x=\"" & x & "\" y=\"" & fmtNum(pb + 16) &
            "\" text-anchor=\"middle\" font-size=\"11\" fill=\"" & inkMuted &
            "\" style=\"font-variant-numeric:tabular-nums\">" &
            esc(tickLabel(v, p.xAxis.unit, xsig)) & "</text>\n"
  # frame (baseline + left axis)
  o.add "<line x1=\"" & fmtNum(pl) & "\" x2=\"" & fmtNum(pr) & "\" y1=\"" &
        fmtNum(pb) & "\" y2=\"" & fmtNum(pb) & "\" stroke=\"" & baseColour &
        "\" stroke-width=\"1\"/>\n"
  o.add "<line x1=\"" & fmtNum(pl) & "\" x2=\"" & fmtNum(pl) & "\" y1=\"" &
        fmtNum(pt) & "\" y2=\"" & fmtNum(pb) & "\" stroke=\"" & baseColour &
        "\" stroke-width=\"1\"/>\n"
  # axis labels
  if showX and p.xAxis.label.len > 0:
    o.add "<text x=\"" & fmtNum((pl + pr) / 2) & "\" y=\"" & fmtNum(pb + 34) &
          "\" text-anchor=\"middle\" font-size=\"11\" fill=\"" & inkSecondary &
          "\">" & esc(p.xAxis.label) & "</text>\n"
  if p.yAxis.label.len > 0:
    let cy = fmtNum((pt + pb) / 2)
    o.add "<text x=\"14\" y=\"" & cy & "\" transform=\"rotate(-90 14 " & cy &
          ")\" text-anchor=\"middle\" font-size=\"11\" fill=\"" & inkSecondary &
          "\">" & esc(p.yAxis.label) & "</text>\n"
  # limits: a failing-side wash, then the line and its label
  let inRange = proc (v: float): bool =
    not v.isNaN and v >= ylo and v <= yhi and (not my.log or v > 0)
  for l in p.limits:
    if not inRange(l.value): continue
    let y = my.map(l.value)
    var x0 = pl
    var x1 = pr
    if l.banded:
      let a = max(l.xFrom, xr[0])
      let b = min(l.xTo, xr[1])
      if not (b > a) or (mx.log and a <= 0): continue
      x0 = mx.map(a); x1 = mx.map(b)
    case l.kind
    of lkMax:
      o.add "<rect x=\"" & fmtNum(x0) & "\" y=\"" & fmtNum(pt) & "\" width=\"" &
            fmtNum(x1 - x0) & "\" height=\"" & fmtNum(max(0.0, y - pt)) &
            "\" fill=\"" & critical & "\" fill-opacity=\"0.07\"/>\n"
    of lkMin:
      o.add "<rect x=\"" & fmtNum(x0) & "\" y=\"" & fmtNum(y) & "\" width=\"" &
            fmtNum(x1 - x0) & "\" height=\"" & fmtNum(max(0.0, pb - y)) &
            "\" fill=\"" & critical & "\" fill-opacity=\"0.07\"/>\n"
    of lkLine: discard
    o.add "<line x1=\"" & fmtNum(x0) & "\" x2=\"" & fmtNum(x1) & "\" y1=\"" &
          fmtNum(y) & "\" y2=\"" & fmtNum(y) & "\" stroke=\"" & inkSecondary &
          "\" stroke-width=\"1.5\"/>\n"
    if l.label.len > 0:
      o.add "<text x=\"" & fmtNum(x0 + 6) & "\" y=\"" & fmtNum(y - 4) &
            "\" font-size=\"11\" fill=\"" & inkSecondary & "\">" & esc(l.label) &
            "</text>\n"
  for v in p.vlines:
    if v.x.isNaN or v.x < xr[0] or v.x > xr[1] or (mx.log and v.x <= 0): continue
    let x = fmtNum(mx.map(v.x))
    o.add "<line x1=\"" & x & "\" x2=\"" & x & "\" y1=\"" & fmtNum(pt) &
          "\" y2=\"" & fmtNum(pb) & "\" stroke=\"" & inkSecondary &
          "\" stroke-width=\"1\"/>\n"
    if v.label.len > 0:
      o.add "<text x=\"" & x & "\" y=\"" & fmtNum(pt + 12) &
            "\" dx=\"4\" font-size=\"11\" fill=\"" & inkSecondary &
            "\" paint-order=\"stroke\" stroke=\"" & surface &
            "\" stroke-width=\"3\">" & esc(v.label) & "</text>\n"
  # series, broken at non-finite or off-scale points
  o.add "<g fill=\"none\" stroke-width=\"2\" stroke-linejoin=\"round\" " &
        "stroke-linecap=\"round\">\n"
  var ends: seq[(float, Series)]
  for s in p.series:
    let (dx, dy) = decimate(s.x, s.y)
    var runs: seq[string]
    var cur = ""
    var lastY = NaN
    for i in 0 ..< dx.len:
      let ok = not dy[i].isNaN and dy[i].classify notin {fcInf, fcNegInf} and
               (not mx.log or dx[i] > 0) and (not my.log or dy[i] > 0) and
               dx[i] >= xr[0] and dx[i] <= xr[1]
      if not ok:
        if cur.len > 0: runs.add cur
        cur = ""
        continue
      let yy = clamp(my.map(dy[i]), pt - 2, pb + 2)
      cur.add fmtNum(mx.map(dx[i])) & "," & fmtNum(yy) & " "
      lastY = yy
    if cur.len > 0: runs.add cur
    for r in runs:
      o.add "<polyline class=\"vx-line\" data-name=\"" & esc(s.name) &
            "\" stroke=\"" & seriesColour(s.slot) & "\" points=\"" & r.strip &
            "\"/>\n"
    if not lastY.isNaN: ends.add (lastY, s)
  o.add "</g>\n"
  # direct labels at line ends, pushed apart
  if labelsRight and ends.len >= 2:
    ends.sort(proc (a, b: (float, Series)): int = cmp(a[0], b[0]))
    var prev = -Inf
    for (y0, s) in ends:
      let y = max(y0, prev + 13)
      prev = y
      var name = s.name
      if name.len > 14: name = name[0 ..< 13] & "…"
      o.add "<line x1=\"" & fmtNum(pr + 3) & "\" x2=\"" & fmtNum(pr + 11) &
            "\" y1=\"" & fmtNum(y) & "\" y2=\"" & fmtNum(y) & "\" stroke=\"" &
            seriesColour(s.slot) & "\" stroke-width=\"2\"/>"
      o.add "<text x=\"" & fmtNum(pr + 14) & "\" y=\"" & fmtNum(y) &
            "\" dy=\"4\" font-size=\"11\" fill=\"" & inkSecondary & "\">" &
            esc(name) & "</text>\n"
  # markers: 8px dot with a 2px surface ring, native tooltip
  for m in p.markers:
    if not inRange(m.y) or m.x.isNaN or m.x < xr[0] or m.x > xr[1] or
       (mx.log and m.x <= 0):
      continue
    let cx = fmtNum(mx.map(m.x))
    let cy = fmtNum(my.map(m.y))
    o.add "<circle cx=\"" & cx & "\" cy=\"" & cy & "\" r=\"5\" fill=\"" &
          seriesColour(m.slot) & "\" stroke=\"" & surface &
          "\" stroke-width=\"2\"><title>" & esc(m.label) & "</title></circle>\n"
    if m.label.len > 0:
      o.add "<text x=\"" & cx & "\" y=\"" & cy & "\" dx=\"8\" dy=\"-8\" " &
            "font-size=\"11\" font-weight=\"600\" fill=\"" & inkPrimary &
            "\" paint-order=\"stroke\" stroke=\"" & surface &
            "\" stroke-width=\"3\">" & esc(m.label) & "</text>\n"
  o.add "</g>\n"
  o

proc xRangeOf(panels: openArray[Plot]): (float, float) =
  var xs: seq[float]
  for p in panels:
    for s in p.series:
      for v in s.x: xs.add v
    for m in p.markers: xs.add m.x
  # Unpadded: a sweep or a transient spans exactly its data.
  resolveRange(panels[0].xAxis, xs, pad = false)

proc stackSvg*(panels: openArray[Plot]): string =
  ## Panels stacked top to bottom on one shared x range (the first panel's
  ## x axis); only the last shows x tick labels and the x label.
  if panels.len == 0: return ""
  let xr = xRangeOf(panels)
  var labelsRight = false
  for p in panels:
    if p.series.len in 2 .. 4: labelsRight = true
  var body = ""
  var top = 0
  for i, p in panels:
    # One legend per figure: the panels share their series.
    body.add renderPanel(p, top, showX = i == panels.high, labelsRight, xr,
                         showLegend = i == 0)
    top += (if p.height > 0: p.height else: defaultPanelHeight)
  "<svg class=\"vx-plot\" xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 " &
    $plotWidth & " " & $top & "\" width=\"" & $plotWidth & "\" height=\"" & $top &
    "\" font-family=\"" & fontStack & "\" role=\"img\">\n" & body & "</svg>\n"

proc plotSvg*(p: Plot): string =
  stackSvg([p])
