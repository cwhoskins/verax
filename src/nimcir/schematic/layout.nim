## Compatibility facade and pipeline coordinator for schematic layout.
##
## The implementation is split into cohesive internal include files so its
## private geometry and routing types remain internal to this module while the
## established public API remains unchanged.

import std/[algorithm, math, sets, strutils, tables, sequtils, heapqueue]
import ../netlist/types
import ../netlist/kinds
import ../netlist/annotations
import ./scene
import ./pipeline

include ./geometry
include ./symbols
include ./router
include ./labels
include ./placement
include ./composites/composite
include ./composites/passive
include ./constrained
include ./state
include ./routing
include ./finish
include ./refinement

proc layout*(nl: Netlist, options: LayoutOptions): Schematic

proc layout*(nl: Netlist): Schematic =
  ## Places and routes `nl` with the historical pipeline configuration.
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
  # legalization pass. It is policy-gated so lpHistorical remains unchanged.
  if options.policy == lpConstrainedLayered and
     options.stageEnabled(lsConstrainedRefinement):
    constrainedRefine(ctx)
    restoreCompositeOffsets(ctx)

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

  # --- orientation: the definitive assignment once the centres are final ---
  # Separation and packing have moved parts since the loop froze rotation, so
  # re-pick every one from the settled centres. One pass, snapshot-read and
  # fresh-write like the loop, and with no hysteresis -- this is the answer,
  # not an increment toward it.
  if options.stageEnabled(lsOrient):
    ctx.rots =
      if options.policy == lpConstrainedLayered:
        constrainedRecomputeRotations(ctx)
      else:
        recomputeRotations(ctx)

  # --- leaf cleanup: a one-signal-net part snapped beside its net-mate ----
  # Historical layout pulls each leaf up against the pin it connects to and
  # turns it to face there, so the router draws a short straight stub rather
  # than a long detour. Constrained layered layout always skips this heuristic.
  if options.policy != lpConstrainedLayered and options.stageEnabled(lsLeafSnap):
    leafSnap(ctx)

  # Reserve complete, unshortened rail/ground glyphs before routing, and
  # repair exact distinct-net terminal-pin coincidences as a hard condition.
  # This bounded pass moves the smallest implicated symbols first; routing
  # still owns the defensive shortening/blocking path for irreducible crowding.
  if options.stageEnabled(lsTerminalRepair):
    repairTerminalClearance(ctx)
  # Terminal repair and leaf cleanup are allowed to move a member; restore the
  # parallel placement unit before routing/recovery sees the final geometry.
  if options.policy == lpConstrainedLayered:
    restoreCompositeOffsets(ctx)
    ctx.rots = constrainedRecomputeRotations(ctx)

  # `recoverRouting` is the bounded routing-aware repair: candidates are
  # accepted only when they route strictly further. Its dedicated stage is an
  # opt-in alias for constrained policy callers; historical stage semantics
  # remain exactly as before.
  let useRecovery = options.stageEnabled(lsRecoverRouting) or
    (options.policy == lpConstrainedLayered and
     options.stageEnabled(lsRoutingAwareRepair))
  ctx.routing =
    if useRecovery:
      recoverRouting(ctx)
    else:
      # A disabled recovery policy still produces the ordinary typed fallback
      # scene for an unrouteable net rather than raising.
      routeScene(ctx, withFallbacks = true)

  result.parts = ctx.routing.parts
  result.ports = ctx.routing.ports
  result.wires = ctx.routing.wires
  result.junctions = ctx.routing.junctions
  result.fallbacks = ctx.routing.fallbacks
  finishLabels(ctx, result)
  finishBounds(result, ctx.options.stageEnabled(lsBounds))
  refineRouting(ctx)

include ./diagnostics
