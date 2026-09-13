## Layout overrides: per-component authored hints (`netlist/layouthints`)
## that must hold as a **guarantee**, not merely steer the heuristic.
##
## Only `sideLeft`/`sideRight` exist today; the plan shape and the pool-level
## resolution rule below are meant to be the landing point for a future hint
## (rotation, a pin placement, an absolute position) -- one more field on
## `LayoutOverridePlan`, one more line in `layoutOverridePlan`, and its own
## enforcement step alongside `enforceLayoutSides` (`state.nim`).
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

proc layoutOverridePlan(comps: seq[Component]): LayoutOverridePlan =
  result.side = newSeq[LayoutSide](comps.len)
  for i, c in comps:
    let s = layoutSide(c)
    result.side[i] = s
    if s != sideAuto: result.any = true

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

proc layoutOverrideReport*(nl: Netlist): seq[string] =
  ## Every stated `layout.side`, as `"U1=left"` -- and, for a composite whose
  ## members disagree, `"C5=right(conflict: composite uses R5=left)"` naming
  ## the pool-level winner -- so the first-wins outcome `poolSide` picks
  ## silently at layout time is visible without rendering a scene. Empty for
  ## a netlist with no `layout.side` attr at all.
  ##
  ## Rebuilds the composite arena directly from `nl`, the same
  ## `bundlePlan`/`compositePlan`/`symbolFor` sequence `prepare` runs --
  ## except for repeated-subsheet/component arrays (`arrays.nim`), which this
  ## does not replicate: a conflict hidden inside a collapsed array's
  ## non-representative members is not reported here.
  var comps: seq[Component]
  for _, c in nl.components: comps.add c
  let ov = layoutOverridePlan(comps)
  if not ov.any: return

  var syms = newSeq[SymbolDef](comps.len)
  for i, c in comps: syms[i] = symbolFor(c)
  let bundles = bundlePlan(nl)
  let plan = compositePlan(comps, syms, bundles.bundled)

  for idx in plan.topLevel:
    let members = rawMembers(plan, idx)
    if members.len == 1:
      let i = members[0]
      if ov.side[i] != sideAuto:
        result.add comps[i].designator & "=" & $ov.side[i]
      continue
    var winner = -1
    var conflict = false
    for i in members:
      if ov.side[i] != sideAuto:
        if winner < 0: winner = i
        elif ov.side[winner] != ov.side[i]: conflict = true
    if winner < 0: continue
    for i in members:
      if ov.side[i] == sideAuto: continue
      if i == winner:
        result.add comps[i].designator & "=" & $ov.side[i]
      elif conflict:
        result.add comps[i].designator & "=" & $ov.side[i] &
          "(conflict: composite uses " & comps[winner].designator & "=" &
          $ov.side[winner] & ")"
