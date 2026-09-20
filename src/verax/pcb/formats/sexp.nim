## A format-agnostic s-expression arena: lexer, DOM, verbatim renderer, and
## the three splice primitives a writer needs to regenerate part of a file
## while leaving the rest byte-identical.
##
## **No KiCad knowledge lives here.** `verax/pcb/formats/kicad` is the only
## consumer; this module knows nothing about `(footprint)`, `(net)` or what
## any keyword means, exactly as `verax/ibis/parse` (lexer) is kept separate
## from `verax/ibis/reader` (typed layer) so an unmodelled block still
## round-trips. That split is the entire reason this exists as two files
## instead of one: a KiCad keyword this library never learns must still
## survive a write, and the only way to guarantee that is for the layer that
## walks bytes to not know which bytes matter.
##
## **Byte-exactness is a property of the data structure, not of a
## pretty-printer.** `interf_u.kicad_pcb`'s own `(xy ...)`-per-line counts are
## 1x5, 2x12, 3x4, 4x2341, 5x135 -- no column-count rule explains that
## distribution, because KiCad's writer runs everything through a `Prettify()`
## pass this library cannot reproduce by rule. So every node here is an
## `(offset, length)` slice into the one `string` holding the whole file, and
## a node nothing has touched is written by copying its bytes. That disposes
## of escape-set, quoting-policy and number-formatting questions for every
## untouched node at once -- the raw bytes are already correct, and there is
## nothing to get subtly wrong about a value this module never re-derives.
##
## **The lexer never raises on a structural defect, only on an unindexable
## file.** `/usr/share/kicad/demos/royalblue54L_feather/RoyalBlue54L-Feather.kicad_pcb`
## is corrupt as shipped -- 349 occurrences of `)filter_ratio 0.9)` where
## `(filter_ratio 0.9)` was meant, each one missing its opening paren, which
## KiCad's own tool wrote and `kicad-cli pcb drc` reads without complaint
## (exit 0, "Found 283 violations, Found 0 unconnected items" -- it silently
## read about 1% of the file). Total `(` count is 125872 against 126221 `)`:
## exactly 349 more closes than opens, so **a stray `)` met with no open list
## is absorbed as ordinary content, never raised on** -- it becomes part of
## the gap text between whatever node ends before it and whatever starts
## after, which is exactly what the (offset, length) model already needs to
## get right for whitespace. A list still open at end-of-file is closed at
## EOF rather than raised on, for the same reason. This is what makes it true
## that "the s-expression layer round-trips this file structurally" while
## `kicad.readPcb` is the layer that refuses it, by name -- the alternative,
## raising here, would conflate a parser's inability to index a file with a
## semantic judgment that the file is not a legal board, and the latter is a
## `kicad.nim` question (does the file have exactly one well-formed root
## headed `kicad_pcb`?), not a lexer one.
##
## Two lexer rules earn their own explanation because getting them wrong
## corrupts data silently rather than failing loudly:
##
## - **Strings are never decoded on the way in.** `skString` spans quote to
##   quote inclusive, with escapes intact; `text()` decodes on demand and the
##   writer never re-encodes. An escape sequence this module does not
##   recognise still round-trips, because `raw()` never depended on
##   recognising it.
## - **Quoting is recorded, not re-derived.** `kind()` distinguishes `skAtom`
##   from `skString`, so `(0 "F.Cu" signal "top_cu")` -- an atom, a quoted
##   string, an atom, a quoted string, all four in one node -- keeps each
##   token's original quoting through a render with zero special-casing,
##   and `(net 0 "")` keeps its quotes on an empty string for the same
##   reason: quoting was never a decision this module makes.

import std/[tables, sets, strutils]

