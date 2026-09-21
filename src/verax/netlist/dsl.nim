## A Nim-macro DSL for authoring `Netlist`s directly in source, as an
## alternative to hand-calling `verax/netlist/graph`'s API or reading a
## file format under `verax/netlist/formats/`.
##
## Every DSL statement expands to ordinary calls into `graph.nim` -- this
## module never hand-sets `.net`/`.pins`/`.component`/`.parent`/`.children`/
## `.instanceOf` itself, keeping the bidirectional-reference bookkeeping
## centralized where `graph.nim` already owns it.
##
## `kind`/`name`/`partNumber` (the handful of typed "known fields" on
## `Net`/`Component`/`Pin`) get direct, type-checked field assignment; any
## other `key = value` pair in a `net`/`component`/`pin`/`instance`
## statement is routed to that entity's open-ended `attrs` bag instead. A
## *typo* of a known field name (e.g. `kidn = "resistor"`) is therefore not
## a compile error -- it silently becomes an `attrs` entry, consistent with
## `attrs` already being an open-ended bag elsewhere in this codebase (e.g.
## the SPICE reader's `value`/model passthrough).
##
## A `component` block may also contain one `simReplace` statement, which
## records a simulation-only replacement for that component (see
## `verax/spice`) without describing anything about the real design -- it
## only ever sets `Component.simReplace`, never `connect`s/mutates the
## component itself:
##
## ```nim
## component U1, kind = "regulator_ic", partNumber = "LM317":
##   pin "IN", vin
##   pin "OUT", vout
##   pin "GND", gnd
##   simReplace kind = "voltage_source":
##     pin "+", vout
##     pin "-", gnd
## ```
##
## ```nim
## import verax/netlist/dsl
##
## let nl = netlist("divider"):
##   net vin, kind = ntSignal
##   net vout, kind = ntSignal
##   net gnd, kind = ntGround, name = "0"
##
##   component R1, kind = "resistor", partNumber = "RC0603", tolerance = "5%":
##     pin "1", vin, kind = ptPassive
##     pin "2", vout, kind = ptPassive
## ```
##
## A reusable sub-circuit is defined once with `subckt` (which produces a
## free-standing template `Netlist`, never registered into any parent) and
## instantiated any number of times afterwards with `instance`, which
## expands to `graph.instantiate` -- each instance is an independent clone,
## except for nets declared `global = true`, which stay the identical
## shared object across every instance (e.g. a common ground):
##
## ```nim
## let GATE = subckt("GATE", [VDD, GND]):
##   net VDD, kind = ntPower
##   net GND, kind = ntGround
##   component U1, kind = "ic":
##     pin "A", VDD, kind = ptPower
##     pin "B", GND, kind = ptGround
##
## let top = netlist("TOP"):
##   net gnd, kind = ntGround, name = "0", global = true
##   net vddA, kind = ntPower
##   net vddB, kind = ntPower
##
##   instance X1, GATE, [vddA, gnd]
##   instance X2, GATE, [vddB, gnd]
## ```

import std/[macros, strutils, tables]
import ./types
import ./graph
import ./annotations
import ./packages
import ./interfaces
import ./pinmux
import ./layouthints
import ./traversal

export types, graph, annotations, packages, interfaces, pinmux, layouthints,
       traversal

const
  netKnownFields = ["kind"]
  componentKnownFields = ["name", "partNumber", "kind", "simDefault"]
  pinKnownFields = ["kind"]

proc globalNetsTypeNode(): NimNode =
  ## `OrderedTable[string, Net]` -- built with `bindSym` for `OrderedTable`
  ## so DSL users don't need their own `import std/tables` just to satisfy
  ## the internal `globalNets` plumbing.
  newTree(nnkBracketExpr, bindSym("OrderedTable"), ident"string", ident"Net")

proc newGlobalsVarSection(sym: NimNode): NimNode =
  newTree(nnkVarSection, newIdentDefs(sym, globalNetsTypeNode()))

proc stripTrailingBlock(args: seq[NimNode]): (seq[NimNode], NimNode) =
  ## If the last arg is a colon-block (`nnkStmtList`), split it off.
  if args.len > 0 and args[^1].kind == nnkStmtList:
    (args[0 ..^ 2], args[^1])
  else:
    (args, nil)

proc dispatchField(entityVar: NimNode, knownFields: openArray[string], pair: NimNode): NimNode =
  ## Known field name -> direct, type-checked field assignment.
  ## Anything else -> `.attrs[key] = $value`.
  pair.expectKind(nnkExprEqExpr)
  let key = pair[0]
  key.expectKind(nnkIdent)
  let value = pair[1]
  if key.strVal in knownFields:
    result = newAssignment(newDotExpr(entityVar, key), value)
  else:
    # Through `setRawAnnotation` rather than `attrs[k] = v` directly, so a DSL
    # user does not need `import std/tables` just to set an unrecognised key.
    result = newCall(ident"setRawAnnotation", entityVar, newLit(key.strVal),
                     newCall(ident"$", value))
  result.copyLineInfo(pair)

