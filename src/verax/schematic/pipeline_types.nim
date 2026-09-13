## Public configuration for the deterministic schematic layout pipeline.
##
## The stage identifiers are intentionally stable: callers may disable optional
## passes, while the built-in coordinator retains the canonical ordering.

import std/[os, strutils]

type
  StageId* = enum
    lsPrepare, lsBundles, lsArrays, lsPartArrays, lsSemanticSeed, lsForcePlacement,
    lsConstrainedRefinement, lsCompositeOrient, lsSeparate, lsPack,
    lsPowerBand, lsLayoutOverrides, lsOrient, lsMirror,
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
  # Consumed inside `prepare`, right after `lsArrays` (component arrays read
  # both the bundle plan and the already-built subsheet-array plan, so a net
  # distributed at both ends -- an 8x(R+C) filter bank -- suppresses a
  # consistent subset regardless of which pass claims it last). Off -> the
  # subsheet-only plan `lsArrays` alone produces, no repeated raw component
  # collapses, bit-for-bit.
  StageSpec(id: lsPartArrays, enabled: true),
  StageSpec(id: lsSemanticSeed, enabled: true),
  StageSpec(id: lsForcePlacement, enabled: true),
  StageSpec(id: lsConstrainedRefinement, enabled: true),
  # Picks each orientable composite's rigid quarter-turn before separation
  # legalizes it. A no-op with no orientable composite on the sheet.
  StageSpec(id: lsCompositeOrient, enabled: true),
  StageSpec(id: lsSeparate, enabled: true),
  StageSpec(id: lsPack, enabled: true),
  # A hard post-placement guarantee for the separated power/decoupling band
  # (`schematic/power`): once separation/packing settle every centre,
  # translate each power-classified unit into a shelf-packed band strictly
  # below every signal-classified unit and record the resulting
  # `powerSplit` y boundary, so `lsTerminalRepair` and
  # `lsRecoverRouting`/`lsRoutingAwareRepair` cannot undo it. Runs *before*
  # `lsLayoutOverrides` -- an `layout.side` column is a left/right band
  # inside whichever y-half a part already landed in, not the other way
  # round. Off, or no unit on the sheet is externally pure-power -> the
  # pre-feature scene, bit-for-bit (`PowerPlan.any` stays false and every
  # consumer is inert).
  StageSpec(id: lsPowerBand, enabled: true),
  # A hard post-placement guarantee for `layout.side` overrides
  # (`netlist/layouthints`): after separation/packing settle every centre,
  # translate each overridden unit rigidly into its own dedicated column,
  # strictly left/right of everything else, and record the resulting
  # `leftSplit`/`rightSplit` band boundaries so `lsTerminalRepair` and
  # `lsRecoverRouting`/`lsRoutingAwareRepair` cannot undo it. Off, or no
  # component states a `layout.side` -> the pre-feature scene, bit-for-bit
  # (`LayoutOverridePlan.any` stays false and every consumer is inert).
  StageSpec(id: lsLayoutOverrides, enabled: true),
  StageSpec(id: lsOrient, enabled: true),
  # The definitive mirror assignment (`state.chooseMirrors`), once the
  # centres are final: a stated `layout.mirror` override is honoured
  # absolutely, and every other mirrorable box (a fallback box with no
  # multi-member composite membership) is scored both ways by the same
  # `rotationScore` wirelength metric `lsOrient` uses. Off, or no box on the
  # sheet is ever mirrored either way -> the pre-feature scene, bit-for-bit
  # (`LayoutState.mirrors` stays all-false and every consumer is inert).
  StageSpec(id: lsMirror, enabled: true),
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
