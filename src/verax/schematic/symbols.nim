type
  SymbolDef = object
    name: string
    isBox: bool
    bodyW, bodyH: float
    inkW, inkH: float
      ## The bounding box of what `svg.drawPart` actually strokes for this
      ## symbol, at rotation 0 -- which for the horizontal two-terminal
      ## symbols is far shorter than the `bodyW`/`bodyH` pin span. `layout`
      ## and `svg` are the two files that must agree on drawn geometry: a
      ## change to a symbol's drawing in `svg.nim` needs the matching extent
      ## updated here (see `inkExtent`). Used only to place labels.
    slots: seq[Point]
      ## Positional pin slots: `slots[i]` is the slot of the `i`-th pin in
      ## `Component.pins` order.
    byName: Table[string, Point]
      ## When non-empty, pin slots are keyed by pin name instead of position
      ## (the controlled-source symbol, whose input and output pins sit on
      ## opposite edges regardless of declaration order).
    extraSlots: seq[Point]
      ## Lane slots that belong to no `Component.pins` entry: today only the
      ## two endpoints a collapsed array's chain arc needs (see `arrays.nim`).
      ## Kept out of `slots` on purpose -- `slots` is parallel to `c.pins` and
      ## `slotOf`/`pinWorldPositions`/`rotationScore`/`terminalClearance` all
      ## depend on that. Only `routeScene`'s part loop reads these.
    extraNames: seq[string]
      ## Parallel to `extraSlots`: the lane id (`arrays.nim` builds it as
      ## `<array key>:out` / `<array key>:in`).

const boxStub* = 20.0
  ## How far a fallback-box pin sits outside the *drawn* rectangle. `boxSlots`
  ## puts the pin (and hence its routing escape point) on the `bodyW`/`bodyH`
  ## extent so routing stays grid-aligned; `svg` insets the visible rectangle
  ## by this much and draws a stub from that edge out to the pin.

