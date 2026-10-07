import std/[streams, strutils, tables, unittest]

import verax/netlist
import verax/netlist/traversal
import verax/netlist/formats/spice

proc render(nl: Netlist): string =
  let outStream = newStringStream()
  writeNetlist(nl, outStream)
  result = outStream.data

proc switchBoard(): Netlist =
  ## A 4-pin switch (`RFC` common, `RF1`/`RF2` throws, `EN` control) that
  ## the 2-pin defaults say nothing about. `Z1` because `formats/spice`
  ## reads `U`/`X` designators as subcircuit instances.
  result = newNetlist("t")
  let rfc = addNet(result, newNet("rfc"))
  let rf1 = addNet(result, newNet("rf1"))
  let rf2 = addNet(result, newNet("rf2"))
  let en = addNet(result, newNet("en"))
  let u1 = addComponent(result, newComponent("Z1", kind = "rf_switch"))
  discard connect(u1, "RFC", rfc, ptPassive)
  discard connect(u1, "RF1", rf1, ptPassive)
  discard connect(u1, "RF2", rf2, ptPassive)
  discard connect(u1, "EN", en, ptInput)

# --- 1. parseTraversalEdges -------------------------------------------------

test "parseTraversalEdges: an empty string is a valid, zero-length list":
  check parseTraversalEdges("", true) == (true, newSeq[TraversalEdge]())

test "parseTraversalEdges: one edge parses in the order written":
  check parseTraversalEdges("RFC,RF1", true) ==
    (true, @[TraversalEdge(a: "RFC", b: "RF1", conducts: true)])

test "parseTraversalEdges: several `;`-separated edges, declaration order":
  let (ok, edges) = parseTraversalEdges("RFC,RF1;RFC,RF2", true)
  check ok
  check edges == @[TraversalEdge(a: "RFC", b: "RF1", conducts: true),
                   TraversalEdge(a: "RFC", b: "RF2", conducts: true)]

test "parseTraversalEdges: a trailing `;` is malformed, not a trailing no-op":
  check parseTraversalEdges("RFC,RF1;", true) == (false, newSeq[TraversalEdge]())

test "parseTraversalEdges: a one-name entry (no comma) is malformed":
  check parseTraversalEdges("RFC", true) == (false, newSeq[TraversalEdge]())

test "parseTraversalEdges: a three-name entry (two commas) is malformed":
  check parseTraversalEdges("RFC,RF1,RF2", true) == (false, newSeq[TraversalEdge]())

test "$ and parseTraversalEdges are exact inverses for one homogeneous list":
  let edges = @[TraversalEdge(a: "RFC", b: "RF1", conducts: true),
                TraversalEdge(a: "RFC", b: "RF2", conducts: true)]
  check $edges == "RFC,RF1;RFC,RF2"
  check parseTraversalEdges($edges, true) == (true, edges)

# --- 2. setTraversal / traversal round trip, raw attrs keys -----------------

test "setTraversal/traversal round-trip through the raw attrs keys":
  let nl = switchBoard()
  let c = nl.components["Z1"]
  check not statesTraversal(c)
  check traversal(c) == TraversalSpec()

  addTraversalEdge(c, "RFC", "RF1")
  check c.attrs[traversalPathsKey] == "RFC,RF1"
  check not c.attrs.hasKey(traversalBlockedKey)
  check not c.attrs.hasKey(traversalModeKey)
  check statesTraversal(c)

  addTraversalEdge(c, "RFC", "RF2")
  check c.attrs[traversalPathsKey] == "RFC,RF1;RFC,RF2"

  addTraversalEdge(c, "EN", "RFC", conducts = false)
  check c.attrs[traversalBlockedKey] == "EN,RFC"

  setTraversalMode(c, tmAll)
  check c.attrs[traversalModeKey] == "all"
  # A later mode statement leaves declared edges alone.
  check c.attrs[traversalPathsKey] == "RFC,RF1;RFC,RF2"

  let spec = traversal(c)
  check spec.mode == tmAll
  check spec.edges == @[TraversalEdge(a: "RFC", b: "RF1", conducts: true),
                        TraversalEdge(a: "RFC", b: "RF2", conducts: true),
                        TraversalEdge(a: "EN", b: "RFC", conducts: false)]

test "setTraversal of a zero (tmDefault, no edges) spec deletes all three keys":
  let nl = switchBoard()
  let c = nl.components["Z1"]
  addTraversalEdge(c, "RFC", "RF1")
  setTraversalMode(c, tmNone)
  check statesTraversal(c)

  setTraversal(c, TraversalSpec())
  check not c.attrs.hasKey(traversalModeKey)
  check not c.attrs.hasKey(traversalPathsKey)
  check not c.attrs.hasKey(traversalBlockedKey)
  check not statesTraversal(c)
  check traversal(c) == TraversalSpec()

# --- 3. an unparseable stored value reads back as a zero spec ---------------

test "an unparseable traverse.mode reads back as tmDefault, not an error":
  let nl = switchBoard()
  nl.components["Z1"].attrs[traversalModeKey] = "sometimes"
  check traversal(nl.components["Z1"]).mode == tmDefault

test "an unparseable traverse.paths reads back as no edges, not an error":
  let nl = switchBoard()
  nl.components["Z1"].attrs[traversalPathsKey] = "RFC,RF1;"
  check traversal(nl.components["Z1"]) == TraversalSpec()
  check statesTraversal(nl.components["Z1"])   # stated, just unparseable

