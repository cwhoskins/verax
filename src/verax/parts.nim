## Choosing a physical part for an electrical requirement: given 22.5 nF,
## *which capacitor*. Depends on `units` and `netlist`; nothing depends on
## it. Start with `parts/types.nim`.
##
##   * `types` -- requests, `Choice`, `PartPolicy`.
##   * `policy` -- `defaultPolicy()` and what it may guess.
##   * `annotate` -- `applyChoice`, writing a `Choice` as annotations.
##   * `series` -- preferred-value ladders (E12/E24/E96) and the
##     `PreferredSeries` hook.

import ./parts/types
import ./parts/policy
import ./parts/annotate
import ./parts/series

export types, policy, annotate, series