proc handleSpec(entityVar: NimNode, scope: AnnScope, stmt: NimNode,
                what = "spec"): NimNode =
  ## `spec:` is the strict counterpart of the permissive `key = value` pairs
  ## on the statement head. Those land in `attrs` whatever they are spelled,
  ## deliberately, because a file format needs somewhere to put data this
  ## library has never heard of. Inside `spec:` there is no such bag: every
  ## key is meant to be part of the shared vocabulary, so an unrecognised one
  ## is a misspelling and is rejected at compile time.
  ##
  ## That is the same split the repo already makes between `netlist/dsl` and
  ## `xspice/dsl` -- permissive where an unknown name can still mean
  ## something, strict where it cannot.
  ##
  ## Only bare, registered keys are accepted here. A namespaced key belongs to
  ## whoever owns the namespace, so it goes through the statement head or the
  ## runtime API rather than through the shared vocabulary's front door.
  var args: seq[NimNode]
  for i in 1 ..< stmt.len: args.add stmt[i]
  let (rest, blk) = stripTrailingBlock(args)
  if rest.len > 0:
    error("`" & what & "` takes no arguments, only a block", stmt)
  if blk == nil:
    error("`" & what & "` requires a block", stmt)

  result = newStmtList()
  for pair in blk:
    if pair.kind == nnkCommentStmt: continue
    if pair.kind != nnkAsgn and pair.kind != nnkExprEqExpr:
      error("expected `key = value` inside `" & what & "`", pair)
    let keyNode = pair[0]
    if keyNode.kind != nnkIdent:
      error("a `" & what & "` key must be a bare identifier from the " &
            "annotation registry; namespaced keys go on the statement head " &
            "instead", keyNode)
    let key = keyNode.strVal
    let def = builtinDef(key)
    if def.key.len == 0:
      var known: seq[string]
      for d in builtinAnnotations:
        if scope in d.scopes: known.add d.key
      error("unknown annotation '" & key & "'. Registered keys for a " &
            $scope & " are: " & known.join(", ") & ". If this is your own, " &
            "namespace it and set it on the statement head.", keyNode)
    if scope notin def.scopes:
      error("annotation '" & key & "' does not apply to a " & $scope, keyNode)
    let call = newCall(ident"setAnnotation", entityVar, newLit(key), pair[1])
    call.copyLineInfo(pair)
    result.add call
  result.copyLineInfo(stmt)

proc layoutSideNode(valueNode: NimNode): NimNode =
  ## Maps the bare ident `left`/`right`/`auto` to the matching `LayoutSide`
  ## enum symbol, at compile time, so a design file never has to spell
  ## `sideLeft` itself. Shared by `handleLayout` (the `component` block) and
  ## `handleInstance`'s head keyword, so the two spellings cannot drift.
  if valueNode.kind != nnkIdent:
    error("a layout `side` must be one of left, right, auto", valueNode)
  case valueNode.strVal
  of "left": return ident"sideLeft"
  of "right": return ident"sideRight"
  of "auto": return ident"sideAuto"
  else: discard
  error("a layout `side` must be one of left, right, auto -- got '" &
        valueNode.strVal & "'", valueNode)

proc layoutMirrorNode(valueNode: NimNode): NimNode =
  ## Maps the bare ident `true`/`false`/`auto` to the matching `LayoutMirror`
  ## enum symbol, at compile time -- `layoutSideNode`'s shape. `true`/`false`
  ## arrive as `nnkIdent` here, same as any other bare identifier, since this
  ## is an untyped macro context and neither has been bound to `system.bool`
  ## yet.
  if valueNode.kind != nnkIdent:
    error("a layout `mirror` must be one of true, false, auto", valueNode)
  case valueNode.strVal
  of "true": return ident"mirrorOn"
  of "false": return ident"mirrorOff"
  of "auto": return ident"mirrorAuto"
  else: discard
  error("a layout `mirror` must be one of true, false, auto -- got '" &
        valueNode.strVal & "'", valueNode)

proc layoutPowerNode(valueNode: NimNode): NimNode =
  ## Maps the bare ident `true`/`false`/`auto` to the matching `LayoutPower`
  ## enum symbol, at compile time -- `layoutMirrorNode`'s shape.
  if valueNode.kind != nnkIdent:
    error("a layout `power` must be one of true, false, auto", valueNode)
  case valueNode.strVal
  of "true": return ident"powerOn"
  of "false": return ident"powerOff"
  of "auto": return ident"powerAuto"
  else: discard
  error("a layout `power` must be one of true, false, auto -- got '" &
        valueNode.strVal & "'", valueNode)

proc handleLayout(entityVar: NimNode, stmt: NimNode): NimNode =
  ## `layout:` inside a `component` block -- the strict counterpart to the
  ## permissive statement-head fallback, exactly the split `handleSpec` makes
  ## for the electrical annotation vocabulary. Only `layoutHintKeys`
  ## (`netlist/layouthints`) are accepted, so a typo is a compile error
  ## naming the real keys rather than a silently ignored `attrs` entry -- and
  ## the list is the one place a future hint (a pin placement, an absolute
  ## position) gets added on this side of the DSL.
  var args: seq[NimNode]
  for i in 1 ..< stmt.len: args.add stmt[i]
  let (rest, blk) = stripTrailingBlock(args)
  if rest.len > 0:
    error("`layout` takes no arguments, only a block", stmt)
  if blk == nil:
    error("`layout` requires a block", stmt)

  result = newStmtList()
  for pair in blk:
    if pair.kind == nnkCommentStmt: continue
    if pair.kind != nnkAsgn and pair.kind != nnkExprEqExpr:
      error("expected `key = value` inside `layout`", pair)
    let keyNode = pair[0]
    if keyNode.kind != nnkIdent:
      error("a `layout` key must be a bare identifier", keyNode)
    let key = keyNode.strVal
    if key notin layoutHintKeys:
      error("unknown layout hint '" & key & "'. Registered keys are: " &
            layoutHintKeys.join(", ") & ".", keyNode)
    case key
    of "side":
      let call = newCall(ident"setLayoutSide", entityVar, layoutSideNode(pair[1]))
      call.copyLineInfo(pair)
      result.add call
    of "mirror":
      let call = newCall(ident"setLayoutMirror", entityVar, layoutMirrorNode(pair[1]))
      call.copyLineInfo(pair)
      result.add call
    of "power":
      let call = newCall(ident"setLayoutPower", entityVar, layoutPowerNode(pair[1]))
      call.copyLineInfo(pair)
      result.add call
    of "variant":
      # Unlike `side`/`mirror`/`power`, a variant name is an open-ended
      # string (`pcb/variant.LayoutVariant` names, a registry this module
      # cannot see -- `netlist/` must not depend on `pcb/`), not a closed
      # set of bare idents -- so `pair[1]` is handed to `setLayoutVariant`
      # exactly as written, the same "value is an arbitrary expression"
      # treatment `handleSpec` already gives `value =`/`designator =`.
      let call = newCall(ident"setLayoutVariant", entityVar, pair[1])
      call.copyLineInfo(pair)
      result.add call
    else:
      error("unknown layout hint '" & key & "'", keyNode)
  result.copyLineInfo(stmt)

