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
    bundleNets: HashSet[string]
      ## Every collapsed-bundle member net name plus its `display`. `finish`
      ## skips these in the ordinary net-name pass -- a merged pin would
      ## otherwise get one label per member stacked on it.
    bundleLabelReqs: seq[tuple[text: string, at, esc: Point]]
      ## One request per **non-ported** collapsed bundle: `finish` places a
      ## single `lrNet` label (`"spi[3]"`) at the merged pin. A ported bundle
      ## emits none -- its port pennant already reads the name.
    arrayNets: HashSet[string]
      ## Every net a collapsed array's group wire drew, plus its display tag
      ## and every chain link. `finish` skips these in the ordinary net-name
      ## pass -- one label per member stacked on the merged pin is what it
      ## prevents.
    arrayLabelReqs: seq[tuple[text: string, at, esc: Point]]
      ## One request per drawn distributed group (`"cs[1:8]"` at the merged
      ## pin) and per non-ported chain arc (`"x7"` at an aux lane). `finish`
      ## places each as a single `lrNet` label.

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
    bundles: BundlePlan
      ## Bus/interface grouping, a function of netlist topology alone (see
      ## `bundles.nim`). Built at the top of `prepare` when `lsBundles` is on,
      ## before `state.syms` is sized -- a merged pin changes `SPI_MEMORY`'s
      ## `U1` box height. `recoverRouting`'s candidate moves never rebuild it.
    arrays: ArrayPlan
      ## Repeated-subsheet grouping (see `arrays.nim`), a function of netlist
      ## topology and the bundle plan. Built in `prepare` when `lsArrays` is
      ## on, **after** `bundles` and **before** `state.comps` is filled -- the
      ## N-1 non-representative members of each collapsed array are never
      ## placed, routed or drawn, so every index-parallel array below is one
      ## entry shorter per hidden member. `recoverRouting` never rebuilds it.
    semanticAnchors: seq[Point]
    portY: Table[string, float]
      ## Post-route interface-port y overrides, keyed by `SchematicPort.name`.
      ## Empty on the first route; `refinePortPlacement` (stage `lsPortRefine`)
      ## fills it from the routed wire geometry and re-routes. `routeScene`
      ## reads it as the column relaxation's *spring target*, not a hard
      ## position, so `portMinGap` still legalises the column.
    routing: RoutingState

proc planComposites(state: var LayoutState) =
  state.composites = compositePlan(state.comps, state.syms, state.bundles.bundled)

proc constrainedSemanticSeed(state: var LayoutState) =
  constrainedSemanticSeed(state.comps, state.pos, state.idxOf, state.composites,
    state.arrays)

proc restoreCompositeOffsets(state: var LayoutState) =
  restoreCompositeOffsets(state.composites, state.pos)

proc constrainedAnchors(state: LayoutState): seq[Point] =
  constrainedAnchors(state.comps, state.pos, state.idxOf, state.composites,
    state.arrays)

proc constrainedRefine(state: var LayoutState) =
  constrainedRefine(state.comps, state.pos, state.idxOf)

proc groupsOf(state: LayoutState): seq[int] =
  var extra: Table[string, seq[string]]
  for netName, homes in state.arrays.extraPins:
    for home in homes: extra.mgetOrPut(netName, @[]).add home.desig
  groupsOf(state.nl, state.comps, state.pos, state.idxOf, extra)

proc packGroups(state: var LayoutState, group: seq[int]) =
  packGroups(state.pos, state.ohw, state.ohh, group)

proc chooseCompositeOrientation(state: var LayoutState) =
  ## `lsCompositeOrient`. No-op unless the constrained plan carries an
  ## orientable composite.
  chooseCompositeOrientation(state.nl, state.comps, state.syms, state.pos,
    state.rots, state.composites)

proc constrainedRecomputeRotations(state: var LayoutState) =
  ## The definitive constrained orient pass: let each orientable composite
  ## revisit its rigid frame now that centres are settled (`revisitCompositeFrames`),
  ## then assign every member and singleton angle. Mutates `state.pos`,
  ## `state.rots` and each composite's `unitRot` in place.
  revisitCompositeFrames(state.nl, state.comps, state.syms, state.pos,
    state.rots, state.semanticAnchors, state.composites)
  state.rots = constrainedRecomputeRotations(state.nl, state.comps, state.syms,
    state.pos, state.rots, state.semanticAnchors, state.composites)

proc placementPool(state: LayoutState): seq[int] =
  ## The items placement actually reasons about: `state.composites.topLevel`,
  ## a mix of leaf and composite arena indices in ascending first-raw-member
  ## order. This -- not `comps.len` -- is the count that actually bounds
  ## `forcePlace`/`separate`'s cost.
  state.composites.topLevel

proc poolMembers(state: LayoutState, item: int): seq[int] =
  ## Every raw component a `placementPool` entry stands for: a composite's
  ## members (`item` is an arena index).
  rawMembers(state.composites, item)

