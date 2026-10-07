## A Nim-macro DSL for authoring an XSPICE code model -- the interface *and*
## the body -- in one declaration.
##
## ```nim
## import verax/spice/xspice/dsl
##
## codeModel "gain":
##   description "a gain block"
##   port inp,  dir = xdIn,  default = xpV, allowed = [xpV, xpVd, xpI, xpId]
##   port outp, dir = xdOut, default = xpV, allowed = [xpV, xpVd, xpI, xpId]
##   param gain,     float, default = 1.0
##   param inOffset, float, default = 0.0
##   eval:
##     if analysis != maAc:
##       output(outp) = param(gain) * (input(inp) + param(inOffset))
##       partial(outp, inp) = param(gain)
## ```
##
## **More than sugar**: ngspice splits a model across `ifspec.ifs` and
## `cfunc.mod` with no cross-check. One declaration here produces both, so
## accessors resolve against the real ports and parameters and a misspelled
## port is a Nim compile error. (Unlike `netlist/dsl`, there's no open
## `attrs` fallback: unknown names fail.)
##
## **Two expansion modes**: normally the `{.exportc, cdecl.}` entry point;
## under `-d:xspiceGenIfs` a `main` that writes `ifspec.ifs`, with no FFI
## (works without ngspice headers). `xspice/build.nim` compiles both.
##
## Reserved in `eval:`: `analysis`, `callType`, `time`, `tstep`, `tstop`,
## `temperature`, `radFreq`, `init`, `newTimepoint`, and the accessors.
## Don't shadow them.

import std/[macros, strutils]

const xspiceNoFfi* = defined(xspiceGenIfs) or defined(xspiceSpecOnly)
  ## Whether to emit the `{.exportc.}` entry point. Skipped for the
  ## `.ifs`-generating pass and for any program that only instantiates the
  ## model (a design file), since the entry point needs ngspice's MIF headers
  ## from a configured source tree. The spec const is always emitted.
  ## `verax check` passes `-d:xspiceSpecOnly`; `-d:xspiceGenIfs` also emits
  ## the `.ifs` writer.

when defined(xspiceGenIfs):
  import std/cmdline  # only the interface-writer branch needs paramCount/paramStr
import ./spec, ./ifs
export spec

when not xspiceNoFfi:
  import ./accessors
  export accessors

# --- parsing the declaration into a ModelSpec --------------------------------

proc badNode(n: NimNode, msg: string) {.noreturn.} =
  error(msg, n)   # `error` is itself noreturn, so nothing follows

proc identStr(n: NimNode): string =
  if n.kind notin {nnkIdent, nnkSym}:
    badNode(n, "expected a name here, got " & $n.kind)
  n.strVal

proc parsePortType(n: NimNode): PortType =
  try: parseEnum[PortType](identStr(n))
  except ValueError:
    badNode(n, "unknown port type '" & n.repr &
      "'; expected one of xpV xpVd xpI xpId xpVnam xpG xpGd xpH xpHd xpD")

proc parsePortDir(n: NimNode): PortDir =
  try: parseEnum[PortDir](identStr(n))
  except ValueError:
    badNode(n, "unknown direction '" & n.repr & "'; expected xdIn, xdOut or xdInout")

proc parseDataType(n: NimNode): DataType =
  ## Accepts `float`/`int`/`bool`/`string`/`complex` or the enum name
  ## (`xtReal`, ...).
  case identStr(n).toLowerAscii
  of "float", "real", "xtreal": xtReal
  of "int", "integer", "xtint": xtInt
  of "bool", "boolean", "xtbool": xtBool
  of "string", "xtstring": xtString
  of "complex", "xtcomplex": xtComplex
  else:
    badNode(n, "unknown data type '" & n.repr &
      "'; expected float, int, bool, string or complex")

proc literalText(n: NimNode): string =
  ## Render a default value as the text the `.ifs` grammar wants.
  case n.kind
  of nnkFloatLit..nnkFloat64Lit: $n.floatVal
  of nnkIntLit..nnkInt64Lit: $n.intVal
  of nnkStrLit: defaultOf(n.strVal)
  of nnkPrefix:
    if n[0].kind == nnkIdent and n[0].strVal == "-": "-" & literalText(n[1])
    else: badNode(n, "unsupported default value: " & n.repr)
  of nnkIdent:
    case n.strVal
    of "true": "TRUE"
    of "false": "FALSE"
    else: badNode(n, "unsupported default value: " & n.repr)
  else: badNode(n, "unsupported default value: " & n.repr)

