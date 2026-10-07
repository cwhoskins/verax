## SI: simulating a net as a signal-integrity problem on a native transient
## engine -- an IBIS driver, its package, the board interconnect, the
## receivers. Above `ibis/` and `pcb/`, below `analysis/`; no ngspice.
## `si/engine/*` is the solver; import it directly to drive it by hand.

import verax/si/topology
import verax/si/drive
import verax/si/simulate
import verax/si/measure
import verax/si/constrain
import verax/si/board

export topology, drive, simulate, measure, constrain, board
