"""Python-authored custom roles and evaluators -- §5/§8 phase 3 of
`docs/python_compatibility.md`, the study's own hardest question: a live
Python callable crossing the FFI boundary as a Nim proc value, called back
into during `plan`/`evaluate`, rather than a plain call in the
Python-into-Nim direction every other binding in this package makes.

The missing piece was never `nimpy`'s -- its `PyObject` is already a Nim
value with a `{.nimcall.}`-callable API (`callObject`) that keeps the
wrapped Python object alive through ordinary refcounting. It was
`contract.RoleDef.expand`/`apply` and `Evaluator.run` being declared
`{.nimcall.}` (non-capturing) Nim proc *types*: a Nim closure bound to one
specific Python callable cannot convert to `{.nimcall.}`, which has no
environment pointer to hold the closure in. `verax_py.nim`'s
`pyRoleExpand`/`pyRoleApply`/`pyEvalRun` are the answer -- one genuinely
non-capturing trampoline **per signature**, not one per Python-defined role
or evaluator, that recovers which Python callable to invoke from data
already in its arguments (a role instance's own `.role` name; an assertion
batch's `.quantity`, looked up through the same public
`evaluate.evaluatorFor` a built-in's own dispatch uses) instead of from a
closure.

`require`'s `ekPredicate` form needs the identical trick and does not get it
here: a predicate is built fresh by every `require pred(...)` call rather
than registered once under a name, and `PredicateProc` takes only
`values: seq[float]` -- nothing in its call carries an identity a Python
callable could be looked up by. That is the one piece of §5 still open.

    from verax.contract import Design
    from verax.custom import define_role, at_least, define_evaluator, measurement
    from verax.units import mohm

    def expand(inst):
        rail = inst.bindings["rail"]
        return [at_least("my_quantity", rail, lo=inst.param_float("floor", 0.0),
                          id=inst.assertion_id("floor"))]

    define_role("my_role", expand=expand, parts=[{"name": "rail", "kind": "net"}],
                params=[{"key": "floor"}])

    def run(ctx, batch):
        return [measurement(a, 42.0, "ohm") for a in batch]

    define_evaluator("my_evaluator", ["my_quantity"], run=run)

    d = Design("t")
    ...
    d.role("my_role", "r1", rail=vdd, floor=mohm(10))
    sys.exit(d.check())
"""

from __future__ import annotations

import math
from typing import Callable, Optional, Sequence, Union

import verax_py as _vx

from .contract import Design, RoleRef, _condition_text
from .netlist import Component, Net
from .units import Quantity

__all__ = [
    "RoleInstance", "Assertion", "EvalContext",
    "nominal", "at_least", "at_most", "between", "relative",
    "measurement", "passed", "failed", "not_evaluated", "not_evaluable",
    "define_role", "define_evaluator",
    "find_net", "find_component",
]


# --- subjects: a raw handle from a role binding is already a Subject; a
# Net/Component/RoleRef is unwrapped the same way `contract._subject_handle`
# does, so `nominal`/`at_least`/... accept either interchangeably. ----------

def _subject_handle(s) -> object:
    if isinstance(s, RoleRef):
        return _vx.role_subject(s.name)
    if isinstance(s, (Net, Component)):
        return s.subject()
    return s  # already an opaque subject handle from `RoleInstance.bindings`


def _subject_handles(subjects) -> list:
    return [_subject_handle(s) for s in subjects]


def _quantity_target(value, unit: str) -> tuple[float, str]:
    if isinstance(value, Quantity):
        return value.si, (unit or value.unit)
    return float(value), unit


def find_net(nl, name: str) -> Net:
    """A net inside `nl` (the raw netlist handle a role's `apply` receives)
    by name -- `verax/netlist/graph.findNet`, for resolving a binding."""
    return Net(None, _vx.find_net(nl, name))


def find_component(nl, name: str) -> Component:
    """As `find_net`, for a component."""
    return Component(None, _vx.find_component(nl, name))


# --- RoleInstance: the read-only view a Python `expand`/`apply` receives --

