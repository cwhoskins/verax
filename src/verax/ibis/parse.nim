## The IBIS *lexer*: `.ibs` text into a tree of `IbisSection`s, with no
## knowledge of keyword meaning -- so unmodelled keywords survive a load
## (the whole tree is kept in `IbisFile.sections`).
##
## Grammar points whose mishandling is silent:
##
## - **`[Comment Char]` redefines the comment character** (default `|`) from
##   that line on.
## - **Keywords are case-insensitive and space/underscore-equivalent**
##   (`canonicalKeyword`).
## - **A keyword's `[` is in column 1**; elsewhere it's data.
## - **`[End]` ends the file**; anything after is ignored.
## - **`NA` is any absent number**, not zero.
##
## The 120-character line limit isn't enforced; real files exceed it.

import std/[streams, strutils, parseutils, tables, sets]
import ./types

const DefaultCommentChar = '|'

let metricPrefix = {
  'T': 1e12, 'G': 1e9, 'M': 1e6, 'k': 1e3, 'K': 1e3,
  'm': 1e-3, 'u': 1e-6, 'n': 1e-9, 'p': 1e-12, 'f': 1e-15,
}.toTable
  ## IBIS scaling factors. **`M` is mega, `m` milli**. No `meg` (that's
  ## SPICE, not IBIS).

let topLevelKeywords = [
  "ibis_ver", "comment_char", "file_name", "file_rev", "date", "source",
  "notes", "disclaimer", "copyright", "component", "model", "model_selector",
  "submodel", "external_model", "external_circuit", "define_package_model",
  "end_package_model", "begin_board_description", "end_board_description",
  "begin_sim_data", "end_sim_data", "end",
].toHashSet
  ## Keywords that close any open `[Component]`/`[Model]`/`[Model
  ## Selector]`. Anything else met while one is open becomes its child.

proc canonicalKeyword*(k: string): string =
  ## Lowercase, collapsing runs of spaces/underscores to one underscore
  ## (`[gnd  clamp]` -> `gnd_clamp`).
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
  ## Parses one IBIS number: a float, an optional metric prefix, an optional
  ## unit word (`V`, `A`, `ohm`, `F`, `H`, `s`), scaled to SI. Refuses rather
  ## than guesses (leaving `value` untouched): `NA` returns false (test
  ## `isNA` first), and so does RKM like `2k2`.
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
  ## Reads up to three tokens from `first` as `typ min max`. `NA` or a
  ## missing column leaves a corner absent; anything else non-numeric raises.
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
  ## Splits on every column-1 `[Keyword]` line, honouring `[Comment Char]`
  ## and stopping at `[End]`.
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
      # Parse the bracket from raw text: `[Comment Char] |_char` carries the
      # comment character as its argument.
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
      # Drop body lines before any keyword (stray BOMs, editor artefacts).
  if haveCur: result.add cur

proc nest(flat: seq[LexSection]): seq[IbisSection] =
  ## Attach sub-keywords (`[Pulldown]`, `[Pin]`, ...) to the container block
  ## they follow.
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
      # End keywords aren't top-level; handled here.
    elif ls.keyword in ["end_model", "end_model_selector"]:
      container = -1
    elif container >= 0:
      result[container].children.add sec
    else:
      result.add sec

proc splitSections*(s: Stream, name = ""): seq[IbisSection] =
  ## Lex an IBIS stream into its keyword tree (`name` is for messages).
  ## Raises `IbisError` on a structurally broken keyword line.
  discard name
  var commentChar = DefaultCommentChar
  nest(lexFlat(s, commentChar))
