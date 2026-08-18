## Shared contract for SPICE simulation-backend modules.
##
## This is the *simulation runner* half of the "spice" name in this
## codebase; for the *file-format* deck reader/writer see
## `nimcir/netlist/formats/spice`.
##
## Every backend module (e.g. `nimcir/spice/ngspice`) implements the same
## proc names operating only on the core `nimcir/netlist` types plus this
## module's result/error types, so callers needing more than one backend at
## once can import both and disambiguate with module-qualified calls:
##
## .. code-block:: nim
##   proc writeDeck*(nl: Netlist, cards: seq[string], s: Stream)
##   proc writeDeckFile*(nl: Netlist, cards: seq[string], path: string)
##   proc run*(nl: Netlist, cards: seq[string]): SimResult
##
## `cards` are raw analysis card lines only (e.g. `@[".op"]` or
## `@[".tran 1u 1m"]`); a backend decides internally how to capture output
## for them. Only one analysis card is supported per `run()` call in every
## backend implemented so far -- see each backend's own doc comment for its
## specific reasoning/limitations.

import std/[tables, strutils]

type
  SpiceSimError* = object of CatchableError
    ## Raised when a simulation run fails to produce usable results --
    ## covers both "the backend process itself failed" and "it produced
    ## output we couldn't parse".

  SimVector* = object
    name*: string
    values*: seq[float]

  SimResult* = object
    plotName*: string
    vectors*: OrderedTable[string, SimVector]
      ## Keyed by lowercased backend vector name (e.g. `"v(vout)"`).

proc `[]`*(r: SimResult, name: string): seq[float] =
  ## Looks up a vector's values by name (case-insensitive, matching how
  ## SPICE vector names are conventionally treated). Raises `KeyError` if
  ## `name` isn't present in the result.
  r.vectors[name.toLowerAscii].values
