## The declarative interface of an XSPICE code model, as plain Nim data.
##
## This is the single source of truth that `xspice/ifs.nim` renders into an
## `ifspec.ifs` file *and* that `xspice/dsl.nim` reads to resolve accessor
## indices. That sharing is the whole point of the submodule: in the upstream
## C workflow `ifspec.ifs` and `cfunc.mod` are two hand-maintained files with
## no cross-check, and ngspice's `cmpp` only discovers a disagreement between
## them as a yacc error. Here one `ModelSpec` drives both halves, so they
## cannot drift.
##
## **Declaration order is load-bearing.** `cmpp` translates `PARAM(gain)` into
## `mif_private->param[i]->element[0].rvalue` where `i` is the row's position
## in the `.ifs` tables. `ports`/`params`/`stateVars` are `seq`s precisely so
## that position in the seq *is* that index, for both the renderer and the
## accessor rewriter.
##
## Nothing here touches C, ngspice, or the filesystem, so this module is
## usable (and testable) on a machine with no ngspice source tree.

import std/[strutils, sequtils, tables]

type
  XspiceSpecError* = object of CatchableError
    ## Raised by `validate` for a `ModelSpec` that `cmpp` would reject, or
    ## that would produce a code model whose accessors are wrongly typed.

  PortDir* = enum
    ## `Direction:` in a `PORT_TABLE`.
    xdIn, xdOut, xdInout

  PortType* = enum
    ## `Default_Type:` / `Allowed_Types:` in a `PORT_TABLE`.
    ##
    ## The prefix is `xp`, not `pt`, deliberately: `nimcir/netlist/types.nim`
    ## already exports `ptPassive`/`ptPower`/... and a user importing both
    ## modules would otherwise hit ambiguity on unqualified enum values.
    xpV,      ## `v`    single-ended voltage
    xpVd,     ## `vd`   differential voltage
    xpI,      ## `i`    single-ended current
    xpId,     ## `id`   differential current
    xpVnam,   ## `vnam` current through a named voltage source
    xpG,      ## `g`    single-ended VCIS
    xpGd,     ## `gd`   differential VCIS
    xpH,      ## `h`    single-ended ICVS
    xpHd,     ## `hd`   differential ICVS
    xpD       ## `d`    digital / event-driven

  DataType* = enum
    ## `Data_Type:` in a `PARAMETER_TABLE` or `STATIC_VAR_TABLE`.
    xtBool, xtInt, xtReal, xtComplex, xtString

  Bound* = object
    ## One `Limits:` or `Vector_Bounds:` cell.
    ##
    ## Endpoints are held as text rather than numbers because the `.ifs`
    ## format is textual and permits an *open* side -- `[1e-12 -]` is legal
    ## and means "at least 1e-12, no upper limit". Use the `bounds`/`atLeast`/
    ## `atMost` constructors rather than filling this in by hand.
    active*: bool   ## `false` renders the whole cell as `-`
    lo*, hi*: string  ## empty renders as `-`

  PortSpec* = object
    name*: string
    description*: string
    dir*: PortDir
    default*: PortType
      ## Also decides which `Mif_Value_t` member the accessors read: ngspice's
      ## `put_conn_type` maps digital to `.pvalue` and *every* analog type to
      ## `.rvalue`.
    allowed*: seq[PortType]
    vector*: bool
    vectorBounds*: Bound
    nullAllowed*: bool

  ParamSpec* = object
    name*: string
    description*: string
    dataType*: DataType
    default*: string
      ## Rendered verbatim into `Default_Value:`. Use `defaultOf` to format a
      ## typed value correctly (strings get quoted, bools become TRUE/FALSE).
    limits*: Bound
    vector*: bool
    vectorBounds*: Bound
    nullAllowed*: bool

  StateVarSpec* = object
    ## A `STATIC_VAR_TABLE` row -- per-instance storage that persists across
    ## calls. Note ngspice does *not* roll these back when it rejects a
    ## timestep; `cm_analog_alloc` state is what gets rolled back.
    name*: string
    description*: string
    dataType*: DataType

  ModelSpec* = object
    name*: string          ## `Spice_Model_Name:` -- what a `.model` card names
    cFunction*: string     ## `C_Function_Name:` -- the exported symbol
    description*: string
    ports*: seq[PortSpec]
    params*: seq[ParamSpec]
    stateVars*: seq[StateVarSpec]

const
  noBound* = Bound(active: false)

func bounds*(lo, hi: string): Bound = Bound(active: true, lo: lo, hi: hi)
func bounds*(lo, hi: float): Bound = bounds($lo, $hi)
func bounds*(lo, hi: int): Bound = bounds($lo, $hi)
func atLeast*(lo: float): Bound = bounds($lo, "")
func atLeast*(lo: int): Bound = bounds($lo, "")
func atMost*(hi: float): Bound = bounds("", $hi)
func atMost*(hi: int): Bound = bounds("", $hi)

func ifsName*(t: PortType): string =
  ## The `.ifs` spelling of a port type.
  case t
  of xpV: "v"
  of xpVd: "vd"
  of xpI: "i"
  of xpId: "id"
  of xpVnam: "vnam"
  of xpG: "g"
  of xpGd: "gd"
  of xpH: "h"
  of xpHd: "hd"
  of xpD: "d"

func ifsName*(d: PortDir): string =
  case d
  of xdIn: "in"
  of xdOut: "out"
  of xdInout: "inout"

