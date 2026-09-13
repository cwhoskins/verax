## Compatibility facade and pipeline coordinator for schematic layout.
##
## The implementation is split into cohesive internal include files so its
## private geometry and routing types remain internal to this module while the
## established public API remains unchanged.

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
  ## Places and routes `nl` into a renderer-neutral scene. Read-only with
  ## respect to the netlist; deterministic given the same netlist object.
  ## `options.stages` is filtered from the fixed canonical stage order.
  validateLayoutOptions(options)
  result.title = nl.name

  var ctx = LayoutState(nl: nl, options: options)

  # --- placement: golden-angle seed, then Fruchterman-Reingold ------------
  prepare(ctx)
  forcePlace(ctx)

  # Reassert deterministic left-to-right layers before the existing
  # legalization pass.
  if options.policy == lpConstrainedLayered and
     options.stageEnabled(lsConstrainedRefinement):
    constrainedRefine(ctx)
    restoreCompositeOffsets(ctx)

  # Pick each orientable composite's rigid quarter-turn while there is still
  # room to move it, before separation legalizes whatever frame it lands in.
  # A no-op with no orientable composite on the sheet.
  if options.policy == lpConstrainedLayered and
     options.stageEnabled(lsCompositeOrient):
    chooseCompositeOrientation(ctx)

  # Snap centres to the grid, normalising -0.0 away so hashing stays exact.
  snapToGrid(ctx)

  # --- separation: inflated bodies never overlap, channels remain ---------
  separate(ctx)

  # --- packing: blocks that share no signal net are pulled back together --
  # The force layout's only long-range counter-force is a weak gravity, so
  # two disconnected sub-circuits drift as far apart as the repulsion carries
  # them. Group the parts by signal-net connectivity and shelf-pack the group
  # bounding boxes with a fixed gutter. A rigid grid-snapped translation per
  # group, so separation and the grid snap both survive it.
  if options.stageEnabled(lsPack):
    let group = groupsOf(ctx)
    packGroups(ctx, group)

  if options.policy == lpConstrainedLayered:
    restoreCompositeOffsets(ctx)

  # The hard guarantee behind the separated power/decoupling band: translate
  # every power-classified unit into a shelf-packed band strictly below every
  # signal-classified unit now that separation and packing have settled every
  # centre, and record the resulting `powerSplit` band boundary so
  # `repairTerminalClearance`/`recoverRouting` below cannot undo it. A no-op
  # scene, bit-for-bit, when no unit is power-classified or the stage is off.
  # Runs before `lsLayoutOverrides`: a `layout.side` column is a left/right
  # band inside whichever y-half a part already landed in.
  if options.stageEnabled(lsPowerBand):
    enforcePowerBand(ctx)

  # The hard guarantee behind a `layout.side` override: translate each
  # overridden unit into its own dedicated column now that separation and
  # packing have settled every centre, and record the resulting band so
  # `repairTerminalClearance`/`recoverRouting` below cannot undo it. A no-op
  # scene, bit-for-bit, when nothing states a side or the stage is off.
  if options.stageEnabled(lsLayoutOverrides):
    enforceLayoutSides(ctx)

  # --- orientation: the definitive assignment once the centres are final ---
  # Separation and packing have moved parts since the loop froze rotation, so
  # re-pick every one from the settled centres. One pass, snapshot-read and
  # fresh-write like the loop, and with no hysteresis -- this is the answer,
  # not an increment toward it.
  if options.stageEnabled(lsOrient) and options.policy == lpConstrainedLayered:
    constrainedRecomputeRotations(ctx)

  # The definitive mirror assignment, once the centres (and, for a
  # constrained-layered sheet, the rotations) are final: a stated
  # `layout.mirror` override is honoured absolutely, and every other
  # mirrorable box is scored both ways by the same wirelength metric
  # orientation uses. A no-op scene, bit-for-bit, when nothing states a
  # mirror and no box ever scores better mirrored.
  if options.stageEnabled(lsMirror):
    chooseMirrors(ctx)

  # Reserve complete, unshortened rail/ground glyphs before routing, and
  # repair exact distinct-net terminal-pin coincidences as a hard condition.
  # This bounded pass moves the smallest implicated symbols first; routing
  # still owns the defensive shortening/blocking path for irreducible crowding.
  if options.stageEnabled(lsTerminalRepair):
    repairTerminalClearance(ctx)
  # Terminal repair is allowed to move a composite member; restore the
  # parallel placement unit before routing/recovery sees the final geometry.
  if options.policy == lpConstrainedLayered:
    restoreCompositeOffsets(ctx)
    constrainedRecomputeRotations(ctx)

  # `recoverRouting` is the bounded routing-aware repair: candidates are
  # accepted only when they route strictly further. `lsRoutingAwareRepair` is
  # its dedicated stage name for constrained policy callers; `lsRecoverRouting`
  # is the older stage name and either enables the same pass.
  let useRecovery = options.stageEnabled(lsRecoverRouting) or
    (options.policy == lpConstrainedLayered and
     options.stageEnabled(lsRoutingAwareRepair))
  ctx.routing =
    if useRecovery:
      recoverRouting(ctx)
    else:
      # A disabled recovery stage still produces the ordinary typed fallback
      # scene for an unrouteable net rather than raising.
      routeScene(ctx, withFallbacks = true)

  # Post-route interface-port refinement: pull a ported net's ports onto the y
  # its routed wire already runs along when a full re-route scores strictly
  # better. Must precede the scene copy-out so `finishLabels`/`finishBounds`
  # see the final port geometry.
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
