## `ngspice` simulation backend, implementing `verax/spice/backend`. The
## CLI's exit code and output formats have surprises, verified against
## ngspice-46 -- see `run` and `parseRawfile`.

import std/[complex, streams, osproc, os, strutils, tables, tempfiles, times]
import ../netlist/types
import ../netlist/formats/spice as spiceFormat
import ./backend
import ./xspice/cmpath
import ./xspice/instance
import ./provenance

export provenance.BenchInfo, provenance.BenchItem, provenance.BenchRole

export backend

proc writeDeck*(nl: Netlist, cards: seq[string], s: Stream) =
  spiceFormat.writeNetlist(nl, s, cards)

proc writeDeckFile*(nl: Netlist, cards: seq[string], path: string) =
  spiceFormat.writeNetlistFile(nl, path, cards)

proc parseComplexTok(tok, path: string): Complex64 =
  ## One `real,imag` rawfile token. Raises `SpiceSimError`, like every other
  ## unusable-output condition here.
  let parts = tok.split(',')
  if parts.len != 2:
    raise newException(SpiceSimError,
      "malformed complex value '" & tok & "' in " & path &
      " (expected real,imag)")
  try:
    complex64(parseFloat(parts[0].strip()), parseFloat(parts[1].strip()))
  except ValueError:
    raise newException(SpiceSimError,
      "unparseable complex value '" & tok & "' in " & path)

proc parseRawfile(path: string): SimResult =
  ## Parses the ASCII rawfile ngspice writes from `set filetype=ascii; write
  ## <path>`. `Flags: complex` (`.ac`) gives bare `real,imag` pairs with no
  ## space:
  ##
  ## ```
  ## Values:
  ##  0\t1.000000000000000e+01,0.000000000000000e+00
  ## \t9.999605231408795e-01,-6.282937266758387e-03
  ## ```
  ##
  ## Otherwise identical: the first variable shares the index line. `Flags:`
  ## precedes `Values:`, so each vector gets the right variant up front.
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

  let dataKind =
    if "complex" in flags.toLowerAscii().splitWhitespace(): sdComplex
    else: sdReal

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
  result.dataKind = dataKind
  for name in varNames:
    result.vectors[name.toLowerAscii] = newSimVector(name, dataKind)

  var pointIdx = 0
  while i < lines.len and pointIdx < numPoints:
    if lines[i].strip().len == 0:
      inc i
      continue
    let firstToks = lines[i].strip().splitWhitespace()
    if firstToks.len < 2:
      inc i
      continue
    case dataKind
    of sdReal:
      result.vectors[varNames[0].toLowerAscii].values.add parseFloat(firstToks[^1])
      inc i
      for varIdx in 1 ..< varNames.len:
        result.vectors[varNames[varIdx].toLowerAscii].values.add parseFloat(lines[i].strip())
        inc i
    of sdComplex:
      result.vectors[varNames[0].toLowerAscii].cvalues.add parseComplexTok(firstToks[^1], path)
      inc i
      for varIdx in 1 ..< varNames.len:
        let tok = lines[i].strip()
        result.vectors[varNames[varIdx].toLowerAscii].cvalues.add parseComplexTok(tok, path)
        inc i
    inc pointIdx

type
  RunPictureWriter* = proc (nl: Netlist, base: string) {.nimcall.}
    ## Draws the derived netlist of one run into the archive as
    ## `<base>.svg`/`<base>.json`. A hook rather than an import so `spice`
    ## doesn't link the schematic layout engine: `verax/run_archive`
    ## installs the schematic writer, and `verify` imports that.

var runPictureWriter: RunPictureWriter

proc setRunPictureWriter*(w: RunPictureWriter) =
  ## Installs (or, with `nil`, removes) the per-run picture writer.
  runPictureWriter = w