# --- 4. validateTraversal is silent on a clean netlist ----------------------

test "validateTraversal is silent on an undeclared netlist":
  check validateTraversal(switchBoard()).len == 0

test "validateTraversal is silent on a well-formed declaration":
  let nl = switchBoard()
  addTraversalEdge(nl.components["Z1"], "RFC", "RF1")
  addTraversalEdge(nl.components["Z1"], "RFC", "RF2")
  addTraversalEdge(nl.components["Z1"], "EN", "RFC", conducts = false)
  check validateTraversal(nl).len == 0

# --- 5. validateTraversal reports what is wrong, naming the component ------

test "validateTraversal reports a pin name the component does not have":
  let nl = switchBoard()
  addTraversalEdge(nl.components["Z1"], "RFC", "RF9")
  let issues = validateTraversal(nl)
  check issues.len == 1
  check issues[0].kind == KindTraversalUnknownPin
  check issues[0].severity == sevError
  check issues[0].components == @[nl.components["Z1"]]

test "validateTraversal reports mode = none stated alongside edges":
  let nl = switchBoard()
  let c = nl.components["Z1"]
  addTraversalEdge(c, "RFC", "RF1")
  setTraversalMode(c, tmNone)
  let issues = validateTraversal(nl)
  check issues.len == 1
  check issues[0].kind == KindTraversalContradictory
  check issues[0].severity == sevError
  check issues[0].components == @[c]

test "validateTraversal reports the same pair stated as both a path and blocked":
  let nl = switchBoard()
  let c = nl.components["Z1"]
  addTraversalEdge(c, "RFC", "RF1", conducts = true)
  addTraversalEdge(c, "RF1", "RFC", conducts = false)   # same unordered pair
  let issues = validateTraversal(nl)
  check issues.len == 1
  check issues[0].kind == KindTraversalContradictory
  check issues[0].components == @[c]

test "validateTraversal reports a self-edge":
  let nl = switchBoard()
  addTraversalEdge(nl.components["Z1"], "RFC", "RFC")
  let issues = validateTraversal(nl)
  check issues.len == 1
  check issues[0].kind == KindTraversalContradictory

test "validateTraversal reports an unparseable mode, naming the component":
  let nl = switchBoard()
  nl.components["Z1"].attrs[traversalModeKey] = "sometimes"
  let issues = validateTraversal(nl)
  check issues.len == 1
  check issues[0].kind == KindTraversalUnparseable
  check issues[0].severity == sevWarning
  check issues[0].components == @[nl.components["Z1"]]

# --- 6. recursion into children ---------------------------------------------

test "validateTraversal recurses into children by default":
  let child = newNetlist("child")
  let rfc = addNet(child, newNet("rfc"))
  let rf1 = addNet(child, newNet("rf1"))
  let en = addNet(child, newNet("en"))
  let u1 = addComponent(child, newComponent("U1", kind = "rf_switch"))
  discard connect(u1, "RFC", rfc, ptPassive)
  discard connect(u1, "RF1", rf1, ptPassive)
  discard connect(u1, "EN", en, ptInput)
  addTraversalEdge(u1, "RFC", "RF9")   # unknown pin

  let top = newNetlist("top")
  addChild(top, "X1", child)
  check validateTraversal(top).len == 1
  check validateTraversal(top, recursive = false).len == 0

# --- 7. survives clone and instantiate --------------------------------------

test "traverse.* survives clone":
  let nl = switchBoard()
  let c = nl.components["Z1"]
  addTraversalEdge(c, "RFC", "RF1")
  addTraversalEdge(c, "RFC", "RF2")
  var globals: OrderedTable[string, Net]
  let cloned = clone(nl, globals)
  check traversal(cloned.components["Z1"]) == traversal(c)
  check cloned.components["Z1"].attrs[traversalPathsKey] ==
    c.attrs[traversalPathsKey]

test "traverse.* survives instantiate":
  let templ = newNetlist("SW")
  let rfc = addNet(templ, newNet("rfc"))
  let rf1 = addNet(templ, newNet("rf1"))
  let en = addNet(templ, newNet("en"))
  let u1 = addComponent(templ, newComponent("U1", kind = "rf_switch"))
  discard connect(u1, "RFC", rfc, ptPassive)
  discard connect(u1, "RF1", rf1, ptPassive)
  discard connect(u1, "EN", en, ptInput)
  addTraversalEdge(u1, "RFC", "RF1")

  let top = newNetlist("top")
  var globals: OrderedTable[string, Net]
  discard instantiate(top, "X1", templ, @[], globals)
  check traversal(top.children["X1"].components["U1"]).edges ==
    @[TraversalEdge(a: "RFC", b: "RF1", conducts: true)]

# --- 8. a SPICE round trip loses it -----------------------------------------

test "a SPICE round trip loses traverse.*, exactly like package metadata":
  let nl = switchBoard()
  let c = nl.components["Z1"]
  addTraversalEdge(c, "RFC", "RF1")
  addTraversalEdge(c, "RFC", "RF2")
  setTraversalMode(c, tmDefault)
  let text = render(nl)
  check "traverse" notin text
  let back = readNetlist(newStringStream(text), "t")
  for _, comp in back.components:
    check not statesTraversal(comp)
