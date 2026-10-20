# Python authoring: a feasibility study

Can a design — its circuit, its roles, its assertions — be authored in Python
while `verax` itself stays a Nim library with no dependency beyond the
standard library? **Yes, with one architectural commitment**: a
`nimpy`-compiled extension module as a second, permanently-coexisting front
end, packaged as a separate package, so the "opt-in
per import" rule the core observes everywhere else stays true for the core
and applies at the *package* boundary instead. This is a study, not a plan:
nothing here is code, and every claim below that needs a working prototype to
be sure of says so.

Scope, per the questions this was commissioned to answer: circuit designs
*and* roles/assertions/evaluators, Python and Nim DSLs coexisting
permanently (not a migration), and an FFI/library boundary rather than a
serialized intermediate format.

---

## 1. What "the DSL" actually is, and why that matters here

`netlist/dsl.nim` and `contract/dsl.nim` are Nim `macro`s: they run at
**compile time**, rewrite source into calls on `graph.nim`/`design.nim`, and
buy three things a hand-written script doesn't get for free:

1. **Identifiers become real Nim `let`s.** `component ... : ...` bound to a
   bare name is a compile-time-checked variable; typo it later and the
   compiler rejects the file before it runs.
2. **`spec:` keys are validated against `netlist/annotations` at compile
   time.** An unknown or wrong-scope key is a compile error naming the
   registered keys, not a runtime surprise.
3. **Unit literals (`20.mohm`, `3.3.V`) are typed**, so a value can't be
   silently read as the wrong quantity or the wrong decade.

None of this is dimensional analysis, and that turns out to matter a lot for
portability (§3). It's straight text substitution plus a lookup against a
runtime table the macro can see at compile time — `netlist/annotations`'
registry is, in its own words, "a runtime table seeded from a `const`", kept
runtime-visible for exactly this reason. `contract/dsl.nim` is thinner still:
it reuses `buildNetlistBody` and adds `role`/`require`, routing each
`key = value` to a binding or a parameter by testing
`when compiles(subjectOf(value))` — again a compile-time test over an
otherwise perfectly ordinary runtime call.

**The load-bearing fact for this whole study**: `contract/CLAUDE.md` states
outright that built-in roles "use no privileged mechanism" — a `RoleDef` is
"ordinary... proc values on a data object", built and registered at runtime
exactly like a user-defined one, pinned by a test that defines a role outside
the library and checks it takes the identical path. Roles, evaluators, and
assertions were already designed to not need Nim's macro layer. The netlist
DSL's macro layer is authoring convenience and compile-time safety on top of
an otherwise plain runtime API (`graph.nim`) — it is not where the domain
model lives.

That's what makes "write the DSL in Python" a real question rather than a
rhetorical one: a Python binding doesn't have to reimplement a domain model
that only exists as Nim AST; it has to call the same runtime procs the
macros already expand to, and reimplement only the *validation timing* the
macros gave for free.

---

## 2. Recommended boundary: `nimpy`, not an IR, not a subprocess

Three ways Python could reach the Nim engine:

- **FFI/library** — `nimpy` compiles a Nim module into a Python-importable
  extension (`{.exportpy.}`), synchronous, in-process, sharing the live
  object graph. This is the recommended shape, matching the direction
  already indicated: it's the only one of the three that lets Python
  register a *live* custom role or a *live* custom evaluator (§5), because
  those are proc values that need to be called back into from Nim's planner
  during `evaluate`/`readiness` — not data that can be described once and
  handed over.
- **IR/serialization** — Python builds a design, emits a file (JSON,
  s-expressions, whatever), a Nim process reads it and runs `verify`
  unchanged. Simplest to build, and *sufficient* for plain circuit
  authoring. Rejected as the primary mechanism here because it degrades
  hardest exactly where the stated scope is broadest: an `ekPredicate`
  assertion is a closure, and a custom `Evaluator` is a proc registered into
  a runtime table read back during planning — neither survives being
  written to a file and read back later by a separate process. Worth
  keeping in mind anyway (§7) as the fallback for anything the FFI spike
  can't get working.