proc poolOffsets(state: LayoutState, item: int): seq[Point] =
  ## Parallel to `poolMembers(state, item)`.
  rawOffsets(state.composites, item)

proc poolOrigin(state: LayoutState, members: seq[int],
               offsets: seq[Point]): Point =
  ## The point a pool item's members are offset from -- the mean of each
  ## member's *implied* origin (`pos[m] - offsets[m]`), exactly the
  ## computation `restoreCompositeOffsets` already uses to re-rigidify a
  ## composite. Well-defined here because every caller runs after a point
  ## where composites are already exactly rigid (`prepare` rigidifies the
  ## seed before `forcePlace` ever runs; `forcePlace` re-rigidifies at the end
  ## of every iteration), so this is a stable representative position, not an
  ## approximation. A singleton with a zero offset makes this exactly
  ## `pos[item]`.
  for at, m in members: result += state.pos[m] - offsets[at]
  result = result * (1.0 / float(members.len))

proc repairTerminalClearance(state: var LayoutState) =
  let locked = compositeMembers(state.composites, state.comps.len)
  repairTerminalClearance(state.comps, state.syms, state.pos, state.rots,
    state.ohw, state.ohh, locked)

# --- placement stages -----------------------------------------------------
# The bodies below were the inline stretches of `layout`. Each mutates the
# index-parallel arrays in `state`; `layout` now calls them in order. The
# historical policy's output must stay byte-identical, so this is a move, not
# a rewrite.

proc prepare(state: var LayoutState) =
  ## Build the component / symbol arrays, the composite plan, the
  ## golden-angle seed, the designator index and the semantic seed / anchors.
  # Bus/interface grouping first: a merged pin changes `symbolFor`'s box
  # sizing, so the plan must exist before the symbols are built. A zero-value
  # plan when nothing groups.
  if state.options.stageEnabled(lsBundles):
    state.bundles = bundlePlan(state.nl)
  # Repeated-subsheet arrays next, and **before `state.comps` is filled**: the
  # plan decides which components are drawn at all. The N-1 non-representative
  # members of every collapsed array are dropped here and never placed, routed
  # or drawn -- the filter is the sibling-clone shape (`ownsPin` /
  # `partIdxByDesig.hasKey`) that every layout site already tolerates. A
  # zero-value plan when fewer than three components share a subsheet, and then
  # this loop is `for _, c in state.nl.components: state.comps.add c` verbatim.
  if state.options.stageEnabled(lsArrays):
    state.arrays = arrayPlan(state.nl, state.bundles)

  for _, c in state.nl.components:
    if c.designator in state.arrays.hidden: continue
    state.comps.add c
  let n = state.comps.len

  state.syms = newSeq[SymbolDef](n)
  for i, c in state.comps:
    let lanes = arrayLanesFor(state.arrays, c)
    let tw = arrayTitleWidth(state.arrays, c)
    if c.designator in state.bundles.bundled:
      let bg = bundleGroupsFor(state.bundles, c)
      state.syms[i] = symbolFor(c, bg.groupOf, bg.groupNames, bg.groupSide,
                                lanes.names, lanes.side, tw)
    else:
      state.syms[i] = symbolFor(c, @[], @[], @[], lanes.names, lanes.side, tw)
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

  # Layer columns are gated on their own stage so a caller may still disable
  # just this pass.
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

  # Repulsion below is pairwise over *pool items*, not raw components: two
  # composites repel each other once, from their own representative origins,
  # broadcasting the one resulting force to every one of their members --
  # not once per raw-member pair (today's `n^2` term, run fresh every one of
  # `iterations`, is the single most expensive computation in the whole
  # pipeline). Membership is static across iterations (composites don't
  # change during force placement), so it is computed once here rather than
  # once per iteration; only each item's `repPos` moves. A raw singleton is
  # its own pool item with a zero offset, so `repPos` is exactly
  # `state.pos[i]` for it -- see `placementPool`.
  let pool = placementPool(state)
  var poolMemberLists = newSeq[seq[int]](pool.len)
  var poolOffsetLists = newSeq[seq[Point]](pool.len)
  for pi, item in pool:
    poolMemberLists[pi] = poolMembers(state, item)
    poolOffsetLists[pi] = poolOffsets(state, item)

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

    var repPos = newSeq[Point](pool.len)
    for pi in 0 ..< pool.len:
      repPos[pi] = poolOrigin(state, poolMemberLists[pi], poolOffsetLists[pi])

    for pi in 0 ..< pool.len:
      for pj in pi + 1 ..< pool.len:
        let dx = repPos[pi].x - repPos[pj].x
        let dy = repPos[pi].y - repPos[pj].y
        var d = sqrt(dx * dx + dy * dy)
        if d < 0.01: d = 0.01
        let f = k * k / d
        let fx = dx / d * f
        let fy = dy / d * f
        for i in poolMemberLists[pi]:
          disp[i].x += fx
          disp[i].y += fy
        for j in poolMemberLists[pj]:
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

      # A collapsed array's chain head/tail physically sits on a *hidden*
      # member, so the pair loop above -- both ends read from `net.pins`
      # directly -- can never see it: the hidden end fails
      # `state.idxOf.hasKey`. Without a pull toward whatever this net's other
      # real pin is, a part wired only to a chain's tail (`spi_daisy_chain`'s
      # R1/R2 terminations) gets no electrical force at all and drifts on
      # repulsion and the semantic anchor's weak 8% y-pull alone, landing far
      # off the array's row rather than snug against it. `arrays.extraPins`
      # re-homes the net onto the representative's own same-named pin, so the
      # pull is anchored there -- the same point routing later draws the wire
      # to.
      #
      # Y-only, deliberately: the ordinary pin-to-pin spring below pulls along
      # both axes, which is right when the anchor and the electrical target
      # agree, but here they can genuinely disagree -- the semantic column
      # (`constrainedTargets`) puts this pool item a whole layer pitch past
      # the array, while the real re-homed pin sits right at the array box's
      # own edge. A 2-D pull toward that near point drags the part's *x* back
      # into the array's own column (the box is wide enough that its edge
      # already reaches partway into the next semantic column), fighting the
      # anchor's 70% x-pull and undoing the layering `constrainedTopology`
      # just computed. Only the part's row within its layer is left for this
      # force to settle -- it has no claim on which layer that is.
      if state.arrays.extraPins.hasKey(net.name):
        for home in state.arrays.extraPins[net.name]:
          if not state.idxOf.hasKey(home.desig): continue
          let i = state.idxOf[home.desig]
          let repComp = state.comps[i]
          let pa = pinWorld.getOrDefault(pinKey(repComp, home.pin), state.pos[i])
          for p in net.pins:
            let cb = p.component
            if cb == nil or cb.netlist != nl or cb.designator == home.desig: continue
            if not state.idxOf.hasKey(cb.designator): continue
            let j = state.idxOf[cb.designator]
            let pb = pinWorld.getOrDefault(pinKey(cb, p.name), state.pos[j])
            let dy = pa.y - pb.y
            var ady = abs(dy)
            if ady < 0.01: ady = 0.01
            let f = ady * ady / k * w
            let fy = (dy / ady) * f
            disp[i].y -= fy
            disp[j].y += fy

    for i in 0 ..< n:
      disp[i].x -= state.pos[i].x * 0.08
      disp[i].y -= state.pos[i].y * 0.08
      # Semantic layers are bounded soft anchors: they guide the search but
      # never overwrite obstacle-driven placement.
      if state.options.policy == lpConstrainedLayered:
        disp[i].x += (state.semanticAnchors[i].x - state.pos[i].x) * 0.70
        disp[i].y += (state.semanticAnchors[i].y - state.pos[i].y) * 0.08

    # A constrained parallel motif is a composite during placement: retain its
    # canonical internal offsets by applying the mean force as one translation.
    if state.options.policy == lpConstrainedLayered:
      for idx in state.composites.topLevel:
        if state.composites.items[idx].raw >= 0: continue
        let members = rawMembers(state.composites, idx)
        var d = Point()
        for i in members: d += disp[i]
        d = d * (1.0 / float(members.len))
        for i in members: disp[i] = d

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