proc boundText(n: NimNode): string =
  ## One endpoint of a `[lo, hi]` bound; `_` means open on that side.
  if n.kind == nnkIdent and n.strVal == "_": ""
  else: literalText(n)

proc parseBound(n: NimNode): Bound =
  if n.kind != nnkBracket or n.len != 2:
    badNode(n, "expected a two-element bound like [0.0, 10.0]; use _ for an open side")
  bounds(boundText(n[0]), boundText(n[1]))

proc boolOf(n: NimNode): bool =
  if n.kind == nnkIdent and n.strVal == "true": true
  elif n.kind == nnkIdent and n.strVal == "false": false
  else: badNode(n, "expected true or false, got " & n.repr)

proc handlePort(stmt: NimNode): PortSpec =
  ## `port inp, dir = xdIn, default = xpV, allowed = [...]`
  if stmt.len < 2: badNode(stmt, "`port` needs a name")
  result = PortSpec(name: identStr(stmt[1]), dir: xdIn, default: xpV)
  var sawDefault = false
  for i in 2 ..< stmt.len:
    let pair = stmt[i]
    if pair.kind != nnkExprEqExpr:
      badNode(pair, "expected `key = value` in a `port` declaration")
    case identStr(pair[0])
    of "dir": result.dir = parsePortDir(pair[1])
    of "default":
      result.default = parsePortType(pair[1])
      sawDefault = true
    of "allowed":
      if pair[1].kind != nnkBracket:
        badNode(pair[1], "`allowed` expects a bracketed list, e.g. [xpV, xpVd]")
      for t in pair[1]: result.allowed.add parsePortType(t)
    of "description": result.description = pair[1].strVal
    of "vector": result.vector = boolOf(pair[1])
    of "vectorBounds": result.vectorBounds = parseBound(pair[1])
    of "nullAllowed": result.nullAllowed = boolOf(pair[1])
    else:
      badNode(pair[0], "unknown `port` field '" & pair[0].repr &
        "'; expected dir, default, allowed, description, vector, " &
        "vectorBounds or nullAllowed")
  if result.allowed.len == 0:
    result.allowed = @[result.default]
  elif not sawDefault:
    result.default = result.allowed[0]

proc handleParam(stmt: NimNode): ParamSpec =
  ## `param gain, float, default = 1.0, limits = [0.0, _]`
  if stmt.len < 3: badNode(stmt, "`param` needs a name and a data type")
  result = ParamSpec(name: identStr(stmt[1]), dataType: parseDataType(stmt[2]))
  var sawNullAllowed = false
  for i in 3 ..< stmt.len:
    let pair = stmt[i]
    if pair.kind != nnkExprEqExpr:
      badNode(pair, "expected `key = value` in a `param` declaration")
    case identStr(pair[0])
    of "default": result.default = literalText(pair[1])
    of "limits": result.limits = parseBound(pair[1])
    of "description": result.description = pair[1].strVal
    of "vector": result.vector = boolOf(pair[1])
    of "vectorBounds": result.vectorBounds = parseBound(pair[1])
    of "nullAllowed":
      result.nullAllowed = boolOf(pair[1])
      sawNullAllowed = true
    else:
      badNode(pair[0], "unknown `param` field '" & pair[0].repr &
        "'; expected default, limits, description, vector, vectorBounds " &
        "or nullAllowed")
  if result.default.len > 0 and not sawNullAllowed:
    # A default makes it optional; cmpp rejects a default with
    # `Null_Allowed: no`.
    result.nullAllowed = true

proc handleStateVar(stmt: NimNode): StateVarSpec =
  ## `stateVar lastValue, float`
  if stmt.len < 3: badNode(stmt, "`stateVar` needs a name and a data type")
  result = StateVarSpec(name: identStr(stmt[1]), dataType: parseDataType(stmt[2]))
  for i in 3 ..< stmt.len:
    let pair = stmt[i]
    if pair.kind != nnkExprEqExpr:
      badNode(pair, "expected `key = value` in a `stateVar` declaration")
    case identStr(pair[0])
    of "description": result.description = pair[1].strVal
    else: badNode(pair[0], "unknown `stateVar` field '" & pair[0].repr & "'")

