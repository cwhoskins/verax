type
  SymbolDef = object
    name: string
    isBox: bool
    bodyW, bodyH: float
    inkW, inkH: float
      ## Bounding box of what `svg.drawPart` strokes, at rotation 0 (much
      ## shorter than the pin span for two-terminal symbols). Must match
      ## `svg.nim` (see `inkExtent`). Used only to place labels.
    slots: seq[Point]
      ## Positional slots: `slots[i]` is the `i`-th pin in `Component.pins`.
    byName: Table[string, Point]
      ## When non-empty, slots are keyed by pin name (the controlled-source
      ## symbol, whose pins sit on fixed edges regardless of order).
    extraSlots: seq[Point]
      ## Lane slots with no `Component.pins` entry (an array's chain-arc
      ## endpoints). Kept out of `slots`, which must stay parallel to
      ## `c.pins`. Only `routeScene` reads these.
    extraNames: seq[string]
      ## Parallel to `extraSlots`: lane ids (`<array key>:out`/`:in`).

const boxStub* = 20.0
  ## How far a box pin sits outside the drawn rectangle: pins sit on the
  ## grid-aligned body extent, and `svg` insets the rectangle and draws a
  ## stub.

proc traversalSides(c: Component): seq[int] =
  ## Parallel to `c.pins`: `-1` no opinion, `0` left, `1` right, from a
  ## `traverse:` spec's two-colouring, so a through-path's ends land on
  ## opposite edges. `@[]` (no spec, no edges, or not 2-colourable) means no
  ## opinion. Unknown pin names are skipped (`validateTraversal` reports
  ## them).
  ##
  ## Both paths and blocked edges count (topology, not conduction). Pins with
  ## a kind-forced side keep it and are excluded, but an input/output pin
  ## seeds its component's colour so the two agree.
  if not statesTraversal(c): return @[]
  let spec = traversal(c)
  if spec.mode == tmNone: return @[]
  var ord = initTable[string, int]()
  var n = 0
  for name, _ in c.pins:
    ord[name] = n
    inc n
  if n == 0: return @[]

  var adj = newSeq[seq[int]](n)
  var anyEdge = false
  for e in spec.edges:
    if not ord.hasKey(e.a) or not ord.hasKey(e.b): continue
    let ia = ord[e.a]
    let ib = ord[e.b]
    if ia == ib: continue
    adj[ia].add ib
    adj[ib].add ia
    anyEdge = true
  if not anyEdge: return @[]

  var hasOwnSide = newSeq[bool](n)
  var seedSide = newSeq[int](n)     # -1 / 0 (left, ptInput) / 1 (right, ptOutput)
  var idx = 0
  for _, p in c.pins:
    seedSide[idx] = -1
    case p.kind
    of ptPower, ptGround: hasOwnSide[idx] = true
    of ptInput: hasOwnSide[idx] = true; seedSide[idx] = 0
    of ptOutput: hasOwnSide[idx] = true; seedSide[idx] = 1
    else: discard
    inc idx

  var color = newSeq[int](n)
  for k in 0 ..< n: color[k] = -1
  for start in 0 ..< n:
    if color[start] != -1 or adj[start].len == 0: continue
    # BFS the whole component first, so the seed colour comes from its
    # lowest-ordinal forced-side pin.
    var order = @[start]
    var seen = newSeq[bool](n)
    seen[start] = true
    var qi = 0
    while qi < order.len:
      let u = order[qi]
      inc qi
      for v in adj[u]:
        if not seen[v]:
          seen[v] = true
          order.add v
    var seed = -1
    var seedOrd = n
    for u in order:
      if seedSide[u] != -1 and u < seedOrd:
        seedOrd = u
        seed = seedSide[u]
    color[start] = (if seed == -1: 0 else: seed)
    var bipartite = true
    var queue = @[start]
    var qi2 = 0
    while qi2 < queue.len:
      let u = queue[qi2]
      inc qi2
      for v in adj[u]:
        if color[v] == -1:
          color[v] = 1 - color[u]
          queue.add v
        elif color[v] == color[u]:
          bipartite = false
    if not bipartite: return @[]

  result = newSeq[int](n)
  for k in 0 ..< n:
    result[k] = (if hasOwnSide[k]: -1 else: color[k])

