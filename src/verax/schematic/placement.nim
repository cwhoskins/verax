proc cmpJunction(a, b: SchematicJunction): int =
  result = cmp(a.net, b.net)
  if result == 0: result = cmp(a.x, b.x)
  if result == 0: result = cmp(a.y, b.y)

proc pinKey(c: Component, pinName: string): string =
  ## A table key for a pin position (designator + pin name; ref objects
  ## aren't hashable).
  c.designator & "\x1f" & pinName

proc overlapsAny(i: int, x, y: float, pos: seq[Point],
                 ohw, ohh: seq[float], against: openArray[int]): bool =
  ## Whether candidate centre `(x, y)` for part `i` overlaps any inflated
  ## body in `against` (strict interior; `i` skipped). An explicit list so
  ## passes with different orders can reuse it.
  for j in against:
    if j == i: continue
    if abs(x - pos[j].x) < ohw[i] + ohw[j] - 1e-9 and
       abs(y - pos[j].y) < ohh[i] + ohh[j] - 1e-9:
      return true
  false

proc rotatedSlot(s: Point, rot: float): Point =
  ## A pin slot after SVG `rotate(rot)` about the centre (0/90/180/270), in
  ## y-down world: the same transform as the body. Only square two-terminal
  ## symbols rotate, so body extents don't change.
  if abs(rot - 90.0) < 1e-9: Point(x: -s.y, y: s.x)
  elif abs(rot - 180.0) < 1e-9: Point(x: -s.x, y: -s.y)
  elif abs(rot - 270.0) < 1e-9: Point(x: s.y, y: -s.x)
  else: s

const rotationChoices = [0.0, 90.0, 180.0, 270.0]

proc addRot(a, b: float): float {.inline.} =
  ## Compose two quarter-turns into `[0, 360)` (operands are always
  ## `rotationChoices`).
  result = a + b
  if result >= 360.0: result -= 360.0

proc rotatable(sd: SymbolDef): bool {.inline.} =
  ## Only a square two-terminal non-box turns: extents stay valid and all
  ## four orientations are distinct pin assignments.
  not sd.isBox and sd.slots.len == 2 and abs(sd.bodyW - sd.bodyH) <= 1e-9

proc slotOf(sd: SymbolDef, pinName: string, ordinal: int): Point {.inline.} =
  if sd.byName.len > 0: sd.byName[pinName] else: sd.slots[ordinal]

proc pinWorldPositions(comps: seq[Component], syms: seq[SymbolDef],
                       pos: seq[Point], rots: seq[float]):
    Table[string, Point] =
  ## Every pin's world position for the current centres and rotations,
  ## rebuilt once per force iteration.
  result = initTable[string, Point]()
  for i, c in comps:
    var ord = 0
    for pinName, _ in c.pins:
      result[pinKey(c, pinName)] =
        pos[i] + rotatedSlot(slotOf(syms[i], pinName, ord), rots[i])
      inc ord

proc isGroundForOrientation(net: Net): bool {.inline.} =
  ## An explicit power-net kind beats a stray `ptGround` pin (such as V- on an
  ## op-amp): it is a rail, not ground.
  net != nil and isGround(net) and net.kind != ntPower

proc isRailForOrientation(net: Net): bool {.inline.} =
  net != nil and isRail(net) and not isGroundForOrientation(net)

proc powerRank(sd: SymbolDef, comp: Component, angle: float): array[4, int] =
  ## Orientation penalties, compared before wire length: ground,
  ## non-positive rails, positive rails, unannotated rails. Power direction
  ## is never traded for wire length.
  var ord = 0
  for pinName, p in comp.pins:
    let slot = rotatedSlot(slotOf(sd, pinName, ord), angle)
    inc ord
    if isGroundForOrientation(p.net):
      if slot.y <= 0.0: inc result[0]       # ground points down
    elif isRailForOrientation(p.net):
      let voltage = railVoltage(p.net)
      if voltage.has:
        if float(voltage.value) <= 0.0:
          if slot.y <= 0.0: inc result[1]   # negative/zero rail points down
        elif slot.y >= 0.0:
          inc result[2]                     # positive rail points up
      elif slot.y >= 0.0:
        inc result[3]                       # unannotated rail points up

