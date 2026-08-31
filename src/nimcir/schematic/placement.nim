proc cmpJunction(a, b: SchematicJunction): int =
  result = cmp(a.net, b.net)
  if result == 0: result = cmp(a.x, b.x)
  if result == 0: result = cmp(a.y, b.y)

proc pinKey(c: Component, pinName: string): string =
  ## A composite lookup key for a pin position, since ref objects are not
  ## hashable table keys. A designator is unique within a netlist and a pin
  ## name within a component, so the pair is unique.
  c.designator & "\x1f" & pinName

proc overlapsAny(i: int, x, y: float, pos: seq[Point],
                 ohw, ohh: seq[float], against: openArray[int]): bool =
  ## Whether the candidate centre `(x, y)` for part `i` overlaps the inflated
  ## body of any part named in `against` (strict interior; touching is
  ## allowed). `i` itself is skipped if listed. The separation pass passes the
  ## indices it has already placed; taking an explicit list rather than
  ## hard-coding `0 ..< i` keeps the non-overlap check reusable by a later
  ## pass that places parts in a different order.
  for j in against:
    if j == i: continue
    if abs(x - pos[j].x) < ohw[i] + ohw[j] - 1e-9 and
       abs(y - pos[j].y) < ohh[i] + ohh[j] - 1e-9:
      return true
  false

proc rotatedSlot(s: Point, rot: float): Point =
  ## A pin slot after an SVG `rotate(rot)` around the part centre, for `rot` one
  ## of {0, 90, 180, 270}. In the y-down world `svg.nim` uses, `rotate(90)`
  ## sends a +X slot to +Y -- the same transform the body is drawn under, so a
  ## rotated symbol's pins and body cannot disagree. Only the square
  ## two-terminal symbols are ever rotated, so 90/270 swapping `bodyW`/`bodyH`
  ## does not matter (they are equal) and the obstacle rects stay valid.
  if abs(rot - 90.0) < 1e-9: Point(x: -s.y, y: s.x)
  elif abs(rot - 180.0) < 1e-9: Point(x: -s.x, y: -s.y)
  elif abs(rot - 270.0) < 1e-9: Point(x: s.y, y: -s.x)
  else: s

const rotationChoices = [0.0, 90.0, 180.0, 270.0]

proc rotatable(sd: SymbolDef): bool {.inline.} =
  ## A symbol is turned only when it is a square two-terminal non-box: a
  ## quarter turn then never changes `bodyW`/`bodyH`, so the separation and
  ## routing obstacle rects stay valid without a width/height swap, and every
  ## one of the four orientations is a distinct, meaningful pin assignment.
  not sd.isBox and sd.slots.len == 2 and abs(sd.bodyW - sd.bodyH) <= 1e-9

proc slotOf(sd: SymbolDef, pinName: string, ordinal: int): Point {.inline.} =
  if sd.byName.len > 0: sd.byName[pinName] else: sd.slots[ordinal]

proc pinWorldPositions(comps: seq[Component], syms: seq[SymbolDef],
                       pos: seq[Point], rots: seq[float]):
    Table[string, Point] =
  ## Every pin's world position given the current centres and rotations. The
  ## pin-level attraction force and the rotation search both read net-mates'
  ## pin positions out of this, rebuilt once per force-layout iteration.
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
  ## Orientation penalties, compared lexicographically before wire length:
  ## ground, non-positive rails, positive rails, then unannotated rails.
  ## Thus semantic power direction is never traded for a shorter wire.
  var ord = 0
  for pinName, p in comp.pins:
    let slot = rotatedSlot(slotOf(sd, pinName, ord), angle)
    inc ord
    if isGroundForOrientation(p.net):
      if slot.y <= 0.0: inc result[0]       # ground points down
    elif isRailForOrientation(p.net):
      let voltage = railVoltage(p.net)
      if voltage.has:
        if voltage.value <= 0.0:
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
  ## Total Manhattan distance from each of this part's pins, placed at `angle`,
  ## to the centroid of the *other* pins on that pin's net. Minimising it over
  ## the four orientations picks both the pin axis and which end each pin takes
  ## -- a flip falls out when it shortens the wires, with no separate rule.
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
  ## Power direction has a strong lexicographic rank; wire length only breaks
  ## equal power ranks. `margin` applies solely within the incumbent's rank,
  ## so hysteresis cannot retain an electrically backwards orientation.
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
  ## The outward axis direction of a pin at `slot` relative to its part centre,
  ## by the same body-half-extent test `escapeDir` runs on a placed part.
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

