## `ngspice` simulation backend, implementing the contract documented in
## `nimcir/spice/backend`.
##
## Several behaviors below were verified empirically against the locally
## installed ngspice-46 rather than assumed, because the CLI's exit code and
## output formats have real surprises -- see `run` and `parseRawfile`.

import std/[complex, streams, osproc, os, strutils, tables, tempfiles, times]
import ../netlist/types
import ../netlist/formats/spice as spiceFormat
import ../schematic
import ./backend
import ./xspice/cmpath
import ./xspice/instance

export backend

proc writeDeck*(nl: Netlist, cards: seq[string], s: Stream) =
  spiceFormat.writeNetlist(nl, s, cards)

proc writeDeckFile*(nl: Netlist, cards: seq[string], path: string) =
  spiceFormat.writeNetlistFile(nl, path, cards)

proc parseComplexTok(tok, path: string): Complex64 =
  ## One `real,imag` rawfile token. Raises `SpiceSimError` rather than
  ## `ValueError`/`IndexDefect` so a malformed complex plot surfaces the same
  ## way every other unusable-output condition in this module does.
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
  ## Parses the ASCII rawfile format written by ngspice's
  ## `set filetype=ascii; write <path>` inside a `.control` block. Verified
  ## against real `.op`/`.tran`/`.ac` output.
  ##
  ## `Flags: complex` (produced by `.ac`) selects the `sdComplex` branch of
  ## `SimVector`, where each value is written as a bare `real,imag` pair with
  ## no space around the comma:
  ##
  ## ```
  ## Values:
  ##  0\t1.000000000000000e+01,0.000000000000000e+00
  ## \t9.999605231408795e-01,-6.282937266758387e-03
  ## ```
  ##
  ## The line shape is otherwise identical between the two: the first
  ## variable shares the point-index line, every other variable gets its own.
  ## The flag is known before any value is read (`Flags:` precedes `Values:`),
  ## so each vector is constructed on the correct variant branch up front.
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

proc keepSchematic(nl: Netlist, dir, slot: string) =
  ## Renders the derived netlist once and writes it as a self-contained SVG
  ## and its schematic-scene JSON beside the deck, rawfile and log in a run
  ## archive, when one is being kept.
  ##
  ## Both files come from the one routed scene, and that scene is a pure
  ## function of the netlist that is already in hand, so drawing it cannot
  ## change what is simulated -- the same rule the archive itself obeys. Best
  ## effort, like `keepDeck`: a rendering failure must never be able to fail
  ## a run.
  if dir.len == 0: return
  try:
    writeScenePair(layout(nl, archiveLayoutOptions()), dir / slot)
  except CatchableError:
    discard

proc keepDeck(deckPath: string) =
  ## Copies the deck just handed to ngspice into `$NIMCIR_KEEP_DECKS`, if set.
  ##
  ## Every deck this module writes lives in a temporary directory that the
  ## `finally` below deletes, which is right for a tool that runs dozens of
  ## simulations per check and wrong for the one moment that matters: a claim
  ## has reported a number you do not believe, and the only way to find out
  ## whether the circuit or the fragment is at fault is to read what was
  ## actually simulated. The fragments here are *derived* -- isolated,
  ## terminated, model-substituted -- so they are not the netlist anyone
  ## wrote, and reasoning about them from the design file is guesswork.
  ##
  ## Off unless the variable is set, and it never changes what is simulated.
  let dir = getEnv("NIMCIR_KEEP_DECKS")
  if dir.len == 0: return
  try:
    createDir(dir)
    var i = 0
    while fileExists(dir / ("deck" & $i & ".cir")): inc i
    copyFile(deckPath, dir / ("deck" & $i & ".cir"))
  except CatchableError:
    discard  # a debugging aid must never be able to fail a simulation

const runIndexFile* = "index.txt"
  ## The manifest inside a `$NIMCIR_KEEP_RUNS` directory. A rawfile does not
  ## say which circuit or which analysis produced it, and the fragment
  ## simulated is derived rather than authored, so a directory of `run000` ..
  ## `run012` with nothing beside it answers none of the questions a reader
  ## opens it with.

proc runSlotName(i: int): string =
  ## Zero-padded so `ls` sorts an archive in the order the runs happened.
  "run" & align($i, 3, '0')