proc separationRects(state: LayoutState, i: int): seq[Obstacle] =
  ## The inflated body (or, for a composite member, its whole unit footprint)
  ## the separation search tests for overlap. A free proc rather than a nested
  ## one: a closure may not capture the `var LayoutState` the search threads.
  let owner = state.composites.ownerOf[i]
  if owner != i:
    compositeFootprint(state.composites, owner, state.syms, state.pos,
                       placementPad)
  else:
    @[Obstacle(x1: state.pos[i].x - state.ohw[i], y1: state.pos[i].y - state.ohh[i],
               x2: state.pos[i].x + state.ohw[i], y2: state.pos[i].y + state.ohh[i])]

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
  # Legalize the early units, not their individual members. The footprint
  # carries placementPad externally while the canonical internal offsets are
  # raw-body touching, so another part cannot occupy the composite gap.
  var placed: seq[int]
  for item in placementPool(state):
    let members = poolMembers(state, item)
    let offsets = poolOffsets(state, item)
    let origin = poolOrigin(state, members, offsets)
    var done = false
    for r in 0 .. maxR:
      for dy in -r .. r:
        for dx in -r .. r:
          if max(abs(dx), abs(dy)) != r: continue
          let delta = Point(x: float(dx) * grid, y: float(dy) * grid)
          for at, m in members:
            state.pos[m] = origin + delta + offsets[at]
          let here = separationRects(state, members[0])
          var clear = true
          for j in placed:
            let other = separationRects(state, j)
            if anyOverlap(here, other):
              clear = false
              break
          if clear:
            done = true
            break
        if done: break
      if done: break
    doAssert done,
      "schematic placement could not separate component " &
      state.comps[members[0]].designator
    placed.add members[0]