proc rankLess(a, b: array[4, int]): bool {.inline.} =
  for i in 0 ..< a.len:
    if a[i] != b[i]: return a[i] < b[i]
  false

proc rankEqual(a, b: array[4, int]): bool {.inline.} =
  for i in 0 ..< a.len:
    if a[i] != b[i]: return false
  true

proc hasPowerDirection(comp: Component): bool {.inline.} =
  for _, p in comp.pins:
    if isGroundForOrientation(p.net) or isRailForOrientation(p.net): return true
  false

proc rotationScore(sd: SymbolDef, comp: Component, centre: Point, angle: float,
                   pinWorld: Table[string, Point]): float =
  ## Total Manhattan distance from each pin at `angle` to the centroid of its
  ## net-mates. Minimising over four orientations picks axis and flip.
  var ord = 0
  for pinName, p in comp.pins:
    let mine = centre + rotatedSlot(slotOf(sd, pinName, ord), angle)
    inc ord
    if p.net == nil: continue
    var cx, cy = 0.0
    var cnt = 0
    for other in p.net.pins:
      if other.component == nil or
         other.component.designator == comp.designator: continue
      if other.component.netlist != comp.netlist: continue
      let key = pinKey(other.component, other.name)
      if not pinWorld.hasKey(key): continue
      cx += pinWorld[key].x
      cy += pinWorld[key].y
      inc cnt
    if cnt == 0: continue
    result += abs(mine.x - cx / float(cnt)) + abs(mine.y - cy / float(cnt))

proc bestRotation(sd: SymbolDef, comp: Component, centre: Point, current: float,
                  pinWorld: Table[string, Point], margin: float): float =
  ## Power rank first; wire length breaks ties. `margin` applies only within
  ## the incumbent's rank, so hysteresis can't keep a backwards orientation.
  if not rotatable(sd): return 0.0
  var bestAngle = 0.0
  var bestScore = Inf
  var bestRank: array[4, int]
  var first = true
  for angle in rotationChoices:
    let rank = powerRank(sd, comp, angle)
    let s = rotationScore(sd, comp, centre, angle, pinWorld)
    if first or rankLess(rank, bestRank) or
       (rankEqual(rank, bestRank) and
        (s < bestScore - 1e-9 or
         (abs(s - bestScore) <= 1e-9 and angle < bestAngle))):
      first = false
      bestRank = rank
      bestScore = s
      bestAngle = angle
  let currentRank = powerRank(sd, comp, current)
  if not rankEqual(bestRank, currentRank): return bestAngle
  if abs(bestAngle - current) < 1e-9: return current
  if bestScore <= rotationScore(sd, comp, centre, current, pinWorld) - margin:
    bestAngle
  else:
    current

proc slotEscape(slot: Point, bw, bh: float): Point =
  ## A pin's outward axis direction at `slot`, by the `escapeDir` test.
  if abs(abs(slot.x) - bw / 2.0) < abs(abs(slot.y) - bh / 2.0):
    Point(x: (if slot.x >= 0.0: 1.0 else: -1.0), y: 0.0)
  else:
    Point(x: 0.0, y: (if slot.y >= 0.0: 1.0 else: -1.0))

proc axisUnit(p: Point): Point {.inline.} =
  ## The dominant axis of `p` as a unit vector (ties to x). `(0,0)` stays.
  if abs(p.x) >= abs(p.y) and p.x != 0.0:
    Point(x: (if p.x > 0.0: 1.0 else: -1.0), y: 0.0)
  elif p.y != 0.0:
    Point(x: 0.0, y: (if p.y > 0.0: 1.0 else: -1.0))
  else:
    Point(x: 0.0, y: 0.0)

type
  TerminalPlan = object
    owner: int
    net: string
    glyphs: seq[OccSeg]
  SignalEscape = object
    owner: int
    net: string
    a, b: Point
  TerminalPin = object
    owner: int
    net: string
    pt: Point

