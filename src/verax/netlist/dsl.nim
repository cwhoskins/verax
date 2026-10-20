## A Nim-macro DSL for authoring `Netlist`s in source. Every statement
## expands to ordinary `graph.nim` calls; this module never sets
## back-references itself.
##
## `kind`/`name`/`partNumber` are typed field assignments; any other
## `key = value` on a statement head goes to `attrs`, so a typo of a known
## field (`kidn = ...`) silently becomes an attr. `spec:` is the strict form.
##
## A `component` block may contain `simReplace`, which only records a
## simulation-only replacement (see `verax/spice`):
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
## `subckt` defines a free-standing template; `instance` expands to
## `graph.instantiate` (an independent clone, except `global = true` nets,
## which stay shared):
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
import ./bomdefaults
import ../units

export types, graph, annotations, packages, interfaces, pinmux, layouthints,
       traversal, bomdefaults

const
  netKnownFields = ["kind"]
  componentKnownFields = ["name", "partNumber", "kind", "simDefault"]
  pinKnownFields = ["kind"]

proc globalNetsTypeNode(): NimNode =
  ## `OrderedTable[string, Net]` via `bindSym`, so users needn't import
  ## `std/tables`.
  newTree(nnkBracketExpr, bindSym("OrderedTable"), ident"string", ident"Net")

proc newGlobalsVarSection(sym: NimNode): NimNode =
  newTree(nnkVarSection, newIdentDefs(sym, globalNetsTypeNode()))

proc stripTrailingBlock(args: seq[NimNode]): (seq[NimNode], NimNode) =
  ## If the last arg is a colon-block (`nnkStmtList`), split it off.
  if args.len > 0 and args[^1].kind == nnkStmtList:
    (args[0 ..^ 2], args[^1])
  else:
    (args, nil)

proc deckSafeValue*(x: float): string =
  ## Mirrors `formats/spice.spiceValue` (this core module can't import a
  ## format). Always scientific notation: `value` reaches the deck verbatim,
  ## and a trailing letter would be read as a SPICE multiplier.
  formatFloat(x, ffScientific, 9)

proc dispatchField(entityVar: NimNode, knownFields: openArray[string], pair: NimNode): NimNode =
  ## Known field name -> typed field assignment; anything else ->
  ## `.attrs[key] = $value`, except a `Quantity`: as `value` (`value =
  ## 2.2.kohm`) it is written through `deckSafeValue` because `$` gives
  ## `"2.2 kohm"`, which corrupts a deck line; as any other key it goes
  ## through the typed `setAnnotation` (registered key, unit checked). The
  ## branch is chosen by static type, so no notation is parsed; a plain
  ## string passes through as is.
  pair.expectKind(nnkExprEqExpr)
  let key = pair[0]
  key.expectKind(nnkIdent)
  let value = pair[1]
  if key.strVal in knownFields:
    result = newAssignment(newDotExpr(entityVar, key), value)
  elif key.strVal == "value":
    let quantityTy = bindSym("Quantity")
    result = quote do:
      when `value` is `quantityTy`:
        setRawAnnotation(`entityVar`, "value", deckSafeValue(float(`value`)))
      else:
        setRawAnnotation(`entityVar`, "value", $(`value`))
  else:
    # Via `setRawAnnotation` so users needn't import `std/tables`. A
    # `Quantity` (`pull_up = 40.kohm`) goes through the typed, checked
    # `setAnnotation` instead: `$` would store `"40.0 kohm"`, which no
    # reader parses.
    let quantityTy = bindSym("Quantity")
    let keyLit = newLit(key.strVal)
    result = quote do:
      when `value` is `quantityTy`:
        setAnnotation(`entityVar`, `keyLit`, `value`)
      else:
        setRawAnnotation(`entityVar`, `keyLit`, $(`value`))
  result.copyLineInfo(pair)

proc handleSpec(entityVar: NimNode, scope: AnnScope, stmt: NimNode,
                what = "spec"): NimNode =
  ## `spec:` is the strict counterpart of statement-head pairs: every key
  ## must be a registered, bare annotation, so a misspelling is a compile
  ## error. Namespaced keys go through the statement head or runtime API.
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