proc traversalSides(c: Component): seq[int] =
  ## Parallel to `c.pins`: `-1` no opinion, `0` left, `1` right -- from a
  ## declared `traverse:` spec's connectivity graph, so a through-path (the
  ## ADG904's `RFC <-> [RF1..RF4]`) lands its two ends on *opposite* box
  ## edges instead of alternating by declaration order. `boxSlots` treats
  ## `@[]` (the inert value, returned whenever the component states no
  ## traversal, its declared edges don't 2-colour -- an odd cycle has no
  ## two-sided drawing -- or it declares no edge at all, e.g. `traverse:
  ## none`) as "no opinion for any pin", so an undeclared component takes its
  ## exact historical alternating path. A named pin `c.pins` does not have is
  ## silently skipped -- `validateTraversal` is where a bad name is actually
  ## reported, never here.
  ##
  ## Both `traverse.paths` and `traverse.blocked` edges count: each declares
  ## a through-path, and it is topology, not DC conduction, that decides
  ## which edge a pin is drawn on. A pin whose `Pin.kind` already forces a
  ## side (`ptPower`/`ptGround`/`ptInput`/`ptOutput`, `boxSlots`' own special
  ## cases) keeps that edge -- excluded from the result -- but an
  ## `ptInput`/`ptOutput` pin still seeds its connected component's colour
  ## (lowest-ordinal such pin wins) so the two-colouring agrees with
  ## `boxSlots` rather than fighting it.
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
    # Collect this whole connected component first (BFS), so the seed colour
    # can be picked from the lowest-ordinal forced-side pin anywhere in it,
    # not just at `start`.
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
  ## Deterministic fallback-box pin placement, keyed on pin type: declared
  ## power pins leave the top edge, ground pins the bottom, inputs the left and
  ## outputs the right; every other pin fills the left edge then the right,
  ## unless a declared `traverse:` spec's two-colouring (`traversalSides`)
  ## gives it an opinion first -- so a through-path's two ends land on
  ## opposite edges rather than alternating by declaration order. Within an
  ## edge the pins are spread symmetrically about the body centre. `halfW`/
  ## `halfH` are the pin extent -- pins sit on this rectangle so their escape
  ## points land on the routing grid, and `svg` draws the body itself
  ## `boxStub` smaller so each pin visibly juts out with its name just inside.
  ##
  ## `groupOf` (parallel to `c.pins`: `-1` an own slot, `>=0` a merged-group
  ## id), `groupNames[g]` (the drawn lane name, `"spi[3]"`) and `groupSide[g]`
  ## (`-1` auto / `0` left / `1` right) collapse a collapsed bundle's member
  ## pins onto **one lane sharing one slot `Point`**, so `SymbolDef.slots`
  ## stays parallel to `c.pins` and `slotOf`/`pinWorldPositions`/`rotationScore`
  ## are untouched. `rows`/`cols` count *lanes*. **`groupOf.len == 0` is the
  ## historical path, bit-for-bit** -- that one default is the whole inertness
  ## guarantee at this layer; `traversalSides` returning `@[]` for an
  ## undeclared component is what keeps it bit-for-bit too.
  const
    pitch = 40.0       ## row spacing on the left/right edges
    endPitch = 80.0     ## column spacing on the top/bottom edges -- wider so a
                        ## rail stub's net-name label clears the next pin
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

  # Lane-based: a merged group is one lane; every other pin is its own lane.
  # Auxiliary array lanes (`extraLanes`) are appended after the pin lanes --
  # they carry no `c.pins` entry, so they land in `extraSlots`, not `slots`.
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
    # A declared traversal opinion for this lane's first pin wins over a
    # merged bundle group's own `forced` side: `forced` for a lane of
    # otherwise-directionless pins (the ADG904's `m`/RF bus, all `ptPassive`)
    # comes from `bundleGroupsFor`'s generic `portDirection` fallback --
    # "nothing drives it, so call it an input" -- which is not a real
    # electrical statement, whereas `traverse:` is an explicit one about
    # exactly these pins. A pin with a kind-based side of its own
    # (`ptPower`/`ptGround`/`ptInput`/`ptOutput`) always has `travSide[i] ==
    # -1` (`traversalSides` excludes them), so this never overrides a
    # genuinely directional bundle member.
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
  ## The bounding box of what `svg.drawPart` strokes for symbol `name`, at
  ## rotation 0. These literals mirror `svg.nim`'s drawing code -- the resistor
  ## zigzag is +/-10 tall (`svg.zigzag`), the source circle is r=16, the
  ## transistor has leads on three sides -- and the two files must be kept in
  ## step. Only labels read this; it never feeds an obstacle rect.
  case name
  of "resistor", "diode": (bodyW, 20.0)
  of "capacitor", "passive": (bodyW, 24.0)
  of "inductor": (bodyW, 16.0)
  of "voltage_source", "current_source": (32.0, bodyH)
  of "transistor": (bodyH, bodyH)
  else: (bodyW, bodyH)          # source4, box: the drawn shape is the body

proc symbolFor(c: Component, groupOf: seq[int] = @[],
               groupNames: seq[string] = @[], groupSide: seq[int] = @[],
               extraLanes: seq[string] = @[], extraSide: seq[int] = @[],
               titleWidth = 0.0): SymbolDef =
  ## The symbol for `c.kind`, with pin slots relative to the part centre.
  ##
  ## A part is a fallback box when its kind has no registered symbol, when it
  ## instantiates hierarchy (its pins are the child's ports, best drawn as a
  ## box), or when its pin count does not match the symbol's slots.
  ##
  ## The `group*` / `extra*` / `titleWidth` params reach only the box branch --
  ## every collapsed-bundle carrier and every collapsed-array representative is
  ## a box, and the fixed 2-slot / `byName` symbols have no lane to merge, so
  ## confining it there keeps `rotatable`/`slotOf` untouched.
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
    # A rectangular buffer/controlled source: OUT+/OUT- on the right edge,
    # IN+/IN- on the left edge. Slots are keyed by pin name so declaration
    # order never decides which side a pin lands on.
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
  of "bjt", "mosfet", "jfet", "transistor":
    result = SymbolDef(name: "transistor", bodyW: h, bodyH: h,
      slots: @[Point(x: 0.0, y: -pinSpan), Point(x: -pinSpan, y: 0.0),
               Point(x: 0.0, y: pinSpan)])
  else:
    return box()

  if result.slots.len != n:
    return box()
  (result.inkW, result.inkH) = inkExtent(result.name, result.bodyW, result.bodyH)

