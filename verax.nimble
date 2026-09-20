# Package

version       = "0.1.0"
author        = "Charles Hoskins"
description   = "State what a circuit must do, and check it"
license       = "Proprietary"
srcDir        = "src"
binDir        = "bin"

# The CLI entry point is `src/verax/cli.nim`, deliberately not `src/verax.nim`:
# a plain `bin = @["verax"]` would make the package's top-level importable
# module *be* the binary, so `import verax` in an unrelated program would drag
# in the simulator, `osproc` and the whole analysis tree. `namedBin` keys on the
# source path relative to `srcDir` and values the binary name, which keeps the
# two apart.
namedBin["verax/cli"] = "verax"


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
  exec "nim c --hints:off --path:src --out:bin/verax src/verax/cli.nim"
  for dir in ["designs", "templates"]:
    if not dirExists(dir): continue
    for f in listFiles(dir):
      if f.endsWith(".nim"):
        echo "--- ", f
        exec "bin/verax check " & f

task guide, "print the authoring guide":
  exec "nim c --hints:off --path:src --out:bin/verax src/verax/cli.nim"
  exec "bin/verax guide"

task roundtrip, "sweep /usr/share/kicad/demos for byte-exact kicad_pcb round-tripping":
  # `-d:release`, not `nim c -r`'s debug default: a debug-mode parse of the
  # 81 MB jetson-agx-thor-baseboard.kicad_pcb is minutes, and this task
  # exists precisely to sweep that file along with the rest of the corpus.
  # A `-d:release` compile+run of the whole 18-board corpus is the ~45 s this
  # is budgeted at; `nim c -r` (debug) is not.
  exec "nim c -d:release --hints:off --path:src -r examples/pcb_roundtrip.nim"

task traces, "sweep /usr/share/kicad/demos for trace extraction and reference-plane resolution":
  # Same `-d:release` reasoning as `task roundtrip`: this walks the same
  # corpus (jetson-agx-thor-baseboard.kicad_pcb alone is 81 MB) and does
  # real work per net -- a debug build would not finish in a budget worth
  # running routinely.
  exec "nim c -d:release --hints:off --path:src -r examples/pcb_traces.nim"

task kicadcheck, "kicad-cli acceptance gate for regenerated (edited) output":
  exec "nim c -d:release --hints:off --path:src -r examples/pcb_editcheck.nim"
