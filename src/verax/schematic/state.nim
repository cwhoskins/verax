## Private state and placement-stage bodies for the layout pipeline.
## Included by `layout.nim` (not imported) to keep work data out of the
## public scene contract. `LayoutState` bundles the index-parallel
## component/symbol/position arrays; stage procs take it by `var`.

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
      ## Every collapsed-bundle member net plus its `display`; `finish` skips
      ## these so a merged pin isn't labelled once per member.
    bundleLabelReqs: seq[tuple[text: string, at, esc: Point]]
      ## One `lrNet` label request per **non-ported** collapsed bundle; a
      ## ported bundle's pennant already names it.
    arrayNets: HashSet[string]
      ## Every net an array's group wire drew, its display tag, and chain
      ## links; `finish` skips these in the net-name pass.
    arrayLabelReqs: seq[tuple[text: string, at, esc: Point]]
      ## One `lrNet` label per distributed group (`"cs[1:8]"`) and per
      ## non-ported chain arc (`"x7"`).

  LayoutState = object
    ## All transient placement/routing state; `Schematic` is only the
    ## finished scene.
    nl: Netlist
    options: LayoutOptions
    comps: seq[Component]
    syms: seq[SymbolDef]
    idxOf: Table[string, int]
    pos: seq[Point]
    rots: seq[float]
    mirrors: seq[bool]
      ## Parallel to `comps`. Written only by `applyMirror`, which also bakes
      ## the reflection into `syms[i]`'s slots so nothing downstream needs a
      ## mirror-aware transform. All-false is the zero value.
    ohw: seq[float]
    ohh: seq[float]
    composites: CompositePlan
    bundles: BundlePlan
      ## Bus/interface grouping (`bundles.nim`). Built at the top of `prepare`
      ## before `syms` is sized (merged pins change box heights). Never
      ## rebuilt by `recoverRouting`.
    arrays: ArrayPlan
      ## Repeated-part grouping (`arrays.nim`). Built in `prepare` after
      ## `bundles` and before `comps` is filled: hidden members are never
      ## placed, routed or drawn. Never rebuilt by `recoverRouting`.
    semanticAnchors: seq[Point]
    overrides: LayoutOverridePlan
      ## Authored `layout.side` hints, parallel to `comps`. `any == false` is
      ## the zero value every consumer is gated on.
    leftSplit: float
      ## The left band's x boundary from `enforceLayoutSides`; `-Inf` when
      ## unused. Later movers respect it via `sideBandAllows`.
    rightSplit: float
      ## The mirror of `leftSplit` for the right band; `Inf` when unused.
    power: PowerPlan
      ## Power/decoupling classification (`power.nim`), built after
      ## `planComposites`. Gated on `lsPowerBand`: disabled leaves the zero
      ## value whatever components state.
    powerSplit: float
      ## The power band's y boundary from `enforcePowerBand`; `Inf` when
      ## unused. Later movers respect it via `powerBandAllows`.
    portY: Table[string, float]
      ## Post-route port y overrides by `SchematicPort.name`, filled by
      ## `refinePortPlacement`. A spring target for the column relaxation, not
      ## a hard position.
    routing: RoutingState

proc planComposites(state: var LayoutState) =
  ## An array representative is excluded like a bundle carrier. A component
  ## array's representative is a visible two-terminal part, so without this
  ## a resistor badged `x8` could be claimed by a composite.
  var excluded = state.bundles.bundled
  for rep in state.arrays.byRep.keys: excluded.incl rep
  state.composites = compositePlan(state.comps, state.syms, excluded)

proc activeOverrides(state: LayoutState): LayoutOverridePlan =
  ## `state.overrides` gated on `lsLayoutOverrides`, so disabling the stage
  ## yields an empty plan everywhere, not just a skipped enforcement.
  if state.options.stageEnabled(lsLayoutOverrides): state.overrides
  else: LayoutOverridePlan()

proc constrainedSemanticSeed(state: var LayoutState) =
  constrainedSemanticSeed(state.comps, state.pos, state.idxOf, state.composites,
    state.arrays, activeOverrides(state))

