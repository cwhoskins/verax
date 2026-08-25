## Choosing a physical part for an electrical requirement.
##
## `src/nimcir/parts/` answers a question the netlist layer deliberately does
## not: given that a circuit needs 22.5 nF here, *which capacitor is that*.
## It depends on `nimcir/units` and `nimcir/netlist`; neither depends back on
## it, and no analysis requires it -- a design that annotates its parts by
## hand never imports this at all.
##
## Read `parts/types.nim` first: the asymmetry it opens with is the reason the
## submodule exists at all, and everything else follows from it.
##
##   * `types` -- `CapRequest`/`ResRequest`/`IndRequest`, `Choice`,
##     `PartPolicy`. What a module asks for and what a board decides.
##   * `policy` -- `defaultPolicy()`, and the rule about what it may guess.
##   * `annotate` -- `applyChoice`, which writes a `Choice` onto a component
##     as ordinary registered annotations.

import ./parts/types
import ./parts/policy
import ./parts/annotate

export types, policy, annotate
