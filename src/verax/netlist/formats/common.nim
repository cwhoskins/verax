## Shared contract for netlist file-format modules.
##
## Every format module (e.g. `verax/netlist/formats/spice`) implements the
## same proc names operating only on the core types from `verax/netlist`:
##
## .. code-block:: nim
##   proc readNetlist*(s: Stream, name = ""): Netlist
##   proc writeNetlist*(nl: Netlist, s: Stream)
##   proc readNetlistFile*(path: string): Netlist
##   proc writeNetlistFile*(nl: Netlist, path: string)
##
## Callers needing more than one format at once simply import both modules
## and disambiguate with module-qualified calls (e.g. `spice.readNetlist`),
## so the proc names deliberately don't stutter the format name.

type
  NetlistFormatError* = object of CatchableError
    ## Raised on malformed input or unrepresentable output. `msg` should
    ## include line-number context where practical.
