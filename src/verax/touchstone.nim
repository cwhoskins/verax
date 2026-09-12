## Touchstone -- reading a `.sNp` S-parameter file (`.s1p`, `.s2p`, ...,
## typically exported by a VNA or an RF vendor's simulator) into a typed
## frequency-swept matrix, plus the scalar conversions reading one requires.
##
## This submodule owns *what the measurement says*: the S-parameter matrix
## versus frequency, and Gamma/VSWR/return-loss/insertion-loss/dBm as pure
## functions of the numbers in it. It does **not** decide whether a match or
## a loss is acceptable (that is `verax/contract`'s job, once a role names
## the quantity) and it does not turn a table into a runnable device for a
## simulator (a later phase's XSPICE `.s2p` code model, once one exists to
## read it).
##
## Sits as a **sibling of `verax/ibis`**, not inside `verax/netlist/formats`,
## for the same reason `verax/ibis` is not there: `formats/`'s contract
## (`readNetlist`/`writeNetlist`/`NetlistFormatError`) is for readers that
## produce a core netlist type, and a reader handing back its own `SParams`
## value does not fit that shape. Backend/toolchain-free by construction --
## there is no external tool to run to parse a text file -- so, unlike
## `verax/spice`, the whole submodule is in this one hub, the same call
## `verax/ibis.nim` makes.
##
## **Deferred, not built this phase**: a `touchstone/attach.nim` binding an
## `.s2p` path to a `Component` (the annotation key is `sparams`, registered
## in `netlist/annotations`) has no consumer yet -- nothing reads it back
## until a later phase's `sparam_block` XSPICE model exists to interpolate
## the table it names. `verax/ibis/attach.nim` is exactly this shape, added
## once `verax/spice/models` needed to bind a parsed file to a pin.

import verax/touchstone/types
import verax/touchstone/parse
import verax/touchstone/reader

export types, parse, reader
