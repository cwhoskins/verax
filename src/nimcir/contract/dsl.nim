## Authoring a design together with what is claimed about it.
##
## `design(...)` accepts everything a `netlist(...)` block does -- it reuses
## `netlist/dsl.buildNetlistBody` rather than duplicating those handlers --
## and adds two statements of its own:
##
## ```nim
## let d = design("board"):
##   net vdd, kind = ntPower
##   net sda, kind = ntSignal
##   net scl, kind = ntSignal
##   component R1, kind = "resistor", value = "2.2k":
##     pin "1", vdd, kind = ptPassive
##     pin "2", sda, kind = ptPassive
##
##   role "power_rail", vdd_rail, rail = vdd, voltage = 3.3.V, band = 5.pct
##   role "i2c", i2c0, sda = sda, scl = scl, frequency = 400.kHz
##
##   require dc_voltage(vdd) == 3.3.V, band = 5.pct,
##           id = "REQ-PWR-001", because = "MCU VDD range is 3.0-3.6 V"
## ```
##
## **Part bindings and parameters are told apart by type, not by position.**
## A `role` statement is a flat list of `key = value` pairs; the expansion
## routes each one with `when compiles(subjectOf(value))`, so a `Net` or
## `Component` becomes a binding and a quantity, number or string becomes a
## parameter. That keeps the syntax flat and readable without the macro
## needing to consult the role registry, which is a runtime table it cannot
## see. Getting a binding or a parameter *name* wrong is still caught -- by
## `addRole`, at the point the role is attached.
##
## **`require` is spelled with ordinary Nim comparisons** (`==`, `>=`, `<=`)
## over `quantity(subjects)`, where the quantity is written exactly as the
## analysis `Measurement` names it (`dc_voltage`, `bw_3db`, `z_max_in_band`).
## Nim is style-insensitive, so `dc_voltage` and `dcVoltage` are the same
## identifier; the string used is what you typed.
##
## Everything here expands to calls on the runtime API in
## `nimcir/contract/design` -- the macro is a convenience for Nim authors and
## never the only way in. A real board comes from a file, not from
## hand-written Nim, so anything expressible only through a macro would be
## unusable on exactly the designs this is meant for.

import std/[macros, strutils, tables]
import ../netlist/types
import ../netlist/dsl as netlistDsl
import ../units
import ./types as ctypes
import ./roles
import ./design
import ./evaluate
import ./evaluators/static

# Importing the authoring DSL registers the built-in evaluators, exactly as
# importing `roles` registers the built-in roles: a design you can author but
# whose claims silently have no producer is the surprising half of that pair.
export netlistDsl, ctypes, roles, design, evaluate, static, units

# --- runtime helpers the macros expand into ----------------------------

proc subjectOf*(s: Subject): Subject = s
  ## Identity, so that anything already producing a `Subject` routes as a
  ## *binding* rather than a parameter.
  ##
  ## `role`'s macro tells bindings from parameters with
  ## `when compiles(subjectOf(value))`, which deliberately consults types
  ## rather than the role registry -- a runtime table the macro cannot see.
  ## This one overload opens that test to every helper that returns a
  ## `Subject`, `design.innerComponent` above all, without the macro learning
  ## anything about them.

proc subjectOf*(n: Net): Subject = Subject(kind: skNet, name: n.name)
proc subjectOf*(c: Component): Subject = Subject(kind: skComponent, name: c.designator)
proc subjectOf*(p: Pin): Subject =
  Subject(kind: skPin, name: p.component.designator & "." & p.name)

proc annText*(q: Quantity): string = formatFloat(toFloat(q), ffScientific, 9)
proc annText*(x: SomeNumber): string = formatFloat(float(x), ffScientific, 9)
proc annText*(s: string): string = s

proc expectEq*(v: Quantity, band: Fraction): Expectation =
  nominal(toFloat(v), fracTol = toFloat(band))
