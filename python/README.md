# Python front end (spike)

This is the working prototype for `docs/python_compatibility.md` — all three
phases of its §8 ordering: circuit authoring, `verify`/readiness, built-in
role instantiation and `require` against a built-in evaluator, and now a
Python-authored **custom** `RoleDef`/`Evaluator`, round-tripped through
`plan`/`evaluate` via a live callback. It exists to answer the study's
central question by actually doing it rather than arguing it further, and it
does: annotation validation (`spec()`), the registered-unit check, the SPICE
writer, role attachment (`power_rail`, `i2c`, ...), `verax check`'s own
report, and now a role and an evaluator neither of which exists in
`verax/contract`'s own registry, all run for real, from Python, over the
exact same Nim code the CLI runs. `require`'s `ekPredicate` form is the one
piece still not wired in — see "What's not built yet" below.

`src/verax/` is untouched: nothing under it imports `nimpy`, and nothing in
this directory is on any path `nimble test`/`nimble build` walks. This
package depends on `nimpy` and on `verax` itself; the core stays
zero-nimble-dependency.

## Layout

- **`verax_py.nim`** — the only Nim file. A `nimpy` extension module: a
  curated set of `{.exportpy.}` procs over `verax/netlist/graph`,
  `verax/netlist/annotations` and `verax/verify`. Read its own doc comment
  first; it explains the boundary decisions (opaque object handles for
  `Netlist`/`Net`/`Component`, unit safety crossing as `(float, unit
  string)` and being *rechecked* on the Nim side rather than trusted).
- **`verax_python.nimble`** — declares the `nimpy` dependency and a
  `buildext` task. Not a `namedBin` package: a `nimpy` extension is a
  Python-loadable shared library (`.so`/`.pyd`), built with `nim c
  --app:lib`, not an executable.
- **`verax/`** — the pure-Python package a design file actually imports:
  `units.py` (a `Quantity` tagged-float, mirroring `verax/units.nim`'s
  suffix constructors one-for-one), `netlist.py` (pythonic
  `Netlist`/`Net`/`Component` wrappers around the raw `verax_py` calls), and
  `contract.py` (`Design`: role attachment and `require_nominal`/`_min`/
  `_max`/`_range`/`_relative`, over the same `Design` type `verax/contract`
  itself owns).
- **`examples/divider.py`** — the Python sibling of `examples/divider.nim`.
- **`examples/pdn.py`** — the Python sibling of the netlist half of
  `examples/design_contract.nim`: annotated components, the unit-safety and
  unknown-key checks (both ways: the validated `spec()` path and the
  permissive `raw()` escape hatch), and `Netlist.check()`.
- **`examples/design_contract.py`** — the full Python sibling of
  `examples/design_contract.nim`: the same board, the same `power_rail`/`i2c`
  roles, the same `require`, checked with `Design.check()`. Its output is
  byte-for-byte identical to the Nim version's, roles-and-all — proven by
  running both, not inferred.
- **`custom.py`** — Phase 3: `define_role`/`define_evaluator`, over `expand`/
  `apply`/`run` that are plain Python functions rather than Nim procs, plus
  the assertion builders (`nominal`/`at_least`/`at_most`/`between`/
  `relative`) and result builders (`measurement`/`passed`/`failed`/
  `not_evaluated`/`not_evaluable`) a Python `expand`/`run` build with.
- **`examples/custom_phase3.py`** — a role and an evaluator that exist
  nowhere in `verax/contract`'s own registry, defined and registered from
  Python, then checked by the identical `Design.check()` a built-in role
  goes through — one claim passes, one fails on purpose.

## Building and running

Needs `nim`, `nimble`, `nimpy` (`nimble install nimpy`), and Python 3 with
its development headers.

```sh
cd python
nimble buildext          # -> verax_py.so beside this README
python3 examples/divider.py
python3 examples/pdn.py
```

`verax_py.so` is not committed (`*.so` is already repo-wide gitignored);
build it locally. It links in the same simulator/analysis tree `verax
check` does — `verify.nim` imports `contract_eval` unconditionally, per its
own `CLAUDE.md`, so a compiled report from Python is never missing an
evaluator the CLI would have found — which is why `nimble buildext` takes a
few seconds and produces a multi-megabyte `.so`, not a thin shim.

## What's built and proven, not just sketched

Every claim below was run, not inferred from reading the Nim source:

- **Circuit authoring.** `Netlist`/`Net`/`Component`, `connect()`,
  `to_spice()` — a Python-built voltage divider round-trips to the identical
  SPICE deck `examples/divider.nim` produces.
- **The registered-unit check runs on the Nim side, for real.** `Component
  .spec(esr=nF(1))` raises `annotation 'esr' is in ohm, but was given F` —
  the exact message `esr = 1.nF` gets from the Nim DSL's `spec:` block,
  because it *is* the same `annotations.setAnnotation(e, key, v: Quantity)`
  overload, not a Python reimplementation of the rule.
- **The unknown-key check runs on the Nim side, for real.** `spec()` on an
  unregistered bare key raises `unknown annotation '...'`, matching
  `netlist/annotations.checkKey`.
- **`verify`/`readiness` runs on the Nim side, for real.** `Netlist.check()`
  prints the identical report `verax check` prints for the same graph and
  returns the same exit code — proven by round-tripping the STRUCTURE
  warning for a stray `raw("ESL", ...)` key through it.

This is exactly §3–4 of the study, demonstrated rather than argued: nothing
gets less strict, and what moves is only the *timing* of the check (a
`raise` at the call site instead of a compile error).