proc terminalClearance(comps: seq[Component], syms: seq[SymbolDef],
                       pos: seq[Point], rots: seq[float]):
    tuple[coincidences, violations: int, involved: seq[bool]] =
  ## Counts distinct-net terminal-pin coincidences (a hard condition) and
  ## prospective full-length power/ground glyph collisions (a soft
  ## safeguard): a 40-unit glyph must clear foreign escapes, inflated bodies
  ## and differently-named glyphs. The router still shortens/blocks.
  let n = comps.len
  result.involved = newSeq[bool](n)
  var terminals: seq[TerminalPlan]
  var pins: seq[TerminalPin]
  var escapes: seq[SignalEscape]
  for i, c in comps:
    var ord = 0
    for pinName, p in c.pins:
      let slot = rotatedSlot(slotOf(syms[i], pinName, ord), rots[i])
      let pt = pos[i] + slot
      let dir = slotEscape(slot, syms[i].bodyW, syms[i].bodyH)
      if p.net != nil:
        pins.add TerminalPin(owner: i, net: p.net.name, pt: pt)
      if p.net != nil and (isGroundForOrientation(p.net) or
                            isRailForOrientation(p.net)):
        let kind = if isGroundForOrientation(p.net): wkGround else: wkSupply
        terminals.add TerminalPlan(owner: i, net: p.net.name,
          glyphs: terminalGlyphSegments(SchematicWire(net: p.net.name,
            kind: kind, points: @[pt, pt + dir * pinSpan])))
      elif p.net != nil:
        escapes.add SignalEscape(owner: i, net: p.net.name, a: pt,
                                 b: pt + dir * routingClearance)
      inc ord

  for i in 0 ..< pins.len:
    for j in i + 1 ..< pins.len:
      if pins[i].owner != pins[j].owner and pins[i].net != pins[j].net and
         pins[i].pt == pins[j].pt:
        inc result.coincidences
        result.involved[pins[i].owner] = true
        result.involved[pins[j].owner] = true

  for ti, t in terminals:
    var bad = false
    for g in t.glyphs:
      # The terminal starts at its own body, so only foreign bodies count.
      for j in 0 ..< n:
        if j == t.owner: continue
        let hw = syms[j].bodyW / 2.0 + routingClearance
        let hh = syms[j].bodyH / 2.0 + routingClearance
        if segBlocked(g.a, g.b, @[Obstacle(x1: pos[j].x - hw, y1: pos[j].y - hh,
                                            x2: pos[j].x + hw, y2: pos[j].y + hh)]):
          bad = true
          result.involved[j] = true
      for e in escapes:
        if e.net != t.net and segmentsTouch(g.a, g.b, e.a, e.b):
          bad = true
          result.involved[e.owner] = true
    for ui, u in terminals:
      if ui == ti or u.net == t.net: continue
      for g in t.glyphs:
        for h in u.glyphs:
          if segmentsTouch(g.a, g.b, h.a, h.b):
            bad = true
            result.involved[u.owner] = true
    if bad:
      inc result.violations
      result.involved[t.owner] = true

proc protectedLeaf(c: Component, sd: SymbolDef): bool =
  ## A power-directed part with one real signal net: its orientation is
  ## pinned, so prefer moving another part if possible.
  if not rotatable(sd) or not hasPowerDirection(c): return false
  var signals = 0
  for _, p in c.pins:
    if p.net != nil and not isGroundForOrientation(p.net) and
       not isRailForOrientation(p.net):
      inc signals
  signals == 1

proc terminalRepairClass(c: Component, sd: SymbolDef): int =
  ## Prefer moving compact passives; boxes and larger symbols only when
  ## nothing else frees the corridor.
  if not sd.isBox and sd.slots.len == 2:
    var passive = true
    for _, p in c.pins:
      if p.kind notin {ptPassive, ptPower, ptGround}: passive = false
    if passive: return 0
    return 1
  2

