## The Python front end's only Nim-side module: a `nimpy` extension exposing
## a curated slice of `verax/netlist/graph`, `verax/netlist/annotations` and
## `verax/verify` to Python as `{.exportpy.}` procs.
##
## Scope is deliberately Phase 1 of `docs/python_compatibility.md`'s §8
## ordering: circuit authoring plus `verify`/`readiness`, with **no callback
## boundary** -- every proc here is a plain call in one direction, Python
## into Nim, so none of the §5 "does the FFI hold up for a live custom role
## or evaluator" uncertainty applies to anything in this file. `Netlist`,
## `Net`, `Component` and `Pin` cross the boundary as opaque handles:
## `nimpy` marshals an arbitrary `ref object` as a `PyCapsule` automatically
## (`nimValueToPy`/`pyValueToNim` for `ref` in `nimpy.nim`), which is exactly
## the "a part is just an object handle" property §6 of the study describes
## -- nothing here serializes the graph, Python just holds handles into the
## same live object graph `graph.nim` mutates.
##
## **Unit safety crosses the boundary as `(valueSI: float, unit: string)`,
## not as a Nim `Quantity`.** The Python side (`verax/units.py`) carries the
## unit tag and does the suffix-to-SI-base conversion (`20.mohm` -> a
## Python `Quantity` holding `0.02`), matching §3's conclusion that this is
## "a thin Python `Quantity`/tagged-float layer", not a wrapper around
## `verax/units.nim`'s constructors. What *does* cross into Nim and run for
## real is the **check**: `setComponentQuantity`/`setNetQuantity` reconstruct
## the matching `verax/units.Quantity` subtype from the `unit` string and
## call the exact same `annotations.setAnnotation(e, key, v: Quantity)`
## overload the Nim DSL's `spec:` block expands to -- so `esr = (20e-9,
## "F")` is rejected by the same registered-unit check `esr = 20.nF` is
## rejected by in Nim, not a reimplementation of it. This is the "timing of
## a guarantee moves" tradeoff §4 describes: the same check, now raised the
## moment the call runs rather than at compile time.
##
## Every raised `NetlistError` propagates as an ordinary Python exception --
## `nimpy` converts any Nim exception escaping an `{.exportpy.}` proc into
## one (`pythonException` in `nimpy.nim`) -- so `spec:`'s compile-time
## rejection becomes exactly the runtime raise §4 predicts, with the
## identical message.
##
## **Phase 2** (this file's `Design`/`Subject`/`role`/`require` section below)
## adds §8 step 2 of the study: built-in role instantiation and `require`
## against a built-in evaluator, still with **no callback boundary** --
## `RoleDef.apply`/`expand` are Nim procs already registered by
## `contract/roles/built_in`, and Python is purely a *client* calling
## `design.addRole` the same way `contract/dsl`'s `role` macro expands to.
## `Subject` (`contract/types`) is a plain `object`, not a `ref`, so it cannot
## cross as a bare nimpy capsule the way `Netlist`/`Net`/`Component` do --
## `PySubject` below is the one-line ref wrapper that gives it the same
## opaque-handle treatment, built only by `net_subject`/`component_subject`/
## `pin_subject`/`role_subject`, mirroring `contract/dsl.subjectOf` and
## `design.innerComponent`/`innerPin`/`roleRef`.
##
## **Phase 3** (this file's final section) is the callback boundary itself:
## a Python-authored custom `RoleDef` and a Python-authored custom
## `Evaluator`, round-tripped through `plan`/`evaluate` -- §5/§8 step 3, the
## study's own hardest question. `nimpy`'s `PyObject` is already a Nim value
## with a `{.nimcall.}`-callable API (`callObject`) that keeps the wrapped
## Python object alive via ordinary refcounting (its `=destroy`/`=copy`
## hooks) -- so the missing piece was never nimpy's. It was `RoleDef.expand`/
## `apply` and `Evaluator.run` being declared `{.nimcall.}` (non-capturing)
## Nim proc *types*: a proc value bound to one Python callable via a Nim
## closure cannot convert to `{.nimcall.}`, which has no environment
## pointer. `pyRoleExpand`/`pyRoleApply`/`pyEvalRun` below are the answer --
## one genuinely non-capturing trampoline **per signature**, not per
## Python-defined role or evaluator, that recovers *which* Python callable
## to invoke from data already in its arguments: a role instance's own
## `.role` name, or an assertion batch's `.quantity` looked up through
## `evaluate.evaluatorFor` -- the same public dispatch a built-in already
## goes through, not a private side channel. `require`'s `ekPredicate` form
## needs the identical trick and does not get it here: a predicate is
## created fresh per `require` call rather than registered once under a
## name, and `PredicateProc` takes only `values: seq[float]` -- nothing in
## its call carries an identity to look a Python callable up by. That stays
## the one piece of §5 still open.