proc traversalPinList(node: NimNode): seq[NimNode] =
  ## One side of a `<->`: a single pin-name expression, or a bracketed list
  ## of them (`nnkBracket`). Never checked against the component's own pins
  ## here -- see `handleTraverse`'s own note on why that has to wait.
  if node.kind == nnkBracket:
    for e in node: result.add e
  else:
    result.add node

proc handleTraverseEdge(entityVar: NimNode, infixNode: NimNode,
                        conducts: bool): NimNode =
  ## One `"A" <-> "B"`/`"A" <-> [...]`/`[...] <-> [...]` statement, expanded
  ## to the cross product of its two sides -- `"RFC" <-> ["RF1", "RF2"]` is
  ## two edges, not one, since each names a genuinely different pin pair.
  infixNode.expectKind(nnkInfix)
  if not infixNode[0].eqIdent("<->"):
    error("expected a pin pair written `\"A\" <-> \"B\"` inside `traverse`",
          infixNode)
  let lhs = traversalPinList(infixNode[1])
  let rhs = traversalPinList(infixNode[2])
  result = newStmtList()
  for a in lhs:
    for b in rhs:
      let call = newCall(ident"addTraversalEdge", entityVar, a, b, newLit(conducts))
      call.copyLineInfo(infixNode)
      result.add call

proc handleTraverse(entityVar: NimNode, stmt: NimNode): NimNode =
  ## `traverse:` inside a `component` block -- states which pin pairs
  ## conduct through this part, for the N-pin case `netlist/kinds`'
  ## `classifyConductivity` and `schematic`'s two-terminal-only walk cannot
  ## express (an 8-pin RF switch is the motivating case,
  ## `designs/xbar_rf.nim`'s ADG904). Modelled on `handleLayout` immediately
  ## above: a strict, compile-time-checked block for a namespaced `attrs`
  ## family, the counterpart to the permissive statement-head fallback.
  ##
  ## Accepted statements (`nim --eval`, verified against exactly these
  ## shapes): `"A" <-> "B"` (`nnkInfix`, one conducting edge); `"A" <-> [...]`
  ## or `[...] <-> [...]` (bracket on either/both sides, the cross product);
  ## `blocks "A" <-> "B"` (`nnkCommand` wrapping the infix -- a schematic path
  ## that is not a DC path, e.g. an AC-coupling capacitor's two pins are
  ## connected on the page but never conduct); the bare idents `none`
  ## (explicitly not traversable at all -- the way to override the 2-pin
  ## default on an ordinary resistor) and `all` (every pin pair, answered by
  ## `classifyConductivity` -- opting a whole part into the kind-table
  ## answer regardless of how many pins it has connected).
  ##
  ## **Pin names are never checked against the component's own pins here.**
  ## They are arbitrary expressions, not necessarily literals, and the block
  ## may -- as in the worked example -- precede the `pin` statements that
  ## declare what the component's pins even are; `netlist/traversal.
  ## validateTraversal` is where an unknown pin name is caught, at check
  ## time rather than compile time, exactly the split `handleLayout` makes
  ## for an unparseable *value* (though not for an unknown *key*, which this
  ## block does still catch here, since the key vocabulary itself -- `<->`,
  ## `blocks`, `none`, `all` -- is fixed and closed, unlike a pin name).
  ##
  ## **Directionality (`->`) is deliberately out of scope.** The one
  ## directional case that exists -- an op-amp or buffer passing a signal
  ## input-to-output only -- is already handled, and handled better, by
  ## `spice/models/behavioral.passesSignal` plus `signalPathPins`
  ## (`analysis/analyses/opamp.nim` reads them). A second, weaker directional
  ## mechanism here would give two answers to one question.
  var args: seq[NimNode]
  for i in 1 ..< stmt.len: args.add stmt[i]
  let (rest, blk) = stripTrailingBlock(args)
  if rest.len > 0:
    error("`traverse` takes no arguments, only a block", stmt)
  if blk == nil:
    error("`traverse` requires a block", stmt)

  result = newStmtList()
  for entry in blk:
    if entry.kind == nnkCommentStmt: continue
    if entry.kind == nnkIdent:
      if entry.eqIdent("none"):
        result.add newCall(ident"setTraversalMode", entityVar, ident"tmNone")
      elif entry.eqIdent("all"):
        result.add newCall(ident"setTraversalMode", entityVar, ident"tmAll")
      else:
        error("expected `none`, `all`, a pin pair (`\"A\" <-> \"B\"`) or " &
              "`blocks \"A\" <-> \"B\"` inside `traverse`", entry)
    elif entry.kind == nnkInfix:
      result.add handleTraverseEdge(entityVar, entry, conducts = true)
    elif entry.kind == nnkCommand and entry.len == 2 and
         entry[0].eqIdent("blocks") and entry[1].kind == nnkInfix:
      result.add handleTraverseEdge(entityVar, entry[1], conducts = false)
    else:
      error("expected `none`, `all`, a pin pair (`\"A\" <-> \"B\"`) or " &
            "`blocks \"A\" <-> \"B\"` inside `traverse`", entry)
  result.copyLineInfo(stmt)

proc primaryLabel(node: NimNode): (NimNode, NimNode) =
  ## Splits a `net`/`component`/`instance` primary label into
  ## (identifier-to-bind-or-nil, string-literal-for-the-registered-name).
  case node.kind
  of nnkIdent:
    (node, newLit(node.strVal))
  of nnkStrLit:
    (NimNode(nil), node)
  else:
    error("expected an identifier or string literal name", node)

