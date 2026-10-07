## Author-stated pin-to-pin conduction for a part whose kind can't say it --
## an N-pin RF switch, connector, relay or jumper block.
##
## `kinds.classifyConductivity` (kind tables) and
## `composite.isTwoTerminal` (two connected pins) stay unchanged for parts
## that state nothing; this adds an explicit answer that overrides them.
##
## Follows `layouthints.nim`: pure, total accessors; `validateTraversal` is
## the only place bad values are reported. **Stored as namespaced
## `traverse.*` attrs**, so specs survive clone/flatten/isolate (and are
## lost by a SPICE round trip).
##
## Owns storage, grammar, accessors and validation, but not resolution:
## conduction is a plain `bool` here, and `kinds.conductivityBetween`/
## `conductiveExits` resolve it (the other direction would be an import
## cycle).

import std/[strutils, tables]
import ./types
import ./issue

export issue

const
  traversalModeKey* = "traverse.mode"     ## "none" | "all"; absent = per-edge
  traversalPathsKey* = "traverse.paths"   ## conducting edges
  traversalBlockedKey* = "traverse.blocked" ## a schematic path, not a DC path
  traversalSpecKeys* = ["mode", "paths", "blocked"]
    ## Extension point for the `traverse:` grammar (like `layoutHintKeys`).

## Three homogeneous keys, each a flat `;`-separated list of `a,b` pin
## pairs. Not `-`: `IN-`/`IN+` are real pin names. `validateTraversal`
## catches a pin name containing `,` or `;` as unknown.
##
##     traverse.paths   = "RFC,RF1;RFC,RF2;RFC,RF3;RFC,RF4"
##     traverse.blocked = "IN,OUT"
##     traverse.mode    = "none"
##
## Declaration order, pins as written; `parseTraversalEdges`/`$` are exact
## inverses for one key's list. One parse point for accessor and validator.

type
  TraversalMode* = enum
    ## `tmDefault` is the zero value and "nothing stated".
    tmDefault, tmNone, tmAll

  TraversalEdge* = object
    a*, b*: string      ## pin names, unordered
    conducts*: bool      ## false = a schematic path, not a DC path

  TraversalSpec* = object
    mode*: TraversalMode
    edges*: seq[TraversalEdge]

proc parseTraversalEdges*(s: string; conducts: bool): tuple[ok: bool, edges: seq[TraversalEdge]] =
  ## The one stored-string -> `seq[TraversalEdge]` mapping. Empty is a valid
  ## empty list; a trailing `;` or an entry without exactly one comma fails
  ## the whole value (a partial spec is worse than none -- declarations are
  ## exhaustive).
  if s.len == 0: return (true, @[])
  var edges: seq[TraversalEdge]
  for entry in s.split(';'):
    if entry.len == 0: return (false, @[])
    let parts = entry.split(',')
    if parts.len != 2 or parts[0].len == 0 or parts[1].len == 0:
      return (false, @[])
    edges.add TraversalEdge(a: parts[0], b: parts[1], conducts: conducts)
  (true, edges)

proc `$`*(edges: seq[TraversalEdge]): string =
  ## Inverse of `parseTraversalEdges` for one homogeneous list (`conducts`
  ## is implied by the key).
  var parts: seq[string]
  for e in edges: parts.add e.a & "," & e.b
  parts.join(";")

proc setTraversal*(c: Component, spec: TraversalSpec) =
  ## Writes the three keys from `spec`, splitting edges by `conducts`. A
  ## `tmDefault` spec with no edges **deletes** all three: one way to mean
  ## "nothing stated".
  if spec.mode == tmDefault and spec.edges.len == 0:
    c.attrs.del(traversalModeKey)
    c.attrs.del(traversalPathsKey)
    c.attrs.del(traversalBlockedKey)
    return
  case spec.mode
  of tmDefault: c.attrs.del(traversalModeKey)
  of tmNone: c.attrs[traversalModeKey] = "none"
  of tmAll: c.attrs[traversalModeKey] = "all"
  var paths, blocked: seq[TraversalEdge]
  for e in spec.edges:
    if e.conducts: paths.add e
    else: blocked.add e
  if paths.len > 0: c.attrs[traversalPathsKey] = $paths
  else: c.attrs.del(traversalPathsKey)
  if blocked.len > 0: c.attrs[traversalBlockedKey] = $blocked
  else: c.attrs.del(traversalBlockedKey)

proc traversal*(c: Component): TraversalSpec =
  ## Pure and total: absent or unparseable reads as a zero `TraversalSpec`;
  ## `validateTraversal` reports bad values.
  if c.attrs.hasKey(traversalModeKey):
    case c.attrs[traversalModeKey]
    of "none": result.mode = tmNone
    of "all": result.mode = tmAll
    else: result.mode = tmDefault
  if c.attrs.hasKey(traversalPathsKey):
    let (ok, edges) = parseTraversalEdges(c.attrs[traversalPathsKey], true)
    if ok: result.edges.add edges
  if c.attrs.hasKey(traversalBlockedKey):
    let (ok, edges) = parseTraversalEdges(c.attrs[traversalBlockedKey], false)
    if ok: result.edges.add edges