type
  SexpError* = object of CatchableError
    ## Raised only for what the arena genuinely cannot index -- a file over
    ## 2 GiB. Never raised for a structural defect in the input; see the
    ## module doc comment on why that split belongs to the caller.

  SexpKind* = enum
    skList    ## `( ... )`
    skAtom    ## bare token: `segment`, `0.8`, `yes`, `0x00_ff`
    skString  ## double-quoted token, raw, escapes intact

  SNode* = object
    ## 16 bytes exactly: two `int32` pairs, no padding. `off`/`len` slice
    ## `SexpDoc.src`; for a list they span `(` through the matching `)`
    ## inclusive, so an unmodified list is one substring copy.
    off*, len*: int32
    firstChild*: int32   ## -1 for an atom, a string, or an empty list
    nextSib*: int32      ## -1 at the end of a sibling chain

  SexpDoc* = ref object of RootObj
    src*: string                          ## the file, verbatim, held for its lifetime
    nodes*: seq[SNode]
    kinds*: seq[uint8]                    ## parallel to `nodes`, one byte each
    overrides*: Table[int32, string]      ## node -> regenerated text replacing it
    deleted*: HashSet[int32]              ## nodes dropped from the model
    inserted*: Table[int32, seq[string]]  ## anchor node -> queued new siblings, in order
    roots*: seq[int32]
    tailOff*, tailLen*: int32             ## bytes after the last root (see the
                                           ## corrupt-file note above)
    lineStarts*: seq[int32]               ## built lazily by `lineOf`
    diagnostics*: seq[tuple[line: int, msg: string]]
      ## Non-fatal notes recorded while parsing -- today, every place a stray
      ## `)` was absorbed with no matching `(`. Empty on every well-formed
      ## file; `kicad.nim` reads this to explain a refusal with real line
      ## numbers instead of "the file looked wrong".
    name*: string

# ---------------------------------------------------------------- accessors

proc kind*(d: SexpDoc, n: int32): SexpKind {.inline.} =
  SexpKind(d.kinds[n])

proc addSpan(buf: var string, src: string, a, b: int32) {.inline.} =
  ## Appends `src[a ..< b]`. `system.add(string, openArray[char])` -- which
  ## would let `toOpenArray` avoid the substring allocation `src[a ..< b]`
  ## makes here -- does not exist for `string` destinations in this Nim
  ## version (checked: only `char`/`cstring`/`string` overloads resolve), so
  ## this is one allocation per gap and per leaf rather than zero. Left as
  ## the simple form rather than a manual byte-copy loop, since the measured
  ## render time against the 81 MB board (see `examples/pcb_roundtrip.nim`)
  ## is what determines whether that trade needs revisiting, not a guess
  ## about which allocator call is expensive.
  if b > a: buf.add(src[int(a) ..< int(b)])

proc raw*(d: SexpDoc, n: int32): string =
  ## Exact source text, quotes and escapes intact. For a list this is the
  ## whole `( ... )` span.
  let nd = d.nodes[n]
  d.src[int(nd.off) ..< int(nd.off) + int(nd.len)]

proc decodeString(s: string): string =
  ## `skString`'s escape set, verified against the corpus: `\\` (x5965),
  ## `\n` (x150, an embedded newline -- corpus strings never contain a raw
  ## newline byte, so this is the only way one reaches a value), `\"`
  ## (x76). `s` still carries its surrounding quotes; both are dropped here
  ## and never re-added by anything downstream of `text()`.
  if s.len < 2 or s[0] != '"' or s[^1] != '"':
    return s   # malformed input reached us anyway; hand it back rather than index out of range
  result = newStringOfCap(s.len)
  var i = 1
  let last = s.len - 1
  while i < last:
    if s[i] == '\\' and i + 1 < last + 1:
      let c = s[i + 1]
      case c
      of 'n': result.add '\n'
      of 't': result.add '\t'
      of 'r': result.add '\r'
      else: result.add c   # `\\` -> `\`, `\"` -> `"`, and anything else literally
      i += 2
    else:
      result.add s[i]
      inc i

proc text*(d: SexpDoc, n: int32): string =
  ## Decoded value: quotes stripped and escapes applied for a string, the
  ## bytes unchanged for an atom (which is never quoted, so there is nothing
  ## to decode) or a list (whose "text" is its raw span, for callers that
  ## don't care which kind they got).
  case d.kind(n)
  of skString: decodeString(d.raw(n))
  of skAtom, skList: d.raw(n)

