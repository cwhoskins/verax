## Shared contract for PCB file-format modules.
##
## Every format module (e.g. a future `verax/pcb/formats/kicad` or
## `verax/pcb/formats/odbpp`) implements the same proc names operating only
## on the core types from `verax/pcb`:
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
## departure from `verax/netlist/formats/common`. An ODB++ job is a
## *directory tree* (`matrix/matrix`, `misc/info`, `steps/<step>/...`,
## `symbols/`) whose individual members may be LZW-compressed with a `.Z`
## suffix, and no single `Stream` can express that. A KiCad board is one file,
## so a path covers both cases.
##
## The `step` parameter exists because one ODB++ job may hold several steps
## (board, panel, coupon); readers that support only one step take the first
## and record its name in `Pcb.name`. Single-file formats ignore it.
##
## **The round-trip contract this stage actually delivers, first implemented
## by `formats/kicad.nim`:** `read(f)` then `write()` reproduces an
## *unmodified* board byte-for-byte, and every field this library does not
## model still survives, verbatim, because the reader keeps the whole
## source tree and the writer copies whatever it did not touch. Editing is a
## **narrower** claim: `writePcb` on a board that changed since it was read
## regenerates only what `kicad.nim`'s doc comment lists as regenerable
## (tracks, vias, nets, zone scalars, a placement's position/side/reference/
## pad nets) and **refuses by name** — naming the entity and the class —
## everything else (a new footprint, a new pad, a reshaped zone outline, any
## silkscreen/mask/courtyard/fabrication graphics edit, a stack-up edit)
## rather than fabricating it or silently dropping it. A refusal is not a
## missing feature report; it is the honest alternative to guessing what a
## human meant by a change this format module cannot express back into
## valid KiCad. `formats/odbpp.nim` is unwritten; nothing here assumes ODB++
## will make the same trade — a directory-tree format with LZW-compressed
## members has different constraints on what "regenerate in place" even
## means.

type
  PcbFormatError* = object of CatchableError
    ## Raised on malformed input or unrepresentable output. `msg` should
    ## include file and line-number context where practical.