# --- rewriting the eval body -------------------------------------------------

when not xspiceNoFfi:

  proc portOf(spec: ModelSpec, n: NimNode, ctx: string): int =
    result = spec.portIndex(identStr(n))
    if result < 0:
      var names: seq[string]
      for p in spec.ports: names.add p.name
      badNode(n, "no port named '" & n.repr & "' in code model '" & spec.name &
        "'; declared ports: " & names.join(", ") & " (in " & ctx & ")")

  proc requireDir(spec: ModelSpec, i: int, want: PortDir, n: NimNode, ctx: string) =
    ## Mirrors cmpp's `check_dir`: the direction must match, or be `inout`.
    let d = spec.ports[i].dir
    if d != want and d != xdInout:
      badNode(n, "port '" & spec.ports[i].name & "' is " & d.ifsName &
        ", but " & ctx & "() requires " & want.ifsName & " or inout")

  proc sub(n: NimNode, idx: int): NimNode =
    if n.len > idx: n[idx] else: newLit(0)

  proc paramAccess(spec: ModelSpec, mp, n: NimNode, arr: bool): NimNode =
    let name = identStr(n[1])
    let i = (if arr: spec.stateVarIndex(name) else: spec.paramIndex(name))
    if i < 0:
      badNode(n[1], "no " & (if arr: "stateVar" else: "parameter") & " named '" &
        name & "' in code model '" & spec.name & "'")
    let dt = (if arr: spec.stateVars[i].dataType else: spec.params[i].dataType)
    let fn =
      if arr:
        case dt
        of xtBool: bindSym"mifStateBool"
        of xtInt: bindSym"mifStateInt"
        of xtReal: bindSym"mifStateReal"
        of xtComplex: bindSym"mifStateComplex"
        of xtString: bindSym"mifStateStr"
      else:
        case dt
        of xtBool: bindSym"mifParamBool"
        of xtInt: bindSym"mifParamInt"
        of xtReal: bindSym"mifParamReal"
        of xtComplex: bindSym"mifParamComplex"
        of xtString: bindSym"mifParamStr"
    newCall(fn, mp, newLit(i), sub(n, 2))

  proc rewrite(spec: ModelSpec, mp, n: NimNode): NimNode =
    if n.kind in {nnkCall, nnkCommand} and n.len >= 1 and n[0].kind == nnkIdent:
      let head = n[0].strVal
      template port1(want: PortDir, ctx: string): int =
        (let i = portOf(spec, n[1], ctx); requireDir(spec, i, want, n[1], ctx); i)
      case head
      of "param": return paramAccess(spec, mp, n, false)
      of "stateVar": return paramAccess(spec, mp, n, true)
      of "paramSize":
        return newCall(bindSym"mifParamSize", mp, newLit(spec.paramIndex(identStr(n[1]))))
      of "paramNull":
        return newCall(bindSym"mifParamNull", mp, newLit(spec.paramIndex(identStr(n[1]))))
      of "stateVarSize":
        return newCall(bindSym"mifStateSize", mp, newLit(spec.stateVarIndex(identStr(n[1]))))
      of "input":
        let i = port1(xdIn, "input")
        if spec.ports[i].allowed[0].isDigital:
          return newTree(nnkBracketExpr,
            newCall(bindSym"mifInputDigitalPtr", mp, newLit(i), sub(n, 2)))
        return newCall(bindSym"mifInputReal", mp, newLit(i), sub(n, 2))
      of "output":
        let i = port1(xdOut, "output")
        if spec.ports[i].allowed[0].isDigital:
          return newTree(nnkBracketExpr,
            newCall(bindSym"mifOutputDigitalPtr", mp, newLit(i), sub(n, 2)))
        return newCall(bindSym"mifOutputReal", mp, newLit(i), sub(n, 2))
      of "inputState":
        return newCall(bindSym"mifInputState", mp, newLit(port1(xdIn, "inputState")), sub(n, 2))
      of "inputStrength":
        return newCall(bindSym"mifInputStrength", mp, newLit(port1(xdIn, "inputStrength")), sub(n, 2))
      of "outputState":
        return newCall(bindSym"mifOutputState", mp, newLit(port1(xdOut, "outputState")), sub(n, 2))
      of "outputStrength":
        return newCall(bindSym"mifOutputStrength", mp, newLit(port1(xdOut, "outputStrength")), sub(n, 2))
      of "setOutput":
        # setOutput(port, state[, strength])
        let i = port1(xdOut, "setOutput")
        result = newCall(bindSym"setOutputDigital", mp, newLit(i), newLit(0),
                         rewrite(spec, mp, n[2]))
        if n.len > 3: result.add rewrite(spec, mp, n[3])
        return result
      of "partial", "acGain":
        let fn = (if head == "partial": bindSym"mifPartial" else: bindSym"mifAcGain")
        # partial(out, in) or partial(out, outSub, in, inSub)
        if n.len == 3:
          let o = port1(xdOut, head)
          let i = portOf(spec, n[2], head)
          requireDir(spec, i, xdIn, n[2], head)
          return newCall(fn, mp, newLit(o), newLit(0), newLit(i), newLit(0))
        elif n.len == 5:
          let o = portOf(spec, n[1], head)
          requireDir(spec, o, xdOut, n[1], head)
          let i = portOf(spec, n[3], head)
          requireDir(spec, i, xdIn, n[3], head)
          return newCall(fn, mp, newLit(o), n[2], newLit(i), n[4])
        else:
          badNode(n, head & "() takes (out, in) or (out, outSub, in, inSub)")
      of "portSize":
        return newCall(bindSym"mifPortSize", mp, newLit(portOf(spec, n[1], "portSize")))
      of "portNull":
        return newCall(bindSym"mifPortNull", mp, newLit(portOf(spec, n[1], "portNull")))
      of "outputChanged":
        return newCall(bindSym"mifChanged", mp, newLit(portOf(spec, n[1], "outputChanged")), sub(n, 2))
      of "outputDelay":
        return newCall(bindSym"mifOutputDelay", mp, newLit(port1(xdOut, "outputDelay")), sub(n, 2))
      of "changed":
        return newCall(bindSym"mifChanged", mp, newLit(portOf(spec, n[1], "changed")), sub(n, 2))
      of "load":
        return newCall(bindSym"mifLoad", mp, newLit(portOf(spec, n[1], "load")), sub(n, 2))
      of "totalLoad":
        return newCall(bindSym"mifTotalLoad", mp, newLit(portOf(spec, n[1], "totalLoad")), sub(n, 2))
      of "t":
        return newCall(bindSym"mifT", mp, rewrite(spec, mp, n[1]))
      else: discard

    if n.kind == nnkAsgn and n[0].kind in {nnkCall, nnkCommand} and
       n[0].len >= 2 and n[0][0].kind == nnkIdent:
      let head = n[0][0].strVal
      let setter =
        case head
        of "outputState": bindSym"setOutputState"
        of "outputStrength": bindSym"setOutputStrength"
        of "outputChanged": bindSym"setOutputChanged"
        else: nil
      if setter != nil:
        let want = (if head == "outputChanged": xdOut else: xdOut)
        let i = portOf(spec, n[0][1], head)
        if head != "outputChanged": requireDir(spec, i, want, n[0][1], head)
        return newCall(setter, mp, newLit(i), sub(n[0], 2),
                       rewrite(spec, mp, n[1]))

    if n.kind == nnkIdent:
      case n.strVal
      of "analysis": return newCall(bindSym"mifAnalysis", mp)
      of "callType": return newCall(bindSym"mifCallType", mp)
      of "time": return newCall(bindSym"mifTime", mp)
      of "tstep": return newCall(bindSym"mifTstep", mp)
      of "tstop": return newCall(bindSym"mifTstop", mp)
      of "temperature": return newCall(bindSym"mifTemperature", mp)
      of "radFreq": return newCall(bindSym"mifRadFreq", mp)
      of "init": return newCall(bindSym"mifInit", mp)
      of "newTimepoint": return newCall(bindSym"mifNewTimepoint", mp)
      else: return n

    # Don't rewrite field names in `obj.time`.
    if n.kind == nnkDotExpr:
      return newTree(nnkDotExpr, rewrite(spec, mp, n[0]), n[1])

    result = copyNimNode(n)
    for child in n:
      result.add rewrite(spec, mp, child)