const
  terminalRepairAcceptedBudget = 8
  terminalRepairAttemptBudget = 160
  terminalRepairMaxRadius = 6

proc repairTerminalClearance(comps: seq[Component], syms: seq[SymbolDef],
                             pos: var seq[Point], rots: seq[float],
                             ohw, ohh: seq[float], locked: seq[bool] = @[],
                             sides: seq[LayoutSide] = @[],
                             leftSplit = NegInf, rightSplit = Inf,
                             isPower: seq[bool] = @[], powerSplit = Inf) =
  ## Deterministic, bounded post-placement repair: reduce distinct-net pin
  ## coincidences first (hard), then keep grid moves that strictly reduce
  ## glyph conflicts, preserving separation.
  # A two-part sheet has no third part to move: keep it and let stem
  # shortening handle glyph overlap, but not a pin coincidence.
  let initial = terminalClearance(comps, syms, pos, rots)
  if comps.len < 3 and initial.coincidences == 0: return
  var state = initial
  var accepted = 0
  var attempts = 0
  var all = newSeq[int](comps.len)
  for i in 0 ..< comps.len: all[i] = i
  while (state.coincidences > 0 or state.violations > 0) and
        accepted < terminalRepairAcceptedBudget and
        attempts < terminalRepairAttemptBudget:
    var order: seq[int]
    var haveUnprotected = false
    for i in 0 ..< comps.len:
      if state.involved[i] and (locked.len != comps.len or not locked[i]) and
         not protectedLeaf(comps[i], syms[i]):
        haveUnprotected = true
    for i in 0 ..< comps.len:
      if state.involved[i] and (locked.len != comps.len or not locked[i]) and
         (haveUnprotected == false or not protectedLeaf(comps[i], syms[i])):
        order.add i
    order.sort(proc(a, b: int): int =
      result = cmp(terminalRepairClass(comps[a], syms[a]),
                   terminalRepairClass(comps[b], syms[b]))
      if result == 0:
        result = cmp(syms[a].bodyW * syms[a].bodyH,
                     syms[b].bodyW * syms[b].bodyH)
      if result == 0: result = cmp(a, b))
    var improved = false
    for i in order:
      for r in 1 .. terminalRepairMaxRadius:
        for dy in -r .. r:
          for dx in -r .. r:
            if max(abs(dx), abs(dy)) != r: continue
            if attempts >= terminalRepairAttemptBudget: break
            inc attempts
            let x = pos[i].x + float(dx) * grid
            let y = pos[i].y + float(dy) * grid
            if overlapsAny(i, x, y, pos, ohw, ohh, all): continue
            if sides.len == comps.len and
               not sideBandAllows(sides[i], x, ohw[i], leftSplit, rightSplit):
              continue
            if isPower.len == comps.len and
               not powerBandAllows(isPower[i], y, ohh[i], powerSplit):
              continue
            var candidate = pos
            candidate[i] = Point(x: x, y: y)
            let next = terminalClearance(comps, syms, candidate, rots)
            if next.coincidences < state.coincidences or
               (next.coincidences == state.coincidences and
                next.violations < state.violations):
              pos = candidate
              state = next
              inc accepted
              improved = true
              break
          if improved: break
        if improved: break
      if improved: break
    if not improved: break

proc ufFind(parent: var seq[int], x: int): int =
  ## Union-find root with path compression. A class's root is its smallest
  ## member, so ids don't depend on union order.
  var r = x
  while parent[r] != r: r = parent[r]
  var c = x
  while parent[c] != c:
    let nxt = parent[c]
    parent[c] = r
    c = nxt
  r

proc ufUnion(parent: var seq[int], a, b: int) =
  let ra = ufFind(parent, a)
  let rb = ufFind(parent, b)
  if ra == rb: return
  if ra < rb: parent[rb] = ra else: parent[ra] = rb