- **Subprocess/CLI** — Python shells out to `bin/verax check design.nim`.
  Already possible today, and already insufficient: it checks a `.nim`
  file, it doesn't let Python *author* one. Not a contender for this ask.

`nimpy` was checked for currency rather than assumed from memory: it is
actively maintained against Nim 2.2.x with `--mm:orc` (verax already requires
`nim >= 2.2.10`), compiles a module with `nim c --app:lib`, and its
`{.exportpy.}` pragma generates the CPython glue (module init, argument
unpacking, return conversion) so the wrapped Nim procs don't hand-write
Python C-API calls. It also converts a Python callable into a `PyObject` Nim
can invoke via `PyObject_Call` — the mechanism §5's custom-evaluator callback
depends on — and `nimporter`/`nim-pymod` exist as adjacent tools for
packaging and bulk wrapper generation if the by-hand binding surface (§6)
turns out to be worth automating.
([yglukhov/nimpy](https://github.com/yglukhov/nimpy),
[Pebaz/nimporter](https://github.com/Pebaz/nimporter),
[jboy/nim-pymod](https://github.com/jboy/nim-pymod))

### Packaging

The core's zero-dependency posture (`verax.nimble`: "Nothing beyond the
standard library, on purpose... a nimble dependency cannot be made
opt-in-per-import the way a module can") applies directly. A Python binding
gets the obvious answer: a new top-level package (`python/` or similar), depending on `nimpy` and on `verax` itself, building a `.so`/`.pyd`
nobody who just runs `nimble test` ever compiles. `src/verax/` stays
untouched; `import verax/netlist` in an unrelated Nim program still costs
nothing.

---

## 3. What ports with no real loss

**Units.** `units.nim` says of itself that it is "deliberately not a
dimensional-analysis system" — no unit arithmetic, no derived units, no
compile-time dimension checking. It's `distinct float` plus scaled suffix
constructors (`defCtor(mohm, Ohms, 1e-3)`), existing purely so `esr = 20.mohm`
can't be misread as `"20m"`/`0.02` (a factor-of-1000 ambiguity). There is
nothing here for Python to lose: a thin Python `Quantity`/tagged-float layer
(`mohm(20)`, `uF(100)`) gives the identical "can't be misread" property at
runtime, which is the only property this module ever bought. Whether that
layer is pure Python or itself calls into Nim's constructors via `nimpy` is
an implementation detail, not a feasibility question.

**The netlist graph API.** `graph.nim`'s mutators (`addComponent`, `addNet`,
`addPin`, `connect`/`disconnect`, `instantiate`, `renameNet`, `adoptNet`,
`mergeNets`, ...) are plain procs over `ref object` types. `nimpy` wraps
plain procs and simple objects well; this is the largest part of the ask
(circuit designs) and the least novel part of the work.

**Environment, layout hints, traversal, pinmux, interfaces, packages.**
Every one of these is described in `netlist/CLAUDE.md` as "storage in
namespaced `attrs`" with a pure accessor/validator pair and no privileged
compile-time behavior beyond the same `spec:`-key check units already get.
Same shape, same answer.

**`verify`/readiness.** `verify.readiness(design, allowed)` returning a
report is already a plain runtime call; exposing it to Python is direct.

---

## 4. What ports, but the *timing* of a guarantee moves

This is the honest center of the study, not a footnote: everywhere the Nim
DSL currently catches something at compile time, the Python path catches the
identical thing — same check, same registry — but at the moment that line of
the script *executes* rather than before the file can even be built.

- **Identifier binding.** Nim's macro emits a `genSym`'d `let`; the Python
  binding just returns a Python object from a wrapped `addComponent` call and
  the author assigns it to a variable, which is what Python does for
  everything anyway. Arguably *no* loss: a bare-Nim script without the macro
  would have this exact same runtime-only property, and the macro's actual
  value-add here (a compile-time-checked identifier) has no Python analogue
  at all — but Python was never claiming to have compile-time anything, so
  this isn't a regression against a Python user's expectations, only against
  a Nim author's.
- **`spec:` key validation.** Moves from "compile error, can't build the
  file" to "the `spec(...)` call raises the moment it runs" — which, for a
  script with no separate build step, is functionally close to immediate.
  The check itself (against `netlist/annotations`' runtime table) is
  unchanged and unweakened.
- **Unit-literal safety.** Same shift: a Python `Quantity` wrapper raises
  when constructed with the wrong scope/unit, not when the file is compiled.
- **`for`/`if`/`case`/`when` inside a block.** The Nim macro explicitly
  restricts these to "control flow over DSL statements", rejecting bare
  `discard <expr>` as "arbitrary code wearing a keyword" and rejecting
  nested `role`/`require`. Python has no such macro-enforced restriction to
  replicate or lose — a Python script is already arbitrary code, so `for`/`if`
  compose the ordinary way with no analogous restriction needed. This is a
  case where Python is *more* permissive than the Nim DSL by construction,
  which is a design question for the binding layer (does it want to
  artificially fence in what a design file may do?) rather than a porting
  gap.

None of this is a blocker. It's the same tradeoff every dynamically-typed
scripting front end onto a statically-checked engine makes, and it's the one
part of this study that most benefits from being said plainly rather than
glossed: **nothing gets less strict, some things get checked later.**

---

## 5. Roles, assertions, and custom evaluators

This is where the "FFI, not IR" call earns its keep, and also where the
study is least confident without a prototype.

**Built-in and user-defined roles** — straightforward. `RoleDef.apply`
(writes annotations) and `RoleDef.expand` (returns assertions, pure) are
"proc values on a data object... not compile-time constructs", so a role
"built at runtime registers and behaves identically" to a built-in one. A
Python-authored `RoleDef` is a data object whose two proc fields are Python
callables wrapped as `PyObject`s that Nim calls back into via
`PyObject_Call` when `apply`/`expand` run. This is exactly the callback shape
`nimpy` documents supporting.

**`require` with `ekPredicate`.** `contract/types.nim`'s own doc: "Nim is the
expression language — the predicate is a non-capturing proc, so the macro
needs no parser, no evaluator, no bespoke error messages." A Python predicate
is a Python closure (naturally capturing, unlike the Nim one), stored the
same way a role's `expand` would be, called back the same way. No new
mechanism needed beyond the one role authoring already requires.

**Custom `Evaluator`s** — the most novel case, and the reason this section
opens with a hedge. `Evaluator` is registered into a runtime `quantityIndex`
and called through `EvalProc(EvalContext): seq[AssertionResult]` during
`plan`/`evaluate`. Two things make this harder than a role, not different in
kind: `EvalContext.scratch` is a `Table[string, RootRef]` — a Nim
type-erased carrier that a Python-side analysis result would need a thin Nim
shim to populate rather than crossing the FFI boundary raw; and `Evaluator`
also carries `needs: set[Capability]` and `setupDoc`, which a Python
evaluator would just set as plain data on the same wrapped registration call.
Neither is a wall, but this is the one piece of the whole study worth an
actual half-day spike before quoting effort on it — the shape is sound on
paper, but a type-erased scratch table and a Python object don't get proven
compatible by reading source.

**Deliberately out of first-phase scope**: XSPICE code models
(`spice/xspice/dsl.nim`). The top-level `CLAUDE.md` frames that DSL as
strict specifically *because* it authors compile-time-checked ports that
back a C code-model build — a different, deeper coupling to Nim/C toolchain
plumbing than anything above, and not part of the stated scope (designs,
roles, assertions). Worth a line here only so it isn't quietly assumed to be
free later.

---

## 6. Mixed-language part libraries

A natural question once designs and roles can be authored on either side:
can a design mix parts defined in Nim and parts defined in Python — a
`designs/lib/`-style template instantiated alongside Python-native
components in one netlist? **Yes, and it falls directly out of choosing the
FFI boundary over an IR in §2**: because Python and Nim share one live,
in-memory `Netlist`/`Component`/`Pin` graph rather than exchanging
serialized fragments, a "part" is just an object handle, and nothing stops a
design from holding handles created on either side of the boundary in the
same graph. The two directions are not equally easy.

**Nim-authored part, instantiated from Python — cheap, no callback
needed.** A `designs/lib/` template (`crystal.nim`, `m24c64_sheet.nim`,
`filters.nim`'s parameterized worked example) is already an ordinary Nim
proc that computes from its arguments and returns a template `Netlist` —
exactly the "`subckt` block is ordinary runtime code" property
`netlist/CLAUDE.md` describes. Wrap such a proc with `{.exportpy.}` and
Python calls it with plain arguments, gets back an opaque handle to that
same `Netlist` object, and instantiates it via a wrapped `graph.instantiate`
into a parent design Python itself built — wiring its ports to nets Python
created via wrapped `addNet`/`addComponent`. Nothing serializes across the
boundary, and a net doesn't know or care which side declared the pin it's
connecting to; it's the same object graph either way.

**Python-authored part, instantiated from a Nim-authored design — exactly
as uncertain as the custom-evaluator question, and no more so.** The data
shape is fine (a `Netlist`-like template is a `Netlist`-like template
regardless of which language built it), but *building* it means Nim calling
into Python first — architecturally the same shape as a Python-authored
role's `expand` or a custom `Evaluator`'s callback: a `PyObject` invoked via
`PyObject_Call`. The `with = proc(Netlist)` post-instantiation hook
(per-instance tweaks, `packages.nim`'s section assignment) is the same
mechanism again — a closure run after `instantiate`, Python or Nim
indifferently.

Net effect on scope: mixed-language libraries add no new risk to this study.
They're covered by the same §5/§8.3 callback spike — if a Python-authored
`Evaluator` round-trips through `plan`/`evaluate`, a Python-authored part
template round-trips through `instantiate` by the identical mechanism.

---

## 7. The binding-maintenance risk, named plainly

A hand-written wrapper per exposed proc is the same shape of problem
`spice/models`' "opt-in per import" already names elsewhere in this repo: a
second consumer of an API is exactly what surfaces a wrapper nobody wrote
yet, the same way `nimble test`'s own hand-written task exists because
nimble's built-in one silently swallowed real failures. Two concrete
mitigations, not a full plan:

- A **coverage test** — enumerate exported procs on the Nim side, assert
  every one (or every one on an explicit allowlist of intentionally-Python-
  invisible internals) has a binding — so drift is a failing test, not a
  silent gap discovered by a user.
- Lean on `nim-pymod`/`nimporter`-style generation for the wide, low-risk
  surface (`graph.nim` mutators, accessors) and hand-write only the
  callback-carrying surface (§5), which is genuinely a small fraction of the
  total API.

---

## 8. Fallback and phasing

If the §5 spike shows the callback boundary is rougher than it looks on
paper, the IR/serialization path from §2 is not wasted groundwork — it is
still a fully viable, lower-effort way to cover "circuit designs" alone
(§3–4's scope), it's just weaker on "roles & assertions" and unable to host
a live custom evaluator or predicate. It would need to be paired with a
second, narrower mechanism for that piece rather than replacing it wholesale.

Suggested order, cheapest-and-most-certain first:

1. Circuit authoring — `graph.nim` wrapped directly, `verify`/`readiness`
   callable and returning structured results. Everything in §3, all of §4's
   timing shift, no callback boundary needed at all.
2. Built-in role instantiation and `require` against built-in evaluators —
   still no callback needed; Python is a client of registries Nim already
   populates.
3. **Spike**: a Python-authored custom `RoleDef` and a Python-authored
   custom `Evaluator`, round-tripped through `plan`/`evaluate`. This is the
   item that actually answers "is the FFI-boundary lean right", and it
   should happen before any packaging or coverage-tooling investment.
4. Packaging, coverage testing, and whatever `nim-pymod`/`nimporter`
   automation the surface from steps 1–2 turns out to want.

---

## 9. Bottom line

Nothing in `verax`'s domain model is macro-only — the macros are a
compile-time convenience layer over runtime APIs that were already built to
be registered into and called at runtime, which is precisely what a second,
dynamic front end needs to be true. The core stays pure Nim/stdlib; a
`nimpy`-based `python/` package sits beside it as its own package.
The open question isn't "can Python author a design" — it can, cleanly, for
everything in §3–4 — it's "how far the callback boundary goes before it gets
awkward" for custom evaluators specifically (§5), and that has a cheap,
concrete way to find out (§8.3) rather than a reason to guess.
