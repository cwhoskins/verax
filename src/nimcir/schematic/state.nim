## Private state and placement-stage bodies shared by the included layout
## pipeline.
##
## This is deliberately included by `layout.nim`, not imported: it keeps
## placement and routing work data out of the public scene contract.
## `LayoutState` bundles the index-parallel component / symbol / position
## arrays the pipeline threads; the stage procs below (`prepare`, `forcePlace`,
## `snapToGrid`, `separate`) and the thin `*(state: LayoutState)` forwarders
## take it by `var` so `layout` reads as an ordered stage list.

type
  RoutingState = object
    ## The routed scene material plus private metadata required by finishing.
    ok: bool
    failOrd: int
    failNet: string
    failPin: int
    failPt: Point
    parts: seq[SchematicPart]
    ports: seq[SchematicPort]
    wires: seq[SchematicWire]
    junctions: seq[SchematicJunction]
    fallbacks: seq[SchematicFallback]
    pinPos: Table[string, Point]
    partIdxByDesig: Table[string, int]
    portedNets: HashSet[string]
    railLabelReqs: seq[tuple[text: string, at, dir: Point]]

  LayoutState = object
    ## All transient placement/routing state. `Schematic` remains solely the
    ## renderer-neutral completed scene.
    nl: Netlist
    options: LayoutOptions
    comps: seq[Component]
    syms: seq[SymbolDef]
    idxOf: Table[string, int]
    pos: seq[Point]
    rots: seq[float]
    ohw: seq[float]
    ohh: seq[float]
    composites: CompositePlan
    semanticAnchors: seq[Point]
    routing: RoutingState

proc planComposites(state: var LayoutState) =
  state.composites = compositePlan(state.comps, state.syms)

proc constrainedSemanticSeed(state: var LayoutState) =
  constrainedSemanticSeed(state.comps, state.pos, state.idxOf)

proc restoreCompositeOffsets(state: var LayoutState) =
  restoreCompositeOffsets(state.composites, state.pos)

proc constrainedAnchors(state: LayoutState): seq[Point] =
  constrainedAnchors(state.comps, state.pos, state.idxOf)

proc constrainedRefine(state: var LayoutState) =
  constrainedRefine(state.comps, state.pos, state.idxOf)

proc groupsOf(state: LayoutState): seq[int] =
  groupsOf(state.nl, state.comps, state.pos, state.idxOf)

proc packGroups(state: var LayoutState, group: seq[int]) =
  packGroups(state.pos, state.ohw, state.ohh, group)

proc constrainedRecomputeRotations(state: LayoutState): seq[float] =
  constrainedRecomputeRotations(state.nl, state.comps, state.syms, state.pos,
    state.rots, state.semanticAnchors)

proc leafSnap(state: var LayoutState) =
  leafSnap(state.comps, state.syms, state.pos, state.rots, state.ohw,
    state.ohh, state.idxOf)

proc repairTerminalClearance(state: var LayoutState) =
  let locked =
    if state.options.policy == lpConstrainedLayered:
      compositeMembers(state.composites, state.comps.len)
    else:
      @[]
  repairTerminalClearance(state.comps, state.syms, state.pos, state.rots,
    state.ohw, state.ohh, locked)

# --- placement stages -----------------------------------------------------
# The bodies below were the inline stretches of `layout`. Each mutates the
# index-parallel arrays in `state`; `layout` now calls them in order. The
# historical policy's output must stay byte-identical, so this is a move, not
# a rewrite.

proc prepare(state: var LayoutState) =
  ## Build the component / symbol arrays, the golden-angle seed and the
  ## designator index; under the constrained policy also the composite plan
  ## and the semantic seed / anchors. The historical golden-angle seed is
  ## deliberately left alone -- changing even the first position changes the
  ## established serialized SVG / JSON output.
  for _, c in state.nl.components: state.comps.add c
  let n = state.comps.len

  state.syms = newSeq[SymbolDef](n)
  for i, c in state.comps: state.syms[i] = symbolFor(c)
  # The constrained plan is made before placement and remains the sole source
  # of member offsets and external composite geometry for the whole pipeline.
  if state.options.policy == lpConstrainedLayered:
    planComposites(state)

  state.pos = newSeq[Point](n)
  for i in 0 ..< n:
    let t = float(i) * 2.399963229728653
    let r = 70.0 * sqrt(float(i + 1))
    state.pos[i] = Point(x: r * cos(t), y: r * sin(t))

  state.idxOf = initTable[string, int]()
  for i, c in state.comps: state.idxOf[c.designator] = i

  # Layer columns are opt-in because changing even this first position changes
  # the established serialized output.
  if state.options.policy == lpConstrainedLayered and
     state.options.stageEnabled(lsSemanticSeed):
    constrainedSemanticSeed(state)
  if state.options.policy == lpConstrainedLayered:
    restoreCompositeOffsets(state)
  state.semanticAnchors =
    if state.options.policy == lpConstrainedLayered:
      constrainedAnchors(state)
    else:
      state.pos