proc restoreCompositeOffsets(state: var LayoutState) =
  restoreCompositeOffsets(state.composites, state.pos)

proc constrainedAnchors(state: LayoutState): seq[Point] =
  constrainedAnchors(state.comps, state.pos, state.idxOf, state.composites,
    state.arrays, activeOverrides(state))

proc constrainedRefine(state: var LayoutState) =
  constrainedRefine(state.comps, state.pos, state.idxOf)

proc groupsOf(state: LayoutState): seq[int] =
  var extra: Table[string, seq[string]]
  for netName, homes in state.arrays.extraPins:
    for home in homes: extra.mgetOrPut(netName, @[]).add home.desig
  let noMerge = rawPowerFlags(state.power, state.composites, state.comps.len)
  groupsOf(state.nl, state.comps, state.pos, state.idxOf, extra, noMerge)

proc packGroups(state: var LayoutState, group: seq[int]) =
  packGroups(state.pos, state.ohw, state.ohh, group)

proc chooseCompositeOrientation(state: var LayoutState) =
  ## `lsCompositeOrient`. No-op unless the constrained plan carries an
  ## orientable composite.
  chooseCompositeOrientation(state.nl, state.comps, state.syms, state.pos,
    state.rots, state.composites)

proc mirrorable(sd: SymbolDef): bool {.inline.} =
  ## Mirroring is limited to fallback boxes: they're symmetric and their pin
  ## edges derive from world coordinates, so reflecting the slots is
  ## self-contained. Symbols are excluded (would need an SVG transform; for a
  ## horizontal two-terminal symbol mirror-X equals `rotate(180)` anyway).
  sd.isBox

proc applyMirror(state: var LayoutState, i: int, on: bool) =
  ## Sets `mirrors[i]` and reflects `syms[i]`'s slots about x=0 if the state
  ## changes. Idempotent.
  if state.mirrors[i] == on: return
  state.mirrors[i] = on
  for k in 0 ..< state.syms[i].slots.len:
    state.syms[i].slots[k].x = -state.syms[i].slots[k].x
  for k in 0 ..< state.syms[i].extraSlots.len:
    state.syms[i].extraSlots[k].x = -state.syms[i].extraSlots[k].x
  for key in state.syms[i].byName.keys:
    state.syms[i].byName[key].x = -state.syms[i].byName[key].x

proc chooseMirrors(state: var LayoutState) =
  ## `lsMirror`, once centres are final. A stated `layout.mirror` is honoured
  ## absolutely. Otherwise a mirrorable box outside any multi-member unit
  ## (flipping one member would break the composite's frame) is scored both
  ## ways with `rotationScore`, against one snapshot so order doesn't matter.
  let ov = activeOverrides(state)
  let n = state.comps.len
  let pinWorld = pinWorldPositions(state.comps, state.syms, state.pos, state.rots)
  var decision = newSeq[bool](n)
  for i in 0 ..< n:
    if i < ov.mirror.len and ov.mirror[i] != mirrorAuto:
      decision[i] = ov.mirror[i] == mirrorOn
      continue
    if not mirrorable(state.syms[i]): continue
    if state.composites.ownerOf[i] != i: continue
    let plainScore = rotationScore(state.syms[i], state.comps[i], state.pos[i],
                                    0.0, pinWorld)
    var mirroredSym = state.syms[i]
    for k in 0 ..< mirroredSym.slots.len:
      mirroredSym.slots[k].x = -mirroredSym.slots[k].x
    for k in 0 ..< mirroredSym.extraSlots.len:
      mirroredSym.extraSlots[k].x = -mirroredSym.extraSlots[k].x
    let mirroredScore = rotationScore(mirroredSym, state.comps[i], state.pos[i],
                                       0.0, pinWorld)
    decision[i] = mirroredScore < plainScore - grid
  for i in 0 ..< n:
    applyMirror(state, i, decision[i])