import std/[math, streams, strutils, tables]
import nimpy

import verax/netlist/graph
import verax/netlist/annotations
import verax/netlist/formats/spice as spiceFormat
import verax/units
import verax/contract/design
import verax/contract/evaluate
import verax/verify

# --- enum parsing for the string-typed fields Python passes in --------
#
# Netlist/types.nim's PinType/NetType are ordinary Nim enums; nimpy has no
# generic enum marshalling, so Python spells them as plain strings and this
# is the one place that maps them back. An unrecognised spelling raises
# rather than silently landing on `ptUnknown`/`ntUnknown` -- exactly the
# "typo is indistinguishable from unstated" hazard the annotation registry
# already refuses to allow silently.

proc parsePinKind(s: string): PinType =
  case s.toLowerAscii
  of "unknown", "": ptUnknown
  of "input", "in": ptInput
  of "output", "out": ptOutput
  of "inout": ptInOut
  of "power": ptPower
  of "ground", "gnd": ptGround
  of "passive": ptPassive
  else: raise newException(ValueError, "unknown pin kind: '" & s & "'")

proc parseNetKind(s: string): NetType =
  case s.toLowerAscii
  of "unknown", "": ntUnknown
  of "signal": ntSignal
  of "power": ntPower
  of "ground", "gnd": ntGround
  else: raise newException(ValueError, "unknown net kind: '" & s & "'")

# --- reconstructing a typed Quantity from (valueSI, unit) -------------
#
# `unit` is one of `verax/units.unitOf`'s own output strings ("V", "ohm",
# "F", "H", "Hz", "s", "A", "W", "deg", "dB", "degC", ""), so a caller that
# got the unit from a Python `Quantity.unit` and this proc agree by
# construction. `""` means "no unit to check" -- the plain-float overload of
# `setAnnotation`, used for a dimensionless value the registry declares with
# no unit (there is no such key among the ones with real consumers today,
# but the plumbing is here rather than special-cased away).

proc setAnnByUnit[E](e: E, key: string, valueSI: float, unit: string) =
  case unit
  of "V": setAnnotation(e, key, Volts(valueSI))
  of "ohm": setAnnotation(e, key, Ohms(valueSI))
  of "F": setAnnotation(e, key, Farads(valueSI))
  of "H": setAnnotation(e, key, Henries(valueSI))
  of "Hz": setAnnotation(e, key, Hertz(valueSI))
  of "s": setAnnotation(e, key, Seconds(valueSI))
  of "A": setAnnotation(e, key, Amps(valueSI))
  of "W": setAnnotation(e, key, Watts(valueSI))
  of "deg": setAnnotation(e, key, Degrees(valueSI))
  of "dB": setAnnotation(e, key, Decibels(valueSI))
  of "degC": setAnnotation(e, key, Celsius(valueSI))
  of "": setAnnotation(e, key, valueSI)
  else: raise newException(ValueError, "unknown unit symbol: '" & unit & "'")

# --- netlist / net / component construction ----------------------------

proc vxNewNetlist(name: string): Netlist {.exportpy: "new_netlist".} =
  newNetlist(name)

proc vxNetlistName(nl: Netlist): string {.exportpy: "netlist_name".} =
  nl.name

proc vxComponentCount(nl: Netlist): int {.exportpy: "component_count".} =
  nl.components.len

proc vxNetCount(nl: Netlist): int {.exportpy: "net_count".} =
  nl.nets.len

proc vxAddNet(nl: Netlist, name: string, kind: string = "signal"): Net
    {.exportpy: "add_net".} =
  addNet(nl, newNet(name, parseNetKind(kind)))

proc vxNetName(n: Net): string {.exportpy: "net_name".} =
  n.name

proc vxAddComponent(nl: Netlist, designator, kind: string,
                    partNumber: string = "", name: string = ""): Component
    {.exportpy: "add_component".} =
  addComponent(nl, newComponent(designator, name, partNumber, kind))

proc vxComponentDesignator(c: Component): string
    {.exportpy: "component_designator".} =
  c.designator

proc vxConnect(c: Component, pinName: string, n: Net, kind: string = "passive")
    {.exportpy: "connect".} =
  ## Connects `c`'s pin `pinName` to `n`, auto-creating the pin if it does
  ## not exist yet -- `graph.connect`'s own convenience overload.
  discard graph.connect(c, pinName, n, parsePinKind(kind))