type
  RunRecord* = object
    ## One ngspice run as an observer sees it, success or not. `netlist` is
    ## the derived fragment that was simulated (isolated, flattened,
    ## substituted), not the design.
    label*, analysis*: string
    setup*: seq[string]
    netlist*: Netlist
    ok*: bool
    error*: string        ## the `SpiceSimError` message when `ok` is false
    result*: SimResult    ## empty when `ok` is false
    log*: string          ## ngspice's `-o` log, kept even on success
    deck*: string         ## the deck text that ran
    ms*: int
    bench*: BenchInfo     ## what the analysis declared (empty if it didn't)

  RunObserver* = proc (r: RunRecord) {.closure.}
    ## Sees every run after it finishes. A hook, like `RunPictureWriter`,
    ## so a report can keep curves and logs without `spice` knowing about
    ## it and without anything on disk.

var runObserver: RunObserver

proc setRunObserver*(o: RunObserver) =
  ## Installs (or, with `nil`, removes) the run observer.
  runObserver = o

proc clearRunObserver*() =
  runObserver = nil

proc notifyRunObserver(r: RunRecord) =
  ## Best effort: an observer that raises must not change what a run
  ## returns or raises.
  if runObserver == nil: return
  try:
    runObserver(r)
  except CatchableError:
    discard

proc keepSchematic(nl: Netlist, dir, slot: string) =
  ## Draws the derived netlist into the run archive, when one is kept and a
  ## writer is installed. A pure function of the netlist, so it can't change
  ## what's simulated; best effort, never fails a run.
  if dir.len == 0 or runPictureWriter == nil: return
  try:
    runPictureWriter(nl, dir / slot)
  except CatchableError:
    discard

proc keepDeck(deckPath: string) =
  ## Copies the deck just run into `$VERAX_KEEP_DECKS`, if set. Decks are
  ## derived (isolated, terminated, substituted) and otherwise deleted, so
  ## this is how to see what was actually simulated. Never changes what is
  ## simulated.
  let dir = getEnv("VERAX_KEEP_DECKS")
  if dir.len == 0: return
  try:
    createDir(dir)
    var i = 0
    while fileExists(dir / ("deck" & $i & ".cir")): inc i
    copyFile(deckPath, dir / ("deck" & $i & ".cir"))
  except CatchableError:
    discard  # a debugging aid must never be able to fail a simulation

const runIndexFile* = "index.txt"
  ## The manifest in a `$VERAX_KEEP_RUNS` directory: a rawfile doesn't say
  ## which circuit or analysis produced it.

proc runSlotName(i: int): string =
  ## Zero-padded so `ls` sorts runs in order.
  "run" & align($i, 3, '0')

proc archiveSlot(): tuple[dir, slot: string] =
  ## Picks where this run's deck, rawfile and log are written, up front, so
  ## the archived deck is the one that ran and its `write` names the rawfile
  ## beside it (reproducible by rerunning it). Off unless `$VERAX_KEEP_RUNS`
  ## is set; any failure yields `("", "")` and a normal temp run.
  let dir = getEnv("VERAX_KEEP_RUNS")
  if dir.len == 0: return ("", "")
  try:
    createDir(dir)
    var i = 0
    while fileExists(dir / (runSlotName(i) & ".cir")): inc i
    (dir, runSlotName(i))
  except CatchableError:
    ("", "")

proc appendIndex(dir, slot, status, label, analysis: string,
                 setup: seq[string], netlistName, plot, dataText: string,
                 nvars, npoints, rawBytes, ms: int) =
  ## One tab-separated row per run, failed runs included (`status` says so;
  ## those are the ones worth reading).
  if dir.len == 0: return
  try:
    let path = dir / runIndexFile
    let fresh = not fileExists(path)
    let f = open(path, fmAppend)
    defer: f.close()
    if fresh:
      f.writeLine(["slot", "status", "label", "analysis", "setup", "netlist",
                   "plot", "data", "vectors", "points", "bytes",
                   "ms"].join("\t"))
    proc orDash(s: string): string = (if s.len > 0: s else: "-")
    f.writeLine([slot, status, orDash(label), orDash(analysis.strip()),
                 orDash(setup.join("; ")), orDash(netlistName), orDash(plot),
                 orDash(dataText), $nvars, $npoints, $rawBytes,
                 $ms].join("\t"))
  except CatchableError:
    discard  # as above: an archive must never fail a simulation

