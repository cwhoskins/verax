"""Python front end for `verax`, per `docs/python_compatibility.md`.

A prototype, not a released package: it exists to answer the study's own
question ("can Python author a design") by actually doing it, against the
`verax_py` `nimpy` extension in this same directory (`../verax_py.nim`,
built by `nimble buildext`).

    from verax import Netlist
    from verax.contract import Design
    from verax.custom import define_role, define_evaluator
    from verax.units import mohm, kohm

All three phases of the study's §8 ordering are wired in: phase 1
(`Netlist`/`Net`/`Component`, `verify`/readiness over a bare netlist), phase
2 (`verax.contract.Design`: built-in role instantiation and `require`
against a built-in evaluator, no callback needed), and phase 3
(`verax.custom`: a Python-authored custom `RoleDef`/`Evaluator`, round-
tripped through `plan`/`evaluate` via a live callback). `require`'s
`ekPredicate` form (a Nim proc over named measurement dependencies) is the
one piece still open -- see `verax.custom`'s own module doc for why.

Nothing in this package is imported by `src/verax/`, and nothing under
`src/verax/` imports `nimpy` -- the core stays zero-dependency, exactly the
separate-package boundary the study recommends.
"""

from .contract import Design, RoleRef, role_ref
from .netlist import Component, Net, Netlist

__all__ = ["Netlist", "Net", "Component", "Design", "RoleRef", "role_ref"]
