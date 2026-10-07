## Shared contract for netlist file-format modules: each implements
##
## .. code-block:: nim
##   proc readNetlist*(s: Stream, name = ""): Netlist
##   proc writeNetlist*(nl: Netlist, s: Stream)
##   proc readNetlistFile*(path: string): Netlist
##   proc writeNetlistFile*(nl: Netlist, path: string)
##
## Names don't stutter the format; use module-qualified calls
## (`spice.readNetlist`) when importing several.

type
  NetlistFormatError* = object of CatchableError
    ## Raised on malformed input or unrepresentable output; `msg` should
    ## include line context.
