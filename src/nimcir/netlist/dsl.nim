## A Nim-macro DSL for authoring `Netlist`s directly in source, as an
## alternative to hand-calling `nimcir/netlist/graph`'s API or reading a
## file format under `nimcir/netlist/formats/`.
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
## ```nim
## import nimcir/netlist/dsl
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

import std/[macros, tables]
import ./types
import ./graph

export types, graph

const
  netKnownFields = ["kind"]
  componentKnownFields = ["name", "partNumber", "kind"]
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
    result = newAssignment(
      newTree(nnkBracketExpr, newDotExpr(entityVar, ident"attrs"), newLit(key.strVal)),
      newCall(ident"$", value))
  result.copyLineInfo(pair)

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
  if blk != nil:
    error("`net` does not take a block", stmt)
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
    result.add newAssignment(newTree(nnkBracketExpr, globalsSym, nameStrNode), netVar)
  result.copyLineInfo(stmt)

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
  var fieldPairs: seq[NimNode]
  for a in rest[2 ..^ 1]:
    a.expectKind(nnkExprEqExpr)
    case a[0].strVal
    of "kind": kindNode = a[1]
    else: fieldPairs.add(a)

  let pinVar = genSym(nskLet, "pin")
  result = newStmtList()
  result.add newLetStmt(pinVar, newCall(ident"connect", compVar, pinNameNode, netNode, kindNode))
  for p in fieldPairs:
    result.add dispatchField(pinVar, pinKnownFields, p)
  result.copyLineInfo(stmt)

proc handleComponent(nlSym, globalsSym: NimNode, stmt: NimNode): NimNode =
  var args: seq[NimNode]
  for i in 1 ..< stmt.len: args.add stmt[i]
  let (rest, blk) = stripTrailingBlock(args)
  if rest.len == 0:
    error("`component` requires a designator", stmt)

  let (identSym, initialDesignatorStr) = primaryLabel(rest[0])
  var designatorStrNode = initialDesignatorStr
  var fieldPairs: seq[NimNode]
  for a in rest[1 ..^ 1]:
    a.expectKind(nnkExprEqExpr)
    case a[0].strVal
    of "designator": designatorStrNode = a[1]
    else: fieldPairs.add(a)

  let compVar = if identSym != nil: identSym else: genSym(nskLet, "comp")
  result = newStmtList()
  result.add newLetStmt(compVar,
    newCall(ident"addComponent", nlSym, newCall(ident"newComponent", designatorStrNode)))
  for p in fieldPairs:
    result.add dispatchField(compVar, componentKnownFields, p)

  if blk != nil:
    for inner in blk:
      if inner.kind == nnkCommentStmt: continue
      if inner.kind in {nnkCommand, nnkCall} and inner.len > 0 and inner[0].eqIdent("pin"):
        result.add handlePin(compVar, inner)
      else:
        error("only `pin` statements are allowed inside a `component` block", inner)
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
  let portsNode = rest[2]
  portsNode.expectKind(nnkBracket)
  let portsSeq = newTree(nnkPrefix, ident"@", portsNode)

  var kindNode: NimNode = newLit("subcircuit")
  var fieldPairs: seq[NimNode]
  for a in rest[3 ..^ 1]:
    a.expectKind(nnkExprEqExpr)
    case a[0].strVal
    of "kind": kindNode = a[1]
    of "designator": designatorStrNode = a[1]
    else: fieldPairs.add(a)

  let instVar = if identSym != nil: identSym else: genSym(nskLet, "inst")
  result = newStmtList()
  result.add newLetStmt(instVar,
    newCall(ident"instantiate", nlSym, designatorStrNode, templNode, portsSeq, globalsSym, kindNode))
  for p in fieldPairs:
    result.add dispatchField(instVar, componentKnownFields, p)
  result.copyLineInfo(stmt)

proc buildBody(nlSym, globalsSym: NimNode, body: NimNode): NimNode =
  result = newStmtList()
  for stmt in body:
    if stmt.kind == nnkCommentStmt:
      continue
    if stmt.kind notin {nnkCommand, nnkCall} or stmt.len == 0:
      error("expected a `net`, `component`, or `instance` statement", stmt)
    let head = stmt[0]
    if head.eqIdent("net"):
      result.add handleNet(nlSym, globalsSym, stmt)
    elif head.eqIdent("component"):
      result.add handleComponent(nlSym, globalsSym, stmt)
    elif head.eqIdent("instance"):
      result.add handleInstance(nlSym, globalsSym, stmt)
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
  result.add buildBody(nlSym, globalsSym, body)
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
  result.add buildBody(nlSym, globalsSym, body)
  for portIdent in ports:
    portIdent.expectKind(nnkIdent)
    result.add newCall(ident"addPort", nlSym, newLit(portIdent.strVal), portIdent)
  result.add nlSym
  result = newBlockStmt(result)
  result.copyLineInfo(body)