proc constrainedRecomputeRotations(state: var LayoutState) =
  ## Lets each orientable composite revisit its frame now that centres are
  ## settled, then assigns every angle. Mutates `pos`, `rots` and `unitRot`.
  revisitCompositeFrames(state.nl, state.comps, state.syms, state.pos,
    state.rots, state.semanticAnchors, state.composites)
  state.rots = constrainedRecomputeRotations(state.nl, state.comps, state.syms,
    state.pos, state.rots, state.semanticAnchors, state.composites)

proc placementPool(state: LayoutState): seq[int] =
  ## The items placement reasons about: `composites.topLevel` (leaf and
  ## composite indices). This count bounds `forcePlace`/`separate`'s cost.
  state.composites.topLevel

proc poolMembers(state: LayoutState, item: int): seq[int] =
  ## Every raw component a pool item stands for.
  rawMembers(state.composites, item)

proc poolOffsets(state: LayoutState, item: int): seq[Point] =
  ## Parallel to `poolMembers(state, item)`.
  rawOffsets(state.composites, item)

proc poolOrigin(state: LayoutState, members: seq[int],
               offsets: seq[Point]): Point =
  ## The point a pool item's members are offset from: the mean implied
  ## origin (`pos[m] - offsets[m]`). Exact because composites are rigid at
  ## every caller. For a singleton, `pos[item]`.
  for at, m in members: result += state.pos[m] - offsets[at]
  result = result * (1.0 / float(members.len))

proc repairTerminalClearance(state: var LayoutState) =
  let locked = compositeMembers(state.composites, state.comps.len)
  # `activeOverrides`: with the stage disabled, the splits stay at `-Inf`/
  # `Inf`, and a non-empty `sides` would reject every candidate; an empty one
  # skips the check.
  let ov = activeOverrides(state)
  let isPower = rawPowerFlags(state.power, state.composites, state.comps.len)
  repairTerminalClearance(state.comps, state.syms, state.pos, state.rots,
    state.ohw, state.ohh, locked, ov.side, state.leftSplit, state.rightSplit,
    isPower, state.powerSplit)

# --- placement stages -----------------------------------------------------
# Each mutates the index-parallel arrays in `state`; `layout` calls them in
# order. Output must stay byte-identical.