proc boxSlots(c: Component, groupOf: seq[int] = @[],
              groupNames: seq[string] = @[], groupSide: seq[int] = @[],
              extraLanes: seq[string] = @[], extraSide: seq[int] = @[],
              titleWidth = 0.0):
    tuple[slots, extraSlots: seq[Point], halfW, halfH: float] =
  ## Deterministic box pin placement by pin type: power top, ground bottom,
  ## inputs left, outputs right; others fill left then right unless
  ## `traversalSides` gives an opinion. Pins spread symmetrically per edge on
  ## the `halfW`/`halfH` extent (grid-aligned); `svg` draws the body
  ## `boxStub` smaller.
  ##
  ## `groupOf` (parallel to `c.pins`: `-1` own slot, else merged-group id),
  ## `groupNames` and `groupSide` merge a collapsed bundle's pins onto one
  ## lane sharing one slot, so `slots` stays parallel to `c.pins`. `rows`/
  ## `cols` count lanes. Empty `groupOf` is the unchanged path.
  const
    pitch = 40.0       ## row spacing on the left/right edges
    endPitch = 80.0     ## top/bottom column spacing, wider so a rail stub's
                        ## label clears the next pin
  proc spread(count, k: int, step: float): float =
    (float(k) - float(count - 1) / 2.0) * step

  let travSide = traversalSides(c)

  if groupOf.len == 0 and extraLanes.len == 0 and titleWidth == 0.0:
    var names: seq[string]
    var top, bot, left, right: seq[int]
    var i = 0
    for name, p in c.pins:
      names.add name
      case p.kind
      of ptPower: top.add i
      of ptGround: bot.add i
      of ptInput: left.add i
      of ptOutput: right.add i
      elif i < travSide.len and travSide[i] == 0: left.add i
      elif i < travSide.len and travSide[i] == 1: right.add i
      elif left.len <= right.len: left.add i
      else: right.add i
      inc i
    let n = i
    let rows = max(left.len, right.len)
    let cols = max(top.len, bot.len)
    var sideChars = 0
    for idx in left & right: sideChars = max(sideChars, names[idx].len)
    let innerW = max(max(float(cols) * endPitch / 2.0 + 16.0, 46.0),
                     float(sideChars) * 6.0 + 14.0)
    let innerH = max(float(rows) * pitch / 2.0 + 16.0, 30.0)
    let halfW = innerW + boxStub
    let halfH = innerH + boxStub
    result.slots.setLen(n)
    for k, idx in left:
      result.slots[idx] = Point(x: -halfW, y: spread(left.len, k, pitch))
    for k, idx in right:
      result.slots[idx] = Point(x: halfW, y: spread(right.len, k, pitch))
    for k, idx in top:
      result.slots[idx] = Point(x: spread(top.len, k, endPitch), y: -halfH)
    for k, idx in bot:
      result.slots[idx] = Point(x: spread(bot.len, k, endPitch), y: halfH)
    result.halfW = halfW
    result.halfH = halfH
    return

  # One lane per merged group or ungrouped pin; array lanes (`extraLanes`)
  # follow in `extraSlots`.
  var laneNames: seq[string]
  var laneOfGroup = initTable[int, int]()
  var laneForPin: seq[int]
  var top, bot, left, right: seq[int]
  var i = 0
  for name, p in c.pins:
    let g = (if i < groupOf.len: groupOf[i] else: -1)
    if g >= 0 and laneOfGroup.hasKey(g):
      laneForPin.add laneOfGroup[g]
      inc i
      continue
    let laneName =
      if g >= 0 and g < groupNames.len and groupNames[g].len > 0: groupNames[g]
      else: name
    let forced =
      if g >= 0 and g < groupSide.len: groupSide[g] else: -1
    let laneId = laneNames.len
    # A declared traversal side beats a bundle's `forced` side, which for
    # directionless pins is only `portDirection`'s fallback guess.
    # Directional pins never have a traversal side, so they're unaffected.
    if i < travSide.len and travSide[i] == 0: left.add laneId
    elif i < travSide.len and travSide[i] == 1: right.add laneId
    elif forced == 0: left.add laneId
    elif forced == 1: right.add laneId
    else:
      case p.kind
      of ptPower: top.add laneId
      of ptGround: bot.add laneId
      of ptInput: left.add laneId
      of ptOutput: right.add laneId
      else:
        if left.len <= right.len: left.add laneId
        else: right.add laneId
    laneNames.add laneName
    if g >= 0: laneOfGroup[g] = laneId
    laneForPin.add laneId
    inc i
  let n = i
  var extraLaneId: seq[int]
  for k, laneName in extraLanes:
    let laneId = laneNames.len
    let forced = (if k < extraSide.len: extraSide[k] else: 1)
    if forced == 0: left.add laneId else: right.add laneId
    laneNames.add laneName
    extraLaneId.add laneId
  let rows = max(left.len, right.len)
  let cols = max(top.len, bot.len)
  var sideChars = 0
  for laneId in left & right: sideChars = max(sideChars, laneNames[laneId].len)
  let innerW = max(max(max(float(cols) * endPitch / 2.0 + 16.0, 46.0),
                       float(sideChars) * 6.0 + 14.0), titleWidth)
  let innerH = max(float(rows) * pitch / 2.0 + 16.0, 30.0)
  let halfW = innerW + boxStub
  let halfH = innerH + boxStub
  var laneSlot = newSeq[Point](laneNames.len)
  for k, laneId in left:
    laneSlot[laneId] = Point(x: -halfW, y: spread(left.len, k, pitch))
  for k, laneId in right:
    laneSlot[laneId] = Point(x: halfW, y: spread(right.len, k, pitch))
  for k, laneId in top:
    laneSlot[laneId] = Point(x: spread(top.len, k, endPitch), y: -halfH)
  for k, laneId in bot:
    laneSlot[laneId] = Point(x: spread(bot.len, k, endPitch), y: halfH)
  result.slots.setLen(n)
  for pi in 0 ..< n:
    result.slots[pi] = laneSlot[laneForPin[pi]]
  for laneId in extraLaneId:
    result.extraSlots.add laneSlot[laneId]
  result.halfW = halfW
  result.halfH = halfH