proc head*(d: SexpDoc, n: int32): string =
  ## The leading token of a list -- `"segment"` for `(segment ...)`, `"0"`
  ## for a `(layers)` row like `(0 "F.Cu" signal)`. Empty for an atom, a
  ## string, or an empty list.
  if d.kind(n) != skList: return ""
  let fc = d.nodes[n].firstChild
  if fc < 0: return ""
  d.text(fc)

iterator kids*(d: SexpDoc, n: int32): int32 =
  ## Every child of `n`, in source order. Empty for a non-list or an empty
  ## list -- never raises.
  if d.kind(n) == skList:
    var c = d.nodes[n].firstChild
    while c >= 0:
      yield c
      c = d.nodes[c].nextSib

proc children*(d: SexpDoc, n: int32): seq[int32] =
  for c in d.kids(n): result.add(c)

proc child*(d: SexpDoc, n: int32, headName: string): int32 =
  ## The first child of `n` that is either a list headed `headName` or a bare
  ## atom spelling it (`(locked)` as a flag) -- `-1` if there is no such
  ## child. This is the workhorse for "does this node have a `(width ...)`",
  ## not a general tree search: it looks one level down only.
  for c in d.kids(n):
    case d.kind(c)
    of skList:
      if d.head(c) == headName: return c
    of skAtom:
      if d.text(c) == headName: return c
    of skString: discard
  -1

iterator kidsNamed*(d: SexpDoc, n: int32, headName: string): int32 =
  for c in d.kids(n):
    if d.kind(c) == skList and d.head(c) == headName:
      yield c

proc arg*(d: SexpDoc, n: int32, i: int): int32 =
  ## The `i`-th argument of list `n`, i.e. the `i`-th child *after* the head
  ## token (`arg(atNode, 0)` is the `x` in `(at x y rot)`). `-1` when `n` is
  ## not a list, has no head, or has fewer than `i + 1` arguments -- callers
  ## treat that the same way `parseNumber` treats an unparseable token:
  ## something to refuse on, not to default from.
  if d.kind(n) != skList: return -1
  var c = d.nodes[n].firstChild
  if c < 0: return -1
  # Skip the head itself -- an atom head is not an argument; a list has no
  # head to skip (the "at" in `(at ...)` is always an atom in the corpus, but
  # nothing here assumes it must be, so a headless list starts counting from
  # its first child).
  if d.kind(c) == skAtom or d.kind(c) == skString:
    c = d.nodes[c].nextSib
  var k = 0
  while c >= 0:
    if k == i: return c
    c = d.nodes[c].nextSib
    inc k
  -1

proc parseNumber*(d: SexpDoc, n: int32, value: var float): bool =
  ## The house `parseX(text, var): bool` idiom (`spice.parseSpiceMagnitude`,
  ## `ibis.parseIbisNumber`): refuses rather than guesses. `n` must be an
  ## atom holding exactly a float literal -- no magnitude suffix, since a
  ## KiCad coordinate or angle is already in bare millimetres or degrees, not
  ## a SPICE-style scaled value. `value` is left untouched on failure.
  if n < 0 or d.kind(n) != skAtom: return false
  let s = d.raw(n)
  try:
    value = parseFloat(s)
    true
  except ValueError:
    false

# ---------------------------------------------------------------- line numbers

proc ensureLineStarts(d: SexpDoc) =
  if d.lineStarts.len > 0 or d.src.len == 0: return
  d.lineStarts.add(0)
  for i in 0 ..< d.src.len:
    if d.src[i] == '\n' and i + 1 < d.src.len:
      d.lineStarts.add(int32(i + 1))

proc lineOf*(d: SexpDoc, n: int32): int =
  ## 1-based line number of node `n`'s start offset, for error messages.
  ## Builds `d.lineStarts` on first use (an O(file size) scan, ~15 MB of
  ## `int32` on the 81 MB board) rather than rescanning from byte 0 per call
  ## -- the corpus has files where that difference is minutes versus
  ## milliseconds when many errors are reported at once.
  ensureLineStarts(d)
  if n < 0 or n >= int32(d.nodes.len): return 0
  let off = d.nodes[n].off
  # Binary search for the last line-start <= off.
  var lo = 0
  var hi = d.lineStarts.len - 1
  while lo < hi:
    let mid = (lo + hi + 1) div 2
    if d.lineStarts[mid] <= off: lo = mid
    else: hi = mid - 1
  lo + 1