class RoleInstance:
    """What a Python-defined role's `expand`/`apply` is handed -- built by
    the runtime for each role attachment; never constructed directly."""

    def __init__(self, handle):
        self._handle = handle

    @property
    def name(self) -> str:
        """This instance's own name (`"vdd_rail"`), for `assertion_id`."""
        return _vx.role_instance_name(self._handle)

    @property
    def role(self) -> str:
        """Which role definition this is an instance of."""
        return _vx.role_instance_role(self._handle)

    @property
    def bindings(self) -> dict:
        """`{part_name: subject}`. Each `subject` is an opaque handle,
        already accepted wherever `nominal`/`at_least`/`at_most`/`between`/
        `relative` take a subject, or resolvable against a netlist with
        `find_net`/`find_component` inside `apply`."""
        return _vx.role_instance_bindings(self._handle)

    @property
    def params(self) -> dict:
        """Every stated parameter, as raw text -- the same strings `spec:`
        stores internally, before any unit was attached. Use `param_float`
        for a numeric one with a fallback, matching `roles/core.paramFloat`."""
        return _vx.role_instance_params(self._handle)

    @property
    def declined(self) -> list:
        """Claim suffixes this instance declined via `without=...` --
        `expand` need not act on this itself; a suffix matching one of
        `assertion_id`'s ids is dropped automatically after `expand` returns,
        exactly as a built-in role's claims are."""
        return _vx.role_instance_declined(self._handle)

    def param_float(self, name: str, fallback: float = 0.0) -> float:
        return _vx.role_instance_param_float(self._handle, name, fallback)

    def has_param(self, name: str) -> bool:
        return name in self.params

    def assertion_id(self, suffix: str) -> str:
        """`"<instance>.<suffix>"` -- `roles/core.assertionId`, so a claim's
        id is prefixed the way `without` declining looks for."""
        return f"{self.name}.{suffix}"

    def __repr__(self) -> str:
        return f"RoleInstance({self.name!r}, role={self.role!r})"


# --- Assertion: a claim built by nominal/at_least/... and returned from
# `expand`, or handed into `run` as one element of the evaluator's batch. --

class Assertion:
    """One claim -- either just built (by `nominal`/`at_least`/`at_most`/
    `between`/`relative`, for `expand` to return) or one element of the
    batch a custom evaluator's `run` receives. An opaque handle; read it
    with the accessors below rather than by inspecting it directly."""

    def __init__(self, handle):
        self._handle = handle

    @property
    def id(self) -> str:
        return _vx.assertion_id(self._handle)

    @property
    def quantity(self) -> str:
        return _vx.assertion_quantity(self._handle)

    @property
    def subjects(self) -> list:
        """Opaque subject handles -- `subject_name`/`subject_kind` (or just
        re-passing one to another role's binding-shaped argument) is what a
        `run` can do with one; there is no live `Net`/`Component` here,
        since an evaluator may run before or after flattening."""
        return _vx.assertion_subjects(self._handle)

    @property
    def condition(self) -> dict:
        return _vx.assertion_condition(self._handle)

    @property
    def unit(self) -> str:
        return _vx.assertion_unit(self._handle)

    @property
    def origin(self) -> str:
        return _vx.assertion_origin(self._handle)

    def __repr__(self) -> str:
        return f"Assertion({self.id!r}, {self.quantity!r})"


def nominal(quantity: str, *subjects, target, frac_tol: float = 0.0,
            abs_tol: float = 0.0, unit: str = "", id: str = "",
            because: str = "", origin: str = "", **condition) -> Assertion:
    """`quantity(*subjects) == target`, within `frac_tol`/`abs_tol` -- for a
    Python `expand` to return. `origin` defaults to the expanding instance's
    name when left "" (matching every built-in expander's `origin: inst.name`),
    so it need not be passed at all unless building an assertion for a role
    *other* than the one currently expanding."""
    si, unit = _quantity_target(target, unit)
    return Assertion(_vx.make_nominal(quantity, _subject_handles(subjects), si,
                                       float(frac_tol), float(abs_tol), unit,
                                       id, because, origin,
                                       _condition_text(condition)))


