## The `verax` binary. `check` compiles and runs a design; the discovery
## subcommands (`roles`, `role`, `quantities`, `annotations`, `guide`)
## answer "what may I claim?" from the live registries, read nothing and
## write nothing. Only this module and `verify` link the simulator-backed
## evaluators.

import std/[hashes, os, osproc, strutils]

import ./verify
import ./netlist/interfaces
import ./netlist/interfaces/std

const
  version = "0.1.0"
  # Embedded at compile time, so `docs/` and `templates/` needn't be
  # installed.
  guideText = staticRead("../../docs/authoring.md")
  # Ordered for a reader, not alphabetically: this is the menu `verax new`
  # shows. `templates/README.md` describes each.
  templates = {
    "blank": staticRead("../../templates/blank.nim"),
    "divider": staticRead("../../templates/divider.nim"),
    "rail": staticRead("../../templates/rail.nim"),
    "regulator": staticRead("../../templates/regulator.nim"),
    "settled_rail": staticRead("../../templates/settled_rail.nim"),
    "derating": staticRead("../../templates/derating.nim"),
    "opamp": staticRead("../../templates/opamp.nim"),
    "gain_stage": staticRead("../../templates/gain_stage.nim"),
    "sallen_key": staticRead("../../templates/sallen_key.nim"),
    "large_signal": staticRead("../../templates/large_signal.nim"),
    "oscillator": staticRead("../../templates/oscillator.nim"),
    "i2c": staticRead("../../templates/i2c.nim"),
    "diff_pair": staticRead("../../templates/diff_pair.nim"),
    "subcircuit": staticRead("../../templates/subcircuit.nim"),
  }
  builtinLibDir = currentSourcePath().parentDir.parentDir

# --- locating the library ------------------------------------------------

proc validLibDir(dir: string): bool =
  dir.len > 0 and fileExists(dir / "verax" / "contract" / "dsl.nim")

proc locateLib(designFile, flag: string): tuple[dir, how: string] =
  ## Where to point `--path:` when compiling a design. Every candidate is
  ## validated: nimble builds in a temporary directory, so a compiled-in path
  ## may no longer exist. An empty result means pass no `--path` and let
  ## `nimble.paths` resolve it.
  if flag.len > 0:
    if not validLibDir(flag):
      raise newException(ValueError,
        "--path:" & flag & " does not contain verax/contract/dsl.nim")
    return (flag, "--path")

  let env = getEnv("VERAX_PATH")
  if env.len > 0 and validLibDir(env): return (env, "$VERAX_PATH")

  var dir = designFile.absolutePath().parentDir
  while true:
    if fileExists(dir / "verax.nimble") and validLibDir(dir / "src"):
      return (dir / "src", "repo checkout at " & dir)
    let up = dir.parentDir
    if up == dir or up.len == 0: break
    dir = up

  if validLibDir(builtinLibDir): return (builtinLibDir, "compiled in")

  try:
    let (outp, code) = execCmdEx("nimble path verax")
    if code == 0:
      for line in outp.splitLines():
        let cand = line.strip()
        if validLibDir(cand): return (cand, "nimble path verax")
  except OSError, IOError:
    discard

  ("", "nim's own config (nimble.paths)")

# --- check ----------------------------------------------------------------

proc cacheDirFor(file: string): string =
  ## Stable per design file, so the compile cache stays warm.
  getTempDir() / "verax-check" / $hash(file.absolutePath())

proc cmdCheck(file: string, pathFlag: string, forward: seq[string]): int =
  if not fileExists(file):
    stderr.writeLine "verax: no such file: " & file
    return exitCompile
  if findExe("nim").len == 0:
    stderr.writeLine "verax: `nim` is not on PATH; it is needed to compile " &
                     "a design file"
    return exitCompile

  let src = readFile(file)
  if "verify" notin src:
    stderr.writeLine "verax: warning: " & file & " never calls verify -- " &
      "a design file ends with `quit(verifyMain(d))`, or nothing is checked"

  let (lib, how) = locateLib(file, pathFlag)
  let cache = cacheDirFor(file)
  createDir(cache)
  let bin = cache / "design".addFileExt(ExeExt)

  # Compile model declarations without their FFI entry points
  # (`-d:xspiceSpecOnly`), so designs build without ngspice sources.
  var args = @["c", "--hints:off", "-d:xspiceSpecOnly"]
  if lib.len > 0: args.add "--path:" & lib
  args.add "--nimcache:" & cache / "nc"
  args.add "--out:" & bin
  args.add file

  # Compile and run as two processes, never `nim c -r`, so "doesn't
  # compile" stays distinct from "a claim failed".
  let compile = startProcess(findExe("nim"), args = args,
                             options = {poParentStreams})
  let rc = compile.waitForExit()
  compile.close()
  if rc != 0:
    stderr.writeLine ""
    stderr.writeLine "COMPILE FAILED  " & file & "  (library path: " & how & ")"
    stderr.writeLine "Nothing was checked. Fix the errors above; they are " &
                     "Nim's, not the circuit's."
    return exitCompile

  let run = startProcess(bin, args = forward, options = {poParentStreams})
  result = run.waitForExit()
  run.close()