proc handleNet(nlSym, globalsSym: NimNode, stmt: NimNode): NimNode =
  var args: seq[NimNode]
  for i in 1 ..< stmt.len: args.add stmt[i]
  let (rest, blk) = stripTrailingBlock(args)
  if rest.len == 0:
    error("`net` requires a name", stmt)

  let (identSym, initialNameStr) = primaryLabel(rest[0])
  var nameStrNode = initialNameStr
  var isGlobal = false
  var fieldPairs: seq[NimNode]
  for a in rest[1 ..^ 1]:
    a.expectKind(nnkExprEqExpr)
    case a[0].strVal
    of "name": nameStrNode = a[1]
    of "global": isGlobal = a[1].eqIdent("true")
    else: fieldPairs.add(a)

  let netVar = if identSym != nil: identSym else: genSym(nskLet, "net")
  result = newStmtList()
  result.add newLetStmt(netVar, newCall(ident"addNet", nlSym, newCall(ident"newNet", nameStrNode)))
  for p in fieldPairs:
    result.add dispatchField(netVar, netKnownFields, p)
  if isGlobal:
    result.add newCall(ident"registerGlobalNet", globalsSym, netVar)
  if blk != nil:
    for inner in blk:
      if inner.kind == nnkCommentStmt: continue
      if inner.kind in {nnkCommand, nnkCall} and inner.len > 0 and inner[0].eqIdent("spec"):
        result.add handleSpec(netVar, asNet, inner)
      else:
        error("only `spec` statements are allowed inside a `net` block", inner)
  result.copyLineInfo(stmt)

macro interfaceDef*(name: untyped, body: untyped): untyped =
  ## Defines and registers an interface vocabulary.  Definitions are ordinary
  ## runtime values so parameterised definitions remain ordinary Nim procs.
  name.expectKind(nnkStrLit)
  let defSym = genSym(nskVar, "interfaceDef")
  result = newStmtList()
  result.add newTree(nnkVarSection, newIdentDefs(defSym, ident"InterfaceDef"))
  result.add newAssignment(newDotExpr(defSym, ident"name"), name)
  for stmt in body:
    if stmt.kind == nnkCommentStmt: continue
    if stmt.kind notin {nnkCommand, nnkCall} or stmt.len == 0:
      error("expected `signal`, `modport`, or `implies` in `interfaceDef`", stmt)
    if stmt[0].eqIdent("signal"):
      if stmt.len < 2 or stmt[1].kind != nnkIdent:
        error("`signal` requires an identifier", stmt)
      var width: NimNode = newLit(1)
      var shared: NimNode = newLit(false)
      var doc: NimNode = newLit("")
      for i in 2 ..< stmt.len:
        stmt[i].expectKind(nnkExprEqExpr)
        case stmt[i][0].strVal
        of "width": width = stmt[i][1]
        of "shared": shared = stmt[i][1]
        of "doc": doc = stmt[i][1]
        else: error("unknown `signal` option", stmt[i])
      result.add newCall(newDotExpr(newDotExpr(defSym, ident"signals"), ident"add"),
        newTree(nnkObjConstr, ident"SignalDef",
          newTree(nnkExprColonExpr, ident"name", newLit(stmt[1].strVal)),
          newTree(nnkExprColonExpr, ident"width", width),
          newTree(nnkExprColonExpr, ident"shared", shared),
          newTree(nnkExprColonExpr, ident"doc", doc)))
    elif stmt[0].eqIdent("modport"):
      let args = stmt[1 ..< stmt.len]
      let (rest, blk) = stripTrailingBlock(args)
      if rest.len < 1 or rest[0].kind != nnkIdent or blk == nil:
        error("`modport` requires an identifier and a block", stmt)
      let mpSym = genSym(nskVar, "modport")
      result.add newTree(nnkVarSection, newIdentDefs(mpSym, ident"Modport"))
      result.add newAssignment(newDotExpr(mpSym, ident"name"), newLit(rest[0].strVal))
      for i in 1 ..< rest.len:
        rest[i].expectKind(nnkExprEqExpr)
        if rest[i][0].strVal == "controller":
          result.add newAssignment(newDotExpr(mpSym, ident"controller"), rest[i][1])
        else: error("unknown `modport` option", rest[i])
      for pair in blk:
        if pair.kind == nnkCommentStmt: continue
        if pair.kind notin {nnkAsgn, nnkExprEqExpr} or pair[0].kind != nnkIdent:
          error("expected `signal = ptInput` in `modport`", pair)
        result.add newAssignment(newTree(nnkBracketExpr, newDotExpr(mpSym, ident"dirs"),
          newLit(pair[0].strVal)), pair[1])
      result.add newAssignment(newTree(nnkBracketExpr, newDotExpr(defSym, ident"modports"),
        newLit(rest[0].strVal)), mpSym)
    elif stmt[0].eqIdent("implies"):
      if stmt.len != 2: error("`implies` takes one role name", stmt)
      result.add newCall(newDotExpr(newDotExpr(defSym, ident"implies"), ident"add"),
        newTree(nnkObjConstr, ident"RoleClaim",
          newTree(nnkExprColonExpr, ident"role", stmt[1])))
    else: error("unknown `interfaceDef` statement: " & stmt[0].repr, stmt)
  result.add newCall(ident"registerInterfaceDef", defSym)
  result.add defSym
  result = newBlockStmt(result)

proc handleBus(nlSym: NimNode, stmt: NimNode): NimNode =
  var args: seq[NimNode]
  for i in 1 ..< stmt.len: args.add stmt[i]
  let (rest, blk) = stripTrailingBlock(args)
  if blk != nil or rest.len < 2 or rest[0].kind != nnkIdent:
    error("`bus` requires an identifier and `width =` or `nets =`", stmt)
  var value: NimNode = nil
  for a in rest[1 .. ^1]:
    a.expectKind(nnkExprEqExpr)
    if a[0].strVal == "width": value = newCall(ident"addBus", nlSym, newLit(rest[0].strVal), a[1])
    elif a[0].strVal == "nets": value = newCall(ident"busOf", nlSym, newLit(rest[0].strVal), a[1])
  if value == nil: error("`bus` requires `width =` or `nets =`", stmt)
  newLetStmt(rest[0], value)