def at_least(quantity: str, *subjects, lo, unit: str = "", id: str = "",
             because: str = "", origin: str = "", **condition) -> Assertion:
    """`quantity(*subjects) >= lo`."""
    si, unit = _quantity_target(lo, unit)
    return Assertion(_vx.make_min(quantity, _subject_handles(subjects), si,
                                   unit, id, because, origin,
                                   _condition_text(condition)))


def at_most(quantity: str, *subjects, hi, unit: str = "", id: str = "",
            because: str = "", origin: str = "", **condition) -> Assertion:
    """`quantity(*subjects) <= hi`."""
    si, unit = _quantity_target(hi, unit)
    return Assertion(_vx.make_max(quantity, _subject_handles(subjects), si,
                                   unit, id, because, origin,
                                   _condition_text(condition)))


def between(quantity: str, *subjects, lo, hi, unit: str = "", id: str = "",
            because: str = "", origin: str = "", **condition) -> Assertion:
    """`lo <= quantity(*subjects) <= hi`."""
    if not unit:
        if isinstance(lo, Quantity):
            unit = lo.unit
        elif isinstance(hi, Quantity):
            unit = hi.unit
    lo_si, unit = _quantity_target(lo, unit)
    hi_si, unit = _quantity_target(hi, unit)
    return Assertion(_vx.make_range(quantity, _subject_handles(subjects), lo_si,
                                     hi_si, unit, id, because, origin,
                                     _condition_text(condition)))


def relative(quantity: str, *subjects, op: str, coeff: float, ref_quantity: str,
             ref_subjects, band: float = 0.0, unit: str = "", id: str = "",
             because: str = "", origin: str = "", **condition) -> Assertion:
    """`quantity(*subjects) OP coeff * ref_quantity(*ref_subjects)`, `op` one
    of `"<="`/`">="`/`"=="`. No callback needed even here -- a relative bound
    is data (a reference measurement and a multiplier), unlike a predicate."""
    return Assertion(_vx.make_relative(quantity, _subject_handles(subjects), op,
                                        float(coeff), ref_quantity,
                                        _subject_handles(ref_subjects), float(band),
                                        unit, id, because, origin,
                                        _condition_text(condition)))


def define_role(name: str, *, expand: Callable[[RoleInstance], Sequence[Assertion]],
                 apply: Optional[Callable[[RoleInstance, object], None]] = None,
                 parts: Sequence[dict] = (), params: Sequence[dict] = (),
                 expects: str = "") -> None:
    """Registers a Python-defined role -- `contract/roles/core.registerRole`,
    over `expand`/`apply` that are Python callables rather than Nim procs.
    A built-in that cheats would make this second-class; it does not --
    `Design.role` cannot tell a role registered here from `power_rail`.

    `parts`: a sequence of `{"name": ..., "kind": "net"|"component"|"pin"|
    "class", "optional": bool}` -- `kind`/`optional` default to `"net"`/
    `False`. `params`: `{"key": ..., "kind": "float"|"string"}` -- `kind`
    defaults to `"float"` (matching a `Quantity`/plain-number parameter;
    use `"string"` for a text one like `psrrMethod`). Both are validated by
    `design.addRole` exactly as a built-in role's are: an unknown binding or
    parameter name still raises there, naming what the role actually has.

    `expand(inst: RoleInstance) -> list[Assertion]` must be pure, exactly as
    a Nim `RoleExpander` must be -- it receives no netlist and must not need
    one; build claims with `nominal`/`at_least`/`at_most`/`between`/
    `relative`. `apply(inst, netlist_handle)`, if given, writes annotations
    the way `power_rail` writes a rail's voltage -- resolve a binding
    against the netlist with `find_net`/`find_component`, then call a
    `Net`/`Component`'s own `.spec(...)`/`.raw(...)`.
    """
    def _expand(ri_handle):
        return [a._handle for a in expand(RoleInstance(ri_handle))]

    if apply is not None:
        def _apply(ri_handle, nl_handle):
            apply(RoleInstance(ri_handle), nl_handle)
    else:
        def _apply(ri_handle, nl_handle):
            pass  # no `apply` given -- register_role always wants a real callable

    _vx.register_role(name, _expand, _apply, list(parts), list(params), expects)


# --- EvalContext and result-building for a Python-defined evaluator -------

