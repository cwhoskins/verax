## The IBIS *lexer*: turning `.ibs` text into a tree of `IbisSection`s,
## with no knowledge of what any keyword means.
##
## It is kept separate from `nimcir/ibis/reader` (the typed layer) for one
## concrete reason: a keyword this library does not model must still survive
## a load. The reader builds `IbisFile.components`/`.models` from this tree
## and keeps the whole tree in `IbisFile.sections`, so opening a 7.x file
## with a 3.2-shaped reader loses nothing -- the unmodelled blocks are simply
## still there, verbatim.
##
## What the IBIS grammar forces this module to get right, each recorded
## because getting it wrong is silent:
##
## - **The comment character defaults to `|` but `[Comment Char]` redefines
##   it**, taking effect from that line on. A file that sets it to `#` and
##   then uses `|` as data parses to garbage under a hard-coded `|`.
## - **Keywords are case-insensitive and space/underscore-equivalent.**
##   `[GND Clamp]` and `[GND_Clamp]` are the same keyword; hence
##   `canonicalKeyword`.
## - **A keyword's `[` is in column 1.** A `[` anywhere else on a line is
##   ordinary data (a bus subscript, a table value).
## - **`[End]` ends the file.** Text after it is ignored, not an error.
## - **`NA` stands in for any absent number** and is not zero -- see
##   `nimcir/ibis/types` on `Triplet`.
##
## Deliberately not enforced: the spec's 120-character line limit. Real
## vendor files exceed it routinely and rejecting them helps nobody.

import std/[streams, strutils, parseutils, tables, sets]
import ./types

const DefaultCommentChar = '|'

let metricPrefix = {
  'T': 1e12, 'G': 1e9, 'M': 1e6, 'k': 1e3, 'K': 1e3,
  'm': 1e-3, 'u': 1e-6, 'n': 1e-9, 'p': 1e-12, 'f': 1e-15,
}.toTable
  ## IBIS scaling factors. **`M` is mega and `m` is milli** -- the same
  ## case-sensitivity trap `nimcir/netlist/formats/spice.parseSpiceMagnitude`
  ## documents for decks. `meg` (SPICE's mega) is deliberately absent: it is
  ## not IBIS.

let topLevelKeywords = [
  "ibis_ver", "comment_char", "file_name", "file_rev", "date", "source",
  "notes", "disclaimer", "copyright", "component", "model", "model_selector",
  "submodel", "external_model", "external_circuit", "define_package_model",
  "end_package_model", "begin_board_description", "end_board_description",
  "begin_sim_data", "end_sim_data", "end",
].toHashSet
  ## Keywords that never belong to an open `[Component]` / `[Model]` /
  ## `[Model Selector]` -- meeting one closes whatever container was open.
  ## Anything else met while a container is open is attached to it as a child.

proc canonicalKeyword*(k: string): string =
  ## Lowercase, and collapse every run of spaces/underscores to one
  ## underscore. `[GND Clamp]`, `[GND_Clamp]` and `[gnd  clamp]` all yield
  ## `gnd_clamp`.
  var prevSep = false
  for ch in k.strip():
    if ch in {' ', '\t', '_'}:
      if not prevSep: result.add '_'
      prevSep = true
    else:
      result.add toLowerAscii(ch)
      prevSep = false
  result.strip(chars = {'_'})

proc isNA*(tok: string): bool {.inline.} =
  ## IBIS `NA` -- the token that means "this corner was not characterised".
  cmpIgnoreCase(tok, "NA") == 0

proc parseIbisNumber*(text: string, value: var float): bool =
  ## Parses one IBIS numeric token: a float, an optional single metric
  ## prefix, and an optional trailing unit word (`V`, `A`, `ohm`, `F`, `H`,
  ## `s`). On success sets `value` (scaled to SI base units) and returns
  ## true; on anything it will not vouch for it leaves `value` untouched and
  ## returns false.
  ##
  ## Shaped like `parseSpiceMagnitude`: a `bool` + `var` out-param that
  ## **refuses rather than guesses**, because a silently-wrong exponent is
  ## worse than a rejected file. `NA` returns false (callers test `isNA`
  ## first to tell absence from error), and so does a digit after the prefix
  ## -- IBIS has no RKM notation and `2k2` is a malformed token, not 2200.
  let s = text.strip()
  if s.len == 0 or isNA(s): return false
  var f: float
  let n = parseutils.parseFloat(s, f)
  if n == 0: return false
  var rest = s[n .. ^1]
  var scale = 1.0
  if rest.len > 0 and rest[0] in metricPrefix:
    scale = metricPrefix[rest[0]]
    rest = rest[1 .. ^1]
  for ch in rest:
    if ch notin {'a'..'z', 'A'..'Z', '/'}:
      return false
  value = f * scale
  true

