"""Design *intent* from Python: roles and requirements over a `Design` that
carries them, plus `verify`/readiness run against it -- §8 step 2 of
`docs/python_compatibility.md`, phase 2 of the study.

Still **no callback boundary**: `Design.role` is a client of `RoleDef`s
`verax/contract/roles/built_in` already registered (`power_rail`, `i2c`,
`regulator`, ...), the same way `contract/dsl`'s `role` macro is -- nothing
here defines a new role or evaluator from Python. `Subject` (`net`,
`component`, a pin, or another role instance) cannot cross the boundary as a
bare capsule the way `Net`/`Component` do, because it is a plain Nim
`object`, not a `ref` -- `Net.subject()`/`Component.subject()`/`role_ref()`
are the one-line wrappers `verax_py.nim`'s `PySubject` gives it, mirroring
`verax/contract/design.innerComponent`/`roleRef`.

A Python-authored custom `RoleDef` or `Evaluator` (the study's §5, its
harder question) is `verax.custom`'s job, not this module's -- see there for
the live-callback boundary. `require_relative` below still needs none of it
(a relative bound is data, not a callback); `require pred(...)` would, and
is the one piece still open (see `verax.custom`'s own module doc).

    from verax.contract import Design
    from verax.units import V, pct

    d = Design("sensor_board")
    vdd = d.net("vdd", kind="power")
    ...
    d.role("power_rail", "vdd_rail", rail=vdd, voltage=V(3.3), band=pct(5))
    d.require_max("z_max_in_band", vdd, hi=mohm(100), f_from=Hz(1e5), f_to=Hz(1e8))
    sys.exit(d.check())
"""

from __future__ import annotations

import sys
from dataclasses import dataclass
from typing import Union

import verax_py as _vx

from .netlist import Component, Net, Netlist
from .units import Quantity

__all__ = ["Design", "RoleRef", "role_ref"]

Subject = Union[Net, Component, "RoleRef"]


@dataclass(frozen=True)
class RoleRef:
    """A reference to *another* role instance, for a multi-subject role
    whose parts are themselves role instances (`channel_match`'s `a`/`b`) --
    the Python spelling of `verax/contract/design.roleRef`. Build with
    `role_ref(name)`, not directly; `Design.role` raises, naming what was
    declared so far, if `name` was not attached first."""

    name: str


def role_ref(name: str) -> RoleRef:
    return RoleRef(name)


def _subject_handle(s: Subject):
    if isinstance(s, RoleRef):
        return _vx.role_subject(s.name)
    if isinstance(s, (Net, Component)):
        return s.subject()
    raise TypeError(f"not a role-binding subject: {s!r}")


def _subject_handles(subjects) -> list:
    return [_subject_handle(s) for s in subjects]


def _param_text(value) -> str:
    """Mirrors `contract/dsl.annText`: a `Quantity` or plain number becomes
    its raw SI-base value as text (`voltage = 3.3.V` carries the string
    `"3.3"`, not `"3.3.V"`); a string parameter passes through unchanged."""
    if isinstance(value, Quantity):
        return repr(value.si)
    if isinstance(value, str):
        return value
    return repr(float(value))


def _condition_text(condition: dict) -> dict:
    out = {}
    for key, value in condition.items():
        out[key] = repr(value.si) if isinstance(value, Quantity) else str(value)
    return out


def _quantity_target(value, unit: str) -> tuple[float, str]:
    if isinstance(value, Quantity):
        return value.si, (unit or value.unit)
    return float(value), unit


