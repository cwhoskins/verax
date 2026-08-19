## `ngspice` simulation backend, implementing the contract documented in
## `nimcir/spice/backend`.
##
## Several behaviors below were verified empirically against the locally
## installed ngspice-46 rather than assumed, because the CLI's exit code and
## output formats have real surprises -- see `run` and `parseRawfile`.

import std/[streams, osproc, os, strutils, tables, tempfiles]
import ../netlist/types
import ../netlist/formats/spice as spiceFormat
import ./backend
import ./xspice/cmpath

export backend

proc writeDeck*(nl: Netlist, cards: seq[string], s: Stream) =
  spiceFormat.writeNetlist(nl, s, cards)

proc writeDeckFile*(nl: Netlist, cards: seq[string], path: string) =
  spiceFormat.writeNetlistFile(nl, path, cards)

proc parseRawfile(path: string): SimResult =
  ## Parses the ASCII rawfile format written by ngspice's
  ## `set filetype=ascii; write <path>` inside a `.control` block. Verified
  ## against real `.op`/`.tran` output. `Flags: complex` (produced by
  ## `.ac`) is unimplemented -- raises `SpiceSimError` rather than silently
  ## misreading a real/imaginary pair as a single real value.
  let lines = readFile(path).splitLines()

  var plotName = ""
  var flags = ""
  var numVars = 0
  var numPoints = 0
  var i = 0
  while i < lines.len:
    let line = lines[i]
    if line.startsWith("Plotname:"):
      plotName = line["Plotname:".len .. ^1].strip()
    elif line.startsWith("Flags:"):
      flags = line["Flags:".len .. ^1].strip()
    elif line.startsWith("No. Variables:"):
      numVars = parseInt(line["No. Variables:".len .. ^1].strip())
    elif line.startsWith("No. Points:"):
      numPoints = parseInt(line["No. Points:".len .. ^1].strip())
    elif line.startsWith("Variables:"):
      inc i
      break
    inc i

  if flags.toLowerAscii() == "complex":
    raise newException(SpiceSimError,
      "AC analysis (Flags: complex) is not supported yet: " & path)

  var varNames: seq[string]
  while i < lines.len and varNames.len < numVars:
    let toks = lines[i].strip().splitWhitespace()
    if toks.len >= 2:
      varNames.add toks[1]
    inc i

  while i < lines.len and not lines[i].startsWith("Values:"):
    inc i
  inc i

  result.plotName = plotName
  for name in varNames:
    result.vectors[name.toLowerAscii] = SimVector(name: name)

  var pointIdx = 0
  while i < lines.len and pointIdx < numPoints:
    if lines[i].strip().len == 0:
      inc i
      continue
    let firstToks = lines[i].strip().splitWhitespace()
    if firstToks.len < 2:
      inc i
      continue
    result.vectors[varNames[0].toLowerAscii].values.add parseFloat(firstToks[^1])
    inc i
    for varIdx in 1 ..< varNames.len:
      result.vectors[varNames[varIdx].toLowerAscii].values.add parseFloat(lines[i].strip())
      inc i
    inc pointIdx

proc run*(nl: Netlist, cards: seq[string],
          codemodels: seq[string] = @[]): SimResult =
  ## Runs `nl` through ngspice in batch mode with the given analysis
  ## `cards` (at most one -- see the module/backend doc comments for why)
  ## and returns the resulting vectors.
  ##
  ## The process exit code is not a reliable success signal for ngspice: a
  ## clean run with only benign warnings can still exit non-zero (observed
  ## with more than one analysis card, where only the last analysis's plot
  ## survives the default `write`), and a malformed deck can trigger an
  ## internal ngspice assertion failure (SIGABRT) rather than a graceful
  ## error. So the real success signal here is "a raw output file exists
  ## and parses" -- the exit code and captured log are surfaced in the
  ## error message when it doesn't.
  ##
  ## `codemodels` are paths to XSPICE `.cm` shared objects (see
  ## `nimcir/spice/xspice`) holding behavioural models the deck instantiates
  ## as `A` devices. Each is loaded with `pre_codemodel`, not `codemodel`,
  ## because an `A` device must resolve while the netlist is being *parsed*,
  ## which happens before the control block runs.
  ##
  ## Paths are routed through `deckSafeCmPath` because ngspice case-folds the
  ## lines it pre-parses, so an uppercase character anywhere in a `.cm` path
  ## makes it unloadable. (This does not affect the `write` line below, which
  ## the control interpreter handles later, from the unfolded text.)
  if cards.len > 1:
    raise newException(SpiceSimError,
      "run() supports at most one analysis card per call (only the last " &
      "analysis's plot survives ngspice's default `write`); got " & $cards.len)

  let tmpDir = createTempDir("nimcir_spice_", "")
  try:
    let deckPath = tmpDir / "deck.cir"
    let rawPath = tmpDir / "deck.raw"
    let logPath = tmpDir / "deck.log"

    for cm in codemodels:
      if not fileExists(cm):
        raise newException(SpiceSimError, "no such code model: " & cm)

    var fullCards = cards
    fullCards.add ".control"
    for cm in codemodels:
      fullCards.add "pre_codemodel " & deckSafeCmPath(cm)
    fullCards.add "run"
    fullCards.add "set filetype=ascii"
    fullCards.add "write " & rawPath
    fullCards.add ".endc"
    writeDeckFile(nl, fullCards, deckPath)

    let process = startProcess("ngspice", args = @["-b", "-o", logPath, deckPath],
                                options = {poUsePath})
    let exitCode = process.waitForExit()
    process.close()

    let log = if fileExists(logPath): readFile(logPath) else: ""

    if not fileExists(rawPath):
      raise newException(SpiceSimError,
        "ngspice produced no output (exit code " & $exitCode & "):\n" & log)

    try:
      result = parseRawfile(rawPath)
    except SpiceSimError:
      raise
    except CatchableError as e:
      raise newException(SpiceSimError,
        "failed to parse ngspice output: " & e.msg & "\nngspice log:\n" & log)
  finally:
    removeDir(tmpDir)