const analysisCards* = ["ac", "dc", "op", "tran", "noise", "disto", "pz",
                        "sens", "tf"]
  ## Dot cards that run an analysis and produce a plot. Only used to refuse
  ## one in `setup`; unknown cards are not guessed at.

proc analysisWord(card: string): string =
  ## The bare card name, lowercased (`".tran 1u 1m uic"` -> `"tran"`); empty
  ## for a non-dot card.
  let t = card.strip().toLowerAscii()
  if not t.startsWith("."): return ""
  t[1 .. ^1].split({' ', '\t'})[0]

proc isAnalysisCard*(card: string): bool =
  analysisWord(card) in analysisCards

const realPlotAnalyses = ["op", "tran", "dc"]
  ## Real-valued analyses: the only ones a device-current `.save` may attach
  ## to (see `saveCurrentsCard`).

proc currentParamsFor(letter: char): seq[string] =
  ## Which `@dev[...]` currents exist per device letter, mirroring ngspice's
  ## `inp_savecurrents`. `v` is absent (already a saved branch current), as
  ## are `x` and `a` (no terminal currents).
  case letter
  of 'r', 'c', 'l', 'b', 'f', 'g', 'w', 's': @["i"]
  of 'd': @["id"]
  of 'q': @["ic", "ie", "ib"]
  of 'm': @["id", "is", "ig", "ib"]
  of 'j': @["id", "is", "ig"]
  of 'i': @["current"]
  else: @[]

proc branchCurrentVector*(desig: string): tuple[vector, saveTerm, reason: string] =
  ## Where the current through `desig` appears in a rawfile, and what must
  ## be saved for it to appear. A matrix unknown (`V`, `L`, `E`, `H`) is
  ## saved by default as `i(l1)`; any other device's current is derived,
  ## must be named, and reads back as `i(@r1[i])` (rawfile spellings, which
  ## differ from the manual's vector names).
  ##
  ## An empty `vector` comes with a `reason`. A three-terminal device is
  ## refused: "the current through Q1" doesn't say which terminal.
  if desig.len == 0:
    return ("", "", "the part has no deck designator, so nothing in the deck " &
                    "carries its current")
  let letter = desig[0].toLowerAscii
  case letter
  of 'v', 'l', 'e', 'h':
    ("i(" & desig & ")", "", "")
  of 'r', 'c', 'd', 'b', 'f', 'g', 'w', 's', 'i':
    let p = currentParamsFor(letter)[0]
    ("i(@" & desig & "[" & p & "])", "@" & desig & "[" & p & "]", "")
  of 'q', 'm', 'j':
    ("", "", "'" & desig & "' is a three-terminal device and carries more " &
             "than one current (" & currentParamsFor(letter).join(", ") &
             "); a single current quantity cannot say which one is meant")
  of 'x':
    ("", "", "'" & desig & "' is a subcircuit instance, which is a hierarchy " &
             "boundary rather than a device -- it has no terminal current of " &
             "its own. Name the part inside it")
  of 'a':
    ("", "", "'" & desig & "' is an XSPICE code model, whose ports are the " &
             "model's own and are not addressable as a device current")
  else:
    ("", "", "ngspice defines no terminal current for a '" & desig[0] &
             "' device")

proc saveCurrentsCard*(nl: Netlist, analysis: string): string =
  ## A `.save` card naming every device terminal current in `nl`, or `""`.
  ## The default save already has every unknown (node voltages, source and
  ## inductor currents); this adds derived device currents (`@r1[i]`).
  ##
  ## **`all` must lead**: naming any vector drops the default set.
  ##
  ## **Never emitted for `.ac`-family analyses**: ngspice writes the
  ## real-valued vector as a bare token in a complex plot, which
  ## `parseRawfile` rejects. (Also why `.options savecurrents` isn't used.)
  ##
  ## Off unless `$VERAX_SAVE_CURRENTS` is set. Can't move a solved number,
  ## only enlarge the rawfile.
  if getEnv("VERAX_SAVE_CURRENTS").len == 0: return ""
  if analysisWord(analysis) notin realPlotAnalyses: return ""
  var toks = @["all"]
  for c in nl.components.values:
    # A part with children is an `X` instance; its interior isn't
    # addressable.
    if c.subNetlist != nil: continue
    let desig = spiceFormat.deckDesignator(c)
    if desig.len == 0: continue
    for param in currentParamsFor(desig[0].toLowerAscii):
      toks.add "@" & desig & "[" & param & "]"
  if toks.len == 1: return ""
  ".save " & toks.join(" ")

