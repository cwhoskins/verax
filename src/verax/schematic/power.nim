## Power/decoupling band classification: which placement units go in the
## separated power section below the signal circuit. Plain data only;
## enforcement is `state.enforcePowerBand`. Included after `./constrained`
## and before `./state`.
##
## Per placement unit (a composite is one): a `layout.power` override wins
## (first-wins across members); otherwise `unitExternallyPurePower` --
## every external net a rail or ground (decoupling, bulk caps, a bead between
## rails, a rail-to-rail divider). Any external signal net (an LDO's enable)
## keeps a unit in the signal circuit.

type
  PowerClass = enum
    pcSignal, pcPower

  PowerPlan = object
    cls: seq[PowerClass]
      ## Parallel to `CompositePlan.items`; meaningful for `topLevel` entries.
    any: bool
      ## True only when the sheet has both classes (otherwise nothing to
      ## separate). Every consumer is gated on it.

proc poolPower(comps: seq[Component], plan: CompositePlan,
              ov: LayoutOverridePlan, item: int): PowerClass =
  ## The power class of a pool unit (arena index): the first member's
  ## non-`powerAuto` override, else `unitExternallyPurePower`.
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
  ## `power.cls` projected onto raw component indices, for files spliced
  ## earlier that can't see these types. `@[]` when `power.any` is false.
  if not power.any: return
  result = newSeq[bool](n)
  for idx in plan.topLevel:
    if power.cls[idx] == pcPower:
      for i in rawMembers(plan, idx): result[i] = true
