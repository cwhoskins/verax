## Building the typed `SParams` from a Touchstone (`.sNp`) stream.
##
## Implements the file-format contract's spelling used elsewhere in this
## codebase -- `readTouchstone(s: Stream)` / `readTouchstoneFile(path)`,
## names that do not stutter the format, matching `verax/ibis/reader` and
## `verax/netlist/formats/common`. There is **no writer**: emitting
## Touchstone is not a stated need here, and `verax/ibis/reader`'s reason for
## the same choice applies verbatim -- a half-writer is worse than none.
##
## **A Touchstone (version 1) file never states its own port count.** The
## number of ports is a property of the *filename extension* by convention
## (`.s1p`, `.s2p`, `.s25p`), not of anything inside the file -- version 2
## adds an explicit `[Number of Ports]` keyword, which this reader does not
## implement, matching the scope this phase set for the S-parameter reader.
## So `readTouchstone` needs `name` to end in `.s<N>p` (case-insensitive) to
## know what shape to expect from the data rows that follow; a stream handed
## in with no such name, or a caller that changes it, would otherwise force
## a guess about how many columns the data section holds, and a wrong guess
## reads every subsequent number off by a stride. Refusing here is the same
## call `ibis/parse.parseIbisNumber` makes for a suffix it will not vouch
## for: a `TouchstoneError` naming what is missing beats a matrix that looks
## complete but was assembled from the wrong column count.
##
## Two behaviours carried over from `verax/ibis/reader`'s own borrowing from
## `verax/netlist/formats/spice`: every failure is a `TouchstoneError` **with
## line context** wherever the lexer can supply it, and comment text (`!` to
## end of line, anywhere -- including trailing an option or data line) is
## stripped before anything downstream sees the line. Unlike IBIS there is no
## degrade-and-keep path for unrecognised content: `parse.parseOptionLine`
## already explains why an option-line token cannot be safely skipped, and a
## data row has no "block" structure for unrecognised content to belong to
## in the first place -- it is either the right number of columns or the
## file is malformed.

import std/[complex, math, streams, strutils]
import ./types
import ./parse

export types

type
  Token = tuple[line: int, text: string]

proc extractPortCount(name: string): int =
  ## Pulls `N` out of a `.sNp`/`.SNp` filename suffix. Returns 0 (never a
  ## legal port count) when `name` does not match, so the caller can raise
  ## with the whole filename in the message rather than a bare "invalid".
  let lower = name.toLowerAscii()
  if not lower.endsWith("p"): return 0
  var i = lower.len - 2  # just before the trailing 'p'
  var j = i + 1
  while i >= 0 and lower[i] in {'0'..'9'}: dec i
  if i < 0 or i == j - 1: return 0            # no digits found
  if lower[i] != 's': return 0
  try: parseInt(lower[i + 1 ..< j])
  except ValueError: 0

proc stripComment(line: string): string =
  let bang = line.find('!')
  (if bang >= 0: line[0 ..< bang] else: line).strip()

proc toComplex(a, b: float, fmt: parse.DataFormat): Complex64 =
  case fmt
  of dfRI: complex(a, b)
  of dfMA:
    let rad = degToRad(b)
    complex(a * cos(rad), a * sin(rad))
  of dfDB:
    let mag = dbToVoltageRatio(a)
    let rad = degToRad(b)
    complex(mag * cos(rad), mag * sin(rad))

proc readTouchstone*(s: Stream, name = ""): SParams =
  ## Parses a Touchstone stream into the typed S-parameter matrix. `name`
  ## must carry the `.sNp` extension the port count is inferred from (see
  ## the module doc); raises `TouchstoneError` if it does not, if the option
  ## line is missing or unparseable, or if a data row does not divide evenly
  ## into `1 + 2*nPorts*nPorts` numbers.
  let nPorts = extractPortCount(name)
  if nPorts <= 0:
    raise newException(TouchstoneError,
      "cannot tell how many ports this file has: '" & name &
      "' does not end in .sNp (e.g. .s2p) -- a Touchstone v1 file states " &
      "its port count only in its filename, so pass one that carries it")

  var opt: parse.OptionLine
  var haveOpt = false
  var toks: seq[Token]
  var lineNo = 0
  var line: string
  while s.readLine(line):
    inc lineNo
    let text = stripComment(line)
    if text.len == 0: continue
    if not haveOpt:
      if text[0] != '#':
        raise newException(TouchstoneError,
          "line " & $lineNo & ": expected the option line ('# ...') before " &
          "any data: " & text.escape())
      opt = parse.parseOptionLine(text)
      haveOpt = true
      continue
    for t in text.splitWhitespace():
      toks.add (lineNo, t)

  if not haveOpt:
    raise newException(TouchstoneError, "no option line ('#...') found")
  if opt.param != ptS:
    raise newException(TouchstoneError,
      "not an S-parameter file (option line names a different parameter)")

  result.nPorts = nPorts
  result.z0 = opt.z0
  let scale = parse.freqScale(opt.freqUnit)
  let groupLen = 1 + 2 * nPorts * nPorts

  # The on-disk column order agrees with the row-major target order for
  # every port count except 2, whose historical layout is S11 S21 S12 S22 --
  # diskDataOrder maps disk pair index -> row-major target index, and is the
  # identity everywhere else. See `types.SParams.points` for why the target
  # is always row-major regardless.
  var diskDataOrder: seq[int]
  if nPorts == 2:
    diskDataOrder = @[0, 2, 1, 3]
  else:
    for m in 0 ..< nPorts * nPorts: diskDataOrder.add m

  var i = 0
  while i < toks.len:
    if i + groupLen > toks.len:
      raise newException(TouchstoneError,
        "line " & $toks[i].line & ": incomplete data row -- expected " &
        $groupLen & " numbers (1 frequency + " & $(nPorts * nPorts) &
        " " & $opt.format & " pairs for " & $nPorts & " ports), found " &
        $(toks.len - i))
    var f: float
    if not parseTouchstoneNumber(toks[i].text, f):
      raise newException(TouchstoneError,
        "line " & $toks[i].line & ": not a frequency: " &
        toks[i].text.escape())
    result.freqs.add f * scale

    var pt = newSeq[Complex64](nPorts * nPorts)
    for m in 0 ..< nPorts * nPorts:
      let base = i + 1 + 2 * m
      var a, b: float
      if not parseTouchstoneNumber(toks[base].text, a) or
         not parseTouchstoneNumber(toks[base + 1].text, b):
        raise newException(TouchstoneError,
          "line " & $toks[base].line & ": malformed " & $opt.format &
          " pair: '" & toks[base].text & " " & toks[base + 1].text & "'")
      pt[diskDataOrder[m]] = toComplex(a, b, opt.format)
    result.points.add pt

    i += groupLen

proc readTouchstoneFile*(path: string): SParams =
  ## Path wrapper around `readTouchstone`, passing `path` itself as the
  ## `name` the port count is read from -- the ordinary case, since a file
  ## on disk already carries its `.sNp` extension. Raises `TouchstoneError`
  ## if the file cannot be opened.
  var s: FileStream
  try:
    s = openFileStream(path, fmRead)
  except IOError, OSError:
    raise newException(TouchstoneError, "cannot open Touchstone file: " & path)
  defer: s.close()
  readTouchstone(s, path)