proc groupsOf(nl: Netlist, comps: seq[Component], pos: seq[Point],
              idxOf: Table[string, int],
              extraMembers: Table[string, seq[string]] =
                initTable[string, seq[string]](),
              noMerge: seq[bool] = @[]): seq[int] =
  ## A group id per part. Parts sharing a signal net (not ground/rails) form
  ## a group; groups of at most `mergeMaxParts` fold into the group of their
  ## nearest power-rail net-mate (a decoupling cap stays by its IC). Ids by
  ## lowest member. Deterministic: merges decided against a pre-merge
  ## snapshot.
  ##
  ## `noMerge` (parallel to `comps`) suppresses the fold for an all-flagged
  ## group, so a power-band unit isn't re-glued to its IC.
  ##
  ## `extraMembers` is plain data (arrays.nim is included later, so
  ## `ArrayPlan` isn't visible here): an array chain's head/tail sits on a
  ## hidden member, and without it the parts wired to the chain would be
  ## split into their own group.
  let n = comps.len
  var parent = newSeq[int](n)
  for i in 0 ..< n: parent[i] = i

  proc members(net: Net): seq[int] =
    for p in net.pins:
      if p.component != nil and idxOf.hasKey(p.component.designator):
        let i = idxOf[p.component.designator]
        if result.len == 0 or i notin result: result.add i
    for d in extraMembers.getOrDefault(net.name, @[]):
      if idxOf.hasKey(d):
        let i = idxOf[d]
        if result.len == 0 or i notin result: result.add i

  for _, net in nl.nets:
    if isGround(net) or isRail(net): continue
    let m = members(net)
    for a in 1 ..< m.len: ufUnion(parent, m[0], m[a])

  # Fold small groups into their nearest power-rail net-mate's group,
  # decided against the pre-merge partition.
  var size = newSeq[int](n)
  for i in 0 ..< n: inc size[ufFind(parent, i)]
  var mergeTo = newSeq[int](n)
  for i in 0 ..< n: mergeTo[i] = -1
  for root in 0 ..< n:
    if ufFind(parent, root) != root: continue
    if size[root] == 0 or size[root] > mergeMaxParts: continue
    if noMerge.len == n:
      var allNoMerge = true
      for j in 0 ..< n:
        if ufFind(parent, j) == root and not noMerge[j]: allNoMerge = false
      if allNoMerge: continue
    var cx, cy = 0.0
    for j in 0 ..< n:
      if ufFind(parent, j) == root:
        cx += pos[j].x
        cy += pos[j].y
    cx /= float(size[root])
    cy /= float(size[root])
    var bestQ = -1
    var bestD = Inf
    for _, net in nl.nets:
      if not isRail(net) or isGround(net): continue
      let m = members(net)
      var touchesRoot = false
      for q in m:
        if ufFind(parent, q) == root: touchesRoot = true
      if not touchesRoot: continue
      for q in m:
        if ufFind(parent, q) == root: continue
        let d = abs(pos[q].x - cx) + abs(pos[q].y - cy)
        if bestQ < 0 or d < bestD - 1e-9 or
           (abs(d - bestD) <= 1e-9 and q < bestQ):
          bestQ = q
          bestD = d
    mergeTo[root] = bestQ
  for root in 0 ..< n:
    if mergeTo[root] >= 0: ufUnion(parent, root, mergeTo[root])

  # Roots are minimal members, so scanning 0 ..< n gives ids in order.
  var gid = initTable[int, int]()
  result = newSeq[int](n)
  for i in 0 ..< n:
    let r = ufFind(parent, i)
    if not gid.hasKey(r): gid[r] = gid.len
  for i in 0 ..< n:
    result[i] = gid[ufFind(parent, i)]