proc forcePlace(state: var LayoutState) =
  ## Orientation is co-optimised with placement: the attraction force below
  ## acts pin-to-pin, so it needs each part's rotation, and the rotation that
  ## minimises a part's wire depends on where its neighbours have been pushed.
  ## Each iteration re-picks every rotation from a *snapshot* of the current
  ## centres and rotations (fresh-write, snapshot-read), so the result never
  ## depends on the order parts are visited. The last stretch of iterations
  ## leaves rotation frozen so the centres settle against a fixed orientation,
  ## and a final pass after separation gives the definitive assignment.
  let n = state.comps.len
  let nl = state.nl
  state.rots = newSeq[float](n)

  let k = 110.0
  let iterations = if state.options.stageEnabled(lsForcePlacement): 250 else: 0
  let temp0 = 2.0 * k
  for it in 0 ..< iterations:
    let temp = temp0 * (1.0 - float(it) / float(iterations))
    var disp = newSeq[Point](n)

    if it < iterations - 30:
      let pw = pinWorldPositions(state.comps, state.syms, state.pos, state.rots)
      var newRots = state.rots
      for i in 0 ..< n:
        newRots[i] = bestRotation(state.syms[i], state.comps[i], state.pos[i],
                                  state.rots[i], pw, grid)
      state.rots = newRots
    let pinWorld = pinWorldPositions(state.comps, state.syms, state.pos,
                                     state.rots)

    for i in 0 ..< n:
      for j in i + 1 ..< n:
        let dx = state.pos[i].x - state.pos[j].x
        let dy = state.pos[i].y - state.pos[j].y
        var d = sqrt(dx * dx + dy * dy)
        if d < 0.01: d = 0.01
        let f = k * k / d
        let fx = dx / d * f
        let fy = dy / d * f
        disp[i].x += fx
        disp[i].y += fy
        disp[j].x -= fx
        disp[j].y -= fy

    for _, net in nl.nets:
      if isGround(net): continue
      let w = if isRail(net): 0.35 else: 1.0
      # Pin-to-pin, not centre-to-centre: a net with pins on three parts pulls
      # each pair together, and a parallel pair sharing two nets is pulled by
      # both wires at once -- so its lowest-energy rest is the two parts side
      # by side with both pin pairs short, which centre-to-centre could never
      # express (both nets were the same centre vector, i.e. one doubled tug
      # toward overlap).
      let ps = net.pins
      for a in 0 ..< ps.len:
        for b in a + 1 ..< ps.len:
          let ca = ps[a].component
          let cb = ps[b].component
          if ca == nil or cb == nil or ca.designator == cb.designator: continue
          if ca.netlist != nl or cb.netlist != nl: continue
          if not (state.idxOf.hasKey(ca.designator) and
                  state.idxOf.hasKey(cb.designator)): continue
          let i = state.idxOf[ca.designator]
          let j = state.idxOf[cb.designator]
          let pa = pinWorld.getOrDefault(pinKey(ca, ps[a].name), state.pos[i])
          let pb = pinWorld.getOrDefault(pinKey(cb, ps[b].name), state.pos[j])
          let dx = pa.x - pb.x
          let dy = pa.y - pb.y
          var d = sqrt(dx * dx + dy * dy)
          if d < 0.01: d = 0.01
          let f = d * d / k * w
          let fx = dx / d * f
          let fy = dy / d * f
          disp[i].x -= fx
          disp[i].y -= fy
          disp[j].x += fx
          disp[j].y += fy

    for i in 0 ..< n:
      disp[i].x -= state.pos[i].x * 0.08
      disp[i].y -= state.pos[i].y * 0.08
      # Semantic layers are bounded soft anchors under the opt-in policy.
      # They guide the search but never overwrite obstacle-driven placement.
      if state.options.policy == lpConstrainedLayered:
        disp[i].x += (state.semanticAnchors[i].x - state.pos[i].x) * 0.70
        disp[i].y += (state.semanticAnchors[i].y - state.pos[i].y) * 0.08

    # A constrained parallel motif is a composite during placement: retain its
    # canonical internal offsets by applying the mean force as one translation.
    if state.options.policy == lpConstrainedLayered:
      for unit in state.composites.units:
        var d = Point()
        for i in unit.members: d += disp[i]
        d = d * (1.0 / float(unit.members.len))
        for i in unit.members: disp[i] = d

    for i in 0 ..< n:
      let d = sqrt(disp[i].x * disp[i].x + disp[i].y * disp[i].y)
      if d > 0.0:
        let lim = min(d, temp)
        state.pos[i].x += disp[i].x / d * lim
        state.pos[i].y += disp[i].y / d * lim
    if state.options.policy == lpConstrainedLayered:
      restoreCompositeOffsets(state)