proc handleIface(nlSym: NimNode, stmt: NimNode): NimNode =
  if stmt.len < 3 or stmt[1].kind != nnkIdent:
    error("`iface` requires an identifier and an InterfaceDef", stmt)
  var count: NimNode = nil
  for i in 3 ..< stmt.len:
    stmt[i].expectKind(nnkExprEqExpr)
    if stmt[i][0].strVal == "count": count = stmt[i][1]
    else: error("unknown `iface` option", stmt[i])
  if count == nil:
    newLetStmt(stmt[1], newCall(ident"addInterface", nlSym, newLit(stmt[1].strVal), stmt[2]))
  else:
    newLetStmt(stmt[1], newCall(ident"addInterfaceArray", nlSym, newLit(stmt[1].strVal), stmt[2], count))

proc handlePort(compVar: NimNode, stmt: NimNode): NimNode =
  if stmt.len < 2: error("`port` requires a bus or an interface and modport", stmt)
  var prefix: NimNode = newLit("")
  var mapping = newTree(nnkBracket)
  var funcs = newTree(nnkBracket)
  var peripheral: NimNode = nil
  var modport: NimNode = nil
  var firstOption = 2
  if stmt.len >= 3 and stmt[2].kind == nnkIdent:
    modport = stmt[2]; firstOption = 3
  for i in firstOption ..< stmt.len:
    stmt[i].expectKind(nnkExprEqExpr)
    case stmt[i][0].strVal
    of "prefix": prefix = stmt[i][1]
    of "peripheral": peripheral = stmt[i][1]
    of "pins", "functions":
      if stmt[i][1].kind != nnkTableConstr:
        error("`" & stmt[i][0].strVal & "` must be a table", stmt[i])
      let dst = if stmt[i][0].strVal == "pins": mapping else: funcs
      for pair in stmt[i][1]:
        pair.expectKind(nnkExprColonExpr)
        dst.add newTree(nnkTupleConstr, pair[0], pair[1])
    else: error("unknown `port` option", stmt[i])
  let target = if modport == nil: stmt[1] else: newCall(ident"view", stmt[1], newLit(modport.strVal))
  if peripheral == nil and funcs.len == 0:
    newCall(ident"connectPort", compVar, target, mapping, prefix)
  else:
    newCall(ident"connectPort", compVar, target, mapping, prefix,
            (if peripheral == nil: newLit("") else: peripheral), funcs)

proc handlePin(compVar: NimNode, stmt: NimNode): NimNode =
  var args: seq[NimNode]
  for i in 1 ..< stmt.len: args.add stmt[i]
  let (rest, blk) = stripTrailingBlock(args)
  if blk != nil:
    error("`pin` does not take a block", stmt)
  if rest.len < 2:
    error("`pin` requires a pin name and a net", stmt)

  let pinNameNode = rest[0]
  let netNode = rest[1]

  var kindNode: NimNode = ident"ptUnknown"
  var functionNode: NimNode = nil
  var fieldPairs: seq[NimNode]
  for a in rest[2 ..^ 1]:
    a.expectKind(nnkExprEqExpr)
    case a[0].strVal
    of "kind": kindNode = a[1]
    # Handled explicitly rather than left to `dispatchField`, which would write
    # an unregistered bare `function` key that `validateAnnotations` then
    # reports as a misspelling.
    of "function": functionNode = a[1]
    else: fieldPairs.add(a)

  let pinVar = genSym(nskLet, "pin")
  result = newStmtList()
  result.add newLetStmt(pinVar, newCall(ident"connect", compVar, pinNameNode, netNode, kindNode))
  for p in fieldPairs:
    result.add dispatchField(pinVar, pinKnownFields, p)
  if functionNode != nil:
    result.add newCall(ident"setPinFunction", pinVar, functionNode)
  result.copyLineInfo(stmt)

proc handleSimReplacePin(replVar: NimNode, stmt: NimNode): NimNode =
  var args: seq[NimNode]
  for i in 1 ..< stmt.len: args.add stmt[i]
  let (rest, blk) = stripTrailingBlock(args)
  if blk != nil:
    error("`pin` does not take a block", stmt)
  if rest.len != 2:
    error("`pin` inside `simReplace` requires exactly a pin name and a net", stmt)

  let pinNameNode = rest[0]
  let netNode = rest[1]
  result = newAssignment(
    newTree(nnkBracketExpr, newDotExpr(replVar, ident"pinNets"), pinNameNode),
    newDotExpr(netNode, ident"name"))
  result.copyLineInfo(stmt)

proc handleSimReplace(compVar: NimNode, stmt: NimNode): NimNode =
  ## Builds a `SimReplacement` and adds it to `compVar.simModels`. This only
  ## ever produces a data assignment -- never a `connect`/`addPort`/
  ## `instantiate` call -- so it doesn't touch the component being described;
  ## the override is inert data sitting next to it (see `verax/spice`).
  ##
  ## `addSimModel` rather than an assignment, so a component may carry more
  ## than one `simReplace` block -- each with its own `name` and the `suits`
  ## that says which question it answers. Writing two with the same name is a
  ## runtime error naming the component, which is the same treatment a
  ## duplicate designator gets and for the same reason.
  var args: seq[NimNode]
  for i in 1 ..< stmt.len: args.add stmt[i]
  let (rest, blk) = stripTrailingBlock(args)

  var kindNode: NimNode = nil
  var designatorNode: NimNode = newLit("")
  var partNumberNode: NimNode = newLit("")
  var nameNode: NimNode = newLit("")
  var suitsNode: NimNode = newTree(nnkBracket)
  var fieldPairs: seq[NimNode]
  for a in rest:
    a.expectKind(nnkExprEqExpr)
    case a[0].strVal
    of "kind": kindNode = a[1]
    of "designator": designatorNode = a[1]
    of "partNumber": partNumberNode = a[1]
    of "name": nameNode = a[1]
    of "suits":
      # A bare string is the common case (`suits = spSteadyState`); a bracket
      # is how a model that answers two questions says so.
      suitsNode =
        if a[1].kind == nnkBracket: a[1]
        else: newTree(nnkBracket, a[1])
    else: fieldPairs.add(a)
  if kindNode == nil:
    error("`simReplace` requires `kind = ...`", stmt)

  let replVar = genSym(nskLet, "simRepl")
  result = newStmtList()
  result.add newLetStmt(replVar,
    newCall(ident"newSimReplacement", kindNode, designatorNode, partNumberNode,
            nameNode, suitsNode))
  for p in fieldPairs:
    result.add dispatchField(replVar, [], p)

  if blk != nil:
    for inner in blk:
      if inner.kind == nnkCommentStmt: continue
      if inner.kind in {nnkCommand, nnkCall} and inner.len > 0 and inner[0].eqIdent("pin"):
        result.add handleSimReplacePin(replVar, inner)
      else:
        error("only `pin` statements are allowed inside a `simReplace` block", inner)

  result.add newCall(ident"addSimModel", compVar, replVar)
  result.copyLineInfo(stmt)

