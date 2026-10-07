## Shared pipeline policy checks: the public option semantics, kept apart
## from `layout.nim`'s private implementation.

import ./pipeline_types

export pipeline_types

proc validateLayoutOptions*(options: LayoutOptions) =
  ## Reject configurations that can't produce a scene. Disabled passes leave
  ## the preceding state unchanged.
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