# --- the macro ---------------------------------------------------------------

macro codeModel*(name: untyped, body: untyped): untyped =
  ## Declare an XSPICE code model; see the module doc for the block shape
  ## and `eval:` accessors.
  let modelName =
    if name.kind == nnkStrLit: name.strVal
    else: identStr(name)

  var spec = ModelSpec(name: modelName, cFunction: "cm_" & modelName)
  var evalBody: NimNode = nil

  for stmt in body:
    if stmt.kind == nnkCall and stmt.len == 2 and stmt[0].kind == nnkIdent and
       stmt[0].strVal == "eval":
      if evalBody != nil: badNode(stmt, "a code model may declare only one `eval:` block")
      evalBody = stmt[1]
      continue
    if stmt.kind notin {nnkCommand, nnkCall}:
      badNode(stmt, "unexpected statement in a `codeModel` block: " & stmt.repr)
    case identStr(stmt[0])
    of "description": spec.description = stmt[1].strVal
    of "cFunction": spec.cFunction = stmt[1].strVal
    of "port": spec.ports.add handlePort(stmt)
    of "param": spec.params.add handleParam(stmt)
    of "stateVar": spec.stateVars.add handleStateVar(stmt)
    else:
      badNode(stmt[0], "unknown `codeModel` statement '" & stmt[0].repr &
        "'; expected description, cFunction, port, param, stateVar or eval")

  try:
    validate(spec)
  except XspiceSpecError as e:
    badNode(body, e.msg)

  result = newStmtList()
  let specIdent = ident(modelName & "Spec")
  let ifsIdent = ident(modelName & "Ifs")

  # The spec and `.ifs` text are emitted in every mode: the build driver
  # and `xspice/instance.nim` need them.
  result.add newTree(nnkConstSection,
    newTree(nnkConstDef, postfix(specIdent, "*"), newEmptyNode(), newLit(spec)))
  result.add newTree(nnkConstSection,
    newTree(nnkConstDef, postfix(ifsIdent, "*"), newEmptyNode(), newLit(renderIfs(spec))))

  when xspiceNoFfi and not defined(xspiceGenIfs):
    # Spec only: nothing further.
    discard
  elif defined(xspiceGenIfs):
    # Interface-only build: no FFI. Uses bindSym (not `quote do`) because the
    # code lands in the user's module, which needn't import std/cmdline.
    let mainBody = newStmtList(
      newTree(nnkIfStmt,
        newTree(nnkElifBranch,
          infix(newCall(bindSym"paramCount"), ">=", newLit(1)),
          newStmtList(newCall(bindSym"writeIfsFile",
                              newCall(bindSym"paramStr", newLit(1)), ifsIdent))),
        newTree(nnkElse,
          newStmtList(newCall(bindSym"quit",
            newLit("usage: <exe> <output-dir>   (writes ifspec.ifs there)"),
            newLit(1))))))
    result.add newTree(nnkWhenStmt,
      newTree(nnkElifBranch, ident"isMainModule", mainBody))
  else:
    if evalBody == nil:
      badNode(body, "code model '" & modelName & "' has no `eval:` block")
    let mp = genSym(nskParam, "mifPrivate")
    let rewritten = rewrite(spec, mp, evalBody)
    let msg = newLit("verax: unhandled exception escaped " & spec.cFunction)
    let entry = newProc(
      name = ident(spec.cFunction),
      params = @[newEmptyNode(),
                 newIdentDefs(mp, newTree(nnkPtrTy, bindSym"MifPrivate"))],
      body = newStmtList(
        newTree(nnkTryStmt,
          newStmtList(rewritten),
          newTree(nnkExceptBranch, ident"Exception",
            newStmtList(newCall(bindSym"cmMessageSend", msg))))))
    entry.addPragma(newTree(nnkExprColonExpr, ident"exportc", newLit(spec.cFunction)))
    entry.addPragma(ident"cdecl")
    entry.addPragma(newTree(nnkExprColonExpr, ident"raises", newTree(nnkBracket)))
    result.add entry