proc expectEq*(v: Quantity): Expectation = nominal(toFloat(v))
proc expectEq*(v: SomeNumber, band: Fraction): Expectation =
  nominal(float(v), fracTol = toFloat(band))
proc expectEq*(v: SomeNumber): Expectation = nominal(float(v))

proc expectMin*(v: Quantity): Expectation = atLeast(toFloat(v))
proc expectMin*(v: SomeNumber): Expectation = atLeast(float(v))
proc expectMax*(v: Quantity): Expectation = atMost(toFloat(v))
proc expectMax*(v: SomeNumber): Expectation = atMost(float(v))

proc unitText*(q: Quantity): string = unitOf(q)
proc unitText*(x: SomeNumber): string = ""

proc mkAssertion*(quantity: string, subjects: seq[Subject], e: Expectation,
                  unit: string, id = "", rationale = "",
                  severity = sevError,
                  condition: openArray[(string, string)] = []): Assertion =
  result = Assertion(id: id, subjects: subjects, quantity: quantity,
                     expect: e, unit: unit, severity: severity,
                     rationale: rationale, origin: "authored")
  for (k, v) in condition: result.condition[k] = v

# --- statement expansion -----------------------------------------------

proc labelOf(node: NimNode): string =
  case node.kind
  of nnkIdent: node.strVal
  of nnkStrLit: node.strVal
  else:
    error("expected an identifier or string literal name", node)

proc handleRole(dSym: NimNode, stmt: NimNode): NimNode =
  var args: seq[NimNode]
  for i in 1 ..< stmt.len: args.add stmt[i]
  if args.len < 2:
    error("`role` requires a role name and an instance name", stmt)
  let roleNameNode = args[0]
  let instName = labelOf(args[1])

  let bindsSym = genSym(nskVar, "binds")
  let paramsSym = genSym(nskVar, "params")
  result = newStmtList()
  # Explicitly typed: the `when` branches below may add to neither, so there
  # is nothing for Nim to infer an element type from.
  result.add newTree(nnkVarSection,
    newIdentDefs(bindsSym, parseExpr("seq[(string, Subject)]"),
                 newTree(nnkPrefix, ident"@", newTree(nnkBracket))))
  result.add newTree(nnkVarSection,
    newIdentDefs(paramsSym, parseExpr("seq[(string, string)]"),
                 newTree(nnkPrefix, ident"@", newTree(nnkBracket))))

  for a in args[2 ..^ 1]:
    if a.kind != nnkExprEqExpr:
      error("expected `part = net` or `param = value` in a `role` statement", a)
    let key = newLit(a[0].strVal)
    let val = a[1]
    # Type-directed: an entity is a binding, anything else is a parameter.
    let branch = newTree(nnkWhenStmt,
      newTree(nnkElifBranch,
        newCall(ident"compiles", newCall(ident"subjectOf", val)),
        newStmtList(newCall(newDotExpr(bindsSym, ident"add"),
          newTree(nnkTupleConstr, key, newCall(ident"subjectOf", val)))),
      ),
      newTree(nnkElse,
        newStmtList(newCall(newDotExpr(paramsSym, ident"add"),
          newTree(nnkTupleConstr, key, newCall(ident"annText", val))))))
    branch.copyLineInfo(a)
    result.add branch

  result.add newTree(nnkDiscardStmt,
    newCall(ident"addRole", dSym, roleNameNode, newLit(instName), bindsSym, paramsSym))
  result = newBlockStmt(result)
  result.copyLineInfo(stmt)

