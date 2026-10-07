## Shared contract for PCB file-format modules: each implements
##
## .. code-block:: nim
##   proc readPcb*(path: string, step = ""): Pcb
##   proc writePcb*(pcb: Pcb, path: string)
##
## over `verax/pcb` types, with module-qualified calls for disambiguation.
##
## **Path-based, not `Stream`-based**: an ODB++ job is a directory tree with
## `.Z`-compressed members. `step` selects one of an ODB++ job's steps
## (default the first, named in `Pcb.name`); single-file formats ignore it.
##
## **Round trip**: an unmodified board writes back byte-for-byte, and
## unmodelled fields survive verbatim. Edits are narrower: `writePcb`
## regenerates only what the format module lists (for KiCad: tracks, vias,
## nets, zone scalars, placement position/side/reference/pad nets) and
## **refuses by name** anything else rather than fabricate or drop it.

type
  PcbFormatError* = object of CatchableError
    ## Raised on malformed input or unrepresentable output; `msg` should
    ## include file and line context.
