## Author-stated pin-to-pin conduction for a component whose kind alone
## cannot say it -- an 8-pin RF switch (`designs/xbar_rf.nim`'s ADG904,
## `kind = "rf_switch"`), a connector, a relay, a jumper block, any N-pin
## part whose conduction is a property of the part, not of its `kind` string.
##
## Two independent hard-coded walks answer "can a graph walk pass *through*
## this component" today and neither can be overridden: electrically,
## `netlist/kinds.classifyConductivity` looks `Component.kind` up in two
## fixed tables and calls anything else ambiguous; topologically,
## `schematic/composites/composite.isTwoTerminal` is true only for a flat
## part with exactly two connected pins. Both defaults **stay exactly as
## they were** for a component that states nothing here -- this module adds
## a third, explicit answer that overrides them, never a replacement for
## either.
##
## Mirrors `netlist/layouthints.nim` (read it first; it is the template for
## every decision below), down to the accessor/validator split: an accessor
## is pure and total, so a malformed value never fails a check on its own,
## and `validateTraversal` is the only place a bad value is ever reported.
##
## **Storage is namespaced `attrs` keys**, the trade every sibling module
## here makes (`layouthints.nim`, `environment.nim`, `packages.nim`,
## `pinmux.nim`): `graph.clone` copies `attrs` at every level, so a declared
## spec survives `clone`/`instantiate`/`flatten`/`extractSubcircuit`/
## `isolate` for free, and a SPICE round trip is *expected* to lose it
## exactly as it loses `package.*` -- there is no SPICE card that could carry
## "these two pins of this device conduct" for an arbitrary device kind.
##
## **Why this owns storage and grammar but not resolution.** `Conductivity`
## does not move to this module: `kinds.nim` already imports only `./types`,
## and `schematic/layout.nim` imports `./kinds` -- putting the resolution
## procs (the fallback ladder from a spec, or its absence, to a
## `Conductivity`) here would need `kinds` to import `traversal` and
## `traversal` to need `Conductivity` from `kinds`, a cycle. The split that
## avoids it: this module owns storage, grammar, accessors and validation,
## and states conduction as a plain `bool` (`TraversalEdge.conducts`), so it
## needs nothing from `kinds`. `kinds.conductivityBetween`/`conductiveExits`
## import `./traversal` and do the resolving.

import std/[strutils, tables]
import ./types
import ./issue

export issue

const
  traversalModeKey* = "traverse.mode"     ## "none" | "all"; absent = per-edge
  traversalPathsKey* = "traverse.paths"   ## conducting edges
  traversalBlockedKey* = "traverse.blocked" ## edges that are a path but not a DC path
  traversalSpecKeys* = ["mode", "paths", "blocked"]
    ## Extension point, the `layoutHintKeys` role: nothing else in this
    ## module consults it (there is no free-form `traverse: key = value`
    ## syntax to validate a bare key against), but a future addition to the
    ## `traverse:` grammar has exactly one list to extend, on both sides of
    ## the DSL, the way `layoutHintKeys` already does for `layout:`.

## Three homogeneous keys rather than one key with a per-edge "does this
## count as DC" marker: each value stays a flat `;`-separated list of the
## same shape `switch.select_pins`/`spice.couples` already use, so it stays
## greppable in an `attrs` dump and every entry parses the same way whichever
## key it came from.
##
## Grammar: one edge per `;`-separated entry, the edge's two pin names
## separated by `,`. `-` is deliberately not a separator -- `IN-`/`IN+` are
## real pin names in `spice/models/common.nim`, and a separator that can
## appear inside a pin name is a parser that silently misreads the common
## case to save punctuation. `,` and `;` appear in no pin name anywhere in
## this repo, and `validateTraversal` is where a pin name that ever did
## would be caught (as an "unknown pin", since it could never round-trip).
##
##     traverse.paths   = "RFC,RF1;RFC,RF2;RFC,RF3;RFC,RF4"
##     traverse.blocked = "IN,OUT"
##     traverse.mode    = "none"
##
## Canonical order is declaration order within one key, each edge's two pins
## exactly as written -- `parseTraversalEdges`/`$` are exact inverses for a
## single key's own list (which is what `setTraversal` round-trips), the
## `parseLayoutSide`/`$` discipline `layouthints.nim` documents: one parse
## point shared by the accessor and the validator, so a value neither
## recognises is reported once, not divergently.

