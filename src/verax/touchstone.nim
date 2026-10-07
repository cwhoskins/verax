## Touchstone: reading `.sNp` S-parameter files into a typed swept matrix,
## plus Gamma/VSWR/return-loss/insertion-loss/dBm conversions. Doesn't
## judge acceptability (`contract`'s job) or build a simulatable device.
##
## A sibling of `verax/ibis`, not a `netlist/formats` reader (it doesn't
## produce a netlist). Toolchain-free, so the whole submodule is in this
## hub.
##
## Deferred: binding an `.s2p` to a `Component` (the `sparams` annotation is
## registered) until an S-parameter model exists to read it.

import verax/touchstone/types
import verax/touchstone/parse
import verax/touchstone/reader

export types, parse, reader
