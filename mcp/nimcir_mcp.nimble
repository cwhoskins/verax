# Package

version       = "0.1.0"
author        = "Charles Hoskins"
description   = "MCP server exposing nimcir's design-intent checker"
license       = "Proprietary"
srcDir        = "src"
bin           = @["nimcir_mcp"]


# Dependencies
#
# A separate package on purpose. `nimcp` pulls `mummyx`, `taskpools`, `zippy`,
# `webby`, `crunchy` and `nimsimd` transitively; putting `requires "nimcp"`
# into nimcir.nimble would impose all of that on every consumer of the
# library. "Opt-in per import" is the rule everywhere else in nimcir, but a
# nimble dependency cannot be made opt-in per import -- only per package.
#
# nimcir itself is NOT a dependency: this server drives the `nimcir` binary as
# a subprocess rather than linking the library. That keeps the layer genuinely
# thin -- it couples to the CLI's contract, not to nimcir's module layout, so
# it cannot drift from what a terminal user gets -- and it sidesteps resolving
# a proprietary package that is not in the registry. Point NIMCIR_BIN at the
# binary, or have it on PATH.

requires "nim >= 2.2.10"
requires "nimcp"
