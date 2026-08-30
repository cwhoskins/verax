## Shared pipeline policy checks.
##
## Algorithm implementations remain private to `layout.nim`; this module owns
## the public option semantics so later internal stages can become normal
## modules without changing the configuration API.

import ./pipeline_types

export pipeline_types

proc validateLayoutOptions*(options: LayoutOptions) =
  ## Reject configurations which cannot produce a completed scene. Disabled
  ## placement passes leave the state produced by preceding passes unchanged.
  if options.feedbackAcceptedBudget < 0 or options.feedbackAttemptBudget < 0 or
     options.feedbackMaxParts < 0:
    raise newException(ValueError, "schematic layout budgets must be non-negative")
  if lsRoute notin options.stages:
    raise newException(ValueError,
      "schematic layout requires lsRoute to materialize a completed scene")
  if lsPrepareRouting notin options.stages:
    raise newException(ValueError,
      "schematic layout requires lsPrepareRouting before lsRoute")
  if lsLabels in options.stages and lsRoute notin options.stages:
    raise newException(ValueError,
      "schematic layout labels require a completed routed scene")