proc run*(nl: Netlist, analysis: string, setup: seq[string] = @[],
          codemodels: seq[string] = @[], label = "",
          bench = BenchInfo()): SimResult =
  ## Runs `nl` through ngspice in batch mode and returns the vectors.
  ##
  ## **`analysis` and `setup` are separate**: only one analysis plot can be
  ## returned, but `.ic`/`.nodeset`/`.options`/`.param`/`.temp` configure that
  ## analysis without producing a plot. Setup cards are written first, then
  ## the analysis, then the control block; a known analysis in `setup`
  ## raises.
  ##
  ## The exit code isn't a reliable success signal (benign warnings can exit
  ## non-zero; a malformed deck can SIGABRT), so success is "a rawfile exists
  ## and parses"; the exit code and log go in the error otherwise.
  ##
  ## `codemodels` are XSPICE `.cm` paths, loaded with `pre_codemodel` (an `A`
  ## device must resolve at parse time) through `deckSafeCmPath`, since
  ## ngspice case-folds pre-parsed lines.
  if analysis.strip().len == 0:
    raise newException(SpiceSimError,
      "run() needs an analysis card (e.g. \".op\", \".tran 1u 1m\"); got an " &
      "empty one. A deck with only setup cards computes nothing.")
  for c in setup:
    if isAnalysisCard(c):
      raise newException(SpiceSimError,
        "run() was given the analysis card '" & c.strip() & "' as *setup*, " &
        "alongside the analysis '" & analysis.strip() & "'. Only one " &
        "analysis can be returned per call -- ngspice's default `write` " &
        "keeps only the last analysis's plot, and a SimResult holds one " &
        "plot. Setup means .ic/.nodeset/.options/.param/.temp; run the " &
        "second analysis as its own call.")

  var cards = setup & @[analysis]

  # Prepended for legibility; a `.save` card's position doesn't matter.
  let saveCard = saveCurrentsCard(nl, analysis)
  if saveCard.len > 0: cards = @[saveCard] & cards

  # Choose the archive slot before writing, so the archived deck is the one
  # that ran.
  let (keepDir, slot) = archiveSlot()
  let archiving = keepDir.len > 0
  let workDir = if archiving: keepDir else: createTempDir("verax_spice_", "")
  let stem = if archiving: slot else: "deck"

  let deckPath = workDir / (stem & ".cir")
  let rawPath = workDir / (stem & ".raw")
  let logPath = workDir / (stem & ".log")

  let started = epochTime()
  var status = "failed"
  var plot, dataText = ""
  var nvars, npoints = 0
  var runError = ""
  try:
  # The netlist's components say which code models survived cloning,
  # flattening, substitution and isolation; an explicit argument still
  # wins.
    var allCms = @codemodels
    for cm in collectCodeModels(nl):
      if cm notin allCms: allCms.add cm

    for cm in allCms:
      if not fileExists(cm):
        raise newException(SpiceSimError,
          "the netlist needs XSPICE code model '" & cm & "', which does not " &
          "exist. Build it with `verax/spice/xspice/build.buildCodeModel`; " &
          "that needs $NGSPICE_SRC pointing at a configured ngspice source " &
          "tree. Without it ngspice fails with `unable to find definition of " &
          "model`, which names the model and not the missing file.")

    var fullCards = cards
    fullCards.add ".control"
    for cm in allCms:
      fullCards.add "pre_codemodel " & deckSafeCmPath(cm)
    fullCards.add "run"
    fullCards.add "set filetype=ascii"
    fullCards.add "write " & rawPath
    fullCards.add ".endc"
    writeDeckFile(nl, fullCards, deckPath)
    keepDeck(deckPath)
    keepSchematic(nl, keepDir, stem)

    let process = startProcess("ngspice", args = @["-b", "-o", logPath, deckPath],
                                options = {poUsePath})
    let exitCode = process.waitForExit()
    process.close()

    let log = if fileExists(logPath): readFile(logPath) else: ""

    if not fileExists(rawPath):
      raise newException(SpiceSimError,
        "ngspice produced no output (exit code " & $exitCode & "):\n" & log)

    # A rawfile isn't a solution: a failed DC solve is only a warning, and
    # the last iterate is written with exit code zero (a floating node can
    # read as a plausible wrong voltage). Only markers meaning the solve
    # *failed* count -- gmin/source stepping announcements usually precede
    # success.
    for marker in ["singular matrix", "iteration limit reached",
                   "too many iterations", "no convergence"]:
      if marker in log.toLowerAscii:
        var detail = ""
        for line in log.splitLines:
          if marker in line.toLowerAscii:
            detail = line.strip
            break
        raise newException(SpiceSimError,
          "ngspice did not converge on a solution (" & detail & "). The " &
          "values it wrote are its last iterate, not an answer, so they are " &
          "not reported. A singular matrix usually means a node with no DC " &
          "path to ground -- a capacitor-only node, a bootstrap pin, or an " &
          "AC-coupled input.")

    try:
      result = parseRawfile(rawPath)
    except SpiceSimError:
      raise
    except CatchableError as e:
      raise newException(SpiceSimError,
        "failed to parse ngspice output: " & e.msg & "\nngspice log:\n" & log)

    status = "ok"
    plot = result.plotName
    dataText = (if result.dataKind == sdComplex: "complex" else: "real")
    nvars = result.vectors.len
    for v in result.vectors.values:
      npoints = (case v.kind
                 of sdReal: v.values.len
                 of sdComplex: v.cvalues.len)
      break
  except CatchableError as e:
    runError = e.msg
    raise
  finally:
    if runObserver != nil:
      var rec = RunRecord(label: label, analysis: analysis, setup: setup,
                          netlist: nl, ok: status == "ok", error: runError,
                          ms: int((epochTime() - started) * 1000),
                          bench: bench)
      if rec.ok: rec.result = result
      try:
        if fileExists(logPath): rec.log = readFile(logPath)
        if fileExists(deckPath): rec.deck = readFile(deckPath)
      except CatchableError:
        discard
      notifyRunObserver(rec)
    if archiving:
      var rawBytes = 0
      try:
        if fileExists(rawPath): rawBytes = int(getFileSize(rawPath))
      except CatchableError:
        discard
      appendIndex(keepDir, stem, status, label, analysis, setup, nl.name,
                  plot, dataText, nvars, npoints, rawBytes,
                  int((epochTime() - started) * 1000))
    else:
      removeDir(workDir)