proc inkExtent(name: string, bodyW, bodyH: float): tuple[w, h: float] =
  ## Bounding box of what `svg.drawPart` strokes for `name` at rotation 0.
  ## Mirrors `svg.nim`'s literals; keep the two in step. Labels only.
  case name
  of "resistor", "diode": (bodyW, 20.0)
  of "capacitor", "passive": (bodyW, 24.0)
  of "inductor": (bodyW, 16.0)
  of "voltage_source", "current_source": (32.0, bodyH)
  of "transistor": (bodyH, bodyH)
  else: (bodyW, bodyH)          # source4, box, opamp: the drawn shape is the body

proc symbolFor(c: Component, groupOf: seq[int] = @[],
               groupNames: seq[string] = @[], groupSide: seq[int] = @[],
               extraLanes: seq[string] = @[], extraSide: seq[int] = @[],
               titleWidth = 0.0): SymbolDef =
  ## The symbol for `c.kind`, with slots relative to the part centre. A box
  ## when the kind has no symbol, the part is an instance, or its pin count
  ## doesn't match. The `group*`/`extra*`/`titleWidth` params apply only to
  ## boxes (bundle carriers and array representatives are always boxes).
  let n = c.pins.len
  proc box(): SymbolDef =
    let b = boxSlots(c, groupOf, groupNames, groupSide,
                     extraLanes, extraSide, titleWidth)
    SymbolDef(name: "box", isBox: true, bodyW: b.halfW * 2.0,
              bodyH: b.halfH * 2.0,
              inkW: b.halfW * 2.0 - 2.0 * boxStub,
              inkH: b.halfH * 2.0 - 2.0 * boxStub, slots: b.slots,
              extraSlots: b.extraSlots, extraNames: extraLanes)

  if c.subNetlist != nil:
    return box()

  let h = 2.0 * pinSpan
  let horiz = @[Point(x: -pinSpan, y: 0.0), Point(x: pinSpan, y: 0.0)]
  let vert = @[Point(x: 0.0, y: -pinSpan), Point(x: 0.0, y: pinSpan)]

  case c.kind.toLowerAscii()
  of "resistor":
    result = SymbolDef(name: "resistor", bodyW: h, bodyH: h, slots: horiz)
  of "capacitor":
    result = SymbolDef(name: "capacitor", bodyW: h, bodyH: h, slots: horiz)
  of "inductor":
    result = SymbolDef(name: "inductor", bodyW: h, bodyH: h, slots: horiz)
  of "diode", "led", "zener":
    result = SymbolDef(name: "diode", bodyW: h, bodyH: h, slots: horiz)
  of "fuse", "ferrite_bead", "wire", "jumper", "crystal", "potentiometer",
     "thermistor", "varistor", "switch", "relay", "load_switch", "antenna",
     "speaker", "test_point":
    result = SymbolDef(name: "passive", bodyW: h, bodyH: h, slots: horiz)
  of "voltage_source", "battery":
    result = SymbolDef(name: "voltage_source", bodyW: h, bodyH: h, slots: vert)
  of "current_source", "iswitch":
    result = SymbolDef(name: "current_source", bodyW: h, bodyH: h, slots: vert)
  of "vcvs", "vccs", "cccs", "ccvs":
    # Rectangular buffer/controlled source: OUT+/OUT- right, IN+/IN- left,
    # keyed by pin name.
    if n != 4: return box()
    let bodyW = 2.0 * pinSpan
    let bodyH = 60.0
    var byName = initTable[string, Point]()
    byName["OUT+"] = Point(x: bodyW / 2.0, y: -20.0)
    byName["OUT-"] = Point(x: bodyW / 2.0, y: 20.0)
    byName["IN+"] = Point(x: -bodyW / 2.0, y: -20.0)
    byName["IN-"] = Point(x: -bodyW / 2.0, y: 20.0)
    for pinName, _ in c.pins:
      if not byName.hasKey(pinName): return box()
    return SymbolDef(name: "source4", bodyW: bodyW, bodyH: bodyH,
                     inkW: bodyW, inkH: bodyH, byName: byName)
  of "opamp", "op_amp", "operational_amplifier":
    # Triangular op-amp: IN+/IN- on the left base, OUT at the apex, V+/V- on
    # the slanted edges; keyed by name. A pin mismatch falls back to a box.
    if n != 5: return box()
    let bodyW = 2.0 * pinSpan
    let bodyH = 2.0 * pinSpan
    var byName = initTable[string, Point]()
    byName["IN+"] = Point(x: -bodyW / 2.0, y: -16.0)
    byName["IN-"] = Point(x: -bodyW / 2.0, y: 16.0)
    byName["OUT"] = Point(x: bodyW / 2.0, y: 0.0)
    byName["V+"] = Point(x: 0.0, y: -bodyH / 2.0)
    byName["V-"] = Point(x: 0.0, y: bodyH / 2.0)
    for pinName, _ in c.pins:
      if not byName.hasKey(pinName): return box()
    return SymbolDef(name: "opamp", bodyW: bodyW, bodyH: bodyH,
                     inkW: bodyW, inkH: bodyH, byName: byName)
  of "bjt", "mosfet", "jfet", "transistor":
    result = SymbolDef(name: "transistor", bodyW: h, bodyH: h,
      slots: @[Point(x: 0.0, y: -pinSpan), Point(x: -pinSpan, y: 0.0),
               Point(x: 0.0, y: pinSpan)])
  else:
    return box()

  if result.slots.len != n:
    return box()
  (result.inkW, result.inkH) = inkExtent(result.name, result.bodyW, result.bodyH)