# --- annotations: the validated path (registered keys) -----------------
#
# These are the calls a Python design file makes for the shared vocabulary
# (`value`, `voltage`, `esr`, `esl`, `package`, `footprint`, `tolerance`,
# ...) -- the same keys a Nim `spec:` block checks at compile time, checked
# here at call time instead (see this module's doc comment).

proc vxSetComponentText(c: Component, key, value: string)
    {.exportpy: "set_component_text".} =
  setAnnotation(c, key, value)

proc vxSetNetText(n: Net, key, value: string) {.exportpy: "set_net_text".} =
  setAnnotation(n, key, value)

proc vxSetComponentQuantity(c: Component, key: string, valueSI: float, unit: string)
    {.exportpy: "set_component_quantity".} =
  setAnnByUnit(c, key, valueSI, unit)

proc vxSetNetQuantity(n: Net, key: string, valueSI: float, unit: string)
    {.exportpy: "set_net_quantity".} =
  setAnnByUnit(n, key, valueSI, unit)

proc vxComponentTextAnn(c: Component, key: string): string
    {.exportpy: "component_text_annotation".} =
  ## "" when absent -- provenance (`AnnValue.source`) does not cross the
  ## boundary yet, matching this phase's "read back what you wrote" scope.
  let v = annotation(c, key)
  if v.has: v.value else: ""

proc vxComponentFloatAnn(c: Component, key: string): float
    {.exportpy: "component_float_annotation".} =
  ## `NaN` when absent, since nimpy has no optional-float marshalling;
  ## Python checks with `math.isnan`.
  let v = annotationFloat(c, key)
  if v.has: v.value else: NaN

proc vxNetFloatAnn(n: Net, key: string): float
    {.exportpy: "net_float_annotation".} =
  let v = annotationFloat(n, key)
  if v.has: v.value else: NaN

# --- annotations: the permissive path (namespaced/foreign keys) --------
#
# The escape hatch a file reader or a foreign tool's key wants -- unvalidated,
# exactly `netlist/dsl`'s head-of-statement `key = value` fallback for
# anything that is not `kind`/`name`/`partNumber`.

proc vxSetComponentRaw(c: Component, key, value: string)
    {.exportpy: "set_component_raw".} =
  setRawAnnotation(c, key, value)

proc vxSetNetRaw(n: Net, key, value: string) {.exportpy: "set_net_raw".} =
  setRawAnnotation(n, key, value)

# --- validation and SPICE round-trip ------------------------------------

proc vxValidateAnnotations(nl: Netlist): seq[string]
    {.exportpy: "validate_annotations".} =
  for issue in validateAnnotations(nl): result.add $issue

proc vxToSpice(nl: Netlist): string {.exportpy: "to_spice".} =
  let s = newStringStream()
  spiceFormat.writeNetlist(nl, s)
  s.data

# --- verify / readiness --------------------------------------------------
#
# `newDesign(nl)` with no roles attached and no directly-authored assertions
# is a `Design` that claims nothing -- `readiness` on it reports an empty
# `CHECKS`/`NOT CHECKED` and cannot fail, which is the correct, honest answer
# for a netlist authored with no contract layer at all. `verify()` is used
# unchanged (echoes the rendered report, returns the same exit code
# `verax check` would) rather than reimplemented, so a Python design's report
# is byte-for-byte what the Nim CLI would have printed for the same graph.

proc vxCheck(nl: Netlist, offline: bool = false, verboseReport: bool = false,
             strict: bool = false): int {.exportpy: "check".} =
  let allowed = if offline: offlineCapabilities else: allCapabilities
  verify(newDesign(nl), allowed, verboseReport, strict)

# --- contract: Design, roles and requirements (Phase 2) -----------------
#
# See this module's doc comment for why `PySubject` exists and what this
# section does and does not attempt.

type
  PySubject = ref object
    s: Subject

proc vxNewDesign(nl: Netlist): Design {.exportpy: "new_design".} =
  newDesign(nl)

proc vxDesignNetlist(d: Design): Netlist {.exportpy: "design_netlist".} =
  ## So a `Design` built from Python can still be handed to `Net`/`Component`
  ## constructors that only know a `Netlist` -- `Design` **owns** its
  ## netlist rather than duplicating it (see `contract/design`'s own doc
  ## comment), and this is the one accessor back to it.
  d.netlist

# --- Subject construction: the opaque-handle treatment `Subject` itself
# cannot get, because it is a plain `object`, not a `ref` -----------------

proc vxNetSubject(n: Net): PySubject {.exportpy: "net_subject".} =
  PySubject(s: Subject(kind: skNet, name: n.name))

