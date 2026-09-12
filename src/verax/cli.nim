## The `verax` binary: check a design, and find out what can be claimed.
##
## Two jobs, and the second matters as much as the first. `check` compiles a
## design file and runs it. The discovery subcommands -- `roles`, `role`,
## `quantities`, `annotations`, `guide` -- answer "what am I allowed to say?"
## from the live registries, which is the only way an author working in a
## repository that is not this one can find out. They read no files and write
## none; every one of them is safe to run speculatively.
##
## Only this module and `verax/verify` link the simulator-backed evaluators.
## Importing the library does not.

import std/[hashes, os, osproc, strutils]

import ./verify
import ./netlist/interfaces
import ./netlist/interfaces/std

const
  version = "0.1.0"
  # Read at compile time, so the binary carries them and neither `docs/` nor
  # `templates/` needs to survive installation.
  guideText = staticRead("../../docs/authoring.md")
  # Ordered the way a reader should meet them rather than alphabetically:
  # `verax new` with an unknown name lists these, and that list is the only
  # menu most people will ever see. `templates/README.md` says what each one
  # is for.
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
    "subcircuit": staticRead("../../templates/subcircuit.nim"),
  }
  builtinLibDir = currentSourcePath().parentDir.parentDir

# --- locating the library ------------------------------------------------

proc validLibDir(dir: string): bool =
  dir.len > 0 and fileExists(dir / "verax" / "contract" / "dsl.nim")

proc locateLib(designFile, flag: string): tuple[dir, how: string] =
  ## Where to point `--path:` when compiling a design file.
  ##
  ## Every candidate is *validated* rather than trusted. In particular the
  ## compiled-in path is checked for existence: nimble builds a package that
  ## declares binaries inside a temporary directory and removes it afterwards,
  ## so for an installed `verax` the path baked in here can be a directory
  ## that no longer exists. It is still tried, because for a locally built
  ## binary it is correct and costs nothing.
  ##
  ## An empty result is not a failure -- it means "pass no `--path` and let
  ## Nim's own config resolve it", which is right for a design repository that
  ## has run `nimble setup` and has verax in its `nimble.paths`.
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
  ## Stable per design file, so the warm compile stays warm across runs.
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

  # A design may import an XSPICE code model to instantiate it, and that
  # module's FFI entry point is the one thing in it that needs ngspice's MIF
  # headers -- which exist only in a configured source tree. A design never
  # calls that entry point; ngspice does, out of the built `.cm`. So compile
  # the declaration without the implementation and a design stays buildable
  # on a machine that has ngspice but not its sources.
  var args = @["c", "--hints:off", "-d:xspiceSpecOnly"]
  if lib.len > 0: args.add "--path:" & lib
  args.add "--nimcache:" & cache / "nc"
  args.add "--out:" & bin
  args.add file

  # Compile and run as two processes, never `nim c -r`: that merges "this
  # file does not compile" and "an assertion failed" into one exit status,
  # and a reader who cannot tell those apart edits the circuit to fix a
  # syntax error.
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
  --path:<dir>       where verax's sources live (usually found automatically)

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
    # The file is the first argument that is not a flag, rather than simply
    # the first one: every flag here is forwarded to the design binary, so
    # both orders are natural to type and `check --offline foo.nim` used to
    # report `no such file: --offline`.
    var file = ""
    var forward: seq[string]
    for a in rest:
      if file.len == 0 and not a.startsWith("-"): file = a
      else: forward.add a
    if file.len == 0:
      raise newException(ValueError, "check needs a file: verax check <file.nim>")
    cmdCheck(file, pathFlag, forward)
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