proc handleComponent(nlSym, globalsSym: NimNode, stmt: NimNode): NimNode =
  var args: seq[NimNode]
  for i in 1 ..< stmt.len: args.add stmt[i]
  let (rest, blk) = stripTrailingBlock(args)
  if rest.len == 0:
    error("`component` requires a designator or a `kind`", stmt)

  # A component may omit its label entirely, in which case every argument is
  # a field and the designator is generated from `kind` at construction:
  #
  #     component kind = "capacitor", value = "100n":
  #
  # Worth doing for the parts nobody ever refers to -- a decoupling bank, a
  # termination network -- where hand-authoring twenty designators is work
  # that buys nothing. It is *not* free: a generated designator is positional,
  # so inserting a part earlier renumbers everything after it, and a
  # designator is the join key to a board, a BoM line and silkscreen text.
  # Generated ones are marked so a layout flow can tell them apart, and a part
  # that something names or places should keep a written one -- which is
  # self-selecting, since needing to name it is the signal.
  let generated = rest[0].kind == nnkExprEqExpr
  var identSym: NimNode = nil
  var designatorStrNode: NimNode = nil
  if not generated:
    let (i, s) = primaryLabel(rest[0])
    identSym = i
    designatorStrNode = s

  var kindNode: NimNode = nil
  var fieldPairs: seq[NimNode]
  for a in rest[(if generated: 0 else: 1) ..^ 1]:
    a.expectKind(nnkExprEqExpr)
    case a[0].strVal
    of "designator": designatorStrNode = a[1]
    of "kind":
      kindNode = a[1]
      if not generated: fieldPairs.add(a)
    else: fieldPairs.add(a)

  if generated and designatorStrNode == nil and kindNode == nil:
    error("a `component` with no designator must state `kind`: the " &
          "designator is generated from it", stmt)

  let compVar = if identSym != nil: identSym else: genSym(nskLet, "comp")
  result = newStmtList()
  if generated and designatorStrNode == nil:
    # `kind` is an expression and may not be a literal, so the designator is
    # chosen at construction rather than at macro expansion -- which is also
    # what makes this work inside a `for`, where the macro cannot know how
    # many parts there will be.
    let kindVar = genSym(nskLet, "kind")
    result.add newLetStmt(kindVar, kindNode)
    result.add newLetStmt(compVar,
      newCall(ident"addGenerated", nlSym, kindVar))
  else:
    if generated and kindNode != nil: fieldPairs.add(
      newTree(nnkExprEqExpr, ident"kind", kindNode))
    result.add newLetStmt(compVar,
      newCall(ident"addComponent", nlSym, newCall(ident"newComponent", designatorStrNode)))
  for p in fieldPairs:
    result.add dispatchField(compVar, componentKnownFields, p)

  if blk != nil:
    for inner in blk:
      if inner.kind == nnkCommentStmt: continue
      if inner.kind in {nnkCommand, nnkCall} and inner.len > 0 and inner[0].eqIdent("pin"):
        result.add handlePin(compVar, inner)
      elif inner.kind in {nnkCommand, nnkCall} and inner.len > 0 and inner[0].eqIdent("port"):
        result.add handlePort(compVar, inner)
      elif inner.kind in {nnkCommand, nnkCall} and inner.len > 0 and inner[0].eqIdent("simReplace"): 
        result.add handleSimReplace(compVar, inner)
      elif inner.kind in {nnkCommand, nnkCall} and inner.len > 0 and inner[0].eqIdent("spec"):
        result.add handleSpec(compVar, asComponent, inner)
      elif inner.kind in {nnkCommand, nnkCall} and inner.len > 0 and inner[0].eqIdent("layout"):
        result.add handleLayout(compVar, inner)
      elif inner.kind in {nnkCommand, nnkCall} and inner.len > 0 and inner[0].eqIdent("traverse"):
        result.add handleTraverse(compVar, inner)
      else:
        error("only `pin`, `port`, `simReplace`, `spec`, `layout` and " &
              "`traverse` statements are allowed inside a `component` block", inner)
  result.copyLineInfo(stmt)