proc parseTriplet*(toks: openArray[string], first = 0): Triplet =
  ## Reads up to three tokens starting at `first` as a `typ min max` group.
  ## `NA` (or a missing column) leaves that corner absent; a token that is
  ## neither `NA` nor a number raises `IbisError`.
  result = newTriplet()
  for k in 0 .. 2:
    let idx = first + k
    if idx >= toks.len: break
    let tok = toks[idx]
    if isNA(tok): continue
    var v: float
    if not parseIbisNumber(tok, v):
      raise newException(IbisError, "not an IBIS number: '" & tok & "'")
    result.set(Corner(k), v)

type
  LexSection = object
    keyword, rawKeyword, args: string
    line: int
    body: seq[IbisLine]

proc lexFlat(s: Stream, commentChar: var char): seq[LexSection] =
  ## Splits the stream into flat sections on every column-1 `[Keyword]`
  ## line, honouring `[Comment Char]` as it goes and stopping at `[End]`.
  proc stripComment(text: string, cc: char): string =
    let cix = text.find(cc)
    (if cix >= 0: text[0 ..< cix] else: text)

  var lineNo = 0
  var cur: LexSection
  var haveCur = false
  var line: string
  while s.readLine(line):
    inc lineNo

    if line.len > 0 and line[0] == '[':
      # A keyword line. Parse the bracket from the raw text: the comment
      # character must not be stripped first, since `[Comment Char] |_char`
      # legitimately carries the current comment character as its argument.
      let close = line.find(']')
      if close < 0:
        raise newException(IbisError,
          "line " & $lineNo & ": '[' in column 1 with no matching ']'")
      let raw = line[1 ..< close].strip()
      let canon = canonicalKeyword(raw)
      var args = line[close + 1 .. ^1]

      if canon == "comment_char":
        # `[Comment Char] #_char` -- first token, first character.
        let tok = args.strip().splitWhitespace()
        if tok.len == 0 or tok[0].len == 0:
          raise newException(IbisError,
            "line " & $lineNo & ": [Comment Char] with no character")
        commentChar = tok[0][0]
        args = args.strip()
      else:
        args = stripComment(args, commentChar).strip()

      if haveCur: result.add cur
      cur = LexSection(keyword: canon, rawKeyword: raw, args: args, line: lineNo)
      haveCur = true

      if canon == "end":
        result.add cur
        return
    else:
      let text = stripComment(line, commentChar).strip()
      if text.len == 0:
        continue
      if haveCur:
        cur.body.add (lineNo, text)
      # A body line before any keyword is not legal IBIS; drop it rather than
      # crash on a stray BOM or editor artefact at the top of a file.
  if haveCur: result.add cur

proc nest(flat: seq[LexSection]): seq[IbisSection] =
  ## Second pass: attach `[Pulldown]`, `[Ramp]`, `[Pin]` and friends to the
  ## `[Model]` / `[Component]` / `[Model Selector]` block they follow.
  var container = -1     # index into `result`, or -1
  for ls in flat:
    let sec = IbisSection(keyword: ls.keyword, rawKeyword: ls.rawKeyword,
                          line: ls.line, args: ls.args, body: ls.body)
    if ls.keyword == "end":
      result.add sec
      return
    if ls.keyword in topLevelKeywords:
      result.add sec
      container =
        if ls.keyword in ["component", "model", "model_selector"]:
          result.len - 1
        else:
          -1
      # `[End Model]` / `[End Model Selector]` are not in topLevelKeywords;
      # they arrive here as ordinary keywords and are handled below.
    elif ls.keyword in ["end_model", "end_model_selector"]:
      container = -1
    elif container >= 0:
      result[container].children.add sec
    else:
      result.add sec

proc splitSections*(s: Stream, name = ""): seq[IbisSection] =
  ## Lex an IBIS stream into its keyword tree. `name` is only used in error
  ## messages. Raises `IbisError` on a structurally broken keyword line.
  discard name
  var commentChar = DefaultCommentChar
  nest(lexFlat(s, commentChar))