proc vxComponentSubject(c: Component): PySubject {.exportpy: "component_subject".} =
  PySubject(s: Subject(kind: skComponent, name: c.designator))

proc vxPinSubject(c: Component, pinName: string): PySubject {.exportpy: "pin_subject".} =
  ## Matches `design.innerPin`'s spelling (`"DESIGNATOR.pin"`), not a
  ## `Pin` handle -- pins are not otherwise exposed to Python yet.
  PySubject(s: Subject(kind: skPin, name: c.designator & $hierSep & pinName))

proc vxRoleSubject(name: string): PySubject {.exportpy: "role_subject".} =
  ## `design.roleRef` -- a reference to *another* role instance, for a
  ## multi-subject role like `channel_match` whose parts are themselves role
  ## instances. Raises at `add_role` time (not here) if `name` was not
  ## declared first -- `design.resolve`'s own ordering check.
  PySubject(s: roleRef(name))

# --- role attachment ------------------------------------------------------
#
# `bindings`/`params` are plain Python `dict`s -- nimpy's generic
# `Table[K, V]` marshalling (`pyValueToNim[T; U](Table[T, U])` in
# `nimpy/py_nim_marshalling.nim`) converts a `dict` field-for-field, and that
# already covers a `PySubject` value the same way a bare `seq`/`Table`
# argument covers any other ref handle -- no bespoke builder object needed.
# A role parameter is always a *string* here (as it is in the Nim DSL after
# `annText` runs on it) -- `Design.role` in `verax/contract.py` is what
# formats a Python float/`Quantity` into one, the same "moves to call time,
# not weakened" tradeoff §4 describes for every other annotation.

proc vxAddRole(d: Design, roleName, instanceName: string,
               bindings: Table[string, PySubject],
               params: Table[string, string] = initTable[string, string]())
    {.exportpy: "add_role".} =
  var bs: seq[(string, Subject)]
  for k, v in bindings: bs.add (k, v.s)
  var ps: seq[(string, string)]
  for k, v in params: ps.add (k, v)
  discard design.addRole(d, roleName, instanceName, bs, ps)

proc vxNetRoles(n: Net): seq[(string, string)] {.exportpy: "net_roles".} =
  ## `(instance, part)` pairs, read back off the membership tags `add_role`
  ## wrote -- `design.rolesOf`, so this still works after a fragment carrying
  ## `n` was cut out of the design.
  for r in rolesOf(n): result.add (r.instance, r.part)

proc vxComponentRoles(c: Component): seq[(string, string)]
    {.exportpy: "component_roles".} =
  for r in rolesOf(c): result.add (r.instance, r.part)

proc vxExplain(d: Design): string {.exportpy: "explain".} =
  ## What every role expanded to, and every directly-authored assertion --
  ## `contract/design`'s own `explain`. Printability is not a nicety there,
  ## and it matters at least as much from Python: a claim generated by a
  ## role attached through a `dict` of bindings is easier to get subtly
  ## wrong than one spelled out by the Nim macro.
  design.explain(d)

# --- require: built-in evaluators, no callback needed --------------------
#
# One proc per `Expectation` shape `contract/types` already has a
# constructor for (`nominal`/`atLeast`/`atMost`/`between`/`relative`) --
# mirroring `contract/dsl.handleComparison`'s own routing rather than one
# do-everything call with unused parameters. `ekPredicate` is deliberately
# absent: unlike `ekRelative`, it needs a live Python-callable-as-Nim-proc
# crossing the boundary, which is the genuinely open §5/§8.3 question this
# phase does not attempt.

proc subjList(subjects: seq[PySubject]): seq[Subject] =
  for s in subjects: result.add s.s

proc toCondition(condition: Table[string, string]): OrderedTable[string, string] =
  for k, v in condition: result[k] = v

proc vxRequireNominal(d: Design, quantity: string, subjects: seq[PySubject],
                      target: float, fracTol: float = 0.0, absTol: float = 0.0,
                      unit: string = "", id: string = "", because: string = "",
                      condition: Table[string, string] = initTable[string, string]())
    {.exportpy: "require_nominal".} =
  assertThat(d, Assertion(id: id, subjects: subjList(subjects), quantity: quantity,
    expect: nominal(target, fracTol, absTol), unit: unit, severity: sevError,
    rationale: because, origin: "authored", condition: toCondition(condition)))

