version       = "0.1.0"
author        = "verax"
description   = "nimpy extension exposing a slice of verax's netlist/verify API to Python -- the phase 1 spike for docs/python_compatibility.md. Not part of the verax package: this is what keeps the core's zero-nimble-dependency posture true, the same reasoning that put mcp/ in its own package."
license       = "Proprietary"
srcDir        = "."

requires "nim >= 2.2.10"
requires "nimpy"

import std/strutils

proc extExt(): string =
  when defined(windows): ".pyd" else: ".so"

# Not `namedBin` -- a nimpy extension is a Python-loadable shared library
# (`.so`/`.pyd`), not an executable, so it is built with `nim c --app:lib`
# rather than through nimble's own binary machinery. `nimble build` in this
# directory would try to link verax_py.nim as a program and fail; `buildext`
# below is the actual entry point.

task buildext, "Build the verax_py Python extension module (.so)":
  ## `--path:../src` reaches this repo's `verax/` sources directly, the same
  ## "found by walking up for verax.nimble" fallback `cli.nim` uses for a
  ## design repo that has not run `nimble setup` -- appropriate here because
  ## this package is *inside* the verax checkout, not a design consuming it.
  ## `nimble path nimpy` is resolved at task-run time rather than assumed,
  ## since nimble's own automatic `--path` injection only applies to `nim c`
  ## invocations it runs itself, not to a plain `exec` from inside a task.
  let nimpyPath = gorge("nimble path nimpy").strip()
  exec "nim c --app:lib -d:release --path:../src --path:" & nimpyPath &
       " -o:verax_py" & extExt() & " verax_py.nim"