proc prepare(state: var LayoutState) =
  ## Build the component/symbol arrays, composite plan, seed, designator
  ## index and semantic anchors.
  # Bundles first: merged pins change `symbolFor`'s box sizing.
  if state.options.stageEnabled(lsBundles):
    state.bundles = bundlePlan(state.nl)
  # Arrays before `comps` is filled: hidden members are dropped here.
  # `lsArrays` and `lsPartArrays` build into one `ArrayPlan`, and
  # `finalizeArrayPlan` runs once over their union (see `arrays.nim`).
  if state.options.stageEnabled(lsArrays):
    buildSubsheetArrays(state.nl, state.bundles, state.arrays)
  if state.options.stageEnabled(lsPartArrays):
    buildComponentArrays(state.nl, state.bundles, state.arrays)
  if state.options.stageEnabled(lsArrays) or
     state.options.stageEnabled(lsPartArrays):
    finalizeArrayPlan(state.nl, state.bundles, state.arrays)

  for _, c in state.nl.components:
    if c.designator in state.arrays.hidden: continue
    state.comps.add c
  let n = state.comps.len

  # Side overrides; the splits default to permissive so a run with
  # `lsLayoutOverrides` disabled reads every `sideBandAllows` as unconstrained.
  state.overrides = layoutOverridePlan(state.comps)
  state.leftSplit = NegInf
  state.rightSplit = Inf
  state.powerSplit = Inf

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

  # Apply stated `layout.mirror` overrides now, before composite recognition
  # and the seed read slot geometry. `chooseMirrors` only re-applies them.
  state.mirrors = newSeq[bool](n)
  let earlyOv = activeOverrides(state)
  for i in 0 ..< n:
    if i < earlyOv.mirror.len and earlyOv.mirror[i] != mirrorAuto:
      applyMirror(state, i, earlyOv.mirror[i] == mirrorOn)

  # The constrained plan is the sole source of member offsets and composite
  # geometry for the whole pipeline.
  if state.options.policy == lpConstrainedLayered:
    planComposites(state)
  # Power classification right after the composite arena (a composite is one
  # unit). Gated on `lsPowerBand` so a disabled stage can't change
  # `groupsOf`'s `noMerge` behaviour.
  if state.options.policy == lpConstrainedLayered and
     state.options.stageEnabled(lsPowerBand):
    state.power = powerPlan(state.comps, state.composites, activeOverrides(state))

  state.pos = newSeq[Point](n)
  for i in 0 ..< n:
    let t = float(i) * 2.399963229728653
    let r = 70.0 * sqrt(float(i + 1))
    state.pos[i] = Point(x: r * cos(t), y: r * sin(t))

  state.idxOf = initTable[string, int]()
  for i, c in state.comps: state.idxOf[c.designator] = i

  # Layer columns have their own stage.
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
  ## Orientation is co-optimised with placement (attraction is pin-to-pin).
  ## Each iteration re-picks rotations from a snapshot, so visiting order
  ## doesn't matter; the last iterations freeze rotation so centres settle,
  ## and a final pass after separation assigns definitively.
  let n = state.comps.len
  let nl = state.nl
  state.rots = newSeq[float](n)

  let k = 110.0
  let iterations = if state.options.stageEnabled(lsForcePlacement): 250 else: 0
  let temp0 = 2.0 * k

  # Repulsion is pairwise over pool items, not raw components (the `n^2`
  # term dominates runtime), broadcast to every member. Membership is static,
  # so computed once; only `repPos` moves.
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
      # Pin-to-pin, not centre-to-centre, so a parallel pair rests side by
      # side with both pin pairs short.
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

      # A chain's head/tail sits on a hidden member, so the pair loop never
      # sees it and a part wired only to the tail would drift. Pull toward the
      # re-homed pin on the representative (`arrays.extraPins`).
      #
      # Y-only: the semantic column puts the part a layer past the array,
      # while the re-homed pin is at the array's edge; an x pull would drag it
      # back into the array's column and undo the layering.
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
      # Semantic layers are soft anchors; they never override obstacles.
      if state.options.policy == lpConstrainedLayered:
        disp[i].x += (state.semanticAnchors[i].x - state.pos[i].x) * 0.70
        disp[i].y += (state.semanticAnchors[i].y - state.pos[i].y) * 0.08

    # A constrained composite moves as one: apply the mean force as one
    # translation.
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
  ## The inflated body (or a composite member's whole unit footprint) tested
  ## for overlap. Free proc: a closure can't capture the `var LayoutState`.
  let owner = state.composites.ownerOf[i]
  if owner != i:
    compositeFootprint(state.composites, owner, state.syms, state.pos,
                       placementPad)
  else:
    @[Obstacle(x1: state.pos[i].x - state.ohw[i], y1: state.pos[i].y - state.ohh[i],
               x2: state.pos[i].x + state.ohw[i], y2: state.pos[i].y + state.ohh[i])]

proc separate(state: var LayoutState) =
  ## Places each component in deterministic order at the nearest grid cell
  ## (expanding ring from its force-layout position) clear of every placed
  ## body. Guarantees non-overlap.
  let n = state.comps.len
  state.ohw = newSeq[float](n)
  state.ohh = newSeq[float](n)
  for i in 0 ..< n:
    state.ohw[i] = state.syms[i].bodyW / 2.0 + placementPad
    state.ohh[i] = state.syms[i].bodyH / 2.0 + placementPad

  let maxR = max(64, 4 * n)
  # Legalize units, not members: the footprint carries the external pad, so
  # nothing can occupy the composite's internal gap.
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