proc vxRequireMin(d: Design, quantity: string, subjects: seq[PySubject],
                  lo: float, unit: string = "", id: string = "", because: string = "",
                  condition: Table[string, string] = initTable[string, string]())
    {.exportpy: "require_min".} =
  assertThat(d, Assertion(id: id, subjects: subjList(subjects), quantity: quantity,
    expect: atLeast(lo), unit: unit, severity: sevError,
    rationale: because, origin: "authored", condition: toCondition(condition)))

proc vxRequireMax(d: Design, quantity: string, subjects: seq[PySubject],
                  hi: float, unit: string = "", id: string = "", because: string = "",
                  condition: Table[string, string] = initTable[string, string]())
    {.exportpy: "require_max".} =
  assertThat(d, Assertion(id: id, subjects: subjList(subjects), quantity: quantity,
    expect: atMost(hi), unit: unit, severity: sevError,
    rationale: because, origin: "authored", condition: toCondition(condition)))

proc vxRequireRange(d: Design, quantity: string, subjects: seq[PySubject],
                    lo, hi: float, unit: string = "", id: string = "", because: string = "",
                    condition: Table[string, string] = initTable[string, string]())
    {.exportpy: "require_range".} =
  assertThat(d, Assertion(id: id, subjects: subjList(subjects), quantity: quantity,
    expect: between(lo, hi), unit: unit, severity: sevError,
    rationale: because, origin: "authored", condition: toCondition(condition)))

proc vxRequireRelative(d: Design, quantity: string, subjects: seq[PySubject],
                       op: string, coeff: float,
                       refQuantity: string, refSubjects: seq[PySubject],
                       band: float = 0.0, unit: string = "",
                       id: string = "", because: string = "",
                       condition: Table[string, string] = initTable[string, string]())
    {.exportpy: "require_relative".} =
  ## `q(subjects) op coeff * refQuantity(refSubjects)` -- needs no callback,
  ## since a relative bound is data (a reference measurement and a
  ## multiplier), unlike `ekPredicate`.
  let relOp = case op
    of "<=", "le": roLe
    of ">=", "ge": roGe
    of "==", "eq": roEq
    else: raise newException(ValueError, "unknown relative op: '" & op &
      "'; expected one of <=, >=, ==")
  let cond = toCondition(condition)
  var reference = measurementRef(refQuantity, subjList(refSubjects))
  for k, v in cond: reference.condition[k] = v
  assertThat(d, Assertion(id: id, subjects: subjList(subjects), quantity: quantity,
    expect: relative(relOp, coeff, reference, fracTol = band), unit: unit,
    severity: sevError, rationale: because, origin: "authored", condition: cond))

# --- verify / readiness, over a Design carrying its roles and claims ------

proc vxCheckDesign(d: Design, offline: bool = false, verboseReport: bool = false,
                   strict: bool = false): int {.exportpy: "check_design".} =
  ## As `check`, but over a `Design` Python itself built with `add_role`/
  ## `require_*` -- `verify` runs unchanged over it, so the report is
  ## byte-for-byte what `verax check` would print for the identical roles
  ## and requirements, unlike `check`, which always wraps a bare `Netlist`
  ## with no roles or assertions.
  let allowed = if offline: offlineCapabilities else: allCapabilities
  verify(d, allowed, verboseReport, strict)

# --- contract: Python-defined roles and evaluators (Phase 3) -------------
#
# See this module's doc comment for the trampoline design. Two module-level
# tables hold the live Python callables, keyed by the role/evaluator name
# they were registered under -- `PyObject`'s own `=destroy`/`=copy` hooks
# keep each one's Python refcount correct for as long as it sits in one of
# these, which is the process lifetime of a registered role or evaluator.

var pyRoleExpanders: Table[string, PyObject]
var pyRoleAppliers: Table[string, PyObject]
var pyEvaluatorRuns: Table[string, PyObject]

type
  PyRoleInstance = ref object
    ## `RoleInstance` is a plain `object`, exactly like `Subject` -- the same
    ## one-line ref wrapper gives it the opaque-handle treatment.
    inst: RoleInstance

  PyAssertion = ref object
    ## An `Assertion`, built either by a Python `expand` (via `make_*` below)
    ## or by this module (wrapping one out of an evaluator's input batch) --
    ## either way, the one representation a Python callback trades in, so
    ## `expand`'s output and `run`'s input are handles of the same type.
    a: Assertion

proc vxRiName(ri: PyRoleInstance): string {.exportpy: "role_instance_name".} =
  ri.inst.name
proc vxRiRole(ri: PyRoleInstance): string {.exportpy: "role_instance_role".} =
  ri.inst.role
proc vxRiBindings(ri: PyRoleInstance): Table[string, PySubject]
    {.exportpy: "role_instance_bindings".} =
  for k, v in ri.inst.bindings: result[k] = PySubject(s: v)
