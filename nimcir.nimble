# Package

version       = "0.1.0"
author        = "Charles Hoskins"
description   = "State what a circuit must do, and check it"
license       = "Proprietary"
srcDir        = "src"
binDir        = "bin"

# The CLI entry point is `src/nimcir/cli.nim`, deliberately not `src/nimcir.nim`:
# a plain `bin = @["nimcir"]` would make the package's top-level importable
# module *be* the binary, so `import nimcir` in an unrelated program would drag
# in the simulator, `osproc` and the whole analysis tree. `namedBin` keys on the
# source path relative to `srcDir` and values the binary name, which keeps the
# two apart.
namedBin["nimcir/cli"] = "nimcir"


# Dependencies
# Nothing beyond the standard library, on purpose -- see CLAUDE.md. The MCP
# server lives in its own package under `mcp/` for exactly this reason: a
# nimble dependency cannot be made opt-in-per-import the way a module can.

requires "nim >= 2.2.10"


task test, "compile and run every tests/t*.nim, failing if any of them does":
  # Written out rather than left to nimble's built-in `test`, which prints a
  # compile or assertion failure and then **exits 0 anyway** -- so a green
  # `nimble test` meant only that nimble itself ran. `exec` aborts the task
  # on a non-zero status, which is the whole point.
  for f in listFiles("tests"):
    if f.endsWith(".nim"):
      echo "--- ", f
      exec "nim c --hints:off --path:src -r " & f

task verify, "check every design under designs/ and every template":
  exec "nim c --hints:off --path:src --out:bin/nimcir src/nimcir/cli.nim"
  for dir in ["designs", "templates"]:
    if not dirExists(dir): continue
    for f in listFiles(dir):
      if f.endsWith(".nim"):
        echo "--- ", f
        exec "bin/nimcir check " & f

task guide, "print the authoring guide":
  exec "nim c --hints:off --path:src --out:bin/nimcir src/nimcir/cli.nim"
  exec "bin/nimcir guide"
