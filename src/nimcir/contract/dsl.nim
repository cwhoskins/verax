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
import ./roles/built_in as roles
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

proc dep*(name: string, quantity: string, subjects: seq[Subject]): PredicateDep =
  ## One named dependency of a predicate, in the order the predicate's proc
  ## receives them.
  PredicateDep(name: name,
               measurement: MeasurementRef(quantity: quantity,
                                           subjects: subjects))

proc relAssertion*(quantity: string, subjects: seq[Subject],
                   op: RelativeOp, coeff: float,
                   refQuantity: string, refSubjects: seq[Subject],
                   band = 0.0, id = "", rationale = "",
                   severity = sevError,
                   conditions: openArray[(string, string)] = []): Assertion =
  ## The runtime form of `require q(x) <= 0.2 * r(y)`. The trailing
  ## conditions are stamped on both the claim and its reference; a caller
  ## that needs the reference measured under different circumstances builds
  ## the `MeasurementRef` itself and uses `relative`/`mkAssertion`.
  var reference = measurementRef(refQuantity, refSubjects)
  for (k, v) in conditions: reference.condition[k] = v
  let e = relative(op, coeff, reference, fracTol = band)
  result = mkAssertion(quantity, subjects, e, "", id, rationale, severity,
                       conditions)

proc predicateAssertion*(deps: seq[PredicateDep], pred: PredicateProc,
                         id = "", rationale = "", severity = sevError,
                         conditions: openArray[(string, string)] = []): Assertion =
  ## The runtime form of `require pred(a = q(x), b = r(y)) do ...`. The
  ## trailing conditions are stamped on every dependency's measurement, since
  ## a predicate has no left-hand measurement of its own to carry them.
  var ds = deps
  for d in ds.mitems:
    for (k, v) in conditions: d.measurement.condition[k] = v
  result = Assertion(id: id, subjects: @[], quantity: "predicate",
                     expect: predicate(ds, pred), unit: "",
                     severity: severity, rationale: rationale,
                     origin: "authored")
  for (k, v) in conditions: result.condition[k] = v

# --- statement expansion -----------------------------------------------

proc fieldName(node: NimNode): string =
  if node.kind == nnkIdent: node.strVal
  elif node.kind == nnkAccQuoted and node.len == 1: node[0].strVal
  else: error("expected an identifier", node)

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
  var fromNode: NimNode = nil
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
    if fieldName(a[0]) == "from":
      if fromNode != nil: error("`role` accepts only one `from =`", a)
      fromNode = a[1]
      continue
    let key = newLit(fieldName(a[0]))
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

  let attach = if fromNode == nil:
    newCall(ident"addRole", dSym, roleNameNode, newLit(instName), bindsSym, paramsSym)
  else:
    newCall(ident"addRoleFromInterface", dSym, roleNameNode, newLit(instName),
            fromNode, bindsSym, paramsSym)
  result.add newTree(nnkDiscardStmt, attach)
  result = newBlockStmt(result)
  result.copyLineInfo(stmt)

proc isMeasurementCall(node: NimNode): bool =
  ## `quantity(subject, ...)`: a call whose head is a plain identifier.
  ## The registry is a runtime table a macro cannot see, so -- exactly as the
  ## `role` macro does for bindings -- the decision is syntactic: on the RHS
  ## of a `require` a call *is* a measurement reference. A computed plain
  ## value belongs in a `let` binding first.
  node.kind in {nnkCall, nnkCommand} and node.len > 0 and
    node[0].kind == nnkIdent

proc isPlainNumber(node: NimNode): bool =
  case node.kind
  of nnkIntLit, nnkFloatLit: true
  of nnkPrefix:
    node.len == 2 and node[0].strVal in ["-", "+"] and isPlainNumber(node[1])
  else: false

proc measurementParts(node: NimNode): tuple[quantity: string, subjects: NimNode] =
  let quantity = node[0].strVal
  var subjects = newTree(nnkBracket)
  for i in 1 ..< node.len:
    subjects.add newCall(ident"subjectOf", node[i])
  (quantity, subjects)

proc handleComparison(dSym: NimNode, stmt: NimNode, args: seq[NimNode],
                      cmp: NimNode): NimNode =
  let op = cmp[0].strVal
  let lhs = cmp[1]
  let rhs = cmp[2]
  if op notin ["==", ">=", "<="]:
    error("`require` supports ==, >= and <=; got '" & op & "'", cmp[0])
  if lhs.kind notin {nnkCall, nnkCommand}:
    error("the left side must be `quantity(subject, ...)`, naming a " &
          "Measurement an analysis produces", lhs)

  let (quantity, subjects) = measurementParts(lhs)
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

  # A measurement on the right makes the bound *relative*: `q(x) <= 0.2 *
  # r(y)`. The only arithmetic the relative form accepts is a plain number
  # times a measurement, in either order; anything richer is a predicate.
  let rhsIsRef = isMeasurementCall(rhs)
  let rhsIsScaled =
    rhs.kind == nnkInfix and rhs[0].strVal == "*" and
    ((isPlainNumber(rhs[1]) and isMeasurementCall(rhs[2])) or
     (isMeasurementCall(rhs[1]) and isPlainNumber(rhs[2])))

  if rhsIsRef or rhsIsScaled:
    var coeffNode, refNode: NimNode
    if rhsIsRef:
      coeffNode = newLit(1.0)
      refNode = rhs
    elif isMeasurementCall(rhs[1]):
      coeffNode = rhs[2]
      refNode = rhs[1]
    else:
      coeffNode = rhs[1]
      refNode = rhs[2]
    let (refQuantity, refSubjects) = measurementParts(refNode)
    let relOpNode = case op
      of "==": ident"roEq"
      of ">=": ident"roGe"
      else: ident"roLe"
    # `band` means the same as it does for a plain `==`: the tolerance on the
    # relative equality. It is ignored for >= and <=, exactly as the plain
    # path ignores it.
    let bandArg =
      if op == "==" and bandNode != nil: newCall(ident"toFloat", bandNode)
      else: newLit(0.0)
    result = newCall(ident"assertThat", dSym,
      newCall(ident"relAssertion", newLit(quantity),
        newTree(nnkPrefix, ident"@", subjects),
        relOpNode, coeffNode,
        newLit(refQuantity),
        newTree(nnkPrefix, ident"@", refSubjects),
        bandArg, idNode, becauseNode, sevNode,
        newTree(nnkPrefix, ident"@", conds)))
    result.copyLineInfo(stmt)
    return

  if rhs.kind == nnkInfix:
    error("arithmetic over a measurement is not a plain bound; `require` " &
          "supports `number * measurement` relative bounds -- for anything " &
          "else, write `require pred(a = ..., b = ...) do (a, b: float) " &
          "-> bool: ...`", rhs)

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

