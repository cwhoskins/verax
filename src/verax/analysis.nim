## Netlist-correctness checks and circuit measurements, with two result
## types:
##
## * **`Issue`** -- something is wrong, here and here (the static checks in
##   `io_check`).
## * **`AnalysisReport`** -- a measured curve, its extracted scalars, the
##   issues they imply, and the assumptions behind them.
##
## This hub exports only what needs no toolchain (`issue`, `report`,
## `io_check`, `measure`). Simulator-backed analyses are opt-in, one file
## each under `analysis/analyses/`; `analysis/evaluators/` adapts them for
## the `contract` registry.

import verax/analysis/issue
import verax/analysis/io_check
import verax/analysis/measure
import verax/analysis/report

export issue, io_check, measure, report
