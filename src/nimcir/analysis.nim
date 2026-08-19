## Static netlist-correctness checks (currently: output-net conflicts and
## DC-path reachability for input pins).
##
## A specific simulation backend (`nimcir/spice/ngspice`, pulled in via
## `nimcir/analysis/spice_fallback`) is opt-in per-import, mirroring how
## `nimcir/spice/ngspice` itself is opt-in from `nimcir/spice.nim` -- this
## hub only exports the backend-agnostic pieces: the result type
## (`nimcir/analysis/issue`) and the static checks (`nimcir/analysis/io_check`).
##
## See `nimcir/analysis/io_check` for what these checks can/can't tell from
## netlist topology alone, and `nimcir/analysis/spice_fallback` for the
## opt-in ngspice-backed resolution of anything they can't classify
## statically.
##
## "A section of a netlist" is handled by extracting first with
## `nimcir/spice/extract` (`extractSubcircuit`/`extractInstance`), then
## analyzing the resulting standalone `Netlist` like any other -- no subset
## selection is reinvented here.

import nimcir/analysis/issue
import nimcir/analysis/io_check

export issue, io_check
