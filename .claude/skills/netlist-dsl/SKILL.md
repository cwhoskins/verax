---
name: netlist-dsl
description: Write or edit a verax netlist/design in Nim using the `netlist/dsl.nim` and `contract/dsl.nim` macro DSLs — `net`/`component`/`pin`/`spec:`/`model`/`subckt`/`instance`/`environment`/`role`/`require` syntax, unit literals (`20.mohm`, `3.3.V`), and how bare identifiers, `for`/`if`/`case`, and typed vs. `attrs` fields work. Use this whenever creating a new design file under `designs/`, extending an existing one, writing an example netlist, or reviewing someone else's DSL usage — and also whenever a `netlist(...)`/`design(...)` block throws a confusing compile error, or compiling a design feels slower than it should, since it covers the debugging and fast-iteration workflow for both.
---

# Authoring a netlist with the DSL

This is the quick-reference-plus-workflow layer. The DSL's full, exact
semantics — `spec:`'s registered-key list, `traverse:`'s grammar,
`role`/`require`, packages, pinmux, interfaces — live in
**`docs/authoring.md`** (also `nimble guide`) and
**`src/verax/netlist/CLAUDE.md`**/**`src/verax/contract/CLAUDE.md`**. Read
those for anything beyond the core shape below rather than trusting memory or
this file: those modules are actively developed, and reproducing their rules
here would just be a second copy that goes stale.

## The core shape

```nim
import verax/netlist/dsl              # netlist(...) alone
# or, for roles/require on top of the same netlist body:
import verax/contract/dsl             # design(...)

let nl = netlist("divider"):          # or: let d = design("board"):
  net vin, kind = ntSignal
  net vout, kind = ntSignal
  net gnd, kind = ntGround, name = "0"   # SPICE ground must be named "0"

  component R1, kind = "resistor", value = "1k":
    pin "1", vin, kind = ptPassive
    pin "2", vout, kind = ptPassive
    spec:
      tolerance = 5.pct        # validated against the annotation registry,
                                # at compile time -- an unknown key or wrong
                                # unit is a build error naming what's valid
```

**Bare identifiers become real Nim `let`s** (`vin`, `R1`): reference them
later, and a typo is a compile error rather than a silently-created second
net. `kind`/`name`/`partNumber`/`designator` on a `net`/`component` header
are the only *typed* fields (direct assignment); every other `key = value`
there lands unvalidated in that entity's `attrs` bag — the permissive
head-of-statement path. A nested **`spec:` block is the validated path**:
its keys are checked against `netlist/annotations` **at compile time**, and
a value written as a `verax/units` literal (`20.mohm`, `3.3.V`, `400.kHz`,
`5.pct`, ...) can't be misread by a factor of 1000 the way a bare string
could.

## Statements worth knowing exist (see `docs/authoring.md` for each)

- **`net`** — `kind = ntPower|ntGround|ntSignal|ntUnknown`; `name = "..."`
  gives it a different SPICE-deck name than its Nim identifier.
- **`component ..., kind = "...", value = "..."`** with nested
  `pin "name", <net>, kind = ptPassive|ptPower|ptGround|ptInput|ptOutput|ptInOut`.
  `kind`'s string drives the SPICE device letter.
- **`spec:`** inside a `net`/`component` — the compile-time-validated
  annotation path (see above).
- **`traverse:`** inside a `component` — states which pin pairs actually
  conduct, for a part (`rf_switch`, a connector, a relay) whose `kind` alone
  can't say it.
- **`model "name", "<card>"`** — registers a raw `.MODEL` card
  (`graph.setModel`), passed through unparsed.
- **`environment:`** (top-level) — board ambient temperature range; `spec:`
  at netlist scope, spelled differently because it states board conditions
  rather than a net's own property.
- **`subckt("name", [ports]): ...`** builds a free-standing template
  `Netlist`; **`instance designator, template, [nets]`** (or
  `instantiateByPort` for named wiring) instantiates it via `graph.instantiate`.
  A `subckt` block is ordinary runtime code inside a `block` expression, so
  put it in a `proc` and compute values from arguments — `designs/lib/filters.nim`
  is the worked parameterized example.
- **`role "roleName", instanceName, part = subject, param = value, ...`** and
  **`require quantity(subjects) <= value, id = "...", because = "..."`** —
  `contract/dsl.nim` only, inside `design(...)`. These hoist to *after* the
  netlist is built, so they are **rejected with a message if nested** inside
  a `for`/`if`/`case` branch — attach them at the top level instead.
- **`for`/`if`/`case`/`when`** are allowed inside a `netlist`/`design` block,
  as control flow *over* DSL statements (a decoupling bank, a channel per
  lane) — not as an opening to arbitrary code. A bare `discard <expr>` is
  refused; `discard` alone is fine as an empty branch. A `let` a `net`/
  `component` binds inside a branch is scoped to that branch — address it
  afterwards through `graph.findComponent`/`findNet` by name, not by the
  bound identifier.

## When the macro itself is in your way

The macro is real compile-time value, but it's still a macro: a mistake in
your block can surface as an opaque expansion error rather than a normal
type error. Two things fix that without giving up on the DSL for good —
found and verified while prototyping a Python front end for this same
authoring surface (`docs/python_compatibility.md`).

**It is never the only way in.** `netlist/CLAUDE.md` says the macro "only
ever expands into calls on the `graph.nim` API." When sketching a topology
or chasing a bug and you don't yet need the compile-time guarantee, write
the same thing as plain calls — same safety, checked at the call site
instead of at compile time (`setAnnotation`/`checkKey` *are* what `spec:`
expands to), but ordinary compiler errors instead of macro diagnostics:

```nim
import std/tables
import verax/netlist/graph
import verax/netlist/annotations

let nl = newNetlist("divider")
let vin = addNet(nl, newNet("vin", ntSignal))
let r1 = addComponent(nl, newComponent("R1", kind = "resistor"))
setAnnotation(r1, "value", "1k")
discard connect(r1, "1", vin, ptPassive)
```

Port back to the macro syntax once the topology is settled and the file is
meant to be committed — a design re-verified by CI for years is worth the
earlier failure point; a scratch file answering "does this even work" is
not.

**`expandMacros` turns a confusing macro error into an ordinary one.** Wrap
the block (`import std/macros` first) and the compiler prints the literal
expansion — the real `newNetlist`/`addNet`/`addComponent`/`connect`/
`setRawAnnotation` calls the block turned into:

```nim
import std/[tables, macros]
import verax/netlist/dsl

expandMacros:
  let nl = netlist("divider"):
    net vin, kind = ntSignal
    component R1, kind = "resistor", value = "1k":
      pin "1", vin, kind = ptPassive
```

Now debug the printed calls against `graph.nim`/`annotations.nim` like any
other Nim code, instead of guessing at AST internals. Works identically for
`contract/dsl.nim`'s `design(...)`/`role`/`require`.

**What's actually slow is `verify`, not the macro.** Measured: a plain-calls
divider and a macro-DSL divider both compile in ~0.7–0.8s when the only
import is `verax/netlist/graph` (or `verax/netlist/dsl`). Adding
`import verax/verify` pushed the same file to ~15s, because `verify.nim`
imports `analysis/evaluators/contract_eval` **unconditionally** (per its own
`CLAUDE.md`), pulling in `schematic`/`spice`/`analysis`/`pcb` transitively on
purpose — so a quantity with "no evaluator" really has none, not one that
just wasn't imported. So while sketching pure topology, hold off on
`import verax/verify` until you actually need `readiness`/`check`; that
import, not the DSL choice, is what will dominate your compile time.