proc leafSnap(comps: seq[Component], syms: seq[SymbolDef], pos: var seq[Point],
              rots: var seq[float], ohw, ohh: seq[float],
              idxOf: Table[string, int], locked: seq[bool] = @[]) =
  ## A square two-terminal part with exactly one non-ground / non-rail net has a
  ## single attraction spring: the force layout fixes its distance from that one
  ## net-mate but neither the direction nor the alignment, so it drifts off with
  ## its connected pin facing away. Move each such leaf to the nearest free grid
  ## cell out along its net-mate pin's escape axis -- so the wire between them is
  ## a short straight stub -- and turn it so its connected pin faces back at that
  ## mate. Position is only ever moved *closer* to the mate pin than it already
  ## was, so the pass can only help.
  ##
  ## Runs after the definitive rotation pass, and owns a leaf's orientation
  ## outright: for a part with one real connection "point the pin at it" beats
  ## any wirelength score, and the score's four-way ties (a shunt element sits
  ## symmetrically between its neighbours) were being broken by nothing better
  ## than the smaller angle.
  ##
  ## Deterministic: parts visited in insertion order, each placed and turned
  ## against the others' current centres/rotations, the mate chosen as the
  ## nearest pin with a `pinKey` tie-break.
  let n = comps.len
  var against = newSeq[int](n)
  for i in 0 ..< n: against[i] = i
  for i in 0 ..< n:
    if (locked.len == n and locked[i]) or not rotatable(syms[i]): continue
    var theNet: Net = nil
    var myPin = ""
    var myOrd = 0
    var multi = false
    block:
      var ord = 0
      for pinName, p in comps[i].pins:
        if p.net != nil and not isGroundForOrientation(p.net) and
           not isRailForOrientation(p.net):
          if theNet == nil:
            theNet = p.net; myPin = pinName; myOrd = ord
          elif p.net != theNet: multi = true
        inc ord
    if multi or theNet == nil: continue

    let pw = pinWorldPositions(comps, syms, pos, rots)
    var mate: Pin = nil
    var mateKey = ""
    var mateD = Inf
    for other in theNet.pins:
      if other.component == nil or
         other.component.designator == comps[i].designator: continue
      if other.component.netlist != comps[i].netlist: continue
      if not idxOf.hasKey(other.component.designator): continue
      let key = pinKey(other.component, other.name)
      if not pw.hasKey(key): continue
      let d = manhattan(pw[key], pos[i])
      if d < mateD - 1e-9 or
         (abs(d - mateD) <= 1e-9 and (mate == nil or key < mateKey)):
        mateD = d
        mate = other
        mateKey = key
    if mate == nil: continue

    let j = idxOf[mate.component.designator]
    var ord = 0
    var mslot = Point()
    for pinName, _ in comps[j].pins:
      if pinName == mate.name:
        mslot = rotatedSlot(slotOf(syms[j], pinName, ord), rots[j])
        break
      inc ord
    let m = pos[j] + mslot
    var dir = slotEscape(mslot, syms[j].bodyW, syms[j].bodyH)
    var powerAngle = 0.0
    let powerDirected = hasPowerDirection(comps[i])
    if powerDirected:
      # Put the leaf on the side implied by its power-aware orientation, then
      # its sole signal pin still faces back to the mate after the turn.
      powerAngle = bestRotation(syms[i], comps[i], pos[i], rots[i], pw, 0.0)
      dir = axisUnit(rotatedSlot(slotOf(syms[i], myPin, myOrd), powerAngle)) * -1.0
    let reach = ohw[i] + ohw[j]
    let target = Point(x: round((m.x + dir.x * reach) / grid) * grid,
                       y: round((m.y + dir.y * reach) / grid) * grid)

    var best = pos[i]
    var bestD = manhattan(pos[i], m)
    var found = false
    for r in 0 .. 6:
      for dy in -r .. r:
        for dx in -r .. r:
          if max(abs(dx), abs(dy)) != r: continue
          let x = target.x + float(dx) * grid
          let y = target.y + float(dy) * grid
          if overlapsAny(i, x, y, pos, ohw, ohh, against): continue
          let d = manhattan(Point(x: x, y: y), m)
          if d < bestD - 1e-9:
            bestD = d
            best = Point(x: x, y: y)
            found = true
      if found: break
    if not found: continue
    pos[i] = best

    if powerDirected:
      rots[i] = powerAngle
    else:
      # Turn the leaf so its connected pin points back at the mate (along -dir).
      let wantSlot = Point(x: -dir.x, y: -dir.y)
      let baseSlot = slotOf(syms[i], myPin, myOrd)
      for angle in rotationChoices:
        if axisUnit(rotatedSlot(baseSlot, angle)) == wantSlot:
          rots[i] = angle
          break

