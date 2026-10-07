## Building `SParams` from a Touchstone (`.sNp`) stream, via
## `readTouchstone(s)`/`readTouchstoneFile(path)`. No writer.
##
## **A v1 file doesn't state its port count**; the extension does (`.s2p`).
## So `name` must end in `.s<N>p` (case-insensitive); otherwise it raises
## rather than guess a column stride. (v2's `[Number of Ports]` isn't
## supported.)
##
## Every failure is a `TouchstoneError` with line context where available;
## `!` comments are stripped first. A data row either has the right column
## count or the file is malformed.

import std/[complex, math, streams, strutils]
import ./types
import ./parse

export types

type
  Token = tuple[line: int, text: string]

proc extractPortCount(name: string): int =
  ## `N` from a `.sNp` suffix, or 0 (never legal) so the caller can raise
  ## naming the file.
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
  ## Parses a Touchstone stream into `SParams`. Raises `TouchstoneError` if
  ## `name` lacks the `.sNp` extension, the option line is missing or bad, or
  ## a row doesn't fit `1 + 2*nPorts*nPorts` numbers.
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

  # Disk column order is row-major except for 2 ports (S11 S21 S12 S22);
  # `diskDataOrder` maps disk pair -> row-major index.
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
  ## `readTouchstone` on a file, using `path` as `name`. Raises
  ## `TouchstoneError` if it can't be opened.
  var s: FileStream
  try:
    s = openFileStream(path, fmRead)
  except IOError, OSError:
    raise newException(TouchstoneError, "cannot open Touchstone file: " & path)
  defer: s.close()
  readTouchstone(s, path)