proc run*(nl: Netlist, cards: seq[string],
          codemodels: seq[string] = @[], label = "",
          bench = BenchInfo()): SimResult =
  ## The older one-seq shape. More than one card raises rather than guess
  ## which is the analysis; use `run(nl, analysis, setup = ...)`.
  if cards.len == 0:
    raise newException(SpiceSimError,
      "run() needs an analysis card; got none")
  if cards.len > 1:
    var analyses, setups: seq[string]
    for c in cards:
      if isAnalysisCard(c): analyses.add c.strip() else: setups.add c.strip()
    if analyses.len > 1:
      raise newException(SpiceSimError,
        "run() returns one plot per call and was given " & $analyses.len &
        " analysis cards (" & analyses.join(", ") & "): only the last " &
        "analysis's plot survives ngspice's default `write`. Run each as " &
        "its own call.")
    raise newException(SpiceSimError,
      "run(nl, @[...]) does not know which of " & $cards.len & " cards is " &
      "the analysis. This overload takes exactly one. For setup plus an " &
      "analysis -- " & (if setups.len > 0: setups.join(", ") & " with " &
      (if analyses.len == 1: analyses[0] else: "an analysis")
      else: "e.g. .ic with .tran ... uic") &
      " -- call run(nl, analysis, setup = @[...]), which says which is which.")
  run(nl, cards[0], @[], codemodels, label, bench)

