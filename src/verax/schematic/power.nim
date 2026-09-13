## Power/decoupling band classification: which placement units belong in the
## separated power section `enforcePowerBand` (`state.nim`) carves out below
## the signal circuit, and why.
##
## `include`d right after `./constrained` (needs `unitExternallyPurePower`,
## `CompositePlan`/`rawMembers`) and before `./state` (the actual band
## enforcement is a `LayoutState`-mutating pass, so it lives in `state.nim`
## exactly where `placeOverrideUnit`/`enforceLayoutSides` do -- this file
## holds only the plain-data classification, the `overrides.nim`/
## `layoutOverridePlan` split). Deliberately plain data throughout: nothing
## here takes a `LayoutState`, so nothing here has to sit after `state.nim`.
##
## Classification runs at the **placement-unit** level (a composite is one
## unit), exactly `poolSide`'s shape: an authored `layout.power` override
## wins first-wins across a unit's members, and failing that,
## `unitExternallyPurePower` (`constrained.nim`) classifies the whole unit as
## power when every net linking it to the rest of the sheet is a rail or
## ground -- a decoupling bank, a bulk cap, a ferrite bead or inductor
## between two rails, an LC/RC filter between planes, a rail-to-rail
## divider. A unit with any external signal net stays in the signal circuit
## unless overridden -- an LDO with an enable or feedback pin is exactly this
## case.

type
  PowerClass = enum
    pcSignal, pcPower

  PowerPlan = object
    cls: seq[PowerClass]
      ## Parallel to `CompositePlan.items` (arena index) -- meaningful only
      ## for the indices `CompositePlan.topLevel` lists, which is exactly
      ## `powerPlan` iterates and `enforcePowerBand` reads.
    any: bool
      ## True only when the sheet has *both* a signal-classified and a
      ## power-classified unit -- an all-power or all-signal sheet has
      ## nothing to separate, so this is the zero-value guarantee every
      ## consumer below (`enforcePowerBand`, `groupsOf`'s `noMerge`,
      ## `repairTerminalClearance`/`recoverRouting`'s band check) is gated
      ## on: false ⇒ byte-identical pre-feature output.

proc poolPower(comps: seq[Component], plan: CompositePlan,
              ov: LayoutOverridePlan, item: int): PowerClass =
  ## The power class a placement-pool unit is forced to. `item` is an arena
  ## index (`CompositePlan.items`, what `rawMembers` expects and what
  ## `placementPool`/`CompositePlan.topLevel` entries already are) -- not a
  ## position in `topLevel`, the same convention `poolSide` documents. A
  ## composite is one placement unit, so its class is the first non-
  ## `powerAuto` member's override in canonical member order (deterministic
  ## first-wins, silently -- see `layoutOverrideReport` for making that
  ## visible); failing that, `unitExternallyPurePower` classifies the whole
  ## unit from its external nets.
  let members = rawMembers(plan, item)
  if ov.anyPower:
    for i in members:
      if ov.power[i] != powerAuto:
        return (if ov.power[i] == powerOn: pcPower else: pcSignal)
  if unitExternallyPurePower(comps, members): pcPower else: pcSignal

proc powerPlan(comps: seq[Component], plan: CompositePlan,
              ov: LayoutOverridePlan): PowerPlan =
  ## One classification per `plan.topLevel` entry. `any` is set only when
  ## the sheet has at least one unit of each class -- see `PowerPlan.any`.
  result.cls = newSeq[PowerClass](plan.items.len)
  var anySignal = false
  var anyPower = false
  for idx in plan.topLevel:
    let cls = poolPower(comps, plan, ov, idx)
    result.cls[idx] = cls
    if cls == pcPower: anyPower = true
    else: anySignal = true
  result.any = anySignal and anyPower

proc rawPowerFlags(power: PowerPlan, plan: CompositePlan, n: int): seq[bool] =
  ## `power.cls`, projected onto raw component indices -- the shape
  ## `groupsOf`'s `noMerge` and `repairTerminalClearance`/`recoverRouting`'s
  ## `isPower` band parameters need, since those already-spliced-earlier
  ## files cannot see `PowerPlan`/`CompositePlan` types defined or completed
  ## this late (the same plain-data-escape-hatch reason `arrays.nim`'s
  ## `extraMembers` gives for `groupsOf`). `@[]` when `power.any` is false --
  ## the zero-value guarantee every caller's own default-empty parameter is
  ## gated on.
  if not power.any: return
  result = newSeq[bool](n)
  for idx in plan.topLevel:
    if power.cls[idx] == pcPower:
      for i in rawMembers(plan, idx): result[i] = true
