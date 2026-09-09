## Public configuration for the deterministic schematic layout pipeline.
##
## The stage identifiers are intentionally stable: callers may disable optional
## passes, while the built-in coordinator retains the canonical ordering.

import std/[os, strutils]

type
  StageId* = enum
    lsPrepare, lsBundles, lsArrays, lsSemanticSeed, lsForcePlacement,
    lsConstrainedRefinement, lsCompositeOrient, lsSeparate, lsPack, lsOrient,
    lsLeafSnap, lsTerminalRepair, lsPrepareRouting, lsRoute, lsRecoverRouting,
    lsRoutingAwareRepair, lsPortRefine, lsLabels, lsBounds

  ## An explicit canonical stage description. `LayoutOptions.stages` filters
  ## this sequence; it cannot reorder it.
  StageSpec* = object
    id*: StageId
    enabled*: bool

  LayoutPolicy* = enum
    ## Historical output remains the default. `lpConstrainedLayered` is an
    ## explicit, deterministic opt-in for ordinary (tens-of-parts) sheets.
    lpHistorical, lpConstrainedLayered

  LayoutOptions* = object
    ## Enabled stages from the built-in, canonical pipeline. A set configures
    ## membership only; it never changes stage order.
    policy*: LayoutPolicy
    stages*: set[StageId]
    feedbackAcceptedBudget*: int
    feedbackAttemptBudget*: int
    feedbackMaxParts*: int

const allLayoutStages* = {lsPrepare..lsBounds}

const canonicalStages*: array[StageId, StageSpec] = [
  StageSpec(id: lsPrepare, enabled: true),
  # Consumed inside `prepare` (precedent: `lsSemanticSeed` is too). Off ->
  # a zero-value `BundlePlan` and the pre-feature scene, bit-for-bit.
  StageSpec(id: lsBundles, enabled: true),
  # Consumed inside `prepare`, like `lsBundles`, and after it (the array plan
  # reads the bundle plan). Off -> a zero-value `ArrayPlan`: no repeated
  # subsheet instance is dropped and the scene is the pre-feature one,
  # bit-for-bit.
  StageSpec(id: lsArrays, enabled: true),
  # These stages are inert under lpHistorical; lpConstrainedLayered gives
  # them deterministic topology/layer and bounded repair meanings.
  StageSpec(id: lsSemanticSeed, enabled: true),
  StageSpec(id: lsForcePlacement, enabled: true),
  StageSpec(id: lsConstrainedRefinement, enabled: true),
  # Also inert under lpHistorical (no CompositePlan is built): picks each
  # orientable composite's rigid quarter-turn before separation legalizes it.
  StageSpec(id: lsCompositeOrient, enabled: true),
  StageSpec(id: lsSeparate, enabled: true),
  StageSpec(id: lsPack, enabled: true),
  StageSpec(id: lsOrient, enabled: true),
  # Leaf snap is historical-only; constrained layered layout always skips it.
  StageSpec(id: lsLeafSnap, enabled: true),
  StageSpec(id: lsTerminalRepair, enabled: true),
  StageSpec(id: lsPrepareRouting, enabled: true),
  StageSpec(id: lsRoute, enabled: true),
  StageSpec(id: lsRecoverRouting, enabled: true),
  StageSpec(id: lsRoutingAwareRepair, enabled: true),
  # Post-route: pull interface ports onto the y their routed wire runs along,
  # accepting a re-route only when it scores strictly better. Off -> ports keep
  # the pre-route relaxation's guess.
  StageSpec(id: lsPortRefine, enabled: true),
  StageSpec(id: lsLabels, enabled: true),
  StageSpec(id: lsBounds, enabled: true)]

proc stageSpecs*(options: LayoutOptions): seq[StageSpec] =
  ## The enabled built-in stages in their fixed, deterministic order.
  for spec in canonicalStages:
    if spec.id in options.stages:
      result.add StageSpec(id: spec.id, enabled: true)

proc defaultLayoutOptions*(): LayoutOptions =
  ## The historical layout policy and budgets.
  LayoutOptions(policy: lpHistorical, stages: allLayoutStages,
                feedbackAcceptedBudget: 4, feedbackAttemptBudget: 30,
                feedbackMaxParts: 24)

proc layoutPolicyName*(policy: LayoutPolicy): string =
  case policy
  of lpHistorical: "historical"
  of lpConstrainedLayered: "constrained-layered"

proc parseLayoutPolicy*(text: string): LayoutPolicy =
  ## Parses the one public spelling used by the CLI and archive environment.
  case text.strip().toLowerAscii()
  of "historical": lpHistorical
  of "constrained-layered": lpConstrainedLayered
  else:
    raise newException(ValueError,
      "unknown schematic layout '" & text &
      "'; expected historical or constrained-layered")

proc archiveLayoutOptions*(): LayoutOptions =
  ## Archive rendering is historical unless explicitly selected through the
  ## environment bridge. Layout calls outside archive writers stay unchanged.
  result = defaultLayoutOptions()
  let configured = getEnv("VERAX_SCHEMATIC_LAYOUT")
  if configured.len > 0:
    result.policy = parseLayoutPolicy(configured)

proc stageEnabled*(options: LayoutOptions, stage: StageId): bool {.inline.} =
  stage in options.stages
