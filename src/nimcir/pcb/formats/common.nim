## Shared contract for PCB file-format modules.
##
## Every format module (e.g. a future `nimcir/pcb/formats/kicad` or
## `nimcir/pcb/formats/odbpp`) implements the same proc names operating only
## on the core types from `nimcir/pcb`:
##
## .. code-block:: nim
##   proc readPcb*(path: string, step = ""): Pcb
##   proc writePcb*(pcb: Pcb, path: string)
##
## As with the netlist formats, the proc names deliberately don't stutter the
## format name; callers needing more than one format import both modules and
## disambiguate with module-qualified calls (`kicad.readPcb`).
##
## **This contract is path-based, not `Stream`-based** -- a deliberate
## departure from `nimcir/netlist/formats/common`. An ODB++ job is a
## *directory tree* (`matrix/matrix`, `misc/info`, `steps/<step>/...`,
## `symbols/`) whose individual members may be LZW-compressed with a `.Z`
## suffix, and no single `Stream` can express that. A KiCad board is one file,
## so a path covers both cases.
##
## The `step` parameter exists because one ODB++ job may hold several steps
## (board, panel, coupon); readers that support only one step take the first
## and record its name in `Pcb.name`. Single-file formats ignore it.

type
  PcbFormatError* = object of CatchableError
    ## Raised on malformed input or unrepresentable output. `msg` should
    ## include file and line-number context where practical.