type
  TerminalPlan = object
    owner: int
    net: string
    glyphs: seq[OccSeg]
  SignalEscape = object
    owner: int
    net: string
    a, b: Point

proc terminalClearance(comps: seq[Component], syms: seq[SymbolDef],
                       pos: seq[Point], rots: seq[float]):
    tuple[violations: int, involved: seq[bool]] =
  ## Count prospective *full-length* power/ground terminal glyph collisions.
  ## This is deliberately a placement predicate, before routing has shortened
  ## a terminal stem: a 40-unit glyph must clear foreign signal escapes,
  ## routing-inflated foreign bodies, and a differently-named terminal glyph.
  ## The router retains its shortening/blocking checks for arrangements this
  ## bounded repair cannot improve.
  let n = comps.len
  result.involved = newSeq[bool](n)
  var terminals: seq[TerminalPlan]
  var escapes: seq[SignalEscape]
  for i, c in comps:
    var ord = 0
    for pinName, p in c.pins:
      let slot = rotatedSlot(slotOf(syms[i], pinName, ord), rots[i])
      let pt = pos[i] + slot
      let dir = slotEscape(slot, syms[i].bodyW, syms[i].bodyH)
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

  for ti, t in terminals:
    var bad = false
    for g in t.glyphs:
      # The terminal begins at its own body boundary, so only foreign bodies
      # are obstacles here.
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
  ## `leafSnap` owns a square passive leaf's final close, aligned placement.
  ## Prefer a different implicated part when possible rather than undoing that
  ## established cleanup; the leaf remains available if it is the only choice.
  if not rotatable(sd) or not hasPowerDirection(c): return false
  var signals = 0
  for _, p in c.pins:
    if p.net != nil and not isGroundForOrientation(p.net) and
       not isRailForOrientation(p.net):
      inc signals
  signals == 1

