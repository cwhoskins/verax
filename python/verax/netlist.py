"""Pythonic authoring surface over the ``verax_py`` nimpy extension.

This is the layer §4 of ``docs/python_compatibility.md`` describes: every
guarantee the Nim ``netlist/dsl`` macro gives at compile time is given here
at the moment a statement *runs* instead, over the same runtime registries
(``verax/netlist/annotations``) -- not a separate, weaker check. What is
lost is only what the study says is lost: a bare Nim ``let`` bound by the
macro becomes an ordinary Python assignment, and an identifier typo is a
``NameError``/``AttributeError`` at the point of use rather than a build
failure.

``Netlist``/``Net``/``Component`` here are thin Python objects wrapping the
opaque capsule handles ``verax_py`` hands back -- the "part is just an
object handle" property from §6, so nothing here ever serializes the graph.
"""

from __future__ import annotations

import sys
from typing import Optional

import verax_py as _vx

from .units import Quantity

__all__ = ["Netlist", "Net", "Component"]


def _quantity_args(value) -> tuple[float, str]:
    if isinstance(value, Quantity):
        return value.si, value.unit
    return float(value), ""


class Net:
    """A net in a `Netlist`. Wraps the opaque handle `verax_py.add_net`
    returns; never constructed directly."""

    def __init__(self, netlist: "Netlist", handle):
        self._netlist = netlist
        self._handle = handle

    @property
    def name(self) -> str:
        return _vx.net_name(self._handle)

    def spec(self, **kv) -> "Net":
        """Set one or more registered annotations on this net (`voltage`,
        `t_ambient_min`, ...), validated the moment each is set -- an
        unknown key or a wrong unit raises here, not later. A `Quantity`
        (`3.3.V`'s Python equivalent) is unit-checked against the
        annotation registry; a bare `str`/number is stored as text/an
        unchecked float, same as the Nim DSL's `spec:` block."""
        for key, value in kv.items():
            if isinstance(value, Quantity):
                si, unit = _quantity_args(value)
                _vx.set_net_quantity(self._handle, key, si, unit)
            elif isinstance(value, str):
                _vx.set_net_text(self._handle, key, value)
            else:
                _vx.set_net_quantity(self._handle, key, float(value), "")
        return self

    def raw(self, key: str, value: str) -> "Net":
        """The permissive, unvalidated escape hatch for a namespaced key
        (`kicad.*`, `spice.*`, or your own) -- `netlist/dsl`'s
        head-of-statement fallback, not `spec:`."""
        _vx.set_net_raw(self._handle, key, value)
        return self

    def annotation(self, key: str) -> Optional[float]:
        """The registered float annotation `key`, or `None` if unstated.
        (Provenance -- authored vs. defaulted vs. derived -- does not cross
        the boundary in this phase; see `verax_py.nim`'s own doc comment.)"""
        v = _vx.net_float_annotation(self._handle, key)
        return None if v != v else v  # NaN != NaN

    def subject(self):
        """This net as a role-binding subject -- pass it as a `part = net`
        keyword to `Design.role`. An opaque handle; nothing here to inspect
        from Python."""
        return _vx.net_subject(self._handle)

    def roles(self) -> list[tuple[str, str]]:
        """`(instance, part)` for every role this net belongs to, read back
        off the membership tags `Design.role` wrote -- survives even after
        this net is cut into a simulation fragment."""
        return _vx.net_roles(self._handle)

    def __repr__(self) -> str:
        return f"Net({self.name!r})"