proc handleRequire(dSym: NimNode, stmt: NimNode): NimNode =
  var args: seq[NimNode]
  for i in 1 ..< stmt.len: args.add stmt[i]
  if args.len == 0:
    error("`require` needs a comparison, e.g. `dc_voltage(vdd) == 3.3.V`", stmt)

  let cmp = args[0]
  if cmp.kind != nnkInfix:
    error("`require` needs a comparison using ==, >= or <=", cmp)
  let op = cmp[0].strVal
  let lhs = cmp[1]
  let rhs = cmp[2]
  if lhs.kind notin {nnkCall, nnkCommand}:
    error("the left side must be `quantity(subject, ...)`, naming a " &
          "Measurement an analysis produces", lhs)

  let quantity = lhs[0].strVal
  var subjects = newTree(nnkBracket)
  for i in 1 ..< lhs.len:
    subjects.add newCall(ident"subjectOf", lhs[i])
  if subjects.len == 0:
    error("`" & quantity & "` needs at least one subject", lhs)

  var idNode: NimNode = newLit("")
  var becauseNode: NimNode = newLit("")
  var sevNode: NimNode = ident"sevError"
  var bandNode: NimNode = nil
  var conds = newTree(nnkBracket)
  for a in args[1 ..^ 1]:
    if a.kind != nnkExprEqExpr:
      error("expected `key = value` after the comparison", a)
    case a[0].strVal
    of "id": idNode = a[1]
    of "because": becauseNode = a[1]
    of "severity": sevNode = a[1]
    of "band": bandNode = a[1]
    else:
      conds.add newTree(nnkTupleConstr, newLit(a[0].strVal),
                        newCall(ident"annText", a[1]))

  var expectCall: NimNode
  case op
  of "==":
    if bandNode != nil:
      expectCall = newCall(ident"expectEq", rhs, bandNode)
    else:
      expectCall = newCall(ident"expectEq", rhs)
  of ">=": expectCall = newCall(ident"expectMin", rhs)
  of "<=": expectCall = newCall(ident"expectMax", rhs)
  else:
    error("`require` supports ==, >= and <=; got '" & op & "'", cmp[0])

  result = newCall(ident"assertThat", dSym,
    newCall(ident"mkAssertion", newLit(quantity),
      newTree(nnkPrefix, ident"@", subjects),
      expectCall,
      newCall(ident"unitText", rhs),
      idNode, becauseNode, sevNode,
      newTree(nnkPrefix, ident"@", conds)))
  result.copyLineInfo(stmt)

proc buildDesignBody(dSym, nlSym, globalsSym: NimNode, body: NimNode): NimNode =
  ## Netlist statements go to `netlist/dsl`'s own handlers; the two design
  ## statements are handled here. Splitting the body rather than extending
  ## the netlist DSL keeps `netlist(...)` free of any notion of a claim.
  result = newStmtList()
  var netlistStmts = newStmtList()
  var trailing = newStmtList()

  for stmt in body:
    if stmt.kind == nnkCommentStmt: continue
    if stmt.kind in {nnkCommand, nnkCall} and stmt.len > 0 and
       (stmt[0].eqIdent("role") or stmt[0].eqIdent("require")):
      # Roles and requirements are attached after the graph exists, since
      # they refer to nets and components the netlist statements create.
      if stmt[0].eqIdent("role"): trailing.add handleRole(dSym, stmt)
      else: trailing.add handleRequire(dSym, stmt)
    else:
      netlistStmts.add stmt

  result.add netlistDsl.buildNetlistBody(nlSym, globalsSym, netlistStmts)
  result.add newLetStmt(dSym, newCall(ident"newDesign", nlSym))
  result.add trailing

macro design*(name: untyped, body: untyped): untyped =
  ## Builds a `Design`: a `Netlist` plus the roles and requirements attached
  ## to it. Accepts every statement `netlist(...)` does, plus `role` and
  ## `require`.
  name.expectKind(nnkStrLit)
  let nlSym = genSym(nskLet, "nl")
  let globalsSym = genSym(nskVar, "globalNets")
  let dSym = genSym(nskLet, "design")
  result = newStmtList()
  result.add newLetStmt(nlSym, newCall(ident"newNetlist", name))
  result.add newTree(nnkVarSection,
    newIdentDefs(globalsSym,
      newTree(nnkBracketExpr, bindSym("OrderedTable"), ident"string", ident"Net")))
  result.add buildDesignBody(dSym, nlSym, globalsSym, body)
  result.add dSym
  result = newBlockStmt(result)
  result.copyLineInfo(body)