proc archiveSlot(): tuple[dir, slot: string] =
  ## Picks where this run's deck, rawfile and log are going to be written.
  ##
  ## `keepDeck` copies a deck *after the fact*; this instead chooses the
  ## destination up front, so ngspice writes all three artifacts straight into
  ## the archive. That is not merely fewer steps: the deck kept is then
  ## byte-identical to the one that ran, `write` inside it names the rawfile
  ## sitting next to it, and the whole run is reproducible by handing that
  ## file back to ngspice.
  ##
  ## Off unless `$NIMCIR_KEEP_RUNS` is set, and it never changes what is
  ## simulated. Any failure yields `("", "")` and a normal temp-directory run,
  ## on the same reasoning as `keepDeck`: an archive is a debugging aid and
  ## must never be able to fail a simulation.
  let dir = getEnv("NIMCIR_KEEP_RUNS")
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
  ## One tab-separated row per run, header written when the file is created.
  ##
  ## A failed run gets a row too, and its `status` says so. That is the run
  ## whose deck and log are worth reading, and both are already on disk by the
  ## time anything raises.
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
  ## Dot cards that make ngspice *run an analysis* and produce a plot of its
  ## own. Used only to refuse one in the `setup` slot -- nothing here tries to
  ## decide what an unknown card is, on the same reasoning as
  ## `parseSpiceMagnitude`: refuse what is known to be wrong rather than
  ## require what is guessed to be right.

proc analysisWord(card: string): string =
  ## The bare card name, lowercased: `".tran 1u 1m uic"` -> `"tran"`. Empty
  ## for anything that is not a dot card.
  let t = card.strip().toLowerAscii()
  if not t.startsWith("."): return ""
  t[1 .. ^1].split({' ', '\t'})[0]

proc isAnalysisCard*(card: string): bool =
  analysisWord(card) in analysisCards

const realPlotAnalyses = ["op", "tran", "dc"]
  ## The analyses whose plot is real-valued, and therefore the only ones a
  ## device-current `.save` may be attached to. See `saveCurrentsCard`.

proc currentParamsFor(letter: char): seq[string] =
  ## Which `@dev[...]` currents exist for a device letter, mirroring
  ## ngspice's own table in `src/frontend/inp.c` (`inp_savecurrents`).
  ##
  ## `v` is deliberately absent: a voltage source's branch current is an MNA
  ## unknown and is already in the default saved set. So are `x` (a subcircuit
  ## instance) and `a` (an XSPICE code model), neither of which has terminal
  ## currents to ask for -- ngspice's walk skips both the same way, through
  ## its `default: continue`.
  case letter
  of 'r', 'c', 'l', 'b', 'f', 'g', 'w', 's': @["i"]
  of 'd': @["id"]
  of 'q': @["ic", "ie", "ib"]
  of 'm': @["id", "is", "ig", "ib"]
  of 'j': @["id", "is", "ig"]
  of 'i': @["current"]
  else: @[]

proc branchCurrentVector*(desig: string): tuple[vector, saveTerm, reason: string] =
  ## Where the current through the device written as `desig` shows up in a
  ## rawfile, and what has to be asked for to make it show up at all.
  ##
  ## **Two shapes, and the split is not cosmetic**: it is whether the current
  ## is an *unknown of the matrix* or a quantity computed from the solution
  ## afterwards. A voltage source, an inductor and the two controlled sources
  ## that carry a branch equation (`E`, `H`) are solved *for* their current,
  ## so it is in the default saved set under `i(l1)` and needs no `.save`.
  ## Every other device's terminal current is derived from the node voltages
  ## after the fact, never appears unless named, and reads back as
  ## `i(@r1[i])`. Both spellings verified against ngspice-46 rather than taken
  ## from the manual, which documents the *vector namespace* names (`l1#branch`,
  ## `@r1[i]`) rather than the ones the rawfile writer emits.
  ##
  ## An empty `vector` means there is no single current to ask for, and
  ## `reason` says why in the terms a reader can act on. **Refusing is the
  ## point for a three-terminal device**: a transistor has a collector, an
  ## emitter and a base current, "the current through Q1" does not say which,
  ## and picking one silently would answer a question nobody asked.
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
  ##
  ## **What ngspice saves by default is already everything it has as an
  ## unknown** -- every node voltage plus every voltage-source and inductor
  ## branch current (written `i(v1)`, `i(l1)`; see `branchCurrentVector`)
  ## -- because with no `save` at all the output stage
  ## starts at `saveall` and only drops to an allowlist once one exists. So
  ## this exists for the one category that is genuinely absent: device
  ## *internals* (`@r1[i]`, `@d2[id]`), which are computed from the solution
  ## rather than being part of it and never appear unless asked for.
  ##
  ## **`all` has to lead the list.** Naming any vector turns the default set
  ## off, so a card that said only `@r1[i]` would archive a rail's resistor
  ## current and throw away the rail.
  ##
  ## **Never emitted for an `.ac`-family analysis, and that is not caution.**
  ## A `@r1[i]` is a real-valued vector; in a complex plot ngspice writes it
  ## as a bare real token in among the `real,imag` pairs, and `parseRawfile`
  ## rejects the line as malformed -- so switching this on would turn every
  ## frequency sweep in the library into a parse error. This is also why the
  ## card is built here rather than by asking for `.options savecurrents`,
  ## which injects at parse time whatever analysis follows (and which the
  ## simulator's own option table does not know, so it reports an `unknown
  ## option` error into the log of every run that uses it).
  ##
  ## Off unless `$NIMCIR_SAVE_CURRENTS` is set. Selecting more output cannot
  ## move a solved number -- a `.save` is read after the matrix is solved --
  ## but it does multiply the size of an archived rawfile.
  if getEnv("NIMCIR_SAVE_CURRENTS").len == 0: return ""
  if analysisWord(analysis) notin realPlotAnalyses: return ""
  var toks = @["all"]
  for c in nl.components.values:
    # A part with children is written as an `X` instance, and its interior is
    # not addressable from the top level.
    if c.subNetlist != nil: continue
    let desig = spiceFormat.deckDesignator(c)
    if desig.len == 0: continue
    for param in currentParamsFor(desig[0].toLowerAscii):
      toks.add "@" & desig & "[" & param & "]"
  if toks.len == 1: return ""
  ".save " & toks.join(" ")

