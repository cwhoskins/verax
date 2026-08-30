## Public configuration for the deterministic schematic layout pipeline.
##
## The stage identifiers are intentionally stable: callers may disable optional
## passes, while the built-in coordinator retains the canonical ordering.

type
  StageId* = enum
    lsPrepare, lsForcePlacement, lsSeparate, lsPack, lsOrient, lsLeafSnap,
    lsTerminalRepair, lsPrepareRouting, lsRoute, lsRecoverRouting, lsLabels,
    lsBounds

  ## An explicit canonical stage description. `LayoutOptions.stages` filters
  ## this sequence; it cannot reorder it.
  StageSpec* = object
    id*: StageId
    enabled*: bool

  LayoutOptions* = object
    ## Enabled stages from the built-in, canonical pipeline. A set configures
    ## membership only; it never changes stage order.
    stages*: set[StageId]
    feedbackAcceptedBudget*: int
    feedbackAttemptBudget*: int
    feedbackMaxParts*: int

const allLayoutStages* = {lsPrepare..lsBounds}

const canonicalStages*: array[StageId, StageSpec] = [
  StageSpec(id: lsPrepare, enabled: true),
  StageSpec(id: lsForcePlacement, enabled: true),
  StageSpec(id: lsSeparate, enabled: true),
  StageSpec(id: lsPack, enabled: true),
  StageSpec(id: lsOrient, enabled: true),
  StageSpec(id: lsLeafSnap, enabled: true),
  StageSpec(id: lsTerminalRepair, enabled: true),
  StageSpec(id: lsPrepareRouting, enabled: true),
  StageSpec(id: lsRoute, enabled: true),
  StageSpec(id: lsRecoverRouting, enabled: true),
  StageSpec(id: lsLabels, enabled: true),
  StageSpec(id: lsBounds, enabled: true)]

proc stageSpecs*(options: LayoutOptions): seq[StageSpec] =
  ## The enabled built-in stages in their fixed, deterministic order.
  for spec in canonicalStages:
    if spec.id in options.stages:
      result.add StageSpec(id: spec.id, enabled: true)

proc defaultLayoutOptions*(): LayoutOptions =
  ## The historical layout policy and budgets.
  LayoutOptions(stages: allLayoutStages, feedbackAcceptedBudget: 4,
                feedbackAttemptBudget: 65, feedbackMaxParts: 24)

proc stageEnabled*(options: LayoutOptions, stage: StageId): bool {.inline.} =
  stage in options.stages
