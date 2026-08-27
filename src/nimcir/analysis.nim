## Netlist-correctness checks and circuit measurements.
##
## Two kinds of answer live here, with two result types:
##
## * **`Issue`** (`nimcir/analysis/issue`) -- something is wrong, here is what
##   and where. This is what the static checks in `nimcir/analysis/io_check`
##   return.
## * **`AnalysisReport`** (`nimcir/analysis/report`) -- a measured curve plus
##   the scalars extracted from it, the issues those scalars imply, and the
##   assumptions the measurement rested on. A frequency response is not a
##   yes/no question, so it does not fit in an `Issue`.
##
## Anything needing a simulator is **opt-in per-import**, mirroring how
## `nimcir/spice/ngspice` is opt-in from `nimcir/spice.nim`. This hub exports
## only what runs with no external toolchain: the two result types, the static
## checks (`io_check`), and the pure curve math (`measure`). The ngspice-backed
## analyses live under `nimcir/analysis/analyses/` -- one file each -- and are
## imported directly: `nimcir/analysis/analyses/spice_fallback`,
## `nimcir/analysis/analyses/pdn`, `nimcir/analysis/analyses/startup`,
## `nimcir/analysis/analyses/opamp`, and so on. `nimcir/analysis/evaluators/`
## wraps them for the `contract` assertion registry.
##
## | module | question | analysis |
## | --- | --- | --- |
## | `analyses/spice_fallback` | is this ambiguous DC path real? | `.op` |
## | `analyses/pdn` | is my decoupling adequate? | `.ac` |
## | `analyses/startup` | does this rail come up cleanly? | `.tran` |
## | `analyses/opamp` | gain, bandwidth and stability margin | `.ac` |
##
## Each of those isolates a fragment of the design with
## `nimcir/spice/isolate` and simulates that, never the whole board and never
## the design netlist itself. See `nimcir/analysis/io_check` for what the
## static checks can and cannot tell from topology alone.

import nimcir/analysis/issue
import nimcir/analysis/io_check
import nimcir/analysis/measure
import nimcir/analysis/report

export issue, io_check, measure, report