proc placeOverrideUnit(state: var LayoutState, item: int, isLeft: bool,
                       freeMinX, freeMaxX: float,
                       placedRects: var seq[seq[Obstacle]]) =
  ## Places one overridden pool unit: `separate`'s ring search seeded past the
  ## free region's edge, rejecting any position not wholly on the required
  ## side. Free proc (closure can't capture the `var LayoutState`).
  let members = poolMembers(state, item)
  let offsets = poolOffsets(state, item)
  let origin = poolOrigin(state, members, offsets)
  # Extents relative to origin are translation-invariant.
  let rect0 = separationRects(state, members[0])[0]
  let relLeft = rect0.x1 - origin.x
  let relRight = rect0.x2 - origin.x
  let seedX =
    if isLeft: round((freeMinX - relRight - 2.0 * grid) / grid) * grid
    else: round((freeMaxX - relLeft + 2.0 * grid) / grid) * grid
  let maxR = max(64, 4 * state.comps.len)
  var done = false
  for r in 0 .. maxR:
    for dy in -r .. r:
      for dx in -r .. r:
        if max(abs(dx), abs(dy)) != r: continue
        let cand = Point(x: seedX + float(dx) * grid,
                         y: origin.y + float(dy) * grid)
        if isLeft:
          if cand.x + relRight > freeMinX: continue
        else:
          if cand.x + relLeft < freeMaxX: continue
        for at, m in members: state.pos[m] = cand + offsets[at]
        let here = separationRects(state, members[0])
        var clear = true
        for other in placedRects:
          if anyOverlap(here, other):
            clear = false
            break
        if clear:
          placedRects.add here
          done = true
          break
      if done: break
    if done: break
  doAssert done,
    "schematic placement could not enforce layout.side for " &
    state.comps[members[0]].designator

proc enforceLayoutSides(state: var LayoutState) =
  ## The hard guarantee behind `layout.side`: after separation, move each
  ## overridden unit rigidly into its own column strictly left (or right) of
  ## every other unit, recording `leftSplit`/`rightSplit` so later movers
  ## (`sideBandAllows`) can't pull it back. Uses `separate`'s ring search and
  ## pool helpers.
  state.leftSplit = NegInf
  state.rightSplit = Inf
  if not state.overrides.any: return

  let pool = placementPool(state)
  var leftUnits, rightUnits: seq[int]
  var placedRects: seq[seq[Obstacle]]
  var freeMinX = Inf
  var freeMaxX = NegInf
  for item in pool:
    case poolSide(state.composites, state.overrides, item)
    of sideLeft: leftUnits.add item
    of sideRight: rightUnits.add item
    of sideAuto:
      let rect = separationRects(state, poolMembers(state, item)[0])
      placedRects.add rect
      for r in rect:
        freeMinX = min(freeMinX, r.x1)
        freeMaxX = max(freeMaxX, r.x2)

  if (leftUnits.len == 0 and rightUnits.len == 0) or freeMinX > freeMaxX:
    return

  # Deterministic order: origin x, then first raw member, via a plain tuple
  # sort (no closure over `state`).
  var leftKeyed = newSeq[tuple[x: float, first, item: int]](leftUnits.len)
  for i, item in leftUnits:
    let members = poolMembers(state, item)
    leftKeyed[i] = (poolOrigin(state, members, poolOffsets(state, item)).x,
                    members[0], item)
  leftKeyed.sort()
  var rightKeyed = newSeq[tuple[x: float, first, item: int]](rightUnits.len)
  for i, item in rightUnits:
    let members = poolMembers(state, item)
    rightKeyed[i] = (poolOrigin(state, members, poolOffsets(state, item)).x,
                     members[0], item)
  rightKeyed.sort()

  for k in leftKeyed: placeOverrideUnit(state, k.item, true, freeMinX, freeMaxX, placedRects)
  for k in rightKeyed: placeOverrideUnit(state, k.item, false, freeMinX, freeMaxX, placedRects)

  if leftUnits.len > 0:
    var maxRightEdge = NegInf
    for item in leftUnits:
      maxRightEdge = max(maxRightEdge, separationRects(state, poolMembers(state, item)[0])[0].x2)
    state.leftSplit = (maxRightEdge + freeMinX) / 2.0
  if rightUnits.len > 0:
    var minLeftEdge = Inf
    for item in rightUnits:
      minLeftEdge = min(minLeftEdge, separationRects(state, poolMembers(state, item)[0])[0].x1)
    state.rightSplit = (freeMaxX + minLeftEdge) / 2.0