proc handleInstance(nlSym, globalsSym: NimNode, stmt: NimNode): NimNode =
  var args: seq[NimNode]
  for i in 1 ..< stmt.len: args.add stmt[i]
  let (rest, blk) = stripTrailingBlock(args)
  if blk != nil:
    error("`instance` does not take a block", stmt)
  if rest.len < 3:
    error("`instance` requires a designator, a template, and a bracket of port nets", stmt)

  let (identSym, initialDesignatorStr) = primaryLabel(rest[0])
  var designatorStrNode = initialDesignatorStr
  let templNode = rest[1]
  # Ports may be given positionally (`[a, b, gnd]`) or **by name**
  # (`{"vin": a, "gnd": gnd}`). By name is what a system assembled from
  # `boundary.asSubcircuit` templates wants: those port lists come from
  # whichever nets the connectors sat on, two boards in one system routinely
  # both call a port `vin`, and swapping two same-shaped nets is a miswiring
  # that raises nothing and simulates happily.
  let portsNode = rest[2]
  var byName = false
  var portsSeq: NimNode
  var openGroupsSeq: NimNode = nil
  case portsNode.kind
  of nnkBracket:
    let parts = genSym(nskVar, "ports")
    let init = newCall(newTree(nnkBracketExpr, ident"newSeq", ident"Net"), newLit(0))
    var blk = newStmtList(newVarStmt(parts, init))
    for entry in portsNode:
      blk.add newCall(newDotExpr(parts, ident"add"), newCall(ident"netsOf", entry))
    blk.add parts
    portsSeq = newBlockStmt(blk)
  of nnkTableConstr:
    byName = true
    let pairs = genSym(nskVar, "wiring")
    let openGroups = genSym(nskVar, "openGroups")
    var wiringBlk = newStmtList(newVarStmt(pairs,
      newCall(newTree(nnkBracketExpr, ident"newSeq",
                       newTree(nnkTupleConstr, ident"string", ident"Net")), newLit(0))))
    var openBlk = newStmtList(newVarStmt(openGroups,
      newCall(newTree(nnkBracketExpr, ident"newSeq", ident"string"), newLit(0))))
    for entry in portsNode:
      entry.expectKind(nnkExprColonExpr)
      if entry[1].kind == nnkIdent and entry[1].eqIdent("open"):
        openBlk.add newCall(newDotExpr(openGroups, ident"add"), entry[0])
      else:
        wiringBlk.add newCall(newDotExpr(pairs, ident"add"),
          newCall(ident"wiringOf", entry[0], entry[1]))
    wiringBlk.add pairs
    openBlk.add openGroups
    portsSeq = newBlockStmt(wiringBlk)
    openGroupsSeq = newBlockStmt(openBlk)
  else:
    error("`instance` ports must be a bracket of nets in port order, or a " &
          "`{\"port\": net}` table naming them", portsNode)

  var kindNode: NimNode = newLit("subcircuit")
  var tweakNode: NimNode = nil
  var sideNode: NimNode = nil
  var fieldPairs: seq[NimNode]
  for a in rest[3 ..^ 1]:
    a.expectKind(nnkExprEqExpr)
    case a[0].strVal
    of "kind": kindNode = a[1]
    of "designator": designatorStrNode = a[1]
    of "with": tweakNode = a[1]
    # `side =` here is `layout:`'s head-keyword counterpart -- `instance`
    # takes no trailing block at all (see the check above), so this is the
    # only place an instantiated subcircuit's own layout hint can be stated.
    # Same mapping (`layoutSideNode`), so the two spellings cannot drift.
    of "side": sideNode = layoutSideNode(a[1])
    else: fieldPairs.add(a)

  let instVar = if identSym != nil: identSym else: genSym(nskLet, "inst")
  result = newStmtList()
  result.add newLetStmt(instVar,
    if byName:
      newCall(ident"instantiateByPortOpen", nlSym, designatorStrNode,
              templNode, portsSeq, openGroupsSeq, globalsSym, kindNode)
    else:
      newCall(ident"instantiate", nlSym, designatorStrNode, templNode,
              portsSeq, globalsSym, kindNode))
  for p in fieldPairs:
    result.add dispatchField(instVar, componentKnownFields, p)
  if sideNode != nil:
    result.add newCall(ident"setLayoutSide", instVar, sideNode)
  result.add newCall(ident"promotePortDirections", instVar)

  # `with = <proc(Netlist)>` runs against **this instance's own clone**,
  # immediately after `instantiate` and before anything else sees it.
  #
  # It exists so that a module can be varied per instance without anybody
  # inventing an identifier for its parts. `instantiate` deep-clones, so the
  # proc is handed a netlist nothing else shares, and inside it the only
  # names in play are the module's *own local* designators -- few,
  # author-controlled, and meaningful precisely because they never leave the
  # module. Contrast the alternative, reaching in from the board afterwards,
  # which needs a name that is unique across the whole design and stable
  # against edits: exactly the identifier nobody wants to hand-author.
  #
  # It is a *construction* step rather than a mutation of something already
  # built. That distinction is the same one `Component.simReplace` draws: a
  # post-hoc hook that adds a simulation view is fine, one that changes what
  # the board *is* after the fact is not.
  if tweakNode != nil:
    let tweakSym = genSym(nskLet, "tweak")
    result.add newLetStmt(tweakSym, tweakNode)
    result.add newCall(tweakSym, newDotExpr(instVar, ident"subNetlist"))
  result.copyLineInfo(stmt)

proc handleModel(nlSym: NimNode, stmt: NimNode): NimNode =
  ## `model "1N4148", "D IS=2.52n RS=0.568 N=1.752"` -> a `.MODEL` card.
  ##
  ## The body is passed through **verbatim**, exactly as `Netlist.models`
  ## already stores it and the deck writer already emits it. Parsing a model
  ## card structurally would mean tracking every parameter of every device
  ## type in every SPICE dialect, and getting one wrong silently simulates a
  ## different part -- whereas passing it through means the simulator reads
  ## precisely what the datasheet said.
  ##
  ## What this buys beyond the card reaching the deck: a component whose
  ## `value` names a model is no longer *unmodelled*, so `spice/models`
  ## stops standing it in with per-pin impedances and `spice/isolate` will
  ## traverse it. A diode with a model is a diode; without one it was two
  ## resistors to ground, which is not a diode in any useful sense.
  if stmt.len != 3:
    error("model takes a name and a card body: " &
          "model \"1N4148\", \"D IS=2.52n RS=0.568\"", stmt)
  newCall(ident"setModel", nlSym, stmt[1], stmt[2])