class Component:
    """A component in a `Netlist`. Wraps the opaque handle
    `verax_py.add_component` returns; never constructed directly."""

    def __init__(self, netlist: "Netlist", handle):
        self._netlist = netlist
        self._handle = handle

    @property
    def designator(self) -> str:
        return _vx.component_designator(self._handle)

    def connect(self, pin: str, net: Net, kind: str = "passive") -> "Component":
        """Connects (auto-creating) pin `pin` to `net`. `kind` is one of
        `"input"`/`"output"`/`"inout"`/`"power"`/`"ground"`/`"passive"`."""
        _vx.connect(self._handle, pin, net._handle, kind)
        return self

    def spec(self, **kv) -> "Component":
        """As `Net.spec` -- the registered vocabulary shared by both scopes
        (`value`, `esr`, `esl`, `package`, `footprint`, `tolerance`, ...)."""
        for key, value in kv.items():
            if isinstance(value, Quantity):
                si, unit = _quantity_args(value)
                _vx.set_component_quantity(self._handle, key, si, unit)
            elif isinstance(value, str):
                _vx.set_component_text(self._handle, key, value)
            else:
                _vx.set_component_quantity(self._handle, key, float(value), "")
        return self

    def raw(self, key: str, value: str) -> "Component":
        _vx.set_component_raw(self._handle, key, value)
        return self

    def annotation(self, key: str) -> Optional[float]:
        v = _vx.component_float_annotation(self._handle, key)
        return None if v != v else v

    def text_annotation(self, key: str) -> str:
        return _vx.component_text_annotation(self._handle, key)

    def subject(self):
        """This component as a role-binding subject, as `Net.subject` is."""
        return _vx.component_subject(self._handle)

    def pin_subject(self, pin: str):
        """One of this component's pins as a role-binding subject --
        `verax/contract/design.innerPin`'s top-level counterpart."""
        return _vx.pin_subject(self._handle, pin)

    def roles(self) -> list[tuple[str, str]]:
        """As `Net.roles`."""
        return _vx.component_roles(self._handle)

    def __repr__(self) -> str:
        return f"Component({self.designator!r})"


class Netlist:
    """A netlist under construction. Corresponds to a Nim
    `netlist("name"): ...` block, built by ordinary method calls instead of
    a macro."""

    def __init__(self, name: str):
        self._handle = _vx.new_netlist(name)

    @classmethod
    def _from_handle(cls, handle) -> "Netlist":
        """Wraps a raw netlist handle this process did not just create --
        `verax.custom.EvalContext.design`'s route back to one, or a role's
        `apply` wanting the pythonic wrapper around the raw handle it was
        given. Bypasses `__init__`, which always makes a brand new netlist."""
        obj = cls.__new__(cls)
        obj._handle = handle
        return obj

    @property
    def name(self) -> str:
        return _vx.netlist_name(self._handle)

    def net(self, name: str, kind: str = "signal") -> Net:
        """`kind` is one of `"signal"`/`"power"`/`"ground"`/`"unknown"`."""
        return Net(self, _vx.add_net(self._handle, name, kind))

    def component(self, designator: str, kind: str, part_number: str = "",
                  name: str = "") -> Component:
        return Component(self, _vx.add_component(self._handle, designator,
                                                   kind, part_number, name))

    def __len__(self) -> int:
        return _vx.component_count(self._handle)

    def to_spice(self) -> str:
        """This netlist written out as a SPICE deck -- what
        `verax/netlist/formats/spice.writeNetlist` produces, unchanged."""
        return _vx.to_spice(self._handle)

    def annotation_issues(self) -> list[str]:
        """Every `netlist/annotations.validateAnnotations` finding -- a
        misspelled bare key, a wrong-scope key, or an unparseable value --
        rendered the same way the Nim CLI would print it."""
        return _vx.validate_annotations(self._handle)

    def check(self, offline: bool = False, verbose: bool = False,
              strict: bool = False) -> int:
        """Runs `verax/verify.verify` on this netlist with no roles or
        requirements attached -- prints the identical report `verax check`
        would for a bare netlist (which, honestly, states nothing that can
        be checked) and returns its exit code. For a design that attaches
        roles and `require`s, build a `verax.contract.Design` instead and
        call its own `.check()`."""
        # `verify()`'s own `echo` writes straight to the C stream, unbuffered
        # relative to Python's separately-buffered `sys.stdout` -- without
        # this flush, prior `print()` output can appear *after* the report
        # it was meant to precede, once both share one process's stdout fd.
        sys.stdout.flush()
        return _vx.check(self._handle, offline, verbose, strict)

    def __repr__(self) -> str:
        return f"Netlist({self.name!r}, {len(self)} components)"