proc lineOfOffset(d: SexpDoc, off: int32): int =
  ensureLineStarts(d)
  var lo = 0
  var hi = d.lineStarts.len - 1
  while lo < hi:
    let mid = (lo + hi + 1) div 2
    if d.lineStarts[mid] <= off: lo = mid
    else: hi = mid - 1
  lo + 1

# ---------------------------------------------------------------- parser

proc parseSexpInto*(d: SexpDoc, src: sink string, name = "") =
  ## Lexes `src` and fills the *already-allocated* `d` -- the polymorphic
  ## form `parseSexp` is built on. It exists because `KicadDoc` (in
  ## `kicad.nim`) is a `SexpDoc` subtype carrying its own fields
  ## (`version`, `netByCode`, ...), and a subtype's fields cannot be added to
  ## an object after `SexpDoc(...)` has already allocated the base type: the
  ## caller must allocate the right concrete type first (`KicadDoc()`) and
  ## hand it here to be populated, exactly as `netlist/formats/spice.readNetlist`
  ## fills a `Netlist` its caller (or `resolveSubckt`) already constructed.
  ##
  ## Never raises for a structural defect in the input (see the module doc
  ## comment) -- only for a file too large to index with `int32` offsets.
  if src.len > high(int32).int:
    raise newException(SexpError,
      "sexp: file exceeds 2 GiB (" & $src.len & " bytes), cannot be indexed " &
      "by int32 offsets: " & name)

  d.src = src
  d.name = name
  let n = int32(d.src.len)
  d.nodes = newSeqOfCap[SNode](n.int div 10 + 16)
  d.kinds = newSeqOfCap[uint8](n.int div 10 + 16)

  var stack: seq[tuple[idx: int32, lastChild: int32]]
  var strayCloses: seq[int32]   # offsets, resolved to line numbers after the parse
  var i: int32 = 0

  template addNode(kindVal: SexpKind, offVal: int32): int32 =
    let idx = int32(d.nodes.len)
    d.nodes.add(SNode(off: offVal, len: 0, firstChild: -1, nextSib: -1))
    d.kinds.add(uint8(kindVal))
    idx

  template attach(nodeIdx: int32) =
    if stack.len == 0:
      d.roots.add(nodeIdx)
    else:
      let top = stack[^1].idx
      if stack[^1].lastChild == -1:
        d.nodes[top].firstChild = nodeIdx
      else:
        d.nodes[stack[^1].lastChild].nextSib = nodeIdx
      stack[^1].lastChild = nodeIdx

  while i < n:
    let c = d.src[i]
    if c == ' ' or c == '\t' or c == '\r' or c == '\n':
      inc i
    elif c == '(':
      let idx = addNode(skList, i)
      attach(idx)
      stack.add((idx, -1'i32))
      inc i
    elif c == ')':
      if stack.len == 0:
        # No open list to close. Finding 2: this is exactly what KiCad's own
        # tool produced 349 times in one corrupt demo board. Absorbed as a
        # zero-width event -- the byte itself still lands in the gap text
        # between whichever nodes end up adjacent, so it still round-trips.
        strayCloses.add(i)
      else:
        let top = stack.pop()
        d.nodes[top.idx].len = i + 1 - d.nodes[top.idx].off
      inc i
    elif c == '"':
      let start = i
      inc i
      while i < n:
        if d.src[i] == '\\' and i + 1 < n:
          i += 2
        elif d.src[i] == '"':
          inc i
          break
        else:
          inc i
      # If EOF was hit before a closing quote, `i == n` and the string just
      # runs to end of file -- tolerated, not raised on, same posture as an
      # unclosed list below.
      let idx = addNode(skString, start)
      d.nodes[idx].len = i - start
      attach(idx)
    else:
      let start = i
      while i < n:
        let ch = d.src[i]
        if ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n' or
           ch == '(' or ch == ')' or ch == '"':
          break
        inc i
      let idx = addNode(skAtom, start)
      d.nodes[idx].len = i - start
      attach(idx)

  # Anything still open at EOF is closed there rather than raised on -- the
  # corrupt demo board's excess-close drift means this path is not even
  # exercised by the corpus in practice, but a different malformation could
  # leave opens outnumbering closes, and the lexer's contract is to never
  # raise on that either.
  while stack.len > 0:
    let top = stack.pop()
    d.nodes[top.idx].len = n - d.nodes[top.idx].off

  if d.roots.len > 0:
    let lastRoot = d.roots[^1]
    d.tailOff = d.nodes[lastRoot].off + d.nodes[lastRoot].len
  else:
    d.tailOff = 0
  d.tailLen = n - d.tailOff

  for off in strayCloses:
    d.diagnostics.add((lineOfOffset(d, off),
      "stray ')' with no matching '(' at byte " & $off))

proc parseSexp*(src: sink string, name = ""): SexpDoc =
  ## Lexes `src` into a plain `SexpDoc`. `kicad.nim` does not call this --
  ## it needs a `KicadDoc` allocated up front, so it calls `parseSexpInto`
  ## directly. This wrapper is for a caller with no format-specific subtype,
  ## namely `tests/test_pcb_sexp.nim`.
  result = SexpDoc()
  parseSexpInto(result, src, name)

proc parseSexpFile*(path: string): SexpDoc =
  let content =
    try: readFile(path)
    except IOError: raise newException(SexpError, "sexp: cannot open " & path)
  parseSexp(content, path)

# ---------------------------------------------------------------- render

proc emitNode(d: SexpDoc, n: int32, depth: int, buf: var string)

proc emitSiblings(d: SexpDoc, firstChild, startCursor, endCursor: int32,
                   depth: int, buf: var string) =
  var prevEnd = startCursor
  var cur = firstChild
  while cur >= 0:
    let nd = d.nodes[cur]
    if int32(cur) in d.deleted:
      # markDeleted's contract: neither the node nor the whitespace leading
      # into it is emitted. Only advance the cursor past it -- the gap that
      # follows (leading into the *next* surviving sibling) is left alone,
      # because that gap is what already carries the correct indentation for
      # whichever sibling ends up adjacent to the one before the deletion.
      # Emitting both gaps would double them into a blank, mis-indented line;
      # emitting neither would run two siblings' tokens together.
      prevEnd = nd.off + nd.len
      cur = nd.nextSib
      continue
    addSpan(buf, d.src, prevEnd, nd.off)
    emitNode(d, cur, depth, buf)
    prevEnd = nd.off + nd.len
    if d.inserted.hasKey(cur):
      for txt in d.inserted[cur]:
        buf.add("\n")
        buf.add(repeat('\t', depth))
        buf.add(txt)
    cur = nd.nextSib
  addSpan(buf, d.src, prevEnd, endCursor)

proc emitNode(d: SexpDoc, n: int32, depth: int, buf: var string) =
  if d.overrides.hasKey(n):
    buf.add(d.overrides[n])
    return
  let nd = d.nodes[n]
  case d.kind(n)
  of skAtom, skString:
    addSpan(buf, d.src, nd.off, nd.off + nd.len)
  of skList:
    buf.add("(")
    emitSiblings(d, nd.firstChild, nd.off + 1, nd.off + nd.len - 1, depth + 1, buf)
    buf.add(")")

proc render*(d: SexpDoc, fastPath = true): string =
  ## `fastPath = true` (the default) returns `d.src` untouched -- correct
  ## only when nothing in `d` has been edited, and it proves nothing about
  ## the renderer since it never looks at a single node. Callers that have
  ## made any `markDirty`/`markDeleted`/`markInserted*` call must pass
  ## `fastPath = false`, which walks every root, every gap between siblings
  ## and every leaf to reconstruct the file from the arena -- the path
  ## `tests/test_pcb_sexp.nim` exercises, because it is the one that can
  ## actually be wrong.
  if fastPath:
    return d.src
  var buf = newStringOfCap(d.src.len + 256)
  var prevEnd: int32 = 0
  for r in d.roots:
    let nd = d.nodes[r]
    if int32(r) in d.deleted:
      prevEnd = nd.off + nd.len
      continue
    addSpan(buf, d.src, prevEnd, nd.off)
    emitNode(d, r, 0, buf)
    prevEnd = nd.off + nd.len
    if d.inserted.hasKey(r):
      for txt in d.inserted[r]:
        buf.add("\n")
        buf.add(txt)
  addSpan(buf, d.src, prevEnd, int32(d.src.len))
  buf

proc writeSexpFile*(d: SexpDoc, path: string) =
  writeFile(path, render(d, fastPath = (d.overrides.len == 0 and
                                          d.deleted.len == 0 and
                                          d.inserted.len == 0)))

# ---------------------------------------------------------------- edit primitives

proc markDirty*(d: SexpDoc, n: int32, replacement: string) =
  ## Emits `replacement` in place of node `n`'s own source text on the next
  ## `render(fastPath = false)`. The node's *leading gap* (the whitespace
  ## before it) is untouched, so a one-line change to `(at 101 50)` keeps the
  ## tab that indented it -- only the token span itself is swapped.
  d.overrides[n] = replacement

proc markDeleted*(d: SexpDoc, n: int32) =
  ## Drops node `n` from the next render, and drops the whitespace leading
  ## into it too -- see `emitSiblings` for why dropping only the node's own
  ## bytes would leave a blank, wrongly-indented line where it used to be.
  d.deleted.incl(n)

proc markInserted*(d: SexpDoc, after: int32, text: string) =
  ## Queues `text` as a new sibling immediately following `after`, at
  ## `after`'s own depth. Several insertions queued at one anchor keep their
  ## call order. `text` must already carry whatever internal indentation a
  ## multi-line node needs (`kicadfmt.nim`'s regenerators produce that); this
  ## proc only supplies the leading `"\n" & '\t'.repeat(depth)` that places
  ## it as a sibling, and it supplies that at render time, not here, since
  ## `after`'s depth is a property of where it sits in the tree, not of this
  ## call.
  if not d.inserted.hasKey(after): d.inserted[after] = @[]
  d.inserted[after].add(text)

proc immediatePrevSibling(d: SexpDoc, n: int32): int32 =
  ## The literal previous sibling, with no regard for `d.deleted` -- the
  ## private half of `markInsertedBefore`'s walk, kept separate so that walk
  ## can keep asking "and before *that* one" without re-scanning from `n`
  ## each time.
  result = -1
  for idx in 0 ..< d.nodes.len:
    if d.nodes[idx].nextSib == n:
      return int32(idx)
  for i in 1 ..< d.roots.len:
    if d.roots[i] == n:
      return d.roots[i - 1]

proc markInsertedBefore*(d: SexpDoc, before: int32, text: string) =
  ## Queues `text` as a new sibling immediately preceding `before`, by
  ## resolving `before`'s previous sibling and delegating to `markInserted`.
  ## Every caller in this codebase's anchor-resolution ladder (see
  ## `kicad.nim`'s insert-anchor rule 2) targets a node that has one --
  ## `(version)`/`(generator)` always precede anything a writer inserts this
  ## way -- so the case with no previous sibling at all is left as a raise
  ## rather than a guess about whether to prepend inside the parent instead.
  ##
  ## **Walks past a deleted predecessor rather than anchoring on it.**
  ## `markInserted`'s contract (see `markDeleted`) is that nothing queued at
  ## a deleted node's anchor slot is ever emitted -- a "delete the last
  ## thing before X, insert a new thing right before X too" edit would
  ## otherwise anchor the insertion on the very node the same write is
  ## dropping, and lose it silently. `kicad.nim`'s `resolveInsertAnchor` hit
  ## this for the "after" case (rule 1) against a real corpus board before
  ## the equivalent guard was added there; this is the same guard for the
  ## "before" case, kept in `sexp.nim` because the fix belongs at the layer
  ## that owns what "deleted" means.
  var prev = immediatePrevSibling(d, before)
  while prev >= 0 and prev in d.deleted:
    prev = immediatePrevSibling(d, prev)
  if prev == -1:
    raise newException(SexpError,
      "sexp: markInsertedBefore: node " & $before &
      " has no surviving preceding sibling to anchor after")
  markInserted(d, prev, text)
