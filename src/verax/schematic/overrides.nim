## Layout overrides: authored hints (`netlist/layouthints`) that must hold
## as **guarantees**. A new hint is one more field on `LayoutOverridePlan`
## and one more line in `layoutOverridePlan`. Mirror enforcement is
## `state.chooseMirrors`; side enforcement is `enforceLayoutSides` (in
## `state.nim`, which has the pool helpers).
##
## Spliced after `./composites/tee` and before `./constrained`, which needs
## `LayoutOverridePlan`/`poolSide`.

type
  LayoutOverridePlan = object
    side: seq[LayoutSide]
      ## Parallel to `state.comps`; `sideAuto` when unannotated.
    any: bool
      ## False when no component states a side; every consumer is gated on
      ## it.
    mirror: seq[LayoutMirror]
      ## Parallel to `state.comps`; `mirrorAuto` when unannotated. Read only
      ## by `state.chooseMirrors`.
    anyMirror: bool
      ## False when no component states a mirror (independent of `any`).
    power: seq[LayoutPower]
      ## Parallel to `state.comps`; `powerAuto` when unannotated. Read only by
      ## `power.poolPower`.
    anyPower: bool
      ## False when no component states a power override.

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
  ## The side a placement-pool unit (arena index) is forced to: the first
  ## non-`sideAuto` member in canonical order. Disagreements resolve
  ## first-wins silently; `layoutOverrideReport` shows them.
  if not ov.any: return sideAuto
  for i in rawMembers(plan, item):
    if ov.side[i] != sideAuto: return ov.side[i]
  sideAuto

proc reportPoolOverride[T](result: var seq[string], comps: seq[Component],
                          plan: CompositePlan, values: seq[T], auto: T,
                          render: proc (v: T): string {.noSideEffect.}) =
  ## Shared by the `side` and `power` sections of `layoutOverrideReport`:
  ## both resolve first-wins per unit, reported as the winner plus each
  ## disagreeing member.
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
  ## Every stated hint, for tests: `"U1=left"` (with
  ## `"C5=right(conflict: composite uses R5=left)"` for disagreeing composite
  ## members), then `"U1=mirror"`/`"U1=no-mirror"` per component (multi-member
  ## units are simply never mirrored), then `"C1=power"`/`"C1=no-power"`
  ## (resolved per unit like `side`). Empty with no hints.
  ##
  ## Rebuilds the composite arena as `prepare` does, but not arrays: a
  ## conflict hidden in a collapsed array's members isn't reported.
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