proc run*(nl: Netlist, analysis: string, setup: seq[string] = @[],
          codemodels: seq[string] = @[], label = ""): SimResult =
  ## Runs `nl` through ngspice in batch mode and returns the resulting
  ## vectors.
  ##
  ## **`analysis` and `setup` are separate because they are different things,
  ## and conflating them cost a real capability.** ngspice's default `write`
  ## keeps only the last analysis's plot, and `SimResult` holds exactly one
  ## plot, so two *analyses* per call genuinely cannot both be returned --
  ## that is what the old one-card-per-call rule protected. But `.ic`,
  ## `.nodeset`, `.options`, `.param` and `.temp` are not analyses. They
  ## configure the single analysis that follows and produce no plot at all,
  ## and the old rule counted them anyway: `run(nl, @[".ic v(out)=0.1",
  ## ".tran 1u 10m uic"])` was refused for being "two cards" when it is one
  ## analysis with one setup line. `docs/findings.md` §23 attributed the
  ## oscillator blocker to `run` needing to accept more than one card; it
  ## needed to stop counting setup as analysis.
  ##
  ## Setup cards are written first, then the analysis card, then the control
  ## block. A card in `setup` that is a *known* analysis raises, because that
  ## is the case the original guard existed to catch.
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

  # Prepended rather than appended only for legibility in an archived deck;
  # a `.save` *card* is harvested at parse time, so unlike the `save` control
  # command its position does not matter.
  let saveCard = saveCurrentsCard(nl, analysis)
  if saveCard.len > 0: cards = @[saveCard] & cards

  # Where the three artifacts are written is decided here, before anything is
  # written, so that an archived run is the deck that actually ran rather than
  # a copy of it -- and so the `write` line inside it names the rawfile lying
  # next to it.
  let (keepDir, slot) = archiveSlot()
  let archiving = keepDir.len > 0
  let workDir = if archiving: keepDir else: createTempDir("nimcir_spice_", "")
  let stem = if archiving: slot else: "deck"

  let deckPath = workDir / (stem & ".cir")
  let rawPath = workDir / (stem & ".raw")
  let logPath = workDir / (stem & ".log")

  let started = epochTime()
  var status = "failed"
  var plot, dataText = ""
  var nvars, npoints = 0
  try:
    # What the deck needs is a property of the *netlist*, and by the time a
    # fragment reaches here it has been cloned, flattened, model-substituted
    # and isolated -- so the caller three layers up is in no position to know
    # which code models survived. The netlist carries the answer on the
    # components themselves, and an explicit argument still wins.
    var allCms = @codemodels
    for cm in collectCodeModels(nl):
      if cm notin allCms: allCms.add cm

    for cm in allCms:
      if not fileExists(cm):
        raise newException(SpiceSimError,
          "the netlist needs XSPICE code model '" & cm & "', which does not " &
          "exist. Build it with `nimcir/spice/xspice/build.buildCodeModel`; " &
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

    # A rawfile is not the same as a solution. ngspice reports a failed DC
    # solve as a *warning*, writes whatever its last iterate was, and exits
    # zero -- so the numbers arrive looking exactly like an answer. The
    # LT8640A reference design found this: one node left floating at DC made
    # the matrix singular and the rail read 1.71 V instead of 4.96, as a
    # clean FAIL against a real number rather than as an error.
    # Only markers that mean the solve *failed*, not ones that mean a strategy
    # was tried and abandoned. ngspice attempts dynamic gmin stepping, then
    # true gmin stepping, then source stepping, announcing each failure as it
    # goes -- and then very often succeeds. Treating those as fatal declared
    # the TS808's perfectly good bias-finding .op a failure, which took its
    # large-signal drive offset to 0 V and its output swing with it.
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
  finally:
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
          codemodels: seq[string] = @[], label = ""): SimResult =
  ## The older shape, kept because every existing call site passes a
  ## single-element seq and there is nothing wrong with those calls.
  ##
  ## More than one card still raises here rather than being split by
  ## guesswork: this overload cannot know which of them the caller meant as
  ## the analysis, and picking one would be exactly the silent decision the
  ## rest of this module refuses to make. Say which is which by calling
  ## `run(nl, analysis, setup = ...)` instead.
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
  run(nl, cards[0], @[], codemodels, label)