proc vxRiParams(ri: PyRoleInstance): Table[string, string]
    {.exportpy: "role_instance_params".} =
  for k, v in ri.inst.params: result[k] = v
proc vxRiDeclined(ri: PyRoleInstance): seq[string]
    {.exportpy: "role_instance_declined".} =
  ri.inst.declined
proc vxRiParamFloat(ri: PyRoleInstance, name: string, fallback: float): float
    {.exportpy: "role_instance_param_float".} =
  paramFloat(ri.inst, name, fallback)

proc vxFindNet(nl: Netlist, name: string): Net {.exportpy: "find_net".} =
  ## For a Python `apply` to resolve one of its own bindings against the
  ## netlist it was handed -- `graph.findNet`, raising by name rather than
  ## handing back `nil` the way the bare proc does, since nimpy has no
  ## optional-ref marshalling for Python to check against.
  result = findNet(nl, name)
  if result == nil: raise newException(NetlistError, "no such net: " & name)

proc vxFindComponent(nl: Netlist, name: string): Component
    {.exportpy: "find_component".} =
  result = findComponent(nl, name)
  if result == nil: raise newException(NetlistError, "no such component: " & name)

proc vxSubjectName(s: PySubject): string {.exportpy: "subject_name".} = s.s.name
proc vxSubjectKind(s: PySubject): string {.exportpy: "subject_kind".} = $s.s.kind

# --- building an Assertion from inside a Python `expand` ------------------
#
# One proc per `Expectation` shape, exactly mirroring `require_nominal`/
# `_min`/`_max`/`_range`/`_relative` above -- the difference is these return
# a handle instead of attaching it to a `Design` via `assertThat`, since a
# `RoleExpander` returns its assertions rather than asserting them itself.
# `origin` defaults to "" here and is filled with the instance name by
# `pyRoleExpand` below when a Python author leaves it unset, matching every
# built-in expander's own `origin: inst.name`.

proc vxMakeNominal(quantity: string, subjects: seq[PySubject], target: float,
                   fracTol: float = 0.0, absTol: float = 0.0, unit: string = "",
                   id: string = "", because: string = "", origin: string = "",
                   condition: Table[string, string] = initTable[string, string]()):
    PyAssertion {.exportpy: "make_nominal".} =
  PyAssertion(a: Assertion(id: id, subjects: subjList(subjects), quantity: quantity,
    expect: nominal(target, fracTol, absTol), unit: unit, severity: sevError,
    rationale: because, origin: origin, condition: toCondition(condition)))

proc vxMakeMin(quantity: string, subjects: seq[PySubject], lo: float,
              unit: string = "", id: string = "", because: string = "",
              origin: string = "",
              condition: Table[string, string] = initTable[string, string]()):
    PyAssertion {.exportpy: "make_min".} =
  PyAssertion(a: Assertion(id: id, subjects: subjList(subjects), quantity: quantity,
    expect: atLeast(lo), unit: unit, severity: sevError,
    rationale: because, origin: origin, condition: toCondition(condition)))

proc vxMakeMax(quantity: string, subjects: seq[PySubject], hi: float,
              unit: string = "", id: string = "", because: string = "",
              origin: string = "",
              condition: Table[string, string] = initTable[string, string]()):
    PyAssertion {.exportpy: "make_max".} =
  PyAssertion(a: Assertion(id: id, subjects: subjList(subjects), quantity: quantity,
    expect: atMost(hi), unit: unit, severity: sevError,
    rationale: because, origin: origin, condition: toCondition(condition)))

proc vxMakeRange(quantity: string, subjects: seq[PySubject], lo, hi: float,
                 unit: string = "", id: string = "", because: string = "",
                 origin: string = "",
                 condition: Table[string, string] = initTable[string, string]()):
    PyAssertion {.exportpy: "make_range".} =
  PyAssertion(a: Assertion(id: id, subjects: subjList(subjects), quantity: quantity,
    expect: between(lo, hi), unit: unit, severity: sevError,
    rationale: because, origin: origin, condition: toCondition(condition)))

