## Compiling a bill of materials: which orderable part each component is.
## Above `parts/`, below `verify.nim`; takes a `Netlist` (never a `Design` or
## `Pcb`) and isn't in the verification path.
##
##   * `types` -- `PartFamily`, `BomItem`, `Candidate`, `Resolution`/
##     `BomLine`/`BomResult`.
##   * `classify` -- `familyOf` and `caseCodeOf` (the standard-footprint
##     gate).
##   * `collect` -- netlist -> one `BomItem` per physical part, with `bom:`
##     defaults recorded as `Assumption`s.
##   * `source` -- the `CatalogSource` registry, `PartQuery`, `matches`.
##     Nothing registers on import; see `bom/sources/local`.
##   * `resolve` -- `BomItem`s -> `BomResult`, by MPN or parametric search.
##   * `report` -- text, CSV or `verax.bom/1` JSON, and `loadLock`.

import ./bom/types
import ./bom/classify
import ./bom/collect
import ./bom/source
import ./bom/resolve
import ./bom/report

export types, classify, collect, source, resolve, report