class Design:
    """A `Netlist` plus the roles and requirements attached to it -- the
    Python spelling of Nim's `design("name"): ...` block. `net`/`component`
    delegate to an owned `Netlist` (`self.netlist`), exactly as `design(...)`
    reuses `netlist/dsl.buildNetlistBody` rather than duplicating it."""

    def __init__(self, name: str):
        self.netlist = Netlist(name)
        self._handle = _vx.new_design(self.netlist._handle)

    @classmethod
    def _from_handle(cls, handle) -> "Design":
        """Wraps a raw `Design` handle this process did not just create --
        `verax.custom.EvalContext.design`'s route back to one. Bypasses
        `__init__`, which always builds a brand new, empty netlist."""
        obj = cls.__new__(cls)
        obj._handle = handle
        obj.netlist = Netlist._from_handle(_vx.design_netlist(handle))
        return obj

    def net(self, name: str, kind: str = "signal") -> Net:
        return self.netlist.net(name, kind)

    def component(self, designator: str, kind: str, part_number: str = "",
                  name: str = "") -> Component:
        return self.netlist.component(designator, kind, part_number, name)

    def role(self, role_name: str, instance_name: str, **kv) -> str:
        """Attaches a role instance. `part = net_or_component_or_role_ref`
        is a binding; anything else is a parameter -- the same type-directed
        split `contract/dsl`'s `role` macro makes with
        `when compiles(subjectOf(value))`, made here by `isinstance` instead
        of by the Nim compiler, so a binding/parameter *name* typo is still
        caught (by `add_role`, at attach time) even though the *kind* split
        no longer is. `without="claim_a,claim_b"` declines claims, exactly
        as in Nim. Returns `instance_name`, for passing to `role_ref`."""
        bindings = {}
        params = {}
        for key, value in kv.items():
            if isinstance(value, (Net, Component, RoleRef)):
                bindings[key] = _subject_handle(value)
            else:
                params[key] = _param_text(value)
        _vx.add_role(self._handle, role_name, instance_name, bindings, params)
        return instance_name

    def require_nominal(self, quantity: str, *subjects: Subject, target,
                         frac_tol: float = 0.0, abs_tol: float = 0.0,
                         unit: str = "", id: str = "", because: str = "",
                         **condition) -> None:
        """`quantity(*subjects) == target`, within `frac_tol`/`abs_tol` --
        the wider of the two is accepted, as in Nim. Trailing keyword
        arguments become `condition` entries (`f_from=...`, `at_f=...`)."""
        si, unit = _quantity_target(target, unit)
        _vx.require_nominal(self._handle, quantity, _subject_handles(subjects),
                             si, float(frac_tol), float(abs_tol), unit, id,
                             because, _condition_text(condition))

    def require_min(self, quantity: str, *subjects: Subject, lo,
                     unit: str = "", id: str = "", because: str = "",
                     **condition) -> None:
        """`quantity(*subjects) >= lo`."""
        si, unit = _quantity_target(lo, unit)
        _vx.require_min(self._handle, quantity, _subject_handles(subjects),
                         si, unit, id, because, _condition_text(condition))

    def require_max(self, quantity: str, *subjects: Subject, hi,
                     unit: str = "", id: str = "", because: str = "",
                     **condition) -> None:
        """`quantity(*subjects) <= hi`."""
        si, unit = _quantity_target(hi, unit)
        _vx.require_max(self._handle, quantity, _subject_handles(subjects),
                         si, unit, id, because, _condition_text(condition))

    def require_range(self, quantity: str, *subjects: Subject, lo, hi,
                       unit: str = "", id: str = "", because: str = "",
                       **condition) -> None:
        """`lo <= quantity(*subjects) <= hi`."""
        if not unit:
            if isinstance(lo, Quantity):
                unit = lo.unit
            elif isinstance(hi, Quantity):
                unit = hi.unit
        lo_si, unit = _quantity_target(lo, unit)
        hi_si, unit = _quantity_target(hi, unit)
        _vx.require_range(self._handle, quantity, _subject_handles(subjects),
                           lo_si, hi_si, unit, id, because,
                           _condition_text(condition))

    def require_relative(self, quantity: str, *subjects: Subject, op: str,
                          coeff: float, ref_quantity: str, ref_subjects,
                          band: float = 0.0, unit: str = "", id: str = "",
                          because: str = "", **condition) -> None:
        """`quantity(*subjects) OP coeff * ref_quantity(*ref_subjects)`, `op`
        one of `"<="`/`">="`/`"=="` -- no callback needed, since a relative
        bound is data (a reference measurement and a multiplier), unlike a
        predicate."""
        _vx.require_relative(self._handle, quantity, _subject_handles(subjects),
                              op, float(coeff), ref_quantity,
                              _subject_handles(ref_subjects), float(band),
                              unit, id, because, _condition_text(condition))

    def explain(self) -> str:
        """What every role expanded to, and every directly-authored
        requirement, in full -- `contract/design.explain`. Not a nicety: a
        claim generated by a role attached through a keyword dict is easier
        to get subtly wrong than one spelled out by the Nim macro, so this
        is the way to see exactly what was claimed before checking it."""
        return _vx.explain(self._handle)

    def check(self, offline: bool = False, verbose: bool = False,
              strict: bool = False) -> int:
        """Runs `verax/verify.verify` over this design's actual roles and
        requirements -- unlike `Netlist.check()`, which always checks a bare
        netlist claiming nothing. Prints the identical report `verax check`
        would and returns its exit code."""
        sys.stdout.flush()  # see `Netlist.check`'s own comment on why
        return _vx.check_design(self._handle, offline, verbose, strict)

    def __repr__(self) -> str:
        return f"Design({self.netlist.name!r})"
