## Compiling a bill of materials from a design: which real, orderable part
## each component is. See `docs/bom_compiler_plan.md` for the whole plan and
## `src/verax/bom/CLAUDE.md` for what has shipped.
##
## Sits above `parts/` and below `verify.nim`, takes a `Netlist` -- never a
## `Design` or a `Pcb` -- and is not in the verification path: a design that
## never asks for a BOM never pays for one.
##
##   * `types` -- `PartFamily` and `BomItem`.
##   * `classify` -- `familyOf` (which kinds are searchable, which are not
##     parts at all) and `caseCodeOf` (the standard-footprint gate).
##   * `collect` -- netlist -> one `BomItem` per physical part, with every
##     `bom:` default that filled a gap recorded as an `Assumption`.

import ./bom/types
import ./bom/classify
import ./bom/collect

export types, classify, collect