# --- layout -----------------------------------------------------------

proc cmdLayout(file, pathFlag, outPath: string, layers: int, size: string,
               extra: seq[string]): int =
  ## Reuses `cmdCheck`: the layout flags are read by
  ## `verify.parseVerifyArgs` inside the design binary, like
  ## `--schematic-only`.
  var forward = @["--layout-out=" & outPath]
  if layers > 0: forward.add "--layout-layers=" & $layers
  if size.len > 0: forward.add "--layout-size=" & size
  forward.add extra
  cmdCheck(file, pathFlag, forward)

# --- bom --------------------------------------------------------------

proc cmdBom(file, pathFlag, outPath: string, extra: seq[string]): int =
  ## As `cmdLayout`: forward flags to `cmdCheck`; the design binary reads
  ## them.
  var forward = @["--bom"]
  if outPath.len > 0: forward.add "--bom-out=" & outPath
  forward.add extra
  cmdCheck(file, pathFlag, forward)

# --- discovery ------------------------------------------------------------

proc cmdInterfaces(): int =
  echo describeInterfaces()
  exitClean

proc cmdInterface(name: string): int =
  echo describeInterface(name)
  exitClean

proc cmdRoles(): int =
  echo describeRoles()
  exitClean

proc cmdRole(name: string): int =
  echo describeRole(name)
  exitClean

proc cmdQuantities(): int =
  echo describeQuantities()
  exitClean

proc cmdAnnotations(): int =
  echo describeAnnotations()
  exitClean

proc cmdEnv(): int =
  let (lib, how) = locateLib(getCurrentDir() / "design.nim", "")
  echo "verax      ", version
  echo "nim         ", (if findExe("nim").len > 0: findExe("nim") else: "NOT FOUND")
  let sim = ngspiceVersion()
  echo "simulator   ", (if sim.len > 0: sim else: "none (no ngspice on PATH)")
  echo "library     ", (if lib.len > 0: lib else: "(none needed)"), "  -- ", how
  echo "capabilities", "  ", capList(availableCapabilities(sim))
  echo "roles       ", registeredRoles().len, " registered"
  echo "interfaces  ", registeredInterfaceDefs().len, " registered"
  echo "quantities  ", evaluableQuantities().len, " measurable"
  let cat = getEnv("VERAX_BOM_CATALOG")
  echo "bom catalog ", (if cat.len > 0: cat & "  -- $VERAX_BOM_CATALOG"
                        else: "none (pass --bom-catalog=<file.json>)")
  exitClean

proc cmdNew(kind, path: string): int =
  var body = ""
  for pair in templates:
    if pair[0] == kind: body = pair[1]
  if body.len == 0:
    var names: seq[string]
    for pair in templates: names.add pair[0]
    raise newException(ValueError,
      "no template '" & kind & "'; available: " & names.join(", "))
  if path.len == 0 or path == "-":
    stdout.write body
    return exitClean
  if fileExists(path):
    raise newException(ValueError, path & " already exists; refusing to overwrite")
  createDir(path.parentDir)
  writeFile(path, body)
  echo "wrote ", path
  echo "check it with:  verax check ", path
  exitClean

const usage = """
verax -- state what a circuit must do, and check it

usage:
  verax check <file.nim> [flags]   compile and check a design file
  verax layout <file.nim> -o <out.kicad_pcb> [--layers=N] [--layout-size=WxH]
                                    assemble a board from a design's footprints
  verax bom <file.nim> [-o <out>] [--bom-*]
                                    compile a bill of materials
  verax new <template> [path]      write a starter design ("-" for stdout)
  verax roles                      the bundles of claims available
  verax interfaces                 declared interface definitions
  verax interface <name>           one interface and its modports
  verax role <name>                one role, and the claims it makes
  verax quantities                 everything a `require` can name
  verax annotations                the keys a `spec:` block accepts
  verax guide                      the authoring guide
  verax env                        toolchain, library path, capabilities
  verax version

check flags (forwarded to the design file):
  --offline          graph walks only; do not simulate
  --caps=op,dc,ac,tran
                     offer a specific subset
  --verbose          show the full plan and the passing claims
  --strict           treat warnings and unevaluated claims as failures
  --keep-runs=<dir>  archive every simulation there: the deck handed to
                     ngspice, its raw results, its log, an SVG schematic
                     and its JSON scene, and an index.txt saying which run
                     is which
  --save-currents    with --keep-runs, also save device terminal currents
                     (.op/.tran/.dc only; node voltages are saved anyway)
  --schematic-layout=constrained-layered
                     the layout of archived SVG and JSON schematics
                     (constrained-layered is the only policy and the default)
  --schematic-only   with --keep-runs, draw the runFULL.* archive and stop --
                     no simulation runs
  --format=text|json|junit
                     text (default) for a terminal; json/junit for a CI job.
                     --format=json prints pure JSON on stdout -- nothing
                     else is written there
  --baseline=<path>  a prior --format=json report; report what moved since
                     it (a missing or unparseable file is a usage error)
  --path:<dir>       where verax's sources live (usually found automatically)

bom flags (also accepted by check, where any --bom flag compiles a BOM
instead of checking):
  -o, --out <path>   write the BOM there instead of stdout
  --bom-format=text|csv|json
                     text (default), CSV for procurement, or verax.bom/1
                     JSON -- which is also the lockfile. With JSON or CSV on
                     stdout, findings go to stderr
  --bom-catalog=<file.json>
                     a verax.catalog/1 catalogue to resolve against;
                     repeatable, searched in order. Default:
                     $VERAX_BOM_CATALOG
  --bom-lock=<file.json>
                     a prior --bom-format=json report; keep its choices
                     while they still qualify (a missing or unparseable
                     file is a usage error)
  --bom-min-candidates=N
                     fewer matching parts than N is reported as uncommon
                     (default 3, 0 disables)

exit codes:
  0 clean   1 a claim failed   2 structural problem   3 a claim nothing checked
  4 a capability is unavailable here   5 the design did not compile
"""