proc placePowerUnit(state: var LayoutState, item: int, seedX, seedY, freeMaxY: float,
                    placedRects: var seq[seq[Obstacle]]) =
  ## Places one power-band unit: the ring search seeded near
  ## `(seedX, seedY)`, rejecting any position whose top edge is above
  ## `freeMaxY`. Free proc.
  let members = poolMembers(state, item)
  let offsets = poolOffsets(state, item)
  let origin = poolOrigin(state, members, offsets)
  # Extents relative to origin are translation-invariant.
  let rect0 = separationRects(state, members[0])[0]
  let relLeft = rect0.x1 - origin.x
  let relTop = rect0.y1 - origin.y
  # Round to grid: shelf arithmetic over rect boundaries needn't land on it.
  let seedOriginX = round((seedX - relLeft) / grid) * grid
  let seedOriginY = round((seedY - relTop) / grid) * grid
  let maxR = max(64, 4 * state.comps.len)
  var done = false
  for r in 0 .. maxR:
    for dy in -r .. r:
      for dx in -r .. r:
        if max(abs(dx), abs(dy)) != r: continue
        let cand = Point(x: seedOriginX + float(dx) * grid,
                         y: seedOriginY + float(dy) * grid)
        if cand.y + relTop < freeMaxY: continue
        for at, m in members: state.pos[m] = cand + offsets[at]
        let here = separationRects(state, members[0])
        var clear = true
        for other in placedRects:
          if anyOverlap(here, other):
            clear = false
            break
        if clear:
          placedRects.add here
          done = true
          break
      if done: break
    if done: break
  doAssert done,
    "schematic placement could not enforce layout.power for " &
    state.comps[members[0]].designator

proc enforcePowerBand(state: var LayoutState) =
  ## The hard guarantee behind the power band: after separation, shelf-pack
  ## every power-classified unit strictly below every signal unit and record
  ## `powerSplit` so later movers (`powerBandAllows`) can't pull one back.
  ## `enforceLayoutSides` turned 90 degrees.
  state.powerSplit = Inf
  if not state.power.any: return

  let pool = placementPool(state)
  var signalUnits, powerUnits: seq[int]
  var placedRects: seq[seq[Obstacle]]
  var freeMinX = Inf
  var freeMaxX = NegInf
  var freeMaxY = NegInf
  for item in pool:
    if state.power.cls[item] == pcPower:
      powerUnits.add item
    else:
      let rect = separationRects(state, poolMembers(state, item)[0])
      placedRects.add rect
      for r in rect:
        freeMinX = min(freeMinX, r.x1)
        freeMaxX = max(freeMaxX, r.x2)
        freeMaxY = max(freeMaxY, r.y2)
      signalUnits.add item

  if signalUnits.len == 0 or powerUnits.len == 0 or freeMinX > freeMaxX:
    return

  # Deterministic order: origin y, x, then first raw member.
  var keyed = newSeq[tuple[y, x: float, first, item: int]](powerUnits.len)
  for i, item in powerUnits:
    let members = poolMembers(state, item)
    let o = poolOrigin(state, members, poolOffsets(state, item))
    keyed[i] = (o.y, o.x, members[0], item)
  keyed.sort()

  # Left-to-right shelves across the signal region's width, wrapping rows.
  const bandGutter = 2.0 * grid
  var cursorX = freeMinX
  var rowY = freeMaxY + bandGutter
  var rowHeight = 0.0
  for k in keyed:
    let members = poolMembers(state, k.item)
    let rect0 = separationRects(state, members[0])[0]
    let w = rect0.x2 - rect0.x1
    let h = rect0.y2 - rect0.y1
    if cursorX > freeMinX and cursorX + w > freeMaxX:
      cursorX = freeMinX
      rowY += rowHeight + bandGutter
      rowHeight = 0.0
    placePowerUnit(state, k.item, cursorX, rowY, freeMaxY, placedRects)
    cursorX += w + bandGutter
    rowHeight = max(rowHeight, h)

  var minTopEdge = Inf
  for item in powerUnits:
    minTopEdge = min(minTopEdge, separationRects(state, poolMembers(state, item)[0])[0].y1)
  state.powerSplit = (freeMaxY + minTopEdge) / 2.0