proc handlePredicate(dSym: NimNode, stmt: NimNode, head: NimNode): NimNode =
  ## `require pred(a = q(x), b = r(y), id = ..., f_from = ...) do ...`.
  ## Dependencies are named; trailing conditions are stamped on every one;
  ## the proc is non-capturing and receives the dependency values in order.
  var deps = newTree(nnkBracket)
  var idNode: NimNode = newLit("")
  var becauseNode: NimNode = newLit("")
  var sevNode: NimNode = ident"sevError"
  var conds = newTree(nnkBracket)
  var doNode: NimNode = nil

  for i in 1 ..< head.len:
    let a = head[i]
    if a.kind == nnkDo:
      doNode = a
      continue
    if a.kind != nnkExprEqExpr:
      error("expected `name = quantity(...)` or `key = value` inside " &
            "`pred(...)`", a)
    let key = a[0].strVal
    let val = a[1]
    case key
    of "id": idNode = val
    of "because": becauseNode = val
    of "severity": sevNode = val
    else:
      if isMeasurementCall(val):
        let (qty, subjects) = measurementParts(val)
        deps.add newCall(ident"dep", newLit(key), newLit(qty),
                         newTree(nnkPrefix, ident"@", subjects))
      else:
        conds.add newTree(nnkTupleConstr, newLit(key),
                          newCall(ident"annText", val))

  if doNode == nil:
    error("`pred(...)` needs a `do (a, b: float) -> bool` body after it", head)

  var formalParams: NimNode = nil
  for c in doNode:
    if c.kind == nnkFormalParams:
      formalParams = c
      break
  if formalParams == nil:
    error("the predicate body must declare `(a, b: float) -> bool`", doNode)
  if formalParams.len == 0 or not formalParams[0].eqIdent("bool"):
    error("a predicate must return bool", formalParams[0])

  var paramNames: seq[NimNode]
  for i in 1 ..< formalParams.len:
    let defs = formalParams[i]
    if defs.kind != nnkIdentDefs:
      error("expected `name: float` in the predicate parameters", defs)
    for j in 0 ..< defs.len - 2:
      paramNames.add defs[j]

  if paramNames.len != deps.len:
    error("`pred` names " & $deps.len & " dependenc" &
          (if deps.len == 1: "y" else: "ies") & " but the proc takes " &
          $paramNames.len & " parameter(s)", doNode)

  let valueParam = genSym(nskParam, "values")
  let lambdaParams = newTree(nnkFormalParams, ident"bool",
    newTree(nnkIdentDefs, valueParam,
      newTree(nnkBracketExpr, ident"seq", ident"float"), newEmptyNode()))
  var lambdaBody = newStmtList()
  for i, name in paramNames:
    lambdaBody.add newLetStmt(name,
      newTree(nnkBracketExpr, valueParam, newLit(i)))
  let authorBody = doNode[^1]
  if authorBody.kind == nnkStmtList:
    for c in authorBody: lambdaBody.add c
  else:
    lambdaBody.add authorBody
  let lambda = newTree(nnkLambda,
    newEmptyNode(), newEmptyNode(), newEmptyNode(),
    lambdaParams, newEmptyNode(), newEmptyNode(), lambdaBody)

  result = newCall(ident"assertThat", dSym,
    newCall(ident"predicateAssertion",
      newTree(nnkPrefix, ident"@", deps),
      lambda,
      idNode, becauseNode, sevNode,
      newTree(nnkPrefix, ident"@", conds)))
  result.copyLineInfo(stmt)

proc handleRequire(dSym: NimNode, stmt: NimNode): NimNode =
  var args: seq[NimNode]
  for i in 1 ..< stmt.len: args.add stmt[i]
  if args.len == 0:
    error("`require` needs a comparison, or a `pred(...)` predicate", stmt)

  let head = args[0]
  if head.kind == nnkInfix:
    result = handleComparison(dSym, stmt, args, head)
  elif head.kind in {nnkCall, nnkCommand} and head.len > 0 and
       head[0].eqIdent("pred"):
    result = handlePredicate(dSym, stmt, head)
  else:
    error("`require` needs a comparison using ==, >= or <=, or a `pred(...)` " &
          "predicate", head)

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
  result.add newCall(ident"addImpliedRoles", dSym)

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