proc handleNotes(entityVar: NimNode, stmt: NimNode): NimNode =
  ## `notes:` is `spec:`'s opposite: free-form pairs stored under
  ## `notes.<key>` and never interpreted (skipped by `validateAnnotations`).
  ## A key is an identifier or a string literal.
  var args: seq[NimNode]
  for i in 1 ..< stmt.len: args.add stmt[i]
  let (rest, blk) = stripTrailingBlock(args)
  if rest.len > 0:
    error("`notes` takes no arguments, only a block", stmt)
  if blk == nil:
    error("`notes` requires a block", stmt)
  result = newStmtList()
  for pair in blk:
    if pair.kind == nnkCommentStmt: continue
    if pair.kind != nnkAsgn and pair.kind != nnkExprEqExpr:
      error("expected `key = value` inside `notes`", pair)
    let keyNode = pair[0]
    if keyNode.kind notin {nnkIdent, nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
      error("a `notes` key must be an identifier or a string literal",
            keyNode)
    let key = keyNode.strVal
    if key.len == 0:
      error("a `notes` key cannot be empty", keyNode)
    let call = newCall(ident"setRawAnnotation", entityVar,
                       newLit(notesPrefix & key), newCall(ident"$", pair[1]))
    call.copyLineInfo(pair)
    result.add call
  result.copyLineInfo(stmt)

proc layoutSideNode(valueNode: NimNode): NimNode =
  ## Maps bare `left`/`right`/`auto` to a `LayoutSide` at compile time.
  ## Shared by `handleLayout` and `handleInstance`.
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
  ## Maps bare `true`/`false`/`auto` to a `LayoutMirror` (they arrive as
  ## `nnkIdent` in this untyped context).
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
  ## Maps bare `true`/`false`/`auto` to a `LayoutPower`.
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
  ## `layout:` in a `component` block: only `layoutHintKeys` are accepted, so
  ## a typo is a compile error naming the real keys.
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
      # A variant name is an open string (registry lives in `pcb/`, which
      # `netlist/` can't see), passed through as written.
      let call = newCall(ident"setLayoutVariant", entityVar, pair[1])
      call.copyLineInfo(pair)
      result.add call
    else:
      error("unknown layout hint '" & key & "'", keyNode)
  result.copyLineInfo(stmt)

proc handleBom(nlSym: NimNode, stmt: NimNode): NimNode =
  ## `bom:` at netlist scope: board-level procurement defaults. `bom.*` keys
  ## are owned by `netlist/bomdefaults`, not the annotation registry, so this
  ## is its own handler. Strict here (unknown key = compile error naming
  ## `bomDefaultKeys`); permissive in the underlying `attrs`.
  var args: seq[NimNode]
  for i in 1 ..< stmt.len: args.add stmt[i]
  let (rest, blk) = stripTrailingBlock(args)
  if rest.len > 0:
    error("`bom` takes no arguments, only a block", stmt)
  if blk == nil:
    error("`bom` requires a block", stmt)

  result = newStmtList()
  for pair in blk:
    if pair.kind == nnkCommentStmt: continue
    if pair.kind != nnkAsgn and pair.kind != nnkExprEqExpr:
      error("expected `key = value` inside `bom`", pair)
    let keyNode = pair[0]
    if keyNode.kind != nnkIdent:
      error("a `bom` key must be a bare identifier", keyNode)
    let key = keyNode.strVal
    if key notin bomDefaultKeys:
      error("unknown bom default '" & key & "'. Registered keys are: " &
            bomDefaultKeys.join(", ") & ".", keyNode)
    let setterName =
      case key
      of "tolerance": "setBomTolerance"
      of "dielectric": "setBomDielectric"
      of "series": "setBomSeries"
      of "derating": "setBomDerating"
      of "resistor_package": "setBomResistorPackage"
      of "capacitor_package": "setBomCapacitorPackage"
      of "inductor_package": "setBomInductorPackage"
      of "manufacturers": "setBomManufacturers"
      else: ""  # unreachable: `key notin bomDefaultKeys` already errored
    let call = newCall(ident(setterName), nlSym, pair[1])
    call.copyLineInfo(pair)
    result.add call
  result.copyLineInfo(stmt)

proc traversalPinList(node: NimNode): seq[NimNode] =
  ## One side of a `<->`: a pin-name expression or a bracketed list. Not
  ## checked against the component's pins (see `handleTraverse`).
  if node.kind == nnkBracket:
    for e in node: result.add e
  else:
    result.add node

proc handleTraverseEdge(entityVar: NimNode, infixNode: NimNode,
                        conducts: bool): NimNode =
  ## One `<->` statement, expanded to the cross product of its sides.
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
  ## `traverse:` in a `component` block: which pin pairs conduct, for N-pin
  ## parts `classifyConductivity` can't describe (e.g. an 8-pin RF switch).
  ##
  ## Statements: `"A" <-> "B"`; brackets on either side for a cross product;
  ## `blocks "A" <-> "B"` (connected on the page, no DC path, e.g. a coupling
  ## cap); bare `none` (not traversable) and `all` (defer to
  ## `classifyConductivity`).
  ##
  ## Pin names are arbitrary expressions and may precede the `pin`
  ## statements, so unknown pins are caught by
  ## `traversal.validateTraversal`, not here. Directionality is out of
  ## scope: `behavioral.passesSignal` + `signalPathPins` already cover it.
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
  ## Splits a primary label into (identifier-to-bind-or-nil, registered name).
  case node.kind
  of nnkIdent:
    (node, newLit(node.strVal))
  of nnkStrLit:
    (NimNode(nil), node)
  else:
    error("expected an identifier or string literal name", node)

proc handleOneNet(nlSym, globalsSym: NimNode, identSym, nameStrNode: NimNode,
                   fieldPairs: seq[NimNode], isGlobal: bool,
                   blk: NimNode): NimNode =
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
      elif inner.kind in {nnkCommand, nnkCall} and inner.len > 0 and inner[0].eqIdent("notes"):
        result.add handleNotes(netVar, inner)
      else:
        error("only `spec` and `notes` statements are allowed inside a " &
              "`net` block", inner)

proc handleNet(nlSym, globalsSym: NimNode, stmt: NimNode): NimNode =
  var args: seq[NimNode]
  for i in 1 ..< stmt.len: args.add stmt[i]
  let (rest, blk) = stripTrailingBlock(args)
  if rest.len == 0:
    error("`net` requires a name", stmt)

  # `net [a, b, c], ...`: one `addNet` and one bound `let` per entry, so
  # each stays addressable. `name =` is refused -- every net would get the
  # same SPICE name.
  if rest[0].kind == nnkBracket:
    if rest[0].len == 0:
      error("`net [...]` requires at least one name", rest[0])
    var isGlobal = false
    var fieldPairs: seq[NimNode]
    for a in rest[1 ..^ 1]:
      a.expectKind(nnkExprEqExpr)
      case a[0].strVal
      of "name":
        error("`net [a, b, ...], name = ...` would give every net in the " &
              "group the same SPICE name -- state a net that needs its " &
              "own name separately", a)
      of "global": isGlobal = a[1].eqIdent("true")
      else: fieldPairs.add(a)
    result = newStmtList()
    for label in rest[0]:
      let (identSym, nameStrNode) = primaryLabel(label)
      result.add handleOneNet(nlSym, globalsSym, identSym, nameStrNode,
                               fieldPairs, isGlobal, blk)
    result.copyLineInfo(stmt)
    return

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

  result = handleOneNet(nlSym, globalsSym, identSym, nameStrNode, fieldPairs,
                         isGlobal, blk)
  result.copyLineInfo(stmt)

macro interfaceDef*(name: untyped, body: untyped): untyped =
  ## Defines and registers an interface vocabulary. Definitions are runtime
  ## values, so parameterised ones are ordinary procs.
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
    # Not via `dispatchField`, which would write an unregistered bare
    # `function` key.
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
  ## Adds a `SimReplacement` to `compVar.simModels` -- inert data, never a
  ## `connect`. Several `simReplace` blocks may coexist, each with its own
  ## `name` and `suits`; a duplicate name raises.
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
      # A string for one purpose, a bracket for several.
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

  # A component may omit its label; the designator is then generated from
  # `kind`. Useful for parts nobody refers to (decoupling banks), but
  # positional: inserting a part renumbers later ones, and designators join
  # to the board and BoM. Generated ones are marked.
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
    # `kind` may not be a literal, so the designator is chosen at
    # construction (which also makes it work inside a `for`).
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
      elif inner.kind in {nnkCommand, nnkCall} and inner.len > 0 and inner[0].eqIdent("notes"):
        result.add handleNotes(compVar, inner)
      elif inner.kind in {nnkCommand, nnkCall} and inner.len > 0 and inner[0].eqIdent("layout"):
        result.add handleLayout(compVar, inner)
      elif inner.kind in {nnkCommand, nnkCall} and inner.len > 0 and inner[0].eqIdent("traverse"):
        result.add handleTraverse(compVar, inner)
      else:
        error("only `pin`, `port`, `simReplace`, `spec`, `notes`, `layout` " &
              "and `traverse` statements are allowed inside a `component` " &
              "block", inner)
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
  # Ports positionally (`[a, b, gnd]`) or by name (`{"vin": a, ...}`). By
  # name avoids silent miswiring when port lists come from
  # `boundary.asSubcircuit` and several are same-shaped.
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
    # `side =` is the only place an instance's layout hint can go (no
    # trailing block); shares `layoutSideNode`.
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

  # `with = <proc(Netlist)>` runs against this instance's own clone right
  # after `instantiate`, so a module can be varied per instance using its
  # own local designators instead of design-wide names. A construction step,
  # not a post-hoc mutation.
  if tweakNode != nil:
    let tweakSym = genSym(nskLet, "tweak")
    result.add newLetStmt(tweakSym, tweakNode)
    result.add newCall(tweakSym, newDotExpr(instVar, ident"subNetlist"))
  result.copyLineInfo(stmt)

proc handleModel(nlSym: NimNode, stmt: NimNode): NimNode =
  ## `model "1N4148", "D IS=2.52n ..."` -> a `.MODEL` card, body passed
  ## through verbatim (parsing every dialect's parameters risks silently
  ## simulating a different part). A component whose `value` names a model
  ## is no longer unmodelled, so `spice/models` doesn't stand it in and
  ## `spice/isolate` traverses it.
  if stmt.len != 3:
    error("model takes a name and a card body: " &
          "model \"1N4148\", \"D IS=2.52n RS=0.568\"", stmt)
  newCall(ident"setModel", nlSym, stmt[1], stmt[2])

proc buildNetlistBody*(nlSym, globalsSym: NimNode, body: NimNode): NimNode =
  ## Expands the netlist statement vocabulary against an existing netlist
  ## symbol. Exported so higher-level DSLs (`contract/dsl.design`) reuse it.
  result = newStmtList()
  for stmt in body:
    if stmt.kind == nnkCommentStmt:
      continue

    # `for`/`if`/`case`/`when` are admitted as control flow over DSL
    # statements only: the header passes through, every body is expanded by
    # this proc, so `echo` in a body is still `unknown DSL statement`.
    #
    # A `let` bound inside a branch or iteration is scoped to it; reference
    # such parts by name (`findComponent`/`findNet`) afterwards. Duplicate
    # designators still raise at runtime.
    if stmt.kind in {nnkForStmt, nnkIfStmt, nnkCaseStmt, nnkWhenStmt}:
      var ctl = copyNimTree(stmt)
      if stmt.kind == nnkForStmt:
        # The body is the last child; everything before it is the header.
        ctl[^1] = buildNetlistBody(nlSym, globalsSym, stmt[^1])
      else:
        # A `case` selector is child 0, so match on branch node kind.
        for i in 0 ..< ctl.len:
          if ctl[i].kind in {nnkElifBranch, nnkOfBranch, nnkElse}:
            ctl[i][^1] = buildNetlistBody(nlSym, globalsSym, ctl[i][^1])
      result.add ctl
      continue

    # Bare `discard` only, for empty `if`/`case` branches; `discard <expr>`
    # would be arbitrary code.
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
      # Board-level conditions (ambient range): `spec:` at netlist scope.
      result.add handleSpec(nlSym, asNetlist, stmt, "environment")
    elif head.eqIdent("bom"):
      # Procurement defaults (see `handleBom`).
      result.add handleBom(nlSym, stmt)
    elif head.eqIdent("role") or head.eqIdent("require"):
      # Claims are hoisted by `design` at the top level; nested ones have no
      # defined place while the netlist is still being built.
      error("`" & head.repr & "` cannot appear inside a `for`, `if` or " &
            "`case`: claims are attached once the netlist is complete. " &
            "Build the parts conditionally, then state the claims after.",
            stmt)
    else:
      error("unknown DSL statement: " & head.repr, stmt)

macro netlist*(name: untyped, body: untyped): untyped =
  ## Builds a flat `Netlist` from `net`/`component`/`instance` statements.
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