proc statesTraversal*(c: Component): bool =
  ## Whether anything was declared, valid or not -- the cheap gate every
  ## consumer checks first, so undeclared parts take their default path.
  c.attrs.hasKey(traversalModeKey) or c.attrs.hasKey(traversalPathsKey) or
    c.attrs.hasKey(traversalBlockedKey)

proc addTraversalEdge*(c: Component, a, b: string, conducts = true) =
  ## Appends one edge, keeping what's stated (mode included). The DSL calls
  ## it per `<->` pair, so a multi-statement block accumulates.
  var spec = traversal(c)
  spec.edges.add TraversalEdge(a: a, b: b, conducts: conducts)
  setTraversal(c, spec)

proc setTraversalMode*(c: Component, mode: TraversalMode) =
  ## Sets `mode` alone, keeping edges; `validateTraversal` flags a
  ## `none`-plus-edges contradiction.
  var spec = traversal(c)
  spec.mode = mode
  setTraversal(c, spec)

const
  KindTraversalUnparseable* = "traversal_unparseable"     ## sevWarning
  KindTraversalUnknownPin* = "traversal_unknown_pin"       ## sevError
  KindTraversalContradictory* = "traversal_contradictory"  ## sevError

proc unorderedPair(a, b: string): tuple[lo, hi: string] =
  if a <= b: (a, b) else: (b, a)

proc validateTraversal*(nl: Netlist, recursive = true): seq[Issue] =
  ## Problems with `traverse.*` as written. An unknown pin is `sevError`, not
  ## a warning: a bad spec silently changes what DC walks conclude. The DSL
  ## rejects bad shapes at compile time but can't check pin names (see
  ## `dsl.handleTraverse`).
  for _, c in nl.components:
    if c.attrs.hasKey(traversalModeKey):
      let m = c.attrs[traversalModeKey]
      if m != "none" and m != "all":
        result.add newIssue(KindTraversalUnparseable, sevWarning,
          c.designator & " states " & traversalModeKey & " = \"" & m &
          "\", which is not none/all and will be read as no override at all.",
          components = @[c])

    var paths, blocked: seq[TraversalEdge]
    if c.attrs.hasKey(traversalPathsKey):
      let (ok, edges) = parseTraversalEdges(c.attrs[traversalPathsKey], true)
      if not ok:
        result.add newIssue(KindTraversalUnparseable, sevWarning,
          c.designator & " states " & traversalPathsKey & " = \"" &
          c.attrs[traversalPathsKey] & "\", which does not parse as " &
          "`pin,pin;pin,pin` and will be read as no edges at all.",
          components = @[c])
      else:
        paths = edges
    if c.attrs.hasKey(traversalBlockedKey):
      let (ok, edges) = parseTraversalEdges(c.attrs[traversalBlockedKey], false)
      if not ok:
        result.add newIssue(KindTraversalUnparseable, sevWarning,
          c.designator & " states " & traversalBlockedKey & " = \"" &
          c.attrs[traversalBlockedKey] & "\", which does not parse as " &
          "`pin,pin;pin,pin` and will be read as no edges at all.",
          components = @[c])
      else:
        blocked = edges

    let edges = paths & blocked
    if c.attrs.getOrDefault(traversalModeKey) == "none" and edges.len > 0:
      result.add newIssue(KindTraversalContradictory, sevError,
        c.designator & " states " & traversalModeKey & " = \"none\" " &
        "alongside " & $edges.len & " declared edge(s) -- state one or " &
        "the other.", components = @[c])

    var seenPairs: Table[tuple[lo, hi: string], bool]  # value: conducts
    for e in edges:
      if e.a == e.b:
        result.add newIssue(KindTraversalContradictory, sevError,
          c.designator & " declares a traversal edge from pin \"" & e.a &
          "\" to itself.", components = @[c])
        continue
      for pinName in [e.a, e.b]:
        if not c.pins.hasKey(pinName):
          var known: seq[string]
          for p in c.pins.keys: known.add p
          result.add newIssue(KindTraversalUnknownPin, sevError,
            c.designator & " declares a traversal edge naming pin \"" &
            pinName & "\", which is not one of its pins (" &
            known.join(", ") & ").", components = @[c])
      let key = unorderedPair(e.a, e.b)
      if seenPairs.hasKey(key) and seenPairs[key] != e.conducts:
        result.add newIssue(KindTraversalContradictory, sevError,
          c.designator & " states the pin pair \"" & key.lo & "\"/\"" &
          key.hi & "\" as both a conducting path and a blocked one.",
          components = @[c])
      seenPairs[key] = e.conducts
  if recursive:
    for _, child in nl.children:
      result.add validateTraversal(child, recursive = true)
