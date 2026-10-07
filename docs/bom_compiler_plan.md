# The BOM compiler: plan for `src/verax/bom/`

**Status: Stage 0a, Stage 0b and Stage 1 shipped (2026-09-30); Stage 2 shipped
(2026-10-04); Stages 3 and 4 shipped
(2026-10-06), Stage 3's disk cache moved to Stage 5 — Stages 5–6 not started.** This document is the implementation plan for a parametric
bill-of-materials compiler — the submodule three existing comments already
reserve a slot for — carried from exploration and the approved design
decisions. `src/verax/bom/` now holds collection and classification (Stage 2); before
it landed the two prerequisite fixes to `netlist/` the design depends on, plus
the vocabulary and board-defaults layer Stage 1 adds (see each stage below for
what shipped and where).

**Revision note.** Four codebase limitations surfaced during design were each
independently re-investigated before being built on. All four are resolved in
the design below: fact 1 (`value`/RKM) is closed with no new annotation key at
all — a value-space `when` dispatch makes `value = 2.2.kohm` deck-safe, which
superseded the original "add typed `resistance`/`capacitance`/`inductance`
keys" direction. **Shipped, as Stage 0a.** Fact 2 (`partNumber` overloading)'s
template-name half is fixed — **shipped, as Stage 0b** — its IPN/free-text
half is handled by Stage 3's resolver, which falls back to `partNumber`
when no `mpn` is stated and always says so — info when a source recognises
it, a warning when it is ordered unverified (changed 2026-10-06; it was
originally only *tried*) — and the labels moved to a new `description` annotation in every
design and template, so `partNumber` is no longer overloaded with them. Fact 4 (`Choice` erasing part `use`)
is **shipped, as Stage 1**. Fact 3 (`spec:`'s compile-time registry) is real
but costs nothing today and is recorded as deferred, not built.

*Eight stages. 0a, 0b and 1–4 are offline and hermetic; Stage 5 is the only one
that touches a network, and it is opt-in per import. 0a, 0b and 1–4 are done
(3's disk cache moved to Stage 5); 5–6 remain.*

---

## Context

A verax design states *what a part must do* — `value = "10k"`,
`spec: tolerance = 1.pct`, `spec: footprint = "Resistor_SMD:R_0402_1005Metric"`
— and `parts/policy.nim` computes *what kind of part that is*: a case size, a
dielectric, a voltage rating. Neither answers *which part to buy*, and there is
no way to print either without writing a Nim program.

The gap is already named in three places in the repo, and this plan fills
exactly that slot rather than inventing a new one:

- `src/verax/pcb/bom.nim:1-6` — "This *compiles* what the board file already
  carries; it does not resolve parts against a catalogue — parametric part
  matching against a supplier database is a separate concern and a separate
  submodule."
- `src/verax/pcb/CLAUDE.md:17` — "that is a separate **`verax/bom`** concern."
- `docs/findings.md:243-250`, open finding #17 (§56) — "`verax bom <design>` —
  `pcb/bom.buildBom` exists and the part policy computes real choices with real
  provenance, and there is no way to print any of it without writing a program."

`src/verax/parts/CLAUDE.md` states the extension point in as many words: *"a
policy built at runtime from a preferred-parts database behaves identically to
the built-in one"*. A distributor-backed catalogue is the database that
sentence was written for.

**Target.** `verax bom designs/foo.nim` resolves every part on the board to a
real orderable MPN — parametrically for resistors, capacitors and ferrite
beads/inductors, by stated part number for everything else — checks each MPN
actually exists at a distributor, says out loud when a part is uncommon, and
emits a JSON result a later run reads back as a preference, so a resolved board
stays resolved the same way.

### Design decisions taken up front

1. **Network via `std/httpclient` with `-d:ssl`.** Still stdlib-only; no new
   nimble dependency, which is the rule `verax.nimble:19-24` states and the
   reason the MCP server is its own package. The network source modules are
   opt-in per import and guard on `when defined(ssl)` so a build without the
   flag gets a named refusal rather than an obscure raise from inside
   `std/net`.
2. **Report and CSV, never mutating the design file** — plus a **JSON result
   read back on a later run as a priority**, so a chosen MPN sticks across runs.
   The design source stays the single authority on what a part is; an MPN worth
   keeping permanently is pasted into a `spec:` block by hand.
3. **Board-level defaults are a netlist-scope `bom:` DSL block**, beside the
   existing `environment:` block.
4. **A non-passive with no part number is `sevError`** — a BOM line nobody can
   buy is not a smaller BOM — **except** for DNP and excluded parts, which
   report `sevInfo`.

---

## Five facts from the codebase that shape this

Each is a trap if ignored, and each was verified rather than assumed. (Facts 2
and 4 were independently re-investigated after this plan was first drafted;
both findings below have been revised or hardened by that investigation.)

1. **Resolved — no new annotation key needed.** A passive's magnitude is the
   single `value` key, `akString` (`netlist/annotations.nim:153-156`). The
   obstacle to reading a number back is real — `formats/spice.parseSpiceMagnitude`
   (`formats/spice.nim:109`) correctly refuses **RKM notation** (`"2k2"`) rather
   than guessing, and it must keep doing so: `value` also holds every
   diode/zener/BJT/MOSFET's `.MODEL` name, and real part numbers already in
   this repo (`1N4148`, `1N5819`) are lexically valid RKM, so an RKM-accepting
   parser applied to `value` would silently misread `1N4148` as 1.4148 nF.
   Ruled out for that reason: making `value` numeric (breaks the 76 sites that
   append a source spec, a behavioural expression or a model name verbatim to
   it); adding parallel `resistance`/`capacitance`/`inductance` keys (a
   duplicate field to keep in sync with `value`).

   **The actual fix needs no parser at all.** `2.2.kohm` is not a string to
   disambiguate — it is already a typed Nim expression (`kohm(2.2): Ohms`), so
   there is nothing ambiguous about it and nothing that can collide with a
   model name, which is always a plain string literal. `netlist/dsl.nim`'s
   head-of-statement field dispatch currently stringifies any `key = value`
   pair outside `componentKnownFields` via plain `$value`
   (`setRawAnnotation(c, key, $value)`); for the `value` key specifically that
   is unsafe for a `Quantity`-typed RHS, since `units.nim`'s own `$` renders a
   human-readable form (`"2.2 kohm"`, space and unit suffix) that would
   corrupt a deck line. Fix: a value-space `when` dispatch scoped to the
   `"value"` key, the identical idiom `contract/dsl.nim`'s `subjectOf`
   binding-vs-parameter split already uses
   (`when compiles(subjectOf(value))`):

   ```nim
   when value is Quantity:
     setRawAnnotation(c, "value", spiceValue(float(value)))
   else:
     setRawAnnotation(c, "value", $value)
   ```

   `value = 2.2.kohm` then writes the exact `spiceValue` scientific-notation
   string — unambiguous to ngspice and to `parseSpiceMagnitude`, which already
   reads it back cleanly with no change needed there. Zero registry changes
   (`value` stays the one `akString` key it is today); zero changes to any of
   the 76 existing consumers, since a model name, a source spec, and an
   old-style magnitude string all still hit the unchanged `$value` branch;
   works for a computed `Ohms`/`Farads` variable too, not just a literal,
   since `when x is T` resolves on static type. RKM text itself stays
   refused, correctly — accepting it would still be wrong, since ngspice
   itself silently misreads it (verified empirically against ngspice-46:
   `2k2` → 2000, discarding the `2`), so there is no case where parsing RKM
   text would be both safe and useful once the typed literal exists as the
   safe path.

   Scope call: this fixes only the head-of-statement path (`value = ...`
   outside a `spec:` block), which is where 100% of existing `value` authoring
   already happens — `value` is never used inside a `spec:` block today.
   Extending it into `spec:` would need touching `setAnnotation`'s typed
   dispatch, which checks `AnnDef.kind` (`value` is `akString` there) — left
   out of scope rather than solved speculatively. Built in Stage 0a, below;
   `bom/collect.nim`'s design needs no change either way, since it already
   reads `attrs["value"]` through `parseSpiceMagnitude` regardless of which
   authoring path produced the text.

2. **`Component.partNumber` is overloaded four ways, not two, and one of the
   four is a bug.** (`netlist/types.nim:38-74`.) Confirmed by
   re-investigation:
   - A real manufacturer part number (the intended meaning, and what
     `pinmux`'s `partNumber`-keyed registry correctly assumes —
     `pinmux.nim:117,161,181`, keyed on genuine MPNs like `STM32H563ZIT6`,
     correctly distinguishing it from the pinout-incompatible `...ZIT6Q`
     variant).
   - An internal/house part number (IPN) — `pcb/bom.nim:46`'s
     `PartNumberKeys` list already conflates this with the above, putting
     board-file **IPN** ahead of `Component.partNumber`-as-MPN in one lookup
     chain. Pre-existing, independent of this plan, worth flagging as its
     own finding.
   - **The subcircuit template name.** `graph.instantiate` (`graph.nim:495`)
     sets an instance's `partNumber` to `defNetlist.name`, and
     `formats/spice.nim:465,469` reads `comp.partNumber` (not
     `subNetlist.name`) to spell the `X` card and match it against the
     `.SUBCKT` block — so the two already-written fields agree only because
     `instantiate` keeps them in lockstep, and nothing stops a design's
     `instance ..., partNumber = "LT8640A"` (routed through
     `dsl.nim:809-824`'s field-assignment path) from silently
     desynchronizing them today. **Fixed by Stage 0b, below** — separable
     from the rest of this fact, ships first, a three-line diff, and the
     existing deck-text tests already pin it.
   - **A free-text descriptive label** — confirmed live in ~20 design sites
     (`"USB-C receptacle"`, `"dummy USB HS PHY"`, `"hdr-8"`). Under a naive
     "assume `partNumber` is the MPN when none is stated" rule, every one of
     these would present as a confident, wrong MPN and pass the resolver's
     `sevError` gate. **The resolver must not silently equate `partNumber`
     with `mpn`** — see the amended Stage 3 resolver rule below.

3. **A runtime-registered annotation cannot be used inside a `spec:` block.**
   `annotations.builtinDef` reads the `const builtinAnnotations` only
   (`annotations.nim:479-487`), and that const is what the DSL macro sees at
   compile time. Any new key a design must be able to author therefore has to
   go into the const — exactly what this plan does for
   `mpn`/`manufacturer`/`part_use`/`bom.*`, so nothing here is blocked by it.
   Re-investigation confirmed the limitation is real but **incidental to Nim,
   not fundamental** — a `{.compileTime.}`-seeded registry plus a
   `declareAnnotation` macro was built and compiled successfully in ~20 lines
   across two files — and that it costs nothing today: `registerAnnotation`
   has exactly one caller in the whole repo, and it is a test. **Deferred, not
   built in this plan** — worth doing only when a third party actually needs
   to extend `spec:`-authorable keys beyond what verax itself registers, which
   this plan does not need. One independent bug found along the way, worth a
   separate small fix outside this plan: `verify.nim:1488`'s
   `describeAnnotations` header claims to list "the keys a `spec:` block
   accepts" but iterates the *runtime* registry, so `verax annotations`
   currently overstates what is actually spec:-authorable.

4. **`parts/` erases the part's *use*, and closing it costs four lines.**
   `CapUse`/`ResUse`/`IndUse` are the load-bearing input to every decision
   `policy.nim` makes, and `annotate.applyChoice` writes only the
   *consequences* — dielectric, tolerance — discarding the use itself. So a
   BOM compiler reading a finished netlist cannot tell a timing capacitor
   from a bypass one, which is precisely the distinction `parts/CLAUDE.md`
   exists for: a Class 2 dielectric in a filter moves the corner by tens of
   percent. Re-investigation confirmed this is **incidental, not
   principled** — a side effect of `Choice`'s "one field per registered
   annotation" invariant colliding with a registry that never got a key for
   the question `parts/` exists to ask, not a considered erasure. It also
   confirmed the read of `annotations.nim:310-313` ("`Choice` is a
   procurement record and carries none of this") that might motivate
   hesitation is too broad: that comment is about *where RF performance
   figures belong* (the shared vocabulary, not a second parts-only one), and
   its own siblings in the identical `applyChoice` body — `dielectric`,
   `tolerance`, `voltage_rating` — are already registered bare procurement
   metadata, so `part_use` sits on the same side of that line as they do.
   Mechanical cost is verified at effectively zero: no positional
   `Choice(...)` construction anywhere, no comparison/hash/serialization over
   it, exactly four producers in the whole tree, and no test counts
   annotations or compares `attrs` wholesale. **One new risk the fix
   introduces, folded into Stage 1 below:** `part_use` would be the repo's
   *first* `akEnum` builtin, and `setAnnotation`'s string overload
   (`annotations.nim:608-613`) does not check `allowed` at write time — only
   `validateAnnotations` does, at `readiness`. A typo'd `part_use` value
   therefore surfaces later than an `akFloat` typo would.

5. **A `bom:` DSL block's storage cannot live in `bom/`.** `netlist/dsl.nim`
   may not import a module above `netlist/`. The exact precedent is
   `netlist/layouthints.nim`'s `layout.variant`, whose own `CLAUDE.md` entry
   says it: *"`pcb/` depends on `netlist/`, never the reverse, so the binding is
   authored here and resolved there."* The defaults' storage, grammar and
   validation go in `netlist/bomdefaults.nim`; `bom/` only reads them.

Four more that shape the mechanics rather than the vocabulary:

- **Walk leaves, never flatten.** `spice/flatten` is a *simulation-only*
  concession by its own doc comment, and `bom/` must not import `spice/`. Copy
  `pcb/assemble.collectLeaves` (`assemble.nim:162-175`), which yields
  `(component, hierarchical path)` and descends `subNetlist`. Four modules
  already carry their own copy of this six-line walk for the stated reason that
  none may depend on another for it (`assemble.nim:164-169`).
- **A multi-channel package is one BOM line and N components.** Group by
  `attrs["package.ref"]`, as `pcb/assemble.buildPhysicalParts`
  (`assemble.nim:177-192`) does. Skipping this bills a dual op-amp twice.
- **Generated designators are positional and unstable**
  (`graph.generatedDesignators`, `graph.nim:346`; `netlist/CLAUDE.md` spells out
  that inserting a part earlier renumbers everything after it). A lockfile keyed
  on one silently re-resolves the wrong part after an edit.
- **Disk-cache convention:** `getEnv("VERAX_CACHE", getCacheDir() / "verax") /
  "<sub>"` (`spice/xspice/build.nim:94,106`), and caching work is **lazy, never
  at module init** — *"importing a parts library must not build anything"*
  (`designs/lib/i2c_parts.nim:147`).

---

## Dependency placement

`bom/` sits **above `parts/` and below `verify.nim`**, importing `netlist`,
`parts`, `units` and `eng` — and **not** `pcb`, `spice` or `contract`. It takes
a `Netlist`, never a `Design` and never a `Pcb`.

Like `parts/`, it is **not in the verification path**: nothing in `readiness`
requires it, and a design that never asks for a BOM never pays for one.

Network source modules are opt-in per import, the rule `netlist/formats/`,
`pcb/formats/` and `spice/ngspice` already follow. `import verax/bom` registers
no network source, so it needs no credentials and no `-d:ssl`.

Reconciling a resolved BOM against a board-file BOM (`pcb/bom.buildBom`) is
**deliberately out of scope**: it would give `bom/` an edge to `pcb/`, and
`pcb/bom.nim` already answers the board-file question on its own. Recorded
under non-goals.

---

## Stage 0a — `value = <Quantity>` becomes deck-safe (no network) — **shipped**

Closes fact 1. Independent of everything else here — a pure DSL-authoring
improvement, useful whether or not the rest of the BOM compiler ships.

**`src/verax/netlist/dsl.nim`** — `dispatchField` (the proc behind every
head-of-statement `key = value` pair outside `componentKnownFields`) gained a
value-space `when` branch scoped to the `"value"` key only, mirroring
`contract/dsl.nim`'s `subjectOf` dispatch idiom:

```nim
when value is Quantity:
  setRawAnnotation(entityVar, "value", deckSafeValue(float(value)))
else:
  setRawAnnotation(entityVar, "value", $value)
```

**One deviation from the design as originally written, found during
implementation:** the plan called for reusing `netlist/formats/spice.spiceValue`
directly, but that would have made `netlist/dsl.nim` (core) depend on
`netlist/formats/` — exactly the edge `netlist/CLAUDE.md` forbids ("format
modules only depend on the core types/graph API — the core never depends on a
format"). Fixed by adding a new proc **`dsl.deckSafeValue*(x: float): string`**
— `formatFloat(x, ffScientific, 9)`, byte-identical to `spiceValue`, duplicated
as one line rather than imported, with a doc comment stating why. `Quantity`
is resolved via `bindSym("Quantity")` (`import ../units` added to `dsl.nim`
for the macro's own scope), the same hygiene idiom `globalNetsTypeNode` already
uses for `OrderedTable`, so a caller needs no extra import beyond whatever it
already needs to write the unit literal itself.

Tests, both in `tests/test_netlist_dsl.nim`: *"value = \<Quantity\> writes the
identical text spiceValue would"* (`value = 2.2.kohm` on a resistor produces
`nl.components["R1"].attrs["value"] == spiceValue(2200.0)` and the same text
in the rendered deck) and *"value = \<string\> is unaffected by the Quantity
dispatch"* (a model name and a `"DC 5"` source spec are untouched — the `else`
branch). Verified empirically against real ngspice-46 output during design
(`2k2` → 2000, `1N4148` parses as valid RKM) before this landed, per the
open-item discussion this stage closes.

## Stage 0b — stop `instantiate` overloading `partNumber` (no network) — **shipped**

Closes the template-name half of fact 2. Separable from everything else here
and shipped first — it fixes a real latent hazard whether or not the BOM
compiler is built at all.

- **`src/verax/netlist/graph.nim`** — `instantiate` no longer sets a new
  instance's `partNumber` to `defNetlist.name`; the doc comment now states
  what reads the deck's `.SUBCKT` reference instead (`formats/spice.nim`, via
  `subNetlist.name`) and why a design's own `partNumber` on an instance no
  longer collides with anything the writer depends on.
- **`src/verax/netlist/formats/spice.nim`** — `formatInstanceLine` (the `X`
  card) and `collectTemplates` now read `child.name` instead of
  `comp.partNumber`. `writeSubcktBlock` already spelled the matching
  `.SUBCKT`/`.ENDS` block from `templ.name` (the same field, one level up),
  so both halves of the deck now agree by construction instead of by an
  invariant something else had to maintain.
- Verified behaviour-identical: `tests/test_netlist_spice.nim`,
  `tests/test_schematic.nim`, `tests/test_spice_boundary.nim`,
  `tests/test_spice_flatten.nim` all pass unchanged, plus the full
  `nimble test` (90 files) and `nimble verify` (41 designs/templates) sweeps,
  both clean.
- New regression test, `tests/test_netlist_spice.nim`: *"an instance's own
  partNumber never changes which SUBCKT block its X line names"* — builds a
  template and an instance via `graph.instantiate` directly, overrides
  `comp.partNumber` afterward (the `dsl.nim:809-824` hazard this **structurally
  closes**: `instance X1, buckSheet, {...}, partNumber = "LT8640A"` no longer
  has anything to desync, since the deck writer never reads `partNumber` for
  this purpose at all), and asserts the rendered deck still names the real
  block and never the overridden string.

---

## Stage 1 — vocabulary and board defaults (no network) — **shipped**

Shipped 2026-09-30, as designed, with one judgement call the plan explicitly
left open and two small additions beyond the design-as-written:

- **Fact 4's `setAnnotation` gap was closed by extending the setter, not by
  documenting it.** The plan offered both options and asked for whichever was
  smaller and more consistent; extending `setAnnotation`'s string overload to
  check `allowed` for any `akEnum` key (not only `validateAnnotations` at
  `readiness`) was four lines, closes the gap for every future `akEnum`
  builtin rather than only `part_use`, and needed no new vocabulary in
  `parts/CLAUDE.md` to explain away. The design-time trade-off this makes
  deliberately visible: `test_parts_policy.nim`'s `annotation_not_allowed`
  case (the plan's own ask) now has to reach a bad value through
  `setRawAnnotation`/a direct `attrs[...] =` write to exercise
  `validateAnnotations`'s `akEnum` branch at all, since the setter path it
  used to be reachable from no longer accepts one — the same "only a foreign
  writer gets here" shape `layouthints.nim`'s unparseable-value tests already
  use.
- **`handleBom` (`netlist/dsl.nim`) is a dedicated strict handler, not a
  `handleSpec` call**, because `bom.*` is namespaced and owned by
  `netlist/bomdefaults.nim` rather than registered in
  `annotations.builtinAnnotations` — `environment:`'s `t_ambient_min`/
  `t_ambient_max` *are* registered, which is what lets `environment:` ride
  `handleSpec` for free and is exactly why `bom:` cannot. This was implicit in
  the plan's "modelled on `handleEnvironment`/`handleLayout`" phrasing but
  worth stating plainly: there is no separate `handleEnvironment` proc to
  model on (`environment:` is one `handleSpec` call), so `handleLayout` is the
  only real precedent `handleBom` follows.
- **Two additions beyond the plan's own text, both documentation**: a short
  `netlist/CLAUDE.md` bullet for `bomdefaults.nim` (every sibling attrs-based
  module in that submodule has one) and a `test_netlist_annotations.nim` case
  pinning the new `setAnnotation` `akEnum` check directly, beside the
  `test_parts_policy.nim` case the plan asked for — the behaviour change lives
  in `annotations.nim`, not `parts/`, so it gets a test in the module whose
  invariant it actually is, in addition to the parts-side regression the plan
  named.

Everything else landed exactly as specified: `mpn`/`manufacturer`/`part_use`
in `builtinAnnotations` with `mpn`/`manufacturer`/`partUse` accessors;
`Choice.use` (`parts/types.partUseName` spelling `CapUse`/`ResUse`/`IndUse`
without their enum prefix) set by all three `default*` builders and written by
`applyChoice`; `netlist/bomdefaults.nim` modelled on `layouthints.nim`
(namespaced `attrs`, one parse point shared by the reader and the validator,
a `const seq` of known keys); the
`bom:` DSL block and `validateBomDefaults` wired into `verify.readiness`
beside `validateEnvironment`/`validatePackages`. No existing annotation-count
assertion regressed (there were none counting `attrs` wholesale, confirmed by
grep before writing a line of code — the plan's own fact-4 re-investigation
had already found this).

Verified: `nim check` clean on every new/changed module in isolation;
`tests/test_bom_defaults.nim` (new, 13 cases), `tests/test_parts_policy.nim`
and `tests/test_netlist_annotations.nim` (both extended) all pass; full
`nimble test` — 0 `FAILED`/`Error:` across the suite (`test_bom_defaults.nim`
is now one of the files that glob runs); full `nimble verify` — all 41
designs/templates still `exit 0 (clean)`, unchanged from the Stage 0b baseline
(26 designs + 14 templates = 40 files that declare at least one assertion, all
passing, plus `templates/dc_sweep.nim` with zero assertions declared).

**`src/verax/netlist/annotations.nim`** — three new entries in the `const
builtinAnnotations` (it must be the const, per fact 3), all `{asComponent}`:

| key | kind | why |
| --- | --- | --- |
| `mpn` | `akString` | Manufacturer part number, authorable as `spec: mpn = "..."`. Distinct from `Component.partNumber`, which — even after Stage 0b closes the template-name overload — remains split between a real MPN, an internal/house part number, and, confirmed live in ~20 design sites, a free-text descriptive label. `packages`/`pinmux` index registries by `partNumber` too, correctly, since their catalogue entries are genuine identifiers. |
| `manufacturer` | `akString` | Pairs with `mpn` — an MPN is only unique within a manufacturer. |
| `part_use` | `akEnum` | Closes fact 4. `allowed: @["timing","coupling","decoupling","bulk","precision","general","power","filter"]` — the union of `CapUse`/`ResUse`/`IndUse` spelled without the enum prefixes. |

Accessors beside `esr`/`package`/`footprint` (`annotations.nim:637-641`):
`mpn(c)`, `manufacturer(c)`, `partUse(c)`, each returning `AnnValue[string]`,
pure and never defaulting like every other accessor there.

`part_use` is the repo's first `akEnum` builtin. Because `setAnnotation`'s
string overload (`annotations.nim:608-613`) does not check `allowed` at write
time, a typo'd value is currently caught only by `validateAnnotations` at
`readiness`, later than an `akFloat` typo would be. Either extend that
overload to check `allowed` immediately (tightens every future `akEnum` too),
or document the gap explicitly in `parts/CLAUDE.md` and add a dedicated test
exercising `annotation_not_allowed` (`annotations.nim:675-680`) on this key,
since nothing exercises that branch today.

**`src/verax/parts/types.nim`** — add `use*: string` to `Choice`.
Source-compatible (an object whose fields all default), and it makes `Choice`
non-lossy about the question that produced it.

**`src/verax/parts/policy.nim`** — `defaultCapacitor`/`defaultResistor`/
`defaultInductor` each set `result.use` from `r.use`. No call-site changes
anywhere in `designs/lib/`.

**`src/verax/parts/annotate.nim`** — `applyChoice` writes `part_use` when
`ch.use.len > 0`, the same "nothing is written for a zero field" rule every
other field there follows. *Watch for existing tests that count annotations on
a policy-chosen component.*

**`src/verax/netlist/bomdefaults.nim`** (new) — modelled directly on
`netlist/layouthints.nim` and `netlist/environment.nim`: namespaced `bom.*`
attrs at netlist scope, so `graph.clone` carries them through
`instantiate`/`flatten`/`extractSubcircuit`/`isolate` for free and a SPICE
round trip is expected to lose them, exactly as it loses `package.*`.

```nim
type BomDefaults* = object
  tolerance*: Fraction          ## default part tolerance when a part states none
  dielectric*: string           ## default ceramic class for a cap that states none
  series*: string               ## "exact" | "e12" | "e24" | "e96"
  derating*: float              ## voltage derating factor
  resistorPackage*: string      ## default case size, per family
  capacitorPackage*: string
  inductorPackage*: string
  manufacturers*: seq[string]   ## preferred-manufacturer ranking, first wins
```

Keys: `bom.tolerance`, `bom.dielectric`, `bom.series`, `bom.derating`,
`bom.resistor_package`, `bom.capacitor_package`, `bom.inductor_package`,
`bom.manufacturers` (`;`-delimited, the flat-list shape
`switch.select_pins`/`spice.couples` already use). `bomDefaultKeys` is a `const
seq` so a future key has one place to be added on both sides — the parser here
and the DSL dispatcher there — as `layouthints.layoutHintKeys` does.

Exports `bomDefaults(nl): BomDefaults` — **most specific wins, field by
field**: each field is read from `nl` itself, then each parent up to the root,
so a parent's `bom:` block fills only what a child sheet left unstated (revised
2026-10-04; it originally read the root only, like `environmentOf`, which
silently discarded a library sheet's own `bom:` block). There is no tree-wide
override: a parent changes one instance's default through `instance ...,
with = proc(sub: Netlist) = setBom*(sub, ...)`, which writes onto that
instance's clone only — so every setter writes to the netlist it is given,
never the root. The
`set*` runtime writers a file reader would take, one shared parse point per
value so an unrecognised value is reported once rather than divergently, and
`validateBomDefaults(nl): seq[Issue]` reporting only what was *stated* and
cannot work — an unknown series name, a derating below 1.0, a negative
tolerance — and never nagging a design that stated nothing. Kinds prefixed
`bom_default_`.

**`src/verax/netlist/dsl.nim`** — a netlist-scope `bom:` block handler modelled
on `handleEnvironment`/`handleLayout`: strict at the syntax boundary, where an
unknown key can only be a mistake, so it is a compile error naming the valid
keys. Expands to `bomdefaults`' setters.

**`src/verax/verify.nim`** — wire `validateBomDefaults` into `readiness`'
structural issues beside `validateEnvironment`/`validatePackages`.

---

## Stage 2 — collection and classification (no network) — **shipped**

Shipped 2026-10-04. Where it differs from the design below, and why
(`src/verax/bom/CLAUDE.md` is the standing record):

- **Two gaps the plan left open, decided before building.** *Simulation-only
  kinds:* `PartFamily` gains `pfNotAPart`, seeded in `classify.familyOf`'s
  table with `voltage_source`/`current_source`/`vcvs`/`vccs`/`ccvs`/`cccs`/
  `mutual_inductance`/`vswitch`/`iswitch`; those are left off silently, and
  `registerPartFamily` lets a project add its own. Without it, every design's
  stimulus source (39 `voltage_source`s across `designs/`) would have reached
  Stage 3 as an IC with no MPN — `sevError`. *DNP/exclude:* `BomItem` had
  the fields but no netlist component could state either. They are now
  registered `akBool` builtins `dnp` and `bom_exclude` (so `spec: dnp = true`
  is compile-time checked), which needed the registry's first `akBool`
  plumbing: a `bool` `setAnnotation` overload, `annotationBool`, and the
  check in the string setter and `validateAnnotations`.
- **`collect(nl)` takes no `BomDefaults`.** Defaults became per-netlist, most
  specific first, after the plan was written (see Stage 1's `bomDefaults`
  note), so each item reads `bomDefaults` of the netlist its first member
  lives in.
- **`types.nim` holds `PartFamily` and `BomItem` only.** `Candidate`,
  `Resolution`, `BomResult` and `BomLine` move to Stage 3, the first code
  that reads them.
- **`BomItem` additions:** `members`/`components` (every section's path and
  object — `designators` holds the printed designator, so a packaged part is
  `U9`, not `U9A,U9B`); `partNumber` (verbatim, never promoted to `mpn`, for
  Stage 3's guarded fallback); `issues` (each part's own findings, carried
  into its `Resolution` later rather than kept in a side list). Floats a part
  can leave unstated are `NaN` when unstated, not 0.
- **`bom_package_dnp_conflict`** (sevWarning) when only some sections of a
  package are marked `dnp`; the package is treated as DNP whole.
- **A default package is applied only when the part states neither
  `package` nor `footprint`**, and `caseCodeOf` reads a footprint name only
  when the imperial code sits beside its own metric twin (metric 0603 is
  imperial 0201).
- **`value` is parsed only for the four parametric families** — any other
  kind's `value` is a model name, and `1N4148` is lexically valid RKM.

Verified: `tests/test_bom_collect.nim` (new, 16 cases) and the new
`dnp`/`bom_exclude` case in `tests/test_netlist_annotations.nim` pass;
`collect` smoke-run against `designs/ts808_drive.nim` (17 items) and
`designs/xbar_control.nim` (34 items) with no stimulus source collected and
no spurious finding.

*The design as originally planned:*

**`src/verax/bom/types.nim`** (new)

```nim
type
  PartFamily* = enum
    pfResistor, pfCapacitor, pfInductor, pfFerrite, pfOther
      ## Only the first four are parametrically searchable. Everything else
      ## must state an MPN.

  BomItem* = ref object
    designators*: seq[string]   ## hierarchical paths; >1 for a multi-channel package
    generated*: bool            ## a designator was generated -> positional, unstable
    kind*: string
    family*: PartFamily
    value*: float               ## SI base units; NaN when `value` was unparseable
    valueText*: string          ## the raw `value` attr, verbatim
    tolerance*, voltageRating*, powerRating*, currentRating*, isat*: float
    dielectric*, package*, footprint*, caseCode*: string
    use*: string
    mpn*, manufacturer*: string ## as stated on the component
    quantity*: int
    doNotPopulate*, excluded*: bool
    assumptions*: seq[Assumption]  ## every board default that filled a gap

  Availability* = object
    stock*: int
    moq*: int
    lifecycle*: string          ## "active" | "nrnd" | "obsolete" | "" (unknown)

  Candidate* = ref object
    mpn*, manufacturer*, description*, datasheet*: string
    package*, caseCode*: string
    value*, tolerance*, voltageRating*, powerRating*, currentRating*: float
    dielectric*: string
    avail*: Availability
    source*: string             ## which CatalogSource produced it
    attrs*: OrderedTable[string, string]

  Resolution* = ref object
    item*: BomItem
    chosen*: Candidate          ## nil when nothing resolved
    alternates*: seq[Candidate]
    locked*: bool               ## a prior JSON result decided this
    signature*: string          ## the lockfile key; see Stage 3
    issues*: seq[Issue]

  BomResult* = ref object
    resolutions*: seq[Resolution]
    lines*: seq[BomLine]        ## rolled up by chosen MPN
    issues*: seq[Issue]
    attrs*: OrderedTable[string, string]
```

`BomLine` here is `bom/`'s own, netlist-derived. It deliberately does **not**
reuse `pcb/bom.BomLine`, which would pull `pcb/` in; field names match it so a
future reconciliation is a field copy rather than a translation.

`Issue.kind` is an open-ended string by design (`netlist/issue.nim:15-19`), so
every finding below is a new `bom_*` kind with no edit to the shared type.

**`src/verax/bom/classify.nim`** (new) — two policy decisions, named in one
place:

- `familyOf(kind: string): PartFamily` — a runtime table seeded from a `const`
  and extensible with `registerPartFamily`, the shape
  `kinds.builtinDesignatorPrefixes`/`registerDesignatorPrefix` already uses.
  `resistor`→`pfResistor`, `capacitor`→`pfCapacitor`, `inductor`→`pfInductor`,
  `ferrite_bead`→`pfFerrite`, everything else `pfOther`. **`Component.kind` is
  an open string — there is no `ComponentKind` enum anywhere in the repo — so
  this must never be a `case`.**
- `caseCodeOf(footprint, package: string): string` — **the standard-footprint
  gate.** Derives an imperial chip case code from a footprint spec
  (`R_0402_1005Metric` → `0402`, `C_0603_1608Metric` → `0603`, a bare `0805` in
  `package` → `0805`) and returns `""` for anything it cannot place in
  `standardCaseCodes` (`0201 0402 0603 0805 1206 1210 1812 2010 2512`). A `""`
  is what makes the resolver **refuse to search** rather than return a part
  that will not fit the land pattern the board already has — the same named
  refusal `pcb/variant.selectVariant` prefers over a plausible-looking stub.

**`src/verax/bom/collect.nim`** (new) — `collect(nl: Netlist, d: BomDefaults):
seq[BomItem]`:

1. Walk leaves with a local copy of `assemble.collectLeaves`' recursion.
2. Group by `attrs["package.ref"]` so a multi-channel package is one item.
3. Parse `value` with `parseSpiceMagnitude`; a refusal leaves `value = NaN` and
   `valueText` set, and raises `bom_value_unparseable` (sevWarning) rather than
   guessing. RKM lands here on purpose.
4. Read `tolerance`/`voltage_rating`/`power_rating`/`current_rating`/`isat`/
   `dielectric`/`package`/`footprint`/`part_use`/`mpn`/`manufacturer` through
   the pure accessors, and for each absent one fall back to `BomDefaults`,
   recording an `Assumption` (`annotations.assumption`/`note`) — the discipline
   every `spice/models` expander and `pcb/assemble` already follows for an
   invented input, so a default that moved a choice says so.
5. Mark `generated` from `attrs["designator.generated"]`.

---

## Stage 3 — source interface, offline catalogue, resolver

*`source.nim`, `sources/local.nim` and `resolve.nim` shipped 2026-10-06.
`cache.nim` moves to Stage 5 — it caches network answers and there is no
network source yet. Resolver deviations: the MPN path applies to every
family, with `bom_mpn_spec_mismatch`; ranking puts lifecycle first; a
candidate's whole tolerance band must fit the item's; `bom_no_match`,
`bom_excluded`, `bom_no_sources` are new kinds; `bom_low_stock` is per line;
`series`/`derating` are not read. Other deviations from the sketch below,
all recorded in `src/verax/bom/CLAUDE.md`: the source procs are closures, not `nimcall`;
`Candidate` gained `family`; unknown stock/MOQ is `-1`; the catalogue
`value` is a number in SI base units only; the local source is not
registered on import (`registerCatalogFile` instead); the fixture lives at
`tests/fixtures/catalog.json`, not `tests/data/`.*

**`src/verax/bom/source.nim`** (new) — a provider registry copied from
`pcb/footprint.FootprintSource` (`footprint.nim:97-129`): procs on a data
object, first-registered-that-answers wins, registration order is resolution
order, and **no built-in source registered here**.

```nim
type
  PartQuery* = object
    family*: PartFamily
    value*, valueTolerance*: float   ## wanted value, and the acceptable fraction
    caseCode*: string                ## required; "" means do not search
    minVoltage*, minPower*, minCurrent*: float
    dielectric*: string
    maxTolerance*: float
    manufacturers*: seq[string]
    limit*: int

  CatalogSource* = object
    name*: string
    search*: proc (q: PartQuery): seq[Candidate] {.nimcall.}
      ## nil => this source cannot answer a parametric query
    lookup*: proc (mpn, manufacturer: string): Candidate {.nimcall.}
      ## nil result => "I don't know this part", never an exception
```

`registerCatalogSource`, `catalogSources()`, `searchAll(q)`, `lookupAll(mpn,
mfr)`. `searchAll` unions candidates across sources and de-duplicates on
`(manufacturer, mpn)`, keeping the first source's record and folding a later
source's stock into it when the two agree.

**`src/verax/bom/cache.nim`** (new) — a disk cache under
`getEnv("VERAX_CACHE", getCacheDir() / "verax") / "bom"`, keyed on a hash of
`(source name, request shape)`, with a TTL (default 24 h,
`$VERAX_BOM_CACHE_TTL` in seconds, `0` disabling). Created lazily on first use,
never at module init. This is what makes a repeat `verax bom` offline and a
`nimble verify` sweep affordable.

**`src/verax/bom/sources/local.nim`** (new) — reads a JSON catalogue file
(`--bom-catalog=`, or `$VERAX_BOM_CATALOG`) into `Candidate`s and registers
itself as a `CatalogSource` on import. This is the **hermetic** source: every
resolver test runs against a fixture through it, with no network and no
credentials, and it is also how a project pins a house preferred-parts list —
the "preferred-parts database" `parts/CLAUDE.md` and `series.nim:50-55` both
point at.

**`src/verax/bom/resolve.nim`** (new) — `resolve(items, defaults, opts):
BomResult`. Per item:

- **`pfOther` → the MPN path.** **`mpn` is authoritative when stated.
  `partNumber` is *never* silently treated as the MPN** — fact 2's
  re-investigation found ~20 live design sites where `partNumber` is a
  free-text descriptive label, not a part number of any kind, and a silent
  fallback would present each as a confident, wrong, `sevError`-passing MPN.
  When `mpn` is unstated but `partNumber` is, the resolver **may try
  `partNumber` as a candidate MPN, but only visibly**: attempt
  `lookupAll(partNumber, manufacturer)` and, if a source actually recognises
  it, accept it but raise `bom_partnumber_used_as_mpn` (sevInfo, naming the
  designator and the string) so a reviewer notices a fallback happened; if no
  source recognises it, treat this exactly as "no MPN stated" rather than
  accepting an unverified guess. With an MPN stated (or accepted via the
  fallback above), `lookupAll` verifies it exists; no source knowing it is
  `bom_part_not_found` (**sevWarning, not error** — a distributor simply may
  not carry a part, and a confident claim of non-existence is worse than an
  unverified part), and a source reporting `obsolete`/`nrnd` is
  `bom_part_obsolete`/`bom_part_nrnd` (sevWarning). With no MPN resolved at
  all: `bom_mpn_required`, **`sevError` when the part reaches assembly and
  `sevInfo` when `doNotPopulate` or `excluded`** — decision 4.
- **Parametric families → build a `PartQuery`.** Each query field comes from
  the part's own annotation first (`tolerance`, `dielectric`, `package`, …)
  and only then from `bomDefaults(<the part's netlist>)`. **A `bom:` default
  never overrides a part's own `spec:`**, at any level — a stated spec is a
  requirement, a default is what to buy when nothing was stated. A
  higher-level netlist changes a sheet's component spec only by naming that
  component on that instance (`with = proc(sub: Netlist) =
  setAnnotation(findComponent(sub, "C1"), ...)`). If `caseCode == ""`,
  `bom_nonstandard_footprint` (sevWarning) and **do not search**; the part needs
  an MPN. If `value` is `NaN`, do not search either.
- **Lockfile priority first.** `signature` is a canonical string over
  `(family, value, tolerance, caseCode, dielectric, ratings)` — deliberately
  **not** the designator, because a generated designator renumbers when a part
  is inserted earlier and a designator-keyed lock then silently re-resolves the
  wrong item. Identical requirements deserve the identical part, so a signature
  matching several items locking them all is correct, not a collision.
  Designators are recorded for human readability only. A prior entry whose MPN
  is still available wins and sets `locked = true`; one whose MPN is gone
  reports `bom_lock_stale` (sevInfo) and falls through to ranking.
- **Rank.** Reject anything outside tolerance or under a stated rating, then
  order by preferred manufacturer (`BomDefaults.manufacturers`), then
  exact-value over merely in-tolerance, then stock descending, then **MPN
  ascending as a final tiebreak so a re-run is byte-identical** — the same
  determinism `pcb/assemble`'s designator-sorted grid buys.
- **Availability, both `sevInfo`**, because both are decision-affecting facts
  that silence would hide:
  - `bom_uncommon_part` — fewer than `minCandidates` (default 3) distinct
    orderable parts matched. The message names the count and the query, e.g.
    *"only 1 orderable part matches 22.5 nF C0G 0402 50 V — this is an uncommon
    value"*.
  - `bom_low_stock` — the best candidate's stock is below `quantity ×
    stockFactor` (default 10).
- **Roll up** by `(manufacturer, mpn)` into `BomLine`s, DNP never merging with
  populated, mirroring `pcb/bom.defaultKey`'s rule (`pcb/bom.nim:94-104`).

---

## Stage 4 — report, lockfile, CLI

*Shipped 2026-10-06. Deviations from the sketch below, all recorded in
`src/verax/bom/CLAUDE.md`: `renderJson` writes `parts[]` (one entry per item,
excluded included) and `lines[]` naming parts by index, so nothing is
serialized twice; `parseLock` (text) sits beside `loadLock` (file), and a lock
tying one signature to two parts is refused; only searched parts are locked,
since a part bought by MPN is already named by the design. `--bom` (or any
`--bom-*` flag) selects BOM mode, and an unknown `--bom-*` flag is an error
rather than left for the design; `--bom-catalog=` is repeatable, defaulting to
`$VERAX_BOM_CATALOG`; output goes to `--bom-out=` (the CLI's `-o`) or stdout,
with findings on stderr when the document on stdout is CSV or JSON.
**`--bom-offline` is not added** — there is no network source to withhold
until Stage 5, so it would be a flag that does nothing. `cmdEnv`'s credential
lines likewise wait for Stage 5; it prints `$VERAX_BOM_CATALOG` instead. A bad
flag value anywhere in `parseVerifyArgs` (`--format=xml` too) is now a usage
error (`exitCompile`), where it used to escape as an unhandled exception
exiting 1. A line's value prints through `eng` for a parsed passive.
**Acceptance not met by the datalogger as it stands**: of its 53 parts only
the 100 nF and 10 nF capacitors resolve against the fixture — most of its
resistors state no package (`bom_nonstandard_footprint`), its ICs state
`partNumber` but no `mpn`, and the fixture holds few of its values. That is
the design's footprint stage and catalogue coverage, not the compiler.*

**`src/verax/bom/report.nim`** (new) — three renderers, the
`verify.render`/`renderJson`/`renderJunit` split:

- `render(r): string` — text. Lines first, then issues grouped by severity,
  then a summary. Every number through `eng()` (`eng.nim:42`), never a raw
  float.
- `renderCsv(r): string` — quantity, designators, value, footprint,
  manufacturer, MPN, description, datasheet, DNP. Procurement-ready.
- `renderJson(r): string` — `schema: "verax.bom/1"`, hand-assembled with
  `newJObject`/`newJArray` and no `%*` macro, matching `verify.renderJson` and
  `schematic/json.nim`'s own style for a public document. **Every float goes
  through one `jnum` helper so `NaN`/`Inf` become JSON `null`** — copied from
  `verify.nim:818-819`, because a bare `nan` is not valid JSON and corrupts
  every `jq` call downstream. Each entry carries `signature`, `designators`,
  `mpn`, `manufacturer`, `locked`, `alternates` and the issues raised.

  **This is both the machine-readable report and the lockfile.**
  `loadLock(path): Table[string, LockEntry]` reads it back keyed on
  `signature`. A missing or unparseable `--bom-lock` file is a **usage error**,
  never a silently skipped preference — the rule `verify.loadBaseline` already
  sets for `--baseline`.

**`src/verax/bom.nim`** (new) — the hub, mirroring `src/verax/parts.nim`:
re-exports `types`, `classify`, `collect`, `source`, `resolve`, `report`.
Registers **no** source.

**`src/verax/verify.nim`** — `VerifyOptions` gains `bomOut`, `bomFormat`,
`bomLock`, `bomCatalog`, `bomOffline`, `bomMinCandidates`; `parseVerifyArgs`
parses `--bom-out=`/`--bom-format=`/`--bom-lock=`/`--bom-catalog=`/
`--bom-offline`/`--bom-min-candidates=` in the same `startsWith` style and
`absolutePath()`s every path, because the design binary inherits the caller's
cwd rather than the shell's. `verifyMain` gains one branch **before**
`readiness`, structurally identical to the existing `--layout-out` branch
(`verify.nim:1537-1553`): collect → resolve → render → print issues → fold to
the worst severity → `sevError` ? `exitStructural` : `exitClean`. Compile a BOM
and stop; run no analysis.

**`src/verax/cli.nim`** — `of "bom":` in the dispatch `case`, parsing
`-o/--out` and the `--bom-*` flags and then calling `cmdCheck(file, pathFlag,
forward)` with them forwarded. **This is `cmdLayout`'s shape
(`cli.nim:152-165`) and adds no second compile path** — a `Design` exists only
inside the compiled design binary, and a second entry point would need its own
`locateLib` chain. Extend the `usage` const's command and flag lists.

`cmdEnv` gains credential-*presence* lines (`digikey    configured
($DIGIKEY_CLIENT_ID)` / `not configured`) — **never a secret's value**,
matching how it prints resolved paths and versions only.

---

## Stage 5 — network sources

**`src/verax/bom/sources/mouser.nim`** (new, and first — a plain API key is the
simplest way to prove the pipeline end to end). `$MOUSER_API_KEY`; POST JSON to
the keyword and parametric search endpoints; maps availability, lifecycle and
the manufacturer/MPN pair into `Candidate`.

**`src/verax/bom/sources/digikey.nim`** (new). `$DIGIKEY_CLIENT_ID` /
`$DIGIKEY_CLIENT_SECRET`, OAuth2 `client_credentials` for a bearer token
(cached with its expiry through `bom/cache`), `$DIGIKEY_BASE` selecting sandbox
versus production.

Both:

- `import std/httpclient` inside `when defined(ssl):`, with an `else:` branch
  that **raises a named refusal naming the flag** — the shape
  `spice/xspice/build.nim:105-110` uses for a missing toolchain: name the
  variable, name the directory, say why a partial substitute will not do. An
  obscure "SSL support is not available" from deep inside `std/net` is the
  failure this prevents.
- Register themselves on import only; `import verax/bom` pulls in neither.
- Route every request through `bom/cache`, and honour `bomOffline` by serving
  cache only.
- Never log a token or a secret.

**`examples/bom_live.nim`** and **`task bomcheck`** in `verax.nimble` — the
external-toolchain acceptance-gate pattern `kicadcheck`/`generate`/`roundtrip`
already establish: a `-d:release` driver run outside `nimble test`, here also
with `-d:ssl`. It resolves one real design against the live APIs and skips with
a message when no credentials are set.

**Octopart/Nexar is deliberately not built here.** It is the same
`CatalogSource` interface over a GraphQL endpoint, and having the interface is
what makes it a later addition rather than a redesign.

---

## Stage 6 — docs and findings

- **`src/verax/bom/CLAUDE.md`** (new) — the submodule's decisions in the house
  prose style, each naming the silent failure it prevents. It must carry: why
  `bom/` sits above `parts/` and below `verify.nim` and imports no
  `pcb`/`spice`/`contract`; why the *use* had to be recorded (fact 4) and what
  a wrong dielectric costs; why `caseCodeOf == ""` refuses to search rather than
  returning a plausible part that will not fit; why the lockfile is keyed on a
  query signature and not a designator; why `bom_part_not_found` is a warning
  and `bom_mpn_required` an error; why the defaults' storage lives in
  `netlist/bomdefaults.nim` (the `layout.variant` precedent); why `partNumber`
  is never silently treated as `mpn` (fact 2); and the non-goals below.
- **`src/verax/CLAUDE.md`** — add `bom` to the first-paragraph submodule list
  and to the `CLAUDE.md` enumeration.
- **Root `CLAUDE.md`** — a `src/verax/bom/` row in the submodule table, a
  `verax bom` line under Commands, and `bom/CLAUDE.md` under "Where the detail
  lives".
- **`docs/architecture.md`** — four edits: the dependency-spine diagram
  (~:44-67); the "what each submodule owns, and what it is not allowed to know"
  table (~:98-113); a prose callout beside the existing *"`parts/` is used by
  design libraries, not by the pipeline"* (~:141-154) saying the same of `bom/`;
  and **§8 Deliberate non-goals** (~:994-1032) for the list below.
- **`docs/findings.md` / `docs/RESOLVED_FINDINGS.md`** — finding #17 (§56) is
  half closed: `verax bom <design>` now exists. Move that half across with what
  it was and what the fix was, and leave `verax netlist <design>` open. Also
  close finding #8's complaint that *"`tolerance` is written by the part policy
  and read by nothing"* — the resolver is now a real consumer, though the
  corner run §8 asks for is still open.

### Non-goals, stated so nobody re-litigates them

- **No pricing, price breaks, or quantity-break optimisation.** A price is a
  moving target with a contract behind it; a BOM that quotes one is stale the
  day it is written.
- **No quote or cart generation.** Resolving a part is not ordering it.
- **No alternates or second-source approval workflow.** `Resolution.alternates`
  records what else matched; which of them an organisation *approves* is not a
  fact about the circuit.
- **No reconciliation against a board-file BOM.** That is `pcb/bom.nim`'s
  question, and answering it here would give `bom/` an edge to `pcb/`.
- **No automatic value substitution to an E-series part.**
  `parts/series.exactSeries` rounds nothing by default, and the caller's stated
  obligation (`series.nim:15-19`) is to recompute what the circuit does from the
  values it will actually have. A BOM compiler silently moving 240 R to 243 R —
  240 R is an E24 value and not an E96 one — takes a divider's ratio with it.
  The resolver reports that no part matches; it does not move the target.

---

## Tests

All hermetic. The whole resolver is exercised through `bom/sources/local.nim`
against a JSON fixture, so `nimble test` needs no network and no credentials.
`std/unittest`, bare top-level `test` blocks with full-sentence names stating
the invariant, picked up automatically by the `test` task's
`listFiles("tests")` glob.

- **`tests/test_bom_defaults.nim`** — a `bom:` block round-trips through
  `bomDefaults`; defaults survive `clone`/`instantiate`; a child's stated field
  beats its parent's while unstated fields inherit, across several levels; a
  `with =` proc overrides one instance's default (and one component's spec)
  without touching a sibling instance or the template; `validateBomDefaults`
  reports a bad series name (by instance path, anywhere in the tree) and
  a derating below 1.0 and says nothing about a netlist that stated nothing; an
  unknown key in the block is a compile error.
- **`tests/test_bom_collect.nim`** — `value = "10k"` becomes 10000.0;
  **`value = "2k2"` is refused and reported, read as neither 2200 nor 2000**; a
  dual op-amp's two sections collapse to one item of quantity 1; a leaf two
  instance levels down gets the `X1.X2.R1` path; an absent tolerance takes the
  board default *and* records an `Assumption`; `caseCodeOf` maps
  `R_0402_1005Metric` → `0402` and returns `""` for a DFN/QFN footprint.
- **`tests/test_bom_resolve.nim`** — a resistor resolves to the fixture's best
  candidate; a part outside tolerance is rejected; a `""` case code refuses to
  search and raises `bom_nonstandard_footprint`; an IC with no MPN is `sevError`
  and the same IC marked DNP is `sevInfo`; a value matching one fixture part
  raises `bom_uncommon_part`; ranking is byte-identical across two runs with the
  fixture order shuffled; preferred manufacturers reorder the result.
- **`tests/test_bom_lock.nim`** — `renderJson` output parses, carries
  `schema: "verax.bom/1"`, and renders a `NaN` field as JSON `null` not `nan`;
  feeding that JSON back as a lock pins the same MPN even when a better-stocked
  candidate appears; a lock whose MPN is gone reports `bom_lock_stale` and
  re-resolves; **inserting a part earlier, renumbering generated designators,
  invalidates no lock** — the property the signature key exists for; a missing
  lock file is a usage error.
- **`tests/test_bom_report.nim`** — CSV has one header row and one row per
  line, with quantities summing to the part count; text output names every
  issue.
- **`tests/test_bom_sources.nim`** — the registry: registration order is
  resolution order, a `nil` `search` member is skipped rather than crashing,
  `searchAll` de-duplicates on `(manufacturer, mpn)`. Then the network half
  behind the house skip pattern (`test_spice_ngspice.nim:8,71`):

  ```nim
  let haveMouser = getEnv("MOUSER_API_KEY").len > 0
  if not haveMouser:
    echo "SKIP: MOUSER_API_KEY not set, skipping live catalogue tests"
  else:
    ...
  ```

- **`tests/test_parts_policy.nim`** (existing, if present) — extend for
  `Choice.use` and the new `part_use` annotation, and confirm no existing
  annotation-counting assertion regressed; add a case exercising
  `annotation_not_allowed` on a bad `part_use` value, since `part_use` is the
  repo's first `akEnum` builtin and nothing exercises that validation branch
  today.
- **`tests/test_netlist_dsl.nim`** (existing) — **done, Stage 0a**: `value =
  2.2.kohm` on a resistor produces the same deck line as
  `spiceValue(float(2200.0))`; `value = "1N4148"` and `value = "DC 5"` are
  unchanged (regression guard on the untyped branch).
- **`tests/test_netlist_spice.nim`** (existing) — **done, Stage 0b**: an
  `instance ..., partNumber = "..."` override no longer changes the emitted
  `X` card's target name; every existing deck-text assertion this touches
  still passes unchanged.
- **`tests/test_bom_resolve.nim`** — add: `partNumber` alone (no `mpn`
  stated) is never silently accepted as an MPN; when a source recognises it
  as one, `bom_partnumber_used_as_mpn` is raised alongside the resolution;
  when no source recognises it, it is treated as "no MPN stated" (the
  `sevError`/`sevInfo`-by-DNP rule), not as an accepted guess.

---

## Verification

```bash
# Stage 0a/0b regression guards -- already run, both clean (2026-09-29):
# nimble test: 90/90 files, 0 FAILED/Error:. nimble verify: 41/41
# designs+templates, exit 0, no non-clean exits.
nim c -r --path:./src tests/test_netlist_dsl.nim
nim c -r --path:./src tests/test_netlist_spice.nim
nimble verify 2>&1 | tail -40   # every design still compiles and checks unchanged

# Type-check each new module in isolation first -- the cheapest failure.
nim check --path:./src src/verax/netlist/bomdefaults.nim
nim check --path:./src src/verax/bom.nim
nim check --path:./src src/verax/bom/sources/local.nim
nim c -d:ssl --hints:off --path:./src src/verax/bom/sources/digikey.nim  # the -d:ssl path
nim check --path:./src src/verax/bom/sources/digikey.nim                 # must refuse by name, not crash

# Single files while iterating.
nim c -r --path:./src tests/test_bom_collect.nim
nim c -r --path:./src tests/test_bom_resolve.nim
nim c -r --path:./src tests/test_bom_lock.nim

# Full suite -- READ THE OUTPUT; the exit code is meaningless here.
nimble test 2>&1 | grep -cE "FAILED|Error:"      # must print 0

# Every design and template still checks: the DSL and annotation edits touch all of them.
nimble verify 2>&1 | tail -40

# End to end, offline, against a fixture catalogue.
nimble build
./bin/verax bom designs/datalogger/datalogger.nim --bom-catalog=tests/fixtures/catalog.json
./bin/verax bom designs/datalogger/datalogger.nim --bom-catalog=tests/fixtures/catalog.json \
    --bom-format=json -o /tmp/bom.json
jq . /tmp/bom.json >/dev/null    # proves nothing else wrote to stdout, and no bare `nan`
./bin/verax bom designs/datalogger/datalogger.nim --bom-catalog=tests/fixtures/catalog.json \
    --bom-lock=/tmp/bom.json     # every line should now report `locked`
./bin/verax bom designs/datalogger/datalogger.nim --bom-format=csv -o /tmp/bom.csv

# The CLI surfaces are discoverable, and the credential lines print presence only.
./bin/verax | grep bom
./bin/verax env

# Live, only with credentials set.
MOUSER_API_KEY=... nimble bomcheck
```

**Acceptance.** `designs/datalogger/datalogger.nim` — 17/17 assertions, clean
`nimble verify` — compiles a BOM in which every resistor, capacitor and ferrite
bead resolves to an MPN from the fixture catalogue, every IC without a stated
MPN is reported `sevError` by name, and a second run against the emitted JSON
reproduces the identical selection.