proc terminalRepairClass(c: Component, sd: SymbolDef): int =
  ## Prefer moving compact passive symbols. Boxes and larger active symbols are
  ## still eligible when they are the only way to release a terminal corridor.
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
                             ohw, ohh: seq[float], locked: seq[bool] = @[]) =
  ## Deterministic, bounded post-placement repair. It only keeps a grid move
  ## that strictly reduces full-glyph conflicts, preserving the ordinary
  ## placement separation invariant and leaving routing as the final safeguard.
  # A two-part sheet is the canonical powered-leaf presentation: leafSnap has
  # already selected its one useful alignment, while no third part can release
  # a corridor. Keep that established minimal layout and let stem shortening
  # handle its terminal overlap.
  if comps.len < 3: return
  var state = terminalClearance(comps, syms, pos, rots)
  var accepted = 0
  var attempts = 0
  var all = newSeq[int](comps.len)
  for i in 0 ..< comps.len: all[i] = i
  while state.violations > 0 and accepted < terminalRepairAcceptedBudget and
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
            var candidate = pos
            candidate[i] = Point(x: x, y: y)
            let next = terminalClearance(comps, syms, candidate, rots)
            if next.violations < state.violations:
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
  ## Union-find root with path compression. The root of a class is always its
  ## smallest member index (see `ufUnion`), so a class id is a stable function
  ## of the partition alone -- never of the order the unions happened in.
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
              idxOf: Table[string, int]): seq[int] =
  ## A group id per part. Parts joined by a *signal* net (ground and rails
  ## excluded -- neither is routed as a tree) are one group; then every group
  ## of at most `mergeMaxParts` parts is folded into the group holding its
  ## nearest power-rail net-mate, so a decoupling cap or a pull-up is not
  ## stranded away from the IC it serves. Ids are renumbered by ascending
  ## lowest-member index. Fully deterministic: union-find over a fixed edge
  ## set, merge decisions taken against a snapshot of the pre-merge partition.
  let n = comps.len
  var parent = newSeq[int](n)
  for i in 0 ..< n: parent[i] = i

  proc members(net: Net): seq[int] =
    for p in net.pins:
      if p.component != nil and idxOf.hasKey(p.component.designator):
        let i = idxOf[p.component.designator]
        if result.len == 0 or i notin result: result.add i

  for _, net in nl.nets:
    if isGround(net) or isRail(net): continue
    let m = members(net)
    for a in 1 ..< m.len: ufUnion(parent, m[0], m[a])

  # Fold small groups into the group of their nearest power-rail net-mate.
  # Every decision is computed against the current (pre-merge) partition and
  # only applied afterwards, so the outcome cannot depend on merge order.
  var size = newSeq[int](n)
  for i in 0 ..< n: inc size[ufFind(parent, i)]
  var mergeTo = newSeq[int](n)
  for i in 0 ..< n: mergeTo[i] = -1
  for root in 0 ..< n:
    if ufFind(parent, root) != root: continue
    if size[root] == 0 or size[root] > mergeMaxParts: continue
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

  # Renumber: roots are minimal member indices, so scanning 0 ..< n meets them
  # in ascending order and the first-seen order is the id order.
  var gid = initTable[int, int]()
  result = newSeq[int](n)
  for i in 0 ..< n:
    let r = ufFind(parent, i)
    if not gid.hasKey(r): gid[r] = gid.len
  for i in 0 ..< n:
    result[i] = gid[ufFind(parent, i)]

proc packGroups(pos: var seq[Point], ohw, ohh: seq[float], group: seq[int]) =
  ## Shelf-packs the per-group inflated bounding boxes with a `groupGap`
  ## gutter, translating each group by a grid-snapped delta -- but only if the
  ## packed arrangement is *smaller* than what the force layout produced.
  ##
  ## The force layout keeps disconnected blocks apart by repulsion alone (the
  ## only counter-force is a weak gravity), so on a design with genuinely
  ## independent sub-circuits it leaves a page of empty space between them;
  ## re-packing collapses that. But when the blocks are already close --
  ## pulled together by a shared rail -- re-packing would scatter a sensible
  ## arrangement, so the total-area guard reverts to the force layout in that
  ## case. Deterministic: the guard is a pure comparison of two bounding-box
  ## areas.
  ##
  ## Each translation is rigid, so intra-group geometry -- and the separation
  ## invariant it satisfies -- is untouched; the shelves make boxes x-disjoint
  ## within a row and y-disjoint across rows with `groupGap` between, so any
  ## cross-group part pair clears `ohw[i] + ohw[j]` on the separating axis.
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
  ## Whether a component sitting on a port net can source a signal onto it: a
  ## real or synthesized source, a hierarchical block, or any part
  ## `classifyConductivity` cannot rule out (an IC, a transistor, an
  ## unrecognised kind -- assumed capable rather than guessed harmless).
  if c == nil: return false
  if c.subNetlist != nil: return true
  let k = c.kind.toLowerAscii()
  if k in ["voltage_source", "current_source", "battery"]: return true
  if k in behaviouralKinds: return true
  classifyConductivity(c) == condAmbiguous

proc portDirection(n: Net): PortDirection =
  ## Which way a port net flows. An explicit `Pin.kind` wins -- `ptOutput`,
  ## then `ptInOut`, then `ptInput` -- because that is the authored answer.
  ## With nothing stated, a driver test decides: a net nothing on the sheet
  ## drives is an input; a net something drives makes no directional claim
  ## (`pdUnspecified`, a neutral symbol).
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