proc buildNetlistBody*(nlSym, globalsSym: NimNode, body: NimNode): NimNode =
  ## Expands the `net`/`component`/`instance` statement vocabulary against an
  ## existing netlist symbol.
  ##
  ## Exported as an extension point: a higher-level DSL that wants everything
  ## a `netlist` block accepts *plus* statements of its own (see
  ## `verax/contract/dsl`'s `design`) reuses this rather than duplicating the
  ## handlers and drifting from them.
  result = newStmtList()
  for stmt in body:
    if stmt.kind == nnkCommentStmt:
      continue

    # `for`, `if` and `case` are the ordinary Nim the vocabulary admits, and
    # all three are admitted the same way: as **control flow over DSL
    # statements**, not as an opening to arbitrary code. The header -- the
    # loop variable, the condition, the selector -- passes through untouched,
    # and every branch body is expanded by this same proc, so whatever is
    # inside is still a `net`, `component`, `instance` or `model` and nothing
    # else. `echo` in a loop body is still `unknown DSL statement`.
    #
    # `for` earns it by removing repetition: a decoupling bank or a channel
    # per lane is otherwise N nearly-identical lines, which is where a value
    # gets corrected in one copy and not the others. `if` and `case` earn it
    # by removing the *other* way that happens -- a board with build variants
    # kept as two files that drift apart, or as one file with the unused half
    # commented out, which is the same thing with worse tooling.
    #
    # The one consequence worth stating rather than discovering: the `let` a
    # `net`/`component` statement binds is scoped to the **branch or
    # iteration**, so nothing generated inside one can be referenced by
    # identifier afterwards -- address it by name through
    # `graph.findComponent`/`findNet` instead. A typo in an identifier used
    # *within* the branch is still a compile error, and `spec:` keys are still
    # validated at compile time, because neither depends on whether the branch
    # runs. Nothing is lost on duplicate designators either: `addComponent`
    # has always raised at runtime rather than at compile time.
    if stmt.kind in {nnkForStmt, nnkIfStmt, nnkCaseStmt, nnkWhenStmt}:
      var ctl = copyNimTree(stmt)
      if stmt.kind == nnkForStmt:
        # The body is the last child; everything before it is the header.
        ctl[^1] = buildNetlistBody(nlSym, globalsSym, stmt[^1])
      else:
        # A `case` keeps its selector in child 0, which is an expression and
        # not a branch -- hence matching on the branch node kind rather than
        # counting children.
        for i in 0 ..< ctl.len:
          if ctl[i].kind in {nnkElifBranch, nnkOfBranch, nnkElse}:
            ctl[i][^1] = buildNetlistBody(nlSym, globalsSym, ctl[i][^1])
      result.add ctl
      continue

    # A bare `discard` is the only no-op, and it exists for one reason:
    # `if`/`case` branches need a body, and "this variant adds no parts" is an
    # ordinary thing for a branch to say. `discard <expr>` is *not* accepted --
    # that is arbitrary code wearing a keyword.
    if stmt.kind == nnkDiscardStmt:
      if stmt.len == 1 and stmt[0].kind == nnkEmpty:
        continue
      error("`discard <expression>` is not a statement this block accepts; " &
            "a bare `discard` is allowed as an empty branch", stmt)

    if stmt.kind notin {nnkCommand, nnkCall} or stmt.len == 0:
      error("expected a `net`, `component`, `instance`, `model` or " &
            "`environment` statement, or a `for`/`if`/`case` over them", stmt)
    let head = stmt[0]
    if head.eqIdent("net"):
      result.add handleNet(nlSym, globalsSym, stmt)
    elif head.eqIdent("bus"):
      result.add handleBus(nlSym, stmt)
    elif head.eqIdent("iface"):
      result.add handleIface(nlSym, stmt)
    elif head.eqIdent("component"):
      result.add handleComponent(nlSym, globalsSym, stmt)
    elif head.eqIdent("instance"):
      result.add handleInstance(nlSym, globalsSym, stmt)
    elif head.eqIdent("model"):
      result.add handleModel(nlSym, stmt)
    elif head.eqIdent("environment"):
      # The board-level conditions every part on it shares -- today the
      # ambient temperature range. It is `spec:` at netlist scope and is
      # spelled differently only because that is what it says: a range read
      # off an enclosure specification is not a property of the netlist in
      # the way a net's rail voltage is, and calling the block `environment`
      # is what makes a design file legible at the point somebody adds
      # humidity or altitude beside it.
      result.add handleSpec(nlSym, asNetlist, stmt, "environment")
    elif head.eqIdent("role") or head.eqIdent("require"):
      # Reachable only from inside control flow: `design`'s splitter hoists
      # these out at the top level, so seeing one here means it was nested.
      # They cannot be, and the reason is not arbitrary -- a claim is attached
      # once the whole netlist exists, so it has no defined place inside a
      # `for`/`if`/`case` that is still building it.
      error("`" & head.repr & "` cannot appear inside a `for`, `if` or " &
            "`case`: claims are attached once the netlist is complete. " &
            "Build the parts conditionally, then state the claims after.",
            stmt)
    else:
      error("unknown DSL statement: " & head.repr, stmt)

macro netlist*(name: untyped, body: untyped): untyped =
  ## Builds a flat (non-template) `Netlist` from `net`/`component` (with
  ## nested `pin`) and `instance` statements. See the module doc comment
  ## for a full example.
  name.expectKind(nnkStrLit)
  let nlSym = genSym(nskLet, "nl")
  let globalsSym = genSym(nskVar, "globalNets")
  result = newStmtList()
  result.add newLetStmt(nlSym, newCall(ident"newNetlist", name))
  result.add newGlobalsVarSection(globalsSym)
  result.add buildNetlistBody(nlSym, globalsSym, body)
  result.add nlSym
  result = newBlockStmt(result)
  result.copyLineInfo(body)

macro subckt*(name: untyped, ports: untyped, body: untyped): untyped =
  ## Builds a free-standing template `Netlist` (never registered into any
  ## parent) with the given ports exposed, for later `instance` calls.
  name.expectKind(nnkStrLit)
  ports.expectKind(nnkBracket)
  let nlSym = genSym(nskLet, "templ")
  let globalsSym = genSym(nskVar, "globalNets")
  result = newStmtList()
  result.add newLetStmt(nlSym, newCall(ident"newNetlist", name))
  result.add newGlobalsVarSection(globalsSym)
  result.add buildNetlistBody(nlSym, globalsSym, body)
  for portIdent in ports:
    if portIdent.kind == nnkIdent:
      result.add newCall(ident"addPorts", nlSym, newLit(portIdent.strVal), portIdent)
    elif portIdent.kind == nnkDotExpr:
      result.add newCall(ident"addPorts", nlSym, newLit(portIdent[0].strVal), newCall(ident"view", portIdent[0], newLit(portIdent[1].strVal)))
    else:
      error("a subckt port must be a net, bus, or interface modport", portIdent)
  result.add nlSym
  result = newBlockStmt(result)
  result.copyLineInfo(body)