proc main(): int =
  var args = commandLineParams()
  if args.len == 0 or args[0] in ["-h", "--help", "help"]:
    echo usage
    return exitClean

  let cmd = args[0]
  args.delete(0)

  var pathFlag = ""
  var rest: seq[string]
  for a in args:
    if a.startsWith("--path:"): pathFlag = a["--path:".len .. ^1]
    else: rest.add a

  case cmd
  of "check":
    # The file is the first non-flag argument, so flags may come before or
    # after it.
    var file = ""
    var forward: seq[string]
    for a in rest:
      if file.len == 0 and not a.startsWith("-"): file = a
      else: forward.add a
    if file.len == 0:
      raise newException(ValueError, "check needs a file: verax check <file.nim>")
    cmdCheck(file, pathFlag, forward)
  of "layout":
    var file = ""
    var outPath = ""
    var layers = 0
    var size = ""
    var forward: seq[string]
    var i = 0
    while i < rest.len:
      let a = rest[i]
      if a == "-o" or a == "--out":
        inc i
        if i >= rest.len:
          raise newException(ValueError, "-o needs a path: verax layout <file.nim> -o <out.kicad_pcb>")
        outPath = rest[i]
      elif a.startsWith("--layers="):
        try: layers = parseInt(a["--layers=".len .. ^1])
        except ValueError:
          raise newException(ValueError, "--layers wants an integer, got '" & a & "'")
      elif a.startsWith("--layout-size="):
        size = a["--layout-size=".len .. ^1]
      elif file.len == 0 and not a.startsWith("-"):
        file = a
      else:
        forward.add a
      inc i
    if file.len == 0:
      raise newException(ValueError,
        "layout needs a file: verax layout <file.nim> -o <out.kicad_pcb>")
    if outPath.len == 0:
      raise newException(ValueError,
        "layout needs -o <out.kicad_pcb>: verax layout <file.nim> -o <out.kicad_pcb>")
    cmdLayout(file, pathFlag, outPath, layers, size, forward)
  of "bom":
    var file = ""
    var outPath = ""
    var forward: seq[string]
    var i = 0
    while i < rest.len:
      let a = rest[i]
      if a == "-o" or a == "--out":
        inc i
        if i >= rest.len:
          raise newException(ValueError, "-o needs a path: verax bom <file.nim> -o <out>")
        outPath = rest[i]
      elif file.len == 0 and not a.startsWith("-"):
        file = a
      else:
        forward.add a
      inc i
    if file.len == 0:
      raise newException(ValueError, "bom needs a file: verax bom <file.nim>")
    cmdBom(file, pathFlag, outPath, forward)
  of "new":
    if rest.len == 0:
      raise newException(ValueError, "new needs a template name; try `blank`")
    cmdNew(rest[0], if rest.len > 1: rest[1] else: "-")
  of "roles": cmdRoles()
  of "interfaces": cmdInterfaces()
  of "interface":
    if rest.len == 0:
      raise newException(ValueError, "interface needs a name; `verax interfaces` lists them")
    cmdInterface(rest[0])
  of "role":
    if rest.len == 0:
      raise newException(ValueError, "role needs a name; `verax roles` lists them")
    cmdRole(rest[0])
  of "quantities": cmdQuantities()
  of "annotations": cmdAnnotations()
  of "guide":
    stdout.write guideText
    exitClean
  of "env": cmdEnv()
  of "version":
    echo "verax ", version
    exitClean
  else:
    raise newException(ValueError,
      "unknown command '" & cmd & "'; run `verax` for usage")

when isMainModule:
  try:
    quit(main())
  except ValueError as e:
    stderr.writeLine "verax: " & e.msg
    quit(exitCompile)
