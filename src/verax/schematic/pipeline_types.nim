## Public configuration for the deterministic schematic layout pipeline.
##
## The stage identifiers are intentionally stable: callers may disable optional
## passes, while the built-in coordinator retains the canonical ordering.

import std/[os, strutils]

type
  StageId* = enum
    lsPrepare, lsBundles, lsArrays, lsSemanticSeed, lsForcePlacement,
    lsConstrainedRefinement, lsCompositeOrient, lsSeparate, lsPack, lsOrient,
    lsTerminalRepair, lsPrepareRouting, lsRoute, lsRecoverRouting,
    lsRoutingAwareRepair, lsPortRefine, lsLabels, lsBounds

  ## An explicit canonical stage description. `LayoutOptions.stages` filters
  ## this sequence; it cannot reorder it.
  StageSpec* = object
    id*: StageId
    enabled*: bool

  LayoutPolicy* = enum
    ## `lpConstrainedLayered` is the only policy and the default. The type
    ## stays an enum, rather than being deleted along with `lpHistorical`,
    ## so a future second policy has somewhere to land without every
    ## `options.policy == lpConstrainedLayered` call site changing shape.
    lpConstrainedLayered

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
  StageSpec(id: lsSemanticSeed, enabled: true),
  StageSpec(id: lsForcePlacement, enabled: true),
  StageSpec(id: lsConstrainedRefinement, enabled: true),
  # Picks each orientable composite's rigid quarter-turn before separation
  # legalizes it. A no-op with no orientable composite on the sheet.
  StageSpec(id: lsCompositeOrient, enabled: true),
  StageSpec(id: lsSeparate, enabled: true),
  StageSpec(id: lsPack, enabled: true),
  StageSpec(id: lsOrient, enabled: true),
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
  ## `lpConstrainedLayered`, the default and only policy, with the default
  ## stage set and budgets.
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
  ## Archive rendering uses the same default policy as ordinary `layout`
  ## calls unless the environment bridge names one explicitly -- a no-op
  ## today (there is only one policy), kept so a future second policy needs
  ## no new selection mechanism.
  result = defaultLayoutOptions()
  let configured = getEnv("VERAX_SCHEMATIC_LAYOUT")
  if configured.len > 0:
    result.policy = parseLayoutPolicy(configured)

proc stageEnabled*(options: LayoutOptions, stage: StageId): bool {.inline.} =
  stage in options.stages
