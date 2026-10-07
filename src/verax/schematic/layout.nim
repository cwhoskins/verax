## Public facade and pipeline coordinator for schematic layout. The
## implementation is split into include files so private geometry and
## routing types stay internal.

import std/[algorithm, math, sets, strutils, tables, sequtils, heapqueue]
import ../netlist/types
import ../netlist/kinds
import ../netlist/annotations
import ../netlist/packages
import ../netlist/layouthints
import ../netlist/traversal
import ./scene
import ./pipeline

include ./geometry
include ./symbols
include ./router
include ./labels
include ./placement
include ./bundles
include ./arrays
include ./composites/composite
include ./composites/passive
include ./composites/pi
include ./composites/tee
include ./overrides
include ./constrained
include ./power
include ./state
include ./routing
include ./finish
include ./refinement

proc layout*(nl: Netlist, options: LayoutOptions): Schematic

proc layout*(nl: Netlist): Schematic =
  ## Places and routes `nl` with the default pipeline configuration.
  layout(nl, defaultLayoutOptions())

proc layout*(nl: Netlist, options: LayoutOptions): Schematic =
  ## Places and routes `nl` into a renderer-neutral scene. Read-only and
  ## deterministic. `options.stages` filters the fixed stage order.
  validateLayoutOptions(options)
  result.title = nl.name

  var ctx = LayoutState(nl: nl, options: options)

  # --- placement: golden-angle seed, then Fruchterman-Reingold ------------
  prepare(ctx)
  forcePlace(ctx)

  # Reassert left-to-right layers before legalization.
  if options.policy == lpConstrainedLayered and
     options.stageEnabled(lsConstrainedRefinement):
    constrainedRefine(ctx)
    restoreCompositeOffsets(ctx)

  # Composite quarter-turns, while there's still room to move, before
  # separation legalizes them.
  if options.policy == lpConstrainedLayered and
     options.stageEnabled(lsCompositeOrient):
    chooseCompositeOrientation(ctx)

  # Snap centres to the grid, normalising -0.0 away so hashing stays exact.
  snapToGrid(ctx)

  # --- separation: inflated bodies never overlap, channels remain ---------
  separate(ctx)

  # --- packing: blocks that share no signal net are pulled back together --
  # Only weak gravity opposes repulsion, so disconnected sub-circuits drift
  # apart. Shelf-pack signal-connected groups with rigid grid-snapped moves.
  if options.stageEnabled(lsPack):
    let group = groupsOf(ctx)
    packGroups(ctx, group)

  if options.policy == lpConstrainedLayered:
    restoreCompositeOffsets(ctx)

  # Power band guarantee (see `enforcePowerBand`), before side overrides:
  # side columns live within each y-half.
  if options.stageEnabled(lsPowerBand):
    enforcePowerBand(ctx)

  # Side-override guarantee (see `enforceLayoutSides`).
  if options.stageEnabled(lsLayoutOverrides):
    enforceLayoutSides(ctx)

  # --- orientation: the definitive assignment once the centres are final ---
  # Re-pick every rotation from the settled centres; one snapshot pass, no
  # hysteresis.
  if options.stageEnabled(lsOrient) and options.policy == lpConstrainedLayered:
    constrainedRecomputeRotations(ctx)

  # Definitive mirroring (see `chooseMirrors`).
  if options.stageEnabled(lsMirror):
    chooseMirrors(ctx)

  # Reserve full rail/ground glyphs and repair distinct-net pin
  # coincidences (hard), moving the smallest symbols first. Routing still
  # shortens/blocks for irreducible crowding.
  if options.stageEnabled(lsTerminalRepair):
    repairTerminalClearance(ctx)
  # Terminal repair may move a composite member; re-rigidify before routing.
  if options.policy == lpConstrainedLayered:
    restoreCompositeOffsets(ctx)
    constrainedRecomputeRotations(ctx)

  # Bounded routing-aware repair: moves accepted only if they route further.
  # `lsRoutingAwareRepair` and the older `lsRecoverRouting` both enable it.
  let useRecovery = options.stageEnabled(lsRecoverRouting) or
    (options.policy == lpConstrainedLayered and
     options.stageEnabled(lsRoutingAwareRepair))
  ctx.routing =
    if useRecovery:
      recoverRouting(ctx)
    else:
      # With recovery disabled, unroutable nets still get typed fallbacks.
      routeScene(ctx, withFallbacks = true)

  # Port refinement, before the scene copy-out so labels and bounds see the
  # final port geometry.
  if options.stageEnabled(lsPortRefine):
    refinePortPlacement(ctx)

  result.parts = ctx.routing.parts
  result.ports = ctx.routing.ports
  result.wires = ctx.routing.wires
  result.junctions = ctx.routing.junctions
  result.fallbacks = ctx.routing.fallbacks
  finishLabels(ctx, result)
  finishBounds(result, ctx.options.stageEnabled(lsBounds))
  finishDividers(ctx, result)

include ./diagnostics
