## Public configuration for the deterministic schematic layout pipeline.
## Stage ids are stable; callers may disable optional passes, never
## reorder them.

import std/[os, strutils]

type
  StageId* = enum
    lsPrepare, lsBundles, lsArrays, lsPartArrays, lsSemanticSeed, lsForcePlacement,
    lsConstrainedRefinement, lsCompositeOrient, lsSeparate, lsPack,
    lsPowerBand, lsLayoutOverrides, lsOrient, lsMirror,
    lsTerminalRepair, lsPrepareRouting, lsRoute, lsRecoverRouting,
    lsRoutingAwareRepair, lsPortRefine, lsLabels, lsBounds

  ## A canonical stage; `LayoutOptions.stages` filters but never reorders.
  StageSpec* = object
    id*: StageId
    enabled*: bool

  LayoutPolicy* = enum
    ## The only policy and the default; kept an enum so another can be added.
    lpConstrainedLayered

  LayoutOptions* = object
    ## Enabled stages; membership only, never order.
    policy*: LayoutPolicy
    stages*: set[StageId]
    feedbackAcceptedBudget*: int
    feedbackAttemptBudget*: int
    feedbackMaxParts*: int

const allLayoutStages* = {lsPrepare..lsBounds}

const canonicalStages*: array[StageId, StageSpec] = [
  StageSpec(id: lsPrepare, enabled: true),
  # Consumed in `prepare`. Off -> an empty `BundlePlan`, scene unchanged.
  StageSpec(id: lsBundles, enabled: true),
  # Consumed in `prepare`, after bundles. Off -> no subsheet array collapses.
  StageSpec(id: lsArrays, enabled: true),
  # Consumed in `prepare` after `lsArrays`, into the same plan (so nets
  # distributed at both ends suppress consistently). Off -> no raw-component
  # arrays.
  StageSpec(id: lsPartArrays, enabled: true),
  StageSpec(id: lsSemanticSeed, enabled: true),
  StageSpec(id: lsForcePlacement, enabled: true),
  StageSpec(id: lsConstrainedRefinement, enabled: true),
  # Each orientable composite's quarter-turn, before separation.
  StageSpec(id: lsCompositeOrient, enabled: true),
  StageSpec(id: lsSeparate, enabled: true),
  StageSpec(id: lsPack, enabled: true),
  # Guarantee for the power band: after separation, shelf-pack power units
  # strictly below signal units and record `powerSplit` so later movers
  # can't undo it. Before `lsLayoutOverrides` (side columns live within each
  # half). Off or no power units -> scene unchanged.
  StageSpec(id: lsPowerBand, enabled: true),
  # Guarantee for `layout.side`: after separation, move each overridden unit
  # into its own column and record `leftSplit`/`rightSplit` so later movers
  # can't undo it. Off or no side hints -> scene unchanged.
  StageSpec(id: lsLayoutOverrides, enabled: true),
  StageSpec(id: lsOrient, enabled: true),
  # Definitive mirroring (`state.chooseMirrors`): stated overrides absolute,
  # other mirrorable boxes scored by `rotationScore`. Off -> nothing
  # mirrored.
  StageSpec(id: lsMirror, enabled: true),
  StageSpec(id: lsTerminalRepair, enabled: true),
  StageSpec(id: lsPrepareRouting, enabled: true),
  StageSpec(id: lsRoute, enabled: true),
  StageSpec(id: lsRecoverRouting, enabled: true),
  StageSpec(id: lsRoutingAwareRepair, enabled: true),
  # Pull ports onto the y their wire runs along, when a re-route scores
  # strictly better. Off -> the pre-route relaxation's placement.
  StageSpec(id: lsPortRefine, enabled: true),
  StageSpec(id: lsLabels, enabled: true),
  StageSpec(id: lsBounds, enabled: true)]

proc stageSpecs*(options: LayoutOptions): seq[StageSpec] =
  ## The enabled built-in stages in their fixed, deterministic order.
  for spec in canonicalStages:
    if spec.id in options.stages:
      result.add StageSpec(id: spec.id, enabled: true)

proc defaultLayoutOptions*(): LayoutOptions =
  ## The default policy, stage set and budgets.
  LayoutOptions(policy: lpConstrainedLayered, stages: allLayoutStages,
                feedbackAcceptedBudget: 4, feedbackAttemptBudget: 30,
                feedbackMaxParts: 24)

proc layoutPolicyName*(policy: LayoutPolicy): string =
  case policy
  of lpConstrainedLayered: "constrained-layered"

proc parseLayoutPolicy*(text: string): LayoutPolicy =
  ## Parses the one public spelling used by the CLI and archive environment.
  case text.strip().toLowerAscii()
  of "constrained-layered": lpConstrainedLayered
  else:
    raise newException(ValueError,
      "unknown schematic layout '" & text & "'; expected constrained-layered")

proc archiveLayoutOptions*(): LayoutOptions =
  ## Archive rendering uses the default options unless the environment
  ## names a policy.
  result = defaultLayoutOptions()
  let configured = getEnv("VERAX_SCHEMATIC_LAYOUT")
  if configured.len > 0:
    result.policy = parseLayoutPolicy(configured)

proc stageEnabled*(options: LayoutOptions, stage: StageId): bool {.inline.} =
  stage in options.stages