proc vxMakeRelative(quantity: string, subjects: seq[PySubject], op: string,
                    coeff: float, refQuantity: string, refSubjects: seq[PySubject],
                    band: float = 0.0, unit: string = "", id: string = "",
                    because: string = "", origin: string = "",
                    condition: Table[string, string] = initTable[string, string]()):
    PyAssertion {.exportpy: "make_relative".} =
  let relOp = case op
    of "<=", "le": roLe
    of ">=", "ge": roGe
    of "==", "eq": roEq
    else: raise newException(ValueError, "unknown relative op: '" & op &
      "'; expected one of <=, >=, ==")
  let cond = toCondition(condition)
  var reference = measurementRef(refQuantity, subjList(refSubjects))
  for k, v in cond: reference.condition[k] = v
  PyAssertion(a: Assertion(id: id, subjects: subjList(subjects), quantity: quantity,
    expect: relative(relOp, coeff, reference, fracTol = band), unit: unit,
    severity: sevError, rationale: because, origin: origin, condition: cond))

# --- reading an Assertion inside a Python evaluator's `run` ----------------

proc vxAssertionId(a: PyAssertion): string {.exportpy: "assertion_id".} = a.a.id
proc vxAssertionQuantity(a: PyAssertion): string {.exportpy: "assertion_quantity".} =
  a.a.quantity
proc vxAssertionSubjects(a: PyAssertion): seq[PySubject]
    {.exportpy: "assertion_subjects".} =
  for s in a.a.subjects: result.add PySubject(s: s)
proc vxAssertionCondition(a: PyAssertion): Table[string, string]
    {.exportpy: "assertion_condition".} =
  for k, v in a.a.condition: result[k] = v
proc vxAssertionUnit(a: PyAssertion): string {.exportpy: "assertion_unit".} = a.a.unit
proc vxAssertionOrigin(a: PyAssertion): string {.exportpy: "assertion_origin".} =
  a.a.origin
proc vxAssertionSatisfies(a: PyAssertion, value: float): bool
    {.exportpy: "assertion_satisfies".} =
  ## The identical `Expectation.satisfies` comparison every built-in
  ## evaluator's verdict rests on -- so a Python evaluator's pass/fail line
  ## is never a second, drifting reimplementation of that rule; see
  ## `custom.measurement` on the Python side.
  satisfies(a.a.expect, value)

# --- registering a Python-defined role -------------------------------------

proc parseSubjectKindStr(s: string): SubjectKind =
  case s.toLowerAscii
  of "net": skNet
  of "component": skComponent
  of "pin": skPin
  of "class": skClass
  of "design": skDesign
  else: raise newException(ValueError, "unknown subject kind: '" & s &
    "'; expected one of net, component, pin, class, design")

proc parseAnnKindStr(s: string): AnnKind =
  case s.toLowerAscii
  of "float", "": akFloat
  of "string", "text": akString
  of "int": akInt
  of "bool": akBool
  of "enum": akEnum
  else: raise newException(ValueError, "unknown parameter kind: '" & s &
    "'; expected one of float, string, int, bool, enum")

proc pyRoleExpand(inst: RoleInstance): seq[Assertion] {.nimcall.} =
  ## The single trampoline registered as `expand` for **every** Python-
  ## defined role -- it is `inst.role`, not a closure, that says which
  ## Python callable to invoke, exactly as `evaluatorFor` below dispatches
  ## a batch by quantity rather than by which registration made the call.
  if not pyRoleExpanders.hasKey(inst.role):
    raise newException(NetlistError,
      "no python expander registered for role '" & inst.role & "'")
  let fn = pyRoleExpanders[inst.role]
  let handles = callObject(fn, PyRoleInstance(inst: inst)).to(seq[PyAssertion])
  for h in handles:
    var a = h.a
    if a.origin.len == 0: a.origin = inst.name
    result.add a

proc pyRoleApply(inst: RoleInstance, nl: Netlist) {.nimcall.} =
  let fn = pyRoleAppliers[inst.role]
  discard callObject(fn, PyRoleInstance(inst: inst), nl)

proc vxRegisterRole(name: string, expandFn: PyObject, applyFn: PyObject,
                    parts: seq[Table[string, string]] = @[],
                    params: seq[Table[string, string]] = @[],
                    expects: string = "") {.exportpy: "register_role".} =
  ## `contract/roles/core.registerRole`, over `expand`/`apply` that are
  ## Python callables. `parts`/`params` are `{"name"/"key": ..., "kind":
  ## ...}` dicts rather than `RolePart`/`AnnDef` themselves, since neither
  ## crosses the boundary as a capsule and both are small enough to spell as
  ## plain data -- `design.addRole`'s validation is exactly as strict either
  ## way, because it runs against the `RoleDef` this builds, not against
  ## anything Python-specific.
  ##
  ## `applyFn` is never nil here -- nimpy has no way to tell a Python `None`
  ## default apart from a real `PyObject` wrapping it (both are non-nil Nim
  ## refs; only the *wrapped* Python object is `None`), so the Python side
  ## (`verax/custom.define_role`) always passes a real callable, a no-op one
  ## when the author gave no `apply`, rather than this proc trying to sniff
  ## out which kind of PyObject it was handed.
  pyRoleExpanders[name] = expandFn
  pyRoleAppliers[name] = applyFn
  var def = RoleDef(name: name, expects: expects, expand: pyRoleExpand,
                    apply: pyRoleApply)
  for p in parts:
    def.parts.add RolePart(
      name: p.getOrDefault("name", ""),
      kind: parseSubjectKindStr(p.getOrDefault("kind", "net")),
      optional: p.getOrDefault("optional", "false").toLowerAscii == "true",
      doc: p.getOrDefault("doc", ""))
  for p in params:
    def.params.add AnnDef(key: p.getOrDefault("key", ""),
                          kind: parseAnnKindStr(p.getOrDefault("kind", "float")))
  registerRole(def)