type
  TraversalMode* = enum
    ## `tmDefault` is the zero value *and* "nothing stated", so absence and
    ## the explicit default coincide -- the `sideAuto` shape `layouthints.nim`
    ## uses for exactly the same reason.
    tmDefault, tmNone, tmAll

  TraversalEdge* = object
    a*, b*: string      ## pin names, unordered
    conducts*: bool      ## false = a schematic path, not a DC path

  TraversalSpec* = object
    mode*: TraversalMode
    edges*: seq[TraversalEdge]

proc parseTraversalEdges*(s: string; conducts: bool): tuple[ok: bool, edges: seq[TraversalEdge]] =
  ## The one place that maps a stored `paths`/`blocked` string to
  ## `seq[TraversalEdge]`. An empty string is a *valid* zero-length list (the
  ## key simply was not written -- `traversal` never calls this on an absent
  ## key, but a reader constructing one by hand should not have to special
  ## case it); a trailing `;`, an entry with no comma, or an entry with more
  ## than one comma are all malformed and fail the whole value rather than
  ## silently dropping the bad entry, on `parseLayoutSide`'s reasoning: a
  ## partially-read spec is worse than an obviously-absent one, since a
  ## declaration is meant to be exhaustive.
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
  ## The inverse of `parseTraversalEdges` for one homogeneous list (every
  ## edge sharing one `conducts` value, which is what `setTraversal` always
  ## passes in) -- `conducts` itself is not rendered, since which key the
  ## result is stored under already says it.
  var parts: seq[string]
  for e in edges: parts.add e.a & "," & e.b
  parts.join(";")

proc setTraversal*(c: Component, spec: TraversalSpec) =
  ## Writes the three keys from `spec`, splitting `edges` by `conducts` into
  ## `paths`/`blocked`. A `tmDefault` spec with no edges at all **deletes**
  ## all three rather than writing empty strings -- one way to mean "nothing
  ## stated", the same reasoning `setLayoutSide(c, sideAuto)` uses, so an
  ## unannotated component and one explicitly reset are indistinguishable in
  ## `attrs`.
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
  ## Pure and total. Absent or unparseable both read as a zero `TraversalSpec`
  ## (`tmDefault`, no edges) rather than raising -- exactly the `layoutSide`/
  ## `validateLayoutHints` split: a stated-but-broken value must never be the
  ## reason a check that merely wants to know "what conducts here" blows up;
  ## `validateTraversal` is the only place a bad value is ever reported.
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
  ## Whether *anything* was declared, valid or not -- the zero-cost gate every
  ## consumer (`kinds.conductivityBetween`, `schematic`'s widened
  ## `isTraversable`) checks first, so an undeclared component -- the
  ## overwhelming majority of every existing design -- takes its exact
  ## pre-feature path without even reading `traversal(c)`.
  c.attrs.hasKey(traversalModeKey) or c.attrs.hasKey(traversalPathsKey) or
    c.attrs.hasKey(traversalBlockedKey)

proc addTraversalEdge*(c: Component, a, b: string, conducts = true) =
  ## Appends one edge, preserving whatever is already stated (mode included)
  ## -- the DSL calls this once per `<->` pair (per cross-product member, for
  ## a bracketed side) and never calls `setTraversal` directly, so a
  ## multi-statement `traverse:` block accumulates rather than each
  ## statement clobbering the last.
  var spec = traversal(c)
  spec.edges.add TraversalEdge(a: a, b: b, conducts: conducts)
  setTraversal(c, spec)

proc setTraversalMode*(c: Component, mode: TraversalMode) =
  ## Sets `mode` alone, leaving any already-declared edges in place --
  ## `validateTraversal` is what flags the resulting `none`-plus-edges
  ## contradiction if the design actually does that; the accessor does not
  ## pre-empt it, on the same reasoning `setLayoutSide` doesn't validate.
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
  ## What is wrong with a `traverse.*` attr as *written*. Unlike a rendering
  ## hint (`validateLayoutHints`), an unknown pin is `sevError`: a bad
  ## `layout.side` only draws the sheet worse, but a bad traversal spec
  ## silently changes what `dcReachable`/`dc_path_exists` conclude about the
  ## board, and that must not pass quietly to `sevWarning`'s "cosmetic"
  ## reading. Only reachable from a file reader or a raw `attrs` write: the
  ## DSL's `traverse:` block rejects an unrecognised shape at compile time,
  ## but not an unknown *pin name* -- see `dsl.handleTraverse`'s own note on
  ## why that one check has to wait until here.
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
