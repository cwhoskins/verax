# `ibis` submodule

Reads an IBIS `.ibs` file into a typed model (I/V curves, edge rates, die C, package RLC as `typ/min/max`). Depends on `netlist` and `pcb`. The whole submodule is in the hub (no external tool). **Read the file, hand back the data** — turning a model into a SPICE device is `spice/models`' job, judging a design against it is `analysis`'. IBIS 3.2 core is parsed; everything past parsing is a skeleton. **No writer**, deliberately.

- **`types.nim`**
  - Every quantity is a bare `float` in SI base units, not a `verax/units` type — one generic `Triplet` can't carry six quantity types. Don't "fix" this with per-quantity triplet types.
  - `Triplet` records presence per corner: `NA` ≠ `0.0`. `get` **raises** on an absent corner; `has` is the non-raising check.
  - `raw` fields keep each block as lexed so unmodelled subparameters stay reachable; unmodelled keywords survive in `IbisFile.sections`.
- **`parse.nim`** — lexer, separate from `reader` so unknown keywords round-trip. Grammar traps:
  - `[Comment Char]` redefines the comment character from that line on; parse it from the raw line *before* comment stripping.
  - Keywords are case-insensitive and space/underscore-equivalent (`canonicalKeyword`).
  - A keyword's `[` must be in column 1. `[End]` ends the file.
  - `parseIbisNumber`: `M` is mega, `m` is milli; `meg` is not IBIS; RKM (`2k2`) is rejected.
  - The 120-char line limit is not enforced (vendor files exceed it).
- **`reader.nim`** — `readIbis`/`readIbisFile`. Errors are `IbisError` with line context. **An unrecognised keyword degrades, it does not error** — that's why a 3.2 reader opens a 7.x file.
- **`attach.nim`** — `bindIbis(nl, designator, file)` verifies every `[Pin]` maps to a real `Pin` and raises on the first mismatch; that check is the binding's whole value.