# --- registering a Python-defined evaluator --------------------------------

proc parseCapabilityStr(s: string): Capability =
  case s.toLowerAscii
  of "static": capStatic
  of "op", ".op": capSpiceOp
  of "dc", ".dc": capSpiceDc
  of "ac", ".ac": capSpiceAc
  of "tran", ".tran": capSpiceTran
  of "bench": capBench
  else: raise newException(ValueError, "unknown capability: '" & s &
    "'; expected one of static, op, dc, ac, tran, bench")

proc pyEvalRun(ctx: EvalContext, batch: seq[Assertion]): seq[AssertionResult]
    {.nimcall.} =
  ## The single trampoline registered as `run` for **every** Python-defined
  ## evaluator. Which Python callable to invoke is recovered from the
  ## batch's own quantity through `evaluatorFor` -- the identical public
  ## lookup `verax quantities` and every other reader of the registry uses,
  ## not a private table this module alone knows about. Safe because a
  ## `plan`ned batch is homogeneous: every assertion in it was routed here
  ## by sharing one evaluator.
  if batch.len == 0: return
  let ev = evaluatorFor(batch[0].quantity)
  if ev.isNone:
    raise newException(NetlistError,
      "no evaluator registered for quantity '" & batch[0].quantity & "'")
  let evName = ev.get.name
  if not pyEvaluatorRuns.hasKey(evName):
    raise newException(NetlistError,
      "no python run proc registered for evaluator '" & evName & "'")
  let fn = pyEvaluatorRuns[evName]
  var handles: seq[PyAssertion]
  for a in batch: handles.add PyAssertion(a: a)
  let rows = callObject(fn, ctx, handles).to(seq[(string, float, string, string)])
  if rows.len != batch.len:
    raise newException(NetlistError,
      "python evaluator '" & evName & "' returned " & $rows.len &
      " result(s) for a batch of " & $batch.len)
  for i, a in batch:
    let (statusStr, value, unit, reason) = rows[i]
    let status = case statusStr
      of "pass": esPass
      of "fail": esFail
      of "not_evaluated": esNotEvaluated
      of "not_evaluable": esNotEvaluable
      else: raise newException(ValueError,
        "unknown result status: '" & statusStr & "'; expected one of pass, " &
        "fail, not_evaluated, not_evaluable")
    result.add AssertionResult(assertion: a, status: status, value: value,
      unit: unit, reason: reason, evaluator: evName)

proc vxRegisterEvaluator(name: string, produces: seq[string], runFn: PyObject,
                         needs: seq[string] = @[], arityMin: int = 1,
                         arityMax: int = -1, subjectKinds: seq[string] = @[],
                         binds: seq[string] = @[],
                         conditions: seq[string] = @[],
                         units: Table[string, string] = initTable[string, string]())
    {.exportpy: "register_evaluator".} =
  ## `contract/evaluate.registerEvaluator`, over a `run` that is a Python
  ## callable. `arityMax < 0` means unbounded (`int.high`) -- nimpy has no
  ## `Option[int]`/sentinel-free "unspecified" marshalling, and `-1` reads
  ## unambiguously as "no upper bound" for an arity, which is never negative.
  pyEvaluatorRuns[name] = runFn
  var ev = Evaluator(name: name, produces: produces, run: pyEvalRun, binds: binds,
                     conditions: conditions, units: units,
                     arity: arityMin .. (if arityMax < 0: int.high else: arityMax))
  for n in needs: ev.needs.incl parseCapabilityStr(n)
  for k in subjectKinds: ev.subjectKinds.incl parseSubjectKindStr(k)
  registerEvaluator(ev)

proc vxEvalContextDesign(ctx: EvalContext): Design
    {.exportpy: "eval_context_design".} =
  ctx.design
