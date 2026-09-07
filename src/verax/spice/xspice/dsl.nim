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
## **Why this is more than sugar.** ngspice's own workflow splits a code model
## across `ifspec.ifs` and `cfunc.mod`, two hand-maintained files with no
## cross-check; `cmpp` rewrites `PARAM(gain)` into
## `mif_private->param[i]->element[0].rvalue` using `i` = the row's position in
## the `.ifs` tables. Here one declaration produces both, so an accessor can be
## resolved against the ports and parameters that will actually be emitted --
## a misspelled port name is a Nim compile error pointing at the offending
## line, not a yacc error or a wrong-index read at runtime.
##
## This is a deliberate divergence from `verax/netlist/dsl.nim`, whose
## documented stance is that an unrecognised `key = value` silently becomes an
## `attrs` entry. There is no open-ended bag here: a mistyped port name has no
## valid meaning, so it fails.
##
## **Two expansion modes.** Normally the macro emits the `{.exportc, cdecl.}`
## entry point that ngspice calls. Under `-d:xspiceGenIfs` it instead emits a
## `main` that writes `ifspec.ifs` into a directory named on the command line,
## and imports none of the FFI -- so `.ifs` generation works on a machine with
## no ngspice headers. `xspice/build.nim` compiles the same source twice, once
## in each mode.
##
## Names reserved inside an `eval:` body: `analysis`, `callType`, `time`,
## `tstep`, `tstop`, `temperature`, `radFreq`, `init`, `newTimepoint`, and the
## accessor calls listed below. Shadowing one with a local is not supported.

import std/[macros, strutils]

const xspiceNoFfi* = defined(xspiceGenIfs) or defined(xspiceSpecOnly)
  ## Whether to emit the `{.exportc.}` entry point ngspice calls.
  ##
  ## Two situations want the declaration without the implementation, and
  ## neither can compile the implementation at all: the interface-generating
  ## pass of `buildCodeModel`, and **any program that merely instantiates the
  ## model** -- a design file, above all. The entry point is FFI against
  ## ngspice's MIF headers, which live only in a configured ngspice *source
  ## tree*, so importing a model to read its `ModelSpec` would otherwise make
  ## every design on the machine depend on that tree. The spec const is
  ## emitted either way, which is all an instantiating caller needs: port
  ## order, parameter names and the `.MODEL` card.
  ##
  ## `-d:xspiceSpecOnly` is what `verax check` passes; `-d:xspiceGenIfs`
  ## additionally emits the `ifspec.ifs` writer.

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
  ## Accepts either the Nim-ish spelling (`float`, `int`, `bool`, `string`,
  ## `complex`) or the enum name (`xtReal`, ...).
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
    # Giving a default says the parameter is optional; cmpp rejects the
    # combination of a Default_Value with Null_Allowed: no outright.
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
    ## Mirrors cmpp's `check_dir`: the declared direction must match, or be
    ## `inout`, which satisfies both.
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

    # `obj.time` must not have its field name rewritten.
    if n.kind == nnkDotExpr:
      return newTree(nnkDotExpr, rewrite(spec, mp, n[0]), n[1])

    result = copyNimNode(n)
    for child in n:
      result.add rewrite(spec, mp, child)

# --- the macro ---------------------------------------------------------------

macro codeModel*(name: untyped, body: untyped): untyped =
  ## Declare an XSPICE code model. See the module doc comment for the shape of
  ## the block and the list of accessors available inside `eval:`.
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

  # The spec and its rendered .ifs are always available, in both modes: the
  # build driver needs the text, and `xspice/instance.nim` needs the spec to
  # validate an A-device instantiation against the real port list.
  result.add newTree(nnkConstSection,
    newTree(nnkConstDef, postfix(specIdent, "*"), newEmptyNode(), newLit(spec)))
  result.add newTree(nnkConstSection,
    newTree(nnkConstDef, postfix(ifsIdent, "*"), newEmptyNode(), newLit(renderIfs(spec))))

  when xspiceNoFfi and not defined(xspiceGenIfs):
    # Spec only: the consts above are the whole module. Nothing further.
    discard
  elif defined(xspiceGenIfs):
    # Interface-only build: emit no FFI at all, so this compiles on a machine
    # with no ngspice headers.
    # Built with bindSym rather than `quote do`, because the emitted code lands
    # in the *user's* module, which has no reason to import std/cmdline.
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
