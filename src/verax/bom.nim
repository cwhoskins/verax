## Compiling a bill of materials from a design: which real, orderable part
## each component is. See `docs/bom_compiler_plan.md` for the whole plan and
## `src/verax/bom/CLAUDE.md` for what has shipped.
##
## Sits above `parts/` and below `verify.nim`, takes a `Netlist` -- never a
## `Design` or a `Pcb` -- and is not in the verification path: a design that
## never asks for a BOM never pays for one.
##
##   * `types` -- `PartFamily`, `BomItem`, a catalogue's `Candidate`, and the
##     resolver's `Resolution`/`BomLine`/`BomResult`.
##   * `classify` -- `familyOf` (which kinds are searchable, which are not
##     parts at all) and `caseCodeOf` (the standard-footprint gate).
##   * `collect` -- netlist -> one `BomItem` per physical part, with every
##     `bom:` default that filled a gap recorded as an `Assumption`.
##   * `source` -- the `CatalogSource` registry, `PartQuery` and `matches`.
##     No source is registered by importing this; the hermetic one is
##     `verax/bom/sources/local`, imported on its own.
##   * `resolve` -- `BomItem`s -> a `BomResult`: each item's part, by MPN or
##     by parametric search, rolled up into lines.
##   * `report` -- a `BomResult` as text, CSV or `verax.bom/1` JSON, and
##     `loadLock`, which reads that JSON back as the lockfile.

import ./bom/types
import ./bom/classify
import ./bom/collect
import ./bom/source
import ./bom/resolve
import ./bom/report

export types, classify, collect, source, resolve, report
