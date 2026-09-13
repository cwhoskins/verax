## Layout overrides: per-component authored hints (`netlist/layouthints`)
## that must hold as a **guarantee**, not merely steer the heuristic.
##
## `sideLeft`/`sideRight` and `mirrorOn`/`mirrorOff` exist today; the plan
## shape and the pool-level resolution rule below are meant to be the
## landing point for a future hint (a pin placement, an absolute position)
## -- one more field on `LayoutOverridePlan`, one more line in
## `layoutOverridePlan`. `mirror`'s own enforcement is `state.chooseMirrors`
## honouring a stated override absolutely rather than searching, the same
## "guarantee, not steer" contract `enforceLayoutSides` gives `side`.
##
## Spliced in right after `./composites/tee` and before `./constrained`:
## `layoutOverrideReport` needs `compositePlan`/`symbolFor`/`bundlePlan`, all
## defined by that point, and `constrained.nim`'s topology pass needs
## `LayoutOverridePlan`/`poolSide` defined *before* it. The enforcement pass
## itself (`enforceLayoutSides`) lives in `state.nim`, not here -- it needs
## `LayoutState`'s own `placementPool`/`poolMembers`/`poolOffsets`/
## `poolOrigin`/`separationRects` helpers, none of which exist until `state.nim`
## is spliced in, well after this file.

type
  LayoutOverridePlan = object
    side: seq[LayoutSide]
      ## Parallel to `state.comps` (raw component index). `sideAuto` for
      ## every component nobody annotated.
    any: bool
      ## False when no component states a side -- the zero-value guarantee
      ## every consumer of this plan is gated on, so an un-annotated sheet
      ## takes exactly its pre-feature path.
    mirror: seq[LayoutMirror]
      ## Parallel to `state.comps`. `mirrorAuto` for every component nobody
      ## annotated -- `state.chooseMirrors` is the only consumer.
    anyMirror: bool
      ## False when no component states a mirror -- `chooseMirrors`'s own
      ## zero-value guarantee, independent of `any` since a sheet may state
      ## one hint family and not the other.
    power: seq[LayoutPower]
      ## Parallel to `state.comps`. `powerAuto` for every component nobody
      ## annotated -- `power.poolPower` is the only consumer.
    anyPower: bool
      ## False when no component states a power override -- `poolPower`'s
      ## own zero-value guarantee, independent of `any`/`anyMirror` since a
      ## sheet may state any one hint family and not the others.

proc layoutOverridePlan(comps: seq[Component]): LayoutOverridePlan =
  result.side = newSeq[LayoutSide](comps.len)
  result.mirror = newSeq[LayoutMirror](comps.len)
  result.power = newSeq[LayoutPower](comps.len)
  for i, c in comps:
    let s = layoutSide(c)
    result.side[i] = s
    if s != sideAuto: result.any = true
    let m = layoutMirror(c)
    result.mirror[i] = m
    if m != mirrorAuto: result.anyMirror = true
    let p = layoutPower(c)
    result.power[i] = p
    if p != powerAuto: result.anyPower = true

proc poolSide(plan: CompositePlan, ov: LayoutOverridePlan, item: int): LayoutSide =
  ## The side a placement-pool unit is forced to. `item` is an arena index
  ## (`CompositePlan.items`, what `rawMembers` expects and what
  ## `placementPool`/`CompositePlan.topLevel` entries already are) -- not a
  ## position in `topLevel`. A composite is one placement unit, so its side is
  ## the first non-`sideAuto` member in canonical member order; two members
  ## disagreeing is this same deterministic first-wins, silently -- see
  ## `layoutOverrideReport` for making that visible.
  if not ov.any: return sideAuto
  for i in rawMembers(plan, item):
    if ov.side[i] != sideAuto: return ov.side[i]
  sideAuto

proc reportPoolOverride[T](result: var seq[string], comps: seq[Component],
                          plan: CompositePlan, values: seq[T], auto: T,
                          render: proc (v: T): string {.noSideEffect.}) =
  ## Shared by the `side` and `power` sections of `layoutOverrideReport`:
  ## both hints resolve per placement unit with the identical deterministic
  ## first-wins rule (`poolSide`/`poolPower`), so both are reported the
  ## identical way -- the pool-level winner alone, plus every disagreeing
  ## member named against it.
  for idx in plan.topLevel:
    let members = rawMembers(plan, idx)
    if members.len == 1:
      let i = members[0]
      if values[i] != auto:
        result.add comps[i].designator & "=" & render(values[i])
      continue
    var winner = -1
    var conflict = false
    for i in members:
      if values[i] != auto:
        if winner < 0: winner = i
        elif values[winner] != values[i]: conflict = true
    if winner < 0: continue
    for i in members:
      if values[i] == auto: continue
      if i == winner:
        result.add comps[i].designator & "=" & render(values[i])
      elif conflict:
        result.add comps[i].designator & "=" & render(values[i]) &
          "(conflict: composite uses " & comps[winner].designator & "=" &
          render(values[winner]) & ")"

proc layoutOverrideReport*(nl: Netlist): seq[string] =
  ## Every stated `layout.side`, as `"U1=left"` -- and, for a composite whose
  ## members disagree, `"C5=right(conflict: composite uses R5=left)"` naming
  ## the pool-level winner -- so the first-wins outcome `poolSide` picks
  ## silently at layout time is visible without rendering a scene. Every
  ## stated `layout.mirror` follows, as `"U1=mirror"`/`"U1=no-mirror"` --
  ## unconditional per component, since `chooseMirrors` (unlike `poolSide`)
  ## never resolves a composite's disagreeing members, it simply does not
  ## apply a mirror to any component belonging to a multi-member placement
  ## unit. Every stated `layout.power` follows last, as `"C1=power"`/
  ## `"C1=no-power"` -- resolved the identical pool-level first-wins way as
  ## `side` (`poolPower` mirrors `poolSide` exactly), since a power override
  ## is also a per-*unit* guarantee, not a per-component one. Empty for a
  ## netlist with no `layout.side`/`layout.mirror`/`layout.power` attr at
  ## all.
  ##
  ## Rebuilds the composite arena directly from `nl`, the same
  ## `bundlePlan`/`compositePlan`/`symbolFor` sequence `prepare` runs --
  ## except for repeated-subsheet/component arrays (`arrays.nim`), which this
  ## does not replicate: a conflict hidden inside a collapsed array's
  ## non-representative members is not reported here.
  var comps: seq[Component]
  for _, c in nl.components: comps.add c
  let ov = layoutOverridePlan(comps)
  if not ov.any and not ov.anyMirror and not ov.anyPower: return

  for i, c in comps:
    if ov.mirror[i] != mirrorAuto:
      result.add c.designator & "=" & (if ov.mirror[i] == mirrorOn: "mirror"
                                        else: "no-mirror")

  if not ov.any and not ov.anyPower: return

  var syms = newSeq[SymbolDef](comps.len)
  for i, c in comps: syms[i] = symbolFor(c)
  let bundles = bundlePlan(nl)
  let plan = compositePlan(comps, syms, bundles.bundled)

  proc renderSide(v: LayoutSide): string = $v
  if ov.any:
    reportPoolOverride(result, comps, plan, ov.side, sideAuto, renderSide)

  proc renderPower(v: LayoutPower): string =
    if v == powerOn: "power" else: "no-power"
  if ov.anyPower:
    reportPoolOverride(result, comps, plan, ov.power, powerAuto, renderPower)