proc snapToGrid(state: var LayoutState) =
  ## Snap centres to the grid, normalising -0.0 away so hashing stays exact.
  for i in 0 ..< state.pos.len:
    state.pos[i].x = round(state.pos[i].x / grid) * grid
    state.pos[i].y = round(state.pos[i].y / grid) * grid
    if abs(state.pos[i].x) < 1e-9: state.pos[i].x = 0.0
    if abs(state.pos[i].y) < 1e-9: state.pos[i].y = 0.0

proc separationRect(state: LayoutState, unitOf: openArray[int],
                    i: int): Obstacle =
  ## The inflated body (or, for a composite member, its whole unit footprint)
  ## the separation search tests for overlap. A free proc rather than a nested
  ## one: a closure may not capture the `var LayoutState` the search threads.
  if unitOf[i] >= 0:
    compositeFootprint(state.composites, unitOf[i], state.syms, state.pos,
                       placementPad)
  else:
    Obstacle(x1: state.pos[i].x - state.ohw[i], y1: state.pos[i].y - state.ohh[i],
             x2: state.pos[i].x + state.ohw[i], y2: state.pos[i].y + state.ohh[i])

proc separate(state: var LayoutState) =
  ## Separation: each component is placed in deterministic order at the nearest
  ## grid cell whose inflated body is clear of every already-placed body.
  ## Searching an expanding ring outward from the force-layout position keeps
  ## the result close to the layout while guaranteeing non-overlap (no
  ## best-effort pass).
  let n = state.comps.len
  state.ohw = newSeq[float](n)
  state.ohh = newSeq[float](n)
  for i in 0 ..< n:
    state.ohw[i] = state.syms[i].bodyW / 2.0 + placementPad
    state.ohh[i] = state.syms[i].bodyH / 2.0 + placementPad

  let maxR = max(64, 4 * n)
  if state.options.policy == lpConstrainedLayered:
    # Legalize the early units, not their individual members.  The footprint
    # carries placementPad externally while the canonical internal offsets are
    # raw-body touching, so another part cannot occupy the composite gap.
    var unitOf = newSeq[int](n)
    for i in 0 ..< n: unitOf[i] = -1
    for u, unit in state.composites.units:
      for i in unit.members: unitOf[i] = u
    var placed: seq[int]
    for i in 0 ..< n:
      if unitOf[i] >= 0 and state.composites.units[unitOf[i]].members[0] != i:
        continue
      let members =
        if unitOf[i] >= 0: state.composites.units[unitOf[i]].members
        else: @[i]
      var origin = Point()
      for at, m in members: origin += state.pos[m] -
        (if unitOf[i] >= 0: state.composites.units[unitOf[i]].offsets[at]
         else: Point())
      origin = origin * (1.0 / float(members.len))
      var done = false
      for r in 0 .. maxR:
        for dy in -r .. r:
          for dx in -r .. r:
            if max(abs(dx), abs(dy)) != r: continue
            let delta = Point(x: float(dx) * grid, y: float(dy) * grid)
            for at, m in members:
              state.pos[m] = origin + delta +
                (if unitOf[i] >= 0: state.composites.units[unitOf[i]].offsets[at]
                 else: Point())
            let here = separationRect(state, unitOf, i)
            var clear = true
            for j in placed:
              let other = separationRect(state, unitOf, j)
              if here.x1 < other.x2 - 1e-9 and here.x2 > other.x1 + 1e-9 and
                 here.y1 < other.y2 - 1e-9 and here.y2 > other.y1 + 1e-9:
                clear = false
                break
            if clear:
              done = true
              break
          if done: break
        if done: break
      doAssert done,
        "schematic placement could not separate component " &
        state.comps[i].designator
      placed.add i
  else:
    var placed: seq[int]
    for i in 0 ..< n:
      let cx = state.pos[i].x
      let cy = state.pos[i].y
      var done = false
      for r in 0 .. maxR:
        for dy in -r .. r:
          for dx in -r .. r:
            if max(abs(dx), abs(dy)) != r: continue
            let x = cx + float(dx) * grid
            let y = cy + float(dy) * grid
            if not overlapsAny(i, x, y, state.pos, state.ohw, state.ohh, placed):
              state.pos[i] = Point(x: x, y: y)
              done = true
              break
          if done: break
        if done: break
      doAssert done,
        "schematic placement could not separate component " &
        state.comps[i].designator
      placed.add i