class EvalContext:
    """What a Python evaluator's `run` is handed alongside its batch --
    `contract/evaluate.EvalContext`. Read-only; built by the runtime."""

    def __init__(self, handle):
        self._handle = handle

    @property
    def design(self) -> Design:
        """The `Design` under evaluation -- `.netlist` reaches its nets and
        components for a graph-walk-style measurement, the same way a
        built-in `static.*` evaluator reads the design directly."""
        return Design._from_handle(_vx.eval_context_design(self._handle))


def measurement(a: Assertion, value: float, unit: str = "", reason: str = "") -> tuple:
    """The result to reach for first: runs the identical `Expectation
    .satisfies` comparison every built-in evaluator's verdict rests on, so a
    custom evaluator's pass/fail line is never a second, drifting
    reimplementation of that rule. A `NaN` (or `float("nan")`) value reads as
    `not_evaluated`, matching `satisfies`'s own "a `NaN` never passes" rule."""
    value = float(value)
    if math.isnan(value):
        return ("not_evaluated", value, unit, reason or "measurement returned no value")
    ok = _vx.assertion_satisfies(a._handle, value)
    return ("pass" if ok else "fail", value, unit, reason)


def passed(value: float, unit: str = "") -> tuple:
    """A verdict `run` has already decided itself, bypassing `satisfies` --
    for the rare evaluator whose pass/fail is not a plain interval check
    (`static.dc_isolation`'s breadth-first walk, say). Prefer `measurement`
    whenever the assertion's own bounds are the actual rule."""
    return ("pass", float(value), unit, "")


def failed(value: float, unit: str = "", reason: str = "") -> tuple:
    return ("fail", float(value), unit, reason)


def not_evaluated(reason: str = "") -> tuple:
    """An evaluator exists and ran, but produced no number this time (a
    withheld capability handled some other way, a simulation that raised)."""
    return ("not_evaluated", float("nan"), "", reason)


def not_evaluable(reason: str) -> tuple:
    """Nothing can produce this quantity for these particular subjects --
    `static.controller_count`'s "no role binding" case is the built-in
    example. `reason` is the whole point: it is what a reader acts on."""
    return ("not_evaluable", float("nan"), "", reason)


def define_evaluator(name: str, produces: Sequence[str], *,
                      run: Callable[[EvalContext, list], list],
                      needs: Sequence[str] = (),
                      arity: tuple[int, Optional[int]] = (1, None),
                      subject_kinds: Sequence[str] = (),
                      binds: Sequence[str] = ()) -> None:
    """Registers a Python-defined evaluator --
    `contract/evaluate.registerEvaluator`, over a `run` that is a Python
    callable rather than a Nim proc. Claiming a quantity a *different*
    evaluator already produces still raises, exactly as it does for a
    built-in registering twice.

    `run(ctx: EvalContext, batch: list[Assertion]) -> list[tuple]` must
    return exactly one result tuple per assertion, **in the same order as
    `batch`** -- planning already grouped the batch by `(evaluator, setup
    key)`, so "one tuple per input assertion" is the whole contract. Build
    each with `measurement`/`passed`/`failed`/`not_evaluated`/
    `not_evaluable`; all four are plain data, so nothing crosses back into
    Nim a second time mid-`run`.

    `needs`: capability strings (`"static"` (default when empty), `"op"`,
    `"dc"`, `"ac"`, `"tran"`, `"bench"`) -- every capability this evaluator's
    `run` actually uses, not just its headline one. `arity`: `(min, max)`
    accepted subject count; `max=None` means unbounded. `subject_kinds`:
    which `Subject` kinds are acceptable (`"net"`/`"component"`/`"pin"`/
    `"class"`/`"design"`); empty means every kind. `binds`: role *parts*
    this evaluator reads back off `Assertion.origin` beyond the assertion's
    own subjects, for `verax quantities`'s "reachable only through a role"
    column.
    """
    lo, hi = arity

    def _run(ctx_handle, batch_handles):
        ctx = EvalContext(ctx_handle)
        batch = [Assertion(h) for h in batch_handles]
        return run(ctx, batch)

    _vx.register_evaluator(name, list(produces), _run, list(needs), lo,
                            -1 if hi is None else hi, list(subject_kinds),
                            list(binds))