One integration wrinkle worth recording: Nim's `echo` inside `verify()`
writes straight to the C stdio stream, unbuffered relative to Python's own
buffered `sys.stdout` — mixing `print()` and a `.check()` call without a
`sys.stdout.flush()` first can print the Nim report *before* Python output
that logically precedes it. `Netlist.check()` flushes for you; nothing else
in this package needs to.

## Phase 2, built on top of phase 1

`verax.contract.Design` wraps a Nim `Design` (`contract/design.Design`, a
`Netlist` plus its roles and requirements) the same opaque-handle way
`Netlist` wraps a bare `Netlist`. `Design.role(role_name, instance_name,
**kv)` attaches a built-in `RoleDef` (`power_rail`, `i2c`, `regulator`, ...)
exactly as `contract/dsl`'s `role` macro does — a `Net`/`Component`/
`role_ref(...)` keyword is a binding, anything else a parameter — and
`Design.require_nominal`/`_min`/`_max`/`_range`/`_relative` attach a directly
-authored claim against whatever quantity a built-in evaluator produces.
Still **no callback boundary**: every one of these is Python calling into a
registry Nim already populated, not Python defining new Nim-callable
behaviour. `examples/design_contract.py` is the proof — same board, same
roles, same requirement as `examples/design_contract.nim`, and running both
side by side gives byte-for-byte identical reports.

One boundary wrinkle worth recording, because it is the reason
`contract.py` exists rather than `Subject` crossing directly: `Subject`
(`contract/types`) is a plain Nim `object`, not a `ref`, so it cannot get
the automatic opaque-capsule treatment `Netlist`/`Net`/`Component` get for
free. `verax_py.nim`'s `PySubject` is the one-line ref wrapper that gives it
the same treatment, built only by `net_subject`/`component_subject`/
`pin_subject`/`role_subject` — `Net.subject()`/`Component.subject()`/
`Component.pin_subject()`/`role_ref()` on the Python side. Everything else
(bindings and params as plain Python `dict`s, a claim's `condition` as
keyword arguments) rides on `nimpy`'s existing generic `Table`/`seq`
marshalling with no bespoke builder object needed.

## Phase 3, the callback boundary itself

`verax.custom.define_role`/`define_evaluator` register a Python-authored
`RoleDef`/`Evaluator` — `contract/roles/core.registerRole`/`contract/
evaluate.registerEvaluator`, over `expand`/`apply`/`run` that are plain
Python functions. The mechanism: `nimpy`'s `PyObject` is already a Nim value
with a `{.nimcall.}`-callable API (`callObject`) that keeps the wrapped
Python object alive through ordinary refcounting — the missing piece was
never `nimpy`'s. It was `RoleDef.expand`/`apply` and `Evaluator.run` being
declared `{.nimcall.}` (non-capturing) Nim proc *types*: a Nim closure bound
to one specific Python callable cannot convert to `{.nimcall.}`, which has
no environment pointer. `verax_py.nim`'s `pyRoleExpand`/`pyRoleApply`/
`pyEvalRun` are the answer — **one genuinely non-capturing trampoline per
signature**, not one per Python-defined role or evaluator, that recovers
*which* Python callable to invoke from data already in its arguments (a
role instance's own `.role` name; an assertion batch's `.quantity`, looked
up through the same public `evaluate.evaluatorFor` a built-in's own
dispatch uses) rather than from a closure. `examples/custom_phase3.py` is
the proof: a role and an evaluator that exist nowhere in `verax/contract`'s
own registry, checked by the identical `Design.check()`, with a real pass
and a real fail — plus a Python exception thrown from inside `expand`
propagating back out through `Design.explain()`/`.check()` as itself,
confirmed by throwing one on purpose.

One nimpy sharp edge found along the way, worth recording since it cost a
debugging pass: a `PyObject`-typed parameter given no default has no safe
"was this omitted" sentinel — passing Python's own `None` for an *optional*
callback (`apply=None`) produces a valid, non-nil `PyObject` wrapping the
`None` singleton, not a nil Nim ref, so `applyFn != nil` on the Nim side is
always true and calling `None` as if it were a callable raises `'NoneType'
object is not callable`. Fixed by never letting `None` reach the Nim
boundary: `custom.define_role` always passes a real Python callable for
`apply`, a no-op lambda when the role author gave none, so `vxRegisterRole`
never needs to distinguish "no apply" from "an apply that wraps `None`".

## What's not built yet

`require`'s `ekPredicate` form (`require pred(a = ..., b = ...) do (a, b:
float) -> bool: ...` in Nim) — a Nim proc over *named measurement
dependencies*, built fresh by every `require` call rather than registered
once under a name the way a role or evaluator is. That is exactly what
breaks the phase-3 trick: `pyRoleExpand`/`pyEvalRun` recover which Python
callable to invoke from data in their arguments (a role name, a quantity),
but `PredicateProc` takes only `values: seq[float]` — nothing in its call
carries an identity a Python callable could be looked up by. A fix would
need a second mechanism (an id-keyed registry and a small pool of
`{.nimcall.}` trampoline procs, or a deliberate, separately-justified
loosening of `PredicateProc` from `{.nimcall.}` to `{.closure.}` in
`contract/types.nim` — the latter costs the non-capturing guarantee the Nim
DSL's own predicates rely on, so it is not a decision to make lightly, and
is not made here). `Design.require_relative` needed none of this (a
relative bound is data, not a callback) and is already wired in.
