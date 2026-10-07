## A format-agnostic s-expression arena: lexer, DOM, verbatim renderer, and
## the splice primitives a writer needs to regenerate part of a file while
## leaving the rest byte-identical.
##
## **No KiCad knowledge lives here**, so a keyword `kicad.nim` never learns
## still survives a write.
##
## **Byte-exactness comes from the data structure, not a pretty-printer.**
## KiCad's `Prettify()` can't be reproduced by rule, so every node is an
## `(offset, length)` slice of the source string and an untouched node is
## written by copying its bytes.
##
## **The lexer never raises on a structural defect**, only on a file too
## large to index. A stray `)` with no open list is absorbed into the gap
## text; a list still open at EOF is closed there. Refusing a malformed board
## is `kicad.readPcb`'s job (exactly one well-formed `kicad_pcb` root), not
## the lexer's.
##
## Two rules whose violation corrupts data silently:
##
## - **Strings are never decoded on the way in.** `skString` spans quote to
##   quote with escapes intact; `text()` decodes on demand and the writer
##   never re-encodes.
## - **Quoting is recorded, not re-derived.** `skAtom` vs `skString` keeps
##   each token's original quoting (`(net 0 "")` keeps its empty quotes).

import std/[tables, sets, strutils]

type
  SexpError* = object of CatchableError
    ## Raised only for a file the arena can't index (over 2 GiB), never for
    ## a structural defect.

  SexpKind* = enum
    skList    ## `( ... )`
    skAtom    ## bare token: `segment`, `0.8`, `yes`, `0x00_ff`
    skString  ## double-quoted token, raw, escapes intact

  SNode* = object
    ## 16 bytes: `off`/`len` slice `SexpDoc.src` (a list spans `(` through
    ## its `)`, so an unmodified list is one substring copy).
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
    tailOff*, tailLen*: int32             ## bytes after the last root
    lineStarts*: seq[int32]               ## built lazily by `lineOf`
    diagnostics*: seq[tuple[line: int, msg: string]]
      ## Non-fatal parse notes (each absorbed stray `)`), so `kicad.nim` can
      ## explain a refusal with line numbers.
    name*: string

# ---------------------------------------------------------------- accessors

proc kind*(d: SexpDoc, n: int32): SexpKind {.inline.} =
  SexpKind(d.kinds[n])

proc addSpan(buf: var string, src: string, a, b: int32) {.inline.} =
  ## Appends `src[a ..< b]` (one allocation per call; no allocation-free
  ## `add(string, openArray[char])` exists for strings).
  if b > a: buf.add(src[int(a) ..< int(b)])

proc raw*(d: SexpDoc, n: int32): string =
  ## Exact source text, quotes and escapes intact (a list's whole span).
  let nd = d.nodes[n]
  d.src[int(nd.off) ..< int(nd.off) + int(nd.len)]

proc decodeString(s: string): string =
  ## Decodes `skString`'s escapes (`\\`, `\n`, `\"`) and strips the quotes,
  ## which nothing downstream re-adds.
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
  ## Decoded value: unquoted and unescaped for a string; raw bytes for an
  ## atom or list.
  case d.kind(n)
  of skString: decodeString(d.raw(n))
  of skAtom, skList: d.raw(n)

proc head*(d: SexpDoc, n: int32): string =
  ## A list's leading token (`"segment"`, or `"0"` for `(0 "F.Cu" signal)`);
  ## empty otherwise.
  if d.kind(n) != skList: return ""
  let fc = d.nodes[n].firstChild
  if fc < 0: return ""
  d.text(fc)

iterator kids*(d: SexpDoc, n: int32): int32 =
  ## Every child of `n` in source order; empty for a non-list. Never raises.
  if d.kind(n) == skList:
    var c = d.nodes[n].firstChild
    while c >= 0:
      yield c
      c = d.nodes[c].nextSib

proc children*(d: SexpDoc, n: int32): seq[int32] =
  for c in d.kids(n): result.add(c)

proc child*(d: SexpDoc, n: int32, headName: string): int32 =
  ## The first direct child that is a list headed `headName` or an atom
  ## spelling it (`(locked)`); `-1` if none. One level only.
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
  ## The `i`-th argument after the head (`arg(atNode, 0)` is `x` in
  ## `(at x y rot)`); `-1` if absent -- callers refuse rather than default.
  if d.kind(n) != skList: return -1
  var c = d.nodes[n].firstChild
  if c < 0: return -1
  # Skip an atom head; a headless list counts from its first child.
  if d.kind(c) == skAtom or d.kind(c) == skString:
    c = d.nodes[c].nextSib
  var k = 0
  while c >= 0:
    if k == i: return c
    c = d.nodes[c].nextSib
    inc k
  -1

proc parseNumber*(d: SexpDoc, n: int32, value: var float): bool =
  ## `parseX(text, var): bool`: refuses rather than guesses. `n` must be an
  ## atom holding exactly a float (no magnitude suffix). `value` is
  ## untouched on failure.
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
  ## 1-based line number of node `n`, for error messages. Builds
  ## `lineStarts` once rather than rescanning per call.
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
  ## Lexes `src` into an already-allocated `d`, so a subtype (`KicadDoc`) can
  ## be allocated by its caller first. Raises only for a file too large for
  ## `int32` offsets.
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
        # No open list: absorb the stray `)`. Its byte still lands in the gap
        # text, so it round-trips.
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
      # An unclosed string runs to EOF; tolerated.
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

  # Anything still open at EOF is closed there, never raised on.
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
  ## Lexes `src` into a plain `SexpDoc`, for callers with no format subtype.
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
      # Deleted: skip the node and its leading gap. The following gap already
      # indents the next survivor; emitting both would leave a blank line,
      # neither would join tokens.
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
  ## `fastPath = true` returns `d.src` untouched -- valid only if nothing was
  ## edited. After any `mark*` call pass `fastPath = false`, which rebuilds
  ## the file from the arena.
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
  ## Emits `replacement` in place of node `n` on the next slow render; the
  ## leading whitespace is kept.
  d.overrides[n] = replacement

proc markDeleted*(d: SexpDoc, n: int32) =
  ## Drops node `n` and its leading whitespace from the next render.
  d.deleted.incl(n)

proc markInserted*(d: SexpDoc, after: int32, text: string) =
  ## Queues `text` as a sibling right after `after`, at its depth; several
  ## keep call order. `text` carries its own internal indentation; the
  ## leading newline and tabs are added at render time.
  if not d.inserted.hasKey(after): d.inserted[after] = @[]
  d.inserted[after].add(text)

proc immediatePrevSibling(d: SexpDoc, n: int32): int32 =
  ## The literal previous sibling, ignoring `d.deleted`.
  result = -1
  for idx in 0 ..< d.nodes.len:
    if d.nodes[idx].nextSib == n:
      return int32(idx)
  for i in 1 ..< d.roots.len:
    if d.roots[i] == n:
      return d.roots[i - 1]

proc markInsertedBefore*(d: SexpDoc, before: int32, text: string) =
  ## Queues `text` right before `before` by anchoring after its previous
  ## sibling. No previous sibling raises (callers always have one).
  ##
  ## **Walks past deleted predecessors**: anything queued at a deleted node
  ## is never emitted, so anchoring there would silently lose the insert.
  var prev = immediatePrevSibling(d, before)
  while prev >= 0 and prev in d.deleted:
    prev = immediatePrevSibling(d, prev)
  if prev == -1:
    raise newException(SexpError,
      "sexp: markInsertedBefore: node " & $before &
      " has no surviving preceding sibling to anchor after")
  markInserted(d, prev, text)