proc packGroups(pos: var seq[Point], ohw, ohh: seq[float], group: seq[int]) =
  ## Shelf-packs per-group inflated boxes with a `groupGap` gutter, by rigid
  ## grid-snapped translations -- only if the packed result is *smaller* than
  ## the force layout (which spreads independent sub-circuits apart but keeps
  ## rail-linked blocks close). Rigid moves keep intra-group geometry; shelf
  ## disjointness keeps cross-group separation.
  let n = pos.len
  var ng = 0
  for g in group: ng = max(ng, g + 1)
  if ng <= 1: return

  var minX = newSeq[float](ng)
  var minY = newSeq[float](ng)
  var maxX = newSeq[float](ng)
  var maxY = newSeq[float](ng)
  for g in 0 ..< ng:
    minX[g] = Inf; minY[g] = Inf; maxX[g] = -Inf; maxY[g] = -Inf
  for i in 0 ..< n:
    let g = group[i]
    minX[g] = min(minX[g], pos[i].x - ohw[i])
    minY[g] = min(minY[g], pos[i].y - ohh[i])
    maxX[g] = max(maxX[g], pos[i].x + ohw[i])
    maxY[g] = max(maxY[g], pos[i].y + ohh[i])

  proc spanArea(): float =
    var x1 = Inf
    var y1 = Inf
    var x2 = -Inf
    var y2 = -Inf
    for g in 0 ..< ng:
      x1 = min(x1, minX[g]); y1 = min(y1, minY[g])
      x2 = max(x2, maxX[g]); y2 = max(y2, maxY[g])
    (x2 - x1) * (y2 - y1)
  let beforeArea = spanArea()

  var totalArea, widest = 0.0
  for g in 0 ..< ng:
    let w = maxX[g] - minX[g]
    totalArea += w * (maxY[g] - minY[g])
    widest = max(widest, w)
  let shelfWidth = max(widest, ceil(packAspect * sqrt(totalArea) / grid) * grid)

  var order = newSeq[int](ng)
  for g in 0 ..< ng: order[g] = g
  order.sort(proc (a, b: int): int =
    result = cmp(maxY[b] - minY[b], maxY[a] - minY[a])
    if result == 0: result = cmp(a, b))

  var dx = newSeq[float](ng)
  var dy = newSeq[float](ng)
  var curX, curY, rowH = 0.0
  for g in order:
    let w = maxX[g] - minX[g]
    let h = maxY[g] - minY[g]
    if curX > 1e-9 and curX + w > shelfWidth:
      curY += rowH + groupGap
      curX = 0.0
      rowH = 0.0
    dx[g] = round((curX - minX[g]) / grid) * grid
    dy[g] = round((curY - minY[g]) / grid) * grid
    curX += w + groupGap
    rowH = max(rowH, h)

  block:
    var x1 = Inf
    var y1 = Inf
    var x2 = -Inf
    var y2 = -Inf
    for g in 0 ..< ng:
      x1 = min(x1, minX[g] + dx[g]); y1 = min(y1, minY[g] + dy[g])
      x2 = max(x2, maxX[g] + dx[g]); y2 = max(y2, maxY[g] + dy[g])
    if (x2 - x1) * (y2 - y1) >= beforeArea - 1e-6: return

  for i in 0 ..< n:
    let g = group[i]
    pos[i].x += dx[g]
    pos[i].y += dy[g]
    if abs(pos[i].x) < 1e-9: pos[i].x = 0.0
    if abs(pos[i].y) < 1e-9: pos[i].y = 0.0

proc portDrives(c: Component): bool =
  ## Whether a component on a port net can source a signal onto it: a
  ## source, a hierarchical block, or anything `classifyConductivity` can't
  ## rule out (assumed capable).
  if c == nil: return false
  if c.subNetlist != nil: return true
  let k = c.kind.toLowerAscii()
  if k in ["voltage_source", "current_source", "battery"]: return true
  if k in behaviouralKinds: return true
  classifyConductivity(c) == condAmbiguous

proc portDirection(n: Net): PortDirection =
  ## Which way a port net flows. An explicit `Pin.kind` wins (`ptOutput`,
  ## then `ptInOut`, then `ptInput`). Otherwise: nothing drives it -> input;
  ## something drives it -> `pdUnspecified`.
  var sawInput = false
  for p in n.pins:
    case p.kind
    of ptOutput: return pdOutput
    of ptInOut: return pdBidir
    of ptInput: sawInput = true
    else: discard
  if sawInput: return pdInput
  for p in n.pins:
    if portDrives(p.component): return pdUnspecified
  pdInput