func ifsName*(t: DataType): string =
  case t
  of xtBool: "boolean"
  of xtInt: "int"
  of xtReal: "real"
  of xtComplex: "complex"
  of xtString: "string"

func isDigital*(t: PortType): bool =
  ## Digital and user-defined ports read `Mif_Value_t.pvalue`; every analog
  ## type reads `.rvalue`. A port whose `allowed` set spanned both would make
  ## the accessor's field choice unsound, which is why `validate` rejects it.
  t == xpD

func defaultOf*(v: float): string = $v
func defaultOf*(v: int): string = $v
func defaultOf*(v: bool): string = (if v: "TRUE" else: "FALSE")
func defaultOf*(v: string): string = "\"" & v & "\""
  ## String defaults must be quoted in the `.ifs`.

func isIdent(s: string): bool =
  if s.len == 0: return false
  if not (s[0] in IdentStartChars): return false
  for c in s:
    if c notin IdentChars: return false
  true

proc validate*(spec: ModelSpec) =
  ## Raise `XspiceSpecError` for anything `cmpp` would reject, plus the two
  ## soundness rules the accessor layer depends on (see `isDigital`, and the
  ## `default in allowed` rule that keeps the rendered `.ifs` self-consistent).
  if not spec.name.isIdent:
    raise newException(XspiceSpecError,
      "Spice_Model_Name must be an identifier, got: " & spec.name.escape)
  if not spec.cFunction.isIdent:
    raise newException(XspiceSpecError,
      "C_Function_Name must be an identifier, got: " & spec.cFunction.escape)
  if spec.ports.len == 0:
    raise newException(XspiceSpecError,
      "code model '" & spec.name & "' declares no ports")

  var seenPorts: Table[string, int]
  for i, p in spec.ports:
    if not p.name.isIdent:
      raise newException(XspiceSpecError,
        "port name must be an identifier, got: " & p.name.escape)
    if p.name in seenPorts:
      raise newException(XspiceSpecError,
        "duplicate port name '" & p.name & "' in code model '" & spec.name & "'")
    seenPorts[p.name] = i
    if p.allowed.len == 0:
      raise newException(XspiceSpecError,
        "port '" & p.name & "' has an empty Allowed_Types list")
    if p.default notin p.allowed:
      raise newException(XspiceSpecError,
        "port '" & p.name & "' has Default_Type " & p.default.ifsName &
        " which is not in its Allowed_Types " &
        "[" & p.allowed.mapIt(it.ifsName).join(",") & "]")
    var nDigital = 0
    for t in p.allowed:
      if t.isDigital: inc nDigital
    if nDigital != 0 and nDigital != p.allowed.len:
      raise newException(XspiceSpecError,
        "port '" & p.name & "' mixes digital and analog Allowed_Types; the " &
        "accessor field (.pvalue vs .rvalue) would be ambiguous")
    if not p.vector and p.vectorBounds.active:
      raise newException(XspiceSpecError,
        "port '" & p.name & "' is not a vector but sets Vector_Bounds")

  var seenParams: Table[string, int]
  for i, pa in spec.params:
    if not pa.name.isIdent:
      raise newException(XspiceSpecError,
        "parameter name must be an identifier, got: " & pa.name.escape)
    if pa.name in seenParams:
      raise newException(XspiceSpecError,
        "duplicate parameter name '" & pa.name & "' in code model '" & spec.name & "'")
    seenParams[pa.name] = i
    if pa.dataType == xtString and pa.default.len > 0 and
       not (pa.default.startsWith("\"") and pa.default.endsWith("\"")):
      raise newException(XspiceSpecError,
        "string parameter '" & pa.name & "' has an unquoted Default_Value: " &
        pa.default & " (use defaultOf)")
    if not pa.vector and pa.vectorBounds.active:
      raise newException(XspiceSpecError,
        "parameter '" & pa.name & "' is not a vector but sets Vector_Bounds")
    if pa.default.len > 0 and not pa.nullAllowed:
      # cmpp: "Default value given for parameter X but the user must set
      # instance value (Null_Allowed: no)". Caught here so it surfaces as a
      # Nim error rather than a cmpp failure deep in the build driver.
      raise newException(XspiceSpecError,
        "parameter '" & pa.name & "' has a Default_Value but Null_Allowed is " &
        "no; a default is only meaningful if the parameter may be omitted")

  var seenVars: Table[string, int]
  for i, sv in spec.stateVars:
    if not sv.name.isIdent:
      raise newException(XspiceSpecError,
        "static var name must be an identifier, got: " & sv.name.escape)
    if sv.name in seenVars:
      raise newException(XspiceSpecError,
        "duplicate static var name '" & sv.name & "' in code model '" & spec.name & "'")
    seenVars[sv.name] = i

func portIndex*(spec: ModelSpec, name: string): int =
  ## Declaration-order index, i.e. the `i` in `mif_private->conn[i]`.
  ## Returns -1 when absent, so the DSL can emit its own `error()` with the
  ## offending AST node rather than raising at macro-expansion time.
  for i, p in spec.ports:
    if p.name == name: return i
  -1

func paramIndex*(spec: ModelSpec, name: string): int =
  ## Declaration-order index, i.e. the `i` in `mif_private->param[i]`.
  for i, p in spec.params:
    if p.name == name: return i
  -1

func stateVarIndex*(spec: ModelSpec, name: string): int =
  ## Declaration-order index, i.e. the `i` in `mif_private->inst_var[i]`.
  for i, v in spec.stateVars:
    if v.name == name: return i
  -1
