# Multi-channel components

## Context

A dual op-amp is one chip, one footprint, one BoM line, one silkscreen designator — and
in `nimcir` today it is N unrelated `Component`s that happen to share a `partNumber`.
`designs/aa_filter.nim:105,130` writes `U1A` and `U1B` as two independent components,
each restating `V+`/`V-`, with nothing in the model saying they are the same die.
`designs/riaa_preamp.nim:89-90` is the harder and more interesting case: its two channels
are two `instance`s of one `subckt` (`designs/lib/riaa.nim:101`), so `XL.U1` and `XR.U1`
are separate objects in separate child netlists — *different sheets* — and a stereo board
built from a dual op-amp cannot currently say so at all.

Nothing in `src/nimcir/netlist/` has a package, section, gang or channel concept. The
registered `package` annotation (`netlist/annotations.nim:170`) means **case size for
parasitic lookup** (`"0402"`, `"film"`), not physical package identity.

The outcome: a design can declare a physical package with numbered pins and named
sections, assign its sections to components that live on different sheets, have the
tool check that the shared pins really are shared, and get one placement and one BoM
line for the part that actually gets soldered.

**Simulation does not change and no measured number moves.** `spice/models/opamp.nim:44`
`idealOpAmp` documents that it does not connect to supply rails at all, so packaging two
amplifiers together alters no deck. This is a physical/structural feature, and §Verification
says how that is proved rather than asserted.

---

## Decisions already made

| | Choice |
|---|---|
| Package definition | **Full physical pinout** — sections, per-section logical pins, global pins, and package pin numbers |
| Assignment | **Per-instance `with =` proc**, reusing the existing `instance` hook |
| Board join | **One `Placement` per package** — `bindComponent`'s designator-equality invariant gains a second branch |
| Checks | **Over-/mis-assignment** and **global-pin net agreement**. Unused-section tie-off and footprint-pin-count are out |

---

## The model

New module **`src/nimcir/netlist/packages.nim`**, a sibling of `environment.nim` in every
respect: it stores its data in namespaced `attrs` rather than in `types.nim`, so membership
survives `clone`/`instantiate`/`flatten`/`extractSubcircuit`/`isolate` for free — the same
argument `netlist/CLAUDE.md` makes for `environment.nim` and `contract/design.nim` makes
for `role.*` tags. **Nothing is added to `netlist/types.nim`.**

### Definitions — a runtime registry of plain data

```nim
type
  PackageSection* = object
    name*: string            ## "A", "B"
    pins*: seq[string]       ## logical pin names on this section

  PackagePin* = object
    section*: string         ## "" for a global pin
    logical*: string         ## "OUT", "V+"

  PackageDef* = ref object
    name*: string                              ## registry key, "NE5532"
    partNumber*, footprint*, doc*: string
    sections*: seq[PackageSection]
    globalPins*: seq[string]                   ## "V+", "V-", "EN"
    pins*: OrderedTable[string, PackagePin]    ## package pin id -> what it is
    attrs*: OrderedTable[string, string]
```

Pin ids are **strings, not ints** — BGA pads are `"A1"`, and both KiCad and ODB++ carry pad
names as text.

`PackageSection.pins` is per-section so a heterogeneous package (dual comparator plus a
reference) stays expressible; `newPackageDef` fills the homogeneous case, which is what a
multi-channel part usually is. A definition holds **no procs**, unlike `RoleDef` — a package
computes nothing — so it could later be read from a file.

Registry, mirroring `roles/core.nim` and `kinds.registerDesignatorPrefix`:

```nim
proc registerPackage*(def: PackageDef)      ## raises on duplicate name; validates the def
proc packageDef*(name: string): PackageDef  ## raises naming knownPackages()
proc knownPackages*(): seq[string]
proc newPackageDef*(name: string, sections, pins: openArray[string],
                    global: openArray[string] = [], partNumber = "",
                    footprint = "", doc = ""): PackageDef
```

`registerPackage` validates the definition itself and **raises**: every section pin and
every global pin must appear in `pins` exactly once, and every entry in `pins` must name a
section the def declares (or be global). Typing a pinout is the point of the full-pinout
choice, and a datasheet transcription error is what this catches.

**No built-ins are registered.** There is no generic multi-channel package the way there is
a generic `power_rail` role; every one is a specific part number. This library owns the
mechanism, `designs/lib/` owns the catalogue — the line `parts/policy.nim` already draws.

### Membership — three dotted keys on the member component

`const packagePrefix* = "package."`, so these are never seen by `validateAnnotations`
("bare means registered, dotted means owned").

| key | meaning |
|---|---|
| `package.ref` | the physical package's board designator, e.g. `"U10"` |
| `package.section` | which section this component is, e.g. `"A"` |
| `package.def` | the `PackageDef` name it was assigned under, e.g. `"NE5532"` |

`package.def` is redundant with the group and is stored anyway, for the reason
`annotations` stores provenance per key: an `isolate`d fragment retains one member and must
still be able to say what part it is.

There is **no side-car store and no attachment step.** The netlist-side truth is entirely
these attrs; `validatePackages` reconstructs each group by walking `nl` and its `children`
recursively and grouping on `package.ref`. That is what makes cross-sheet packaging work
without a design-global registry that `pcb` (which may not import `contract`) could not read.

Accessors — pure, never defaulting, following `annotations.nim`'s discipline:

```nim
proc packageRef*(c: Component): AnnValue[string]
proc packageSection*(c: Component): AnnValue[string]
proc packageDefName*(c: Component): AnnValue[string]
proc isPackaged*(c: Component): bool
proc displayDesignator*(c: Component): string    ## "U10A", else c.designator
proc packageMembers*(nl: Netlist, pkgRef: string): seq[Component]
proc packages*(nl: Netlist): OrderedTable[string, seq[Component]]
```

`assignSection` is the **only** writer of `package.*` — the same rule `graph.nim` has for
back-references.

### The `package` key adjacency

`package = "0402"` (case size) and `package.ref = "U10"` will sit side by side in one
`attrs` bag meaning different things. Accept it and document it loudly; renaming the
registered key to `case_size` with `package` in its `AnnDef.aliases` is the tidier end state
but touches ~15 design files and `spice/models/capacitor.nim`'s defaults table, and is
better as a separate mechanical change if the adjacency proves confusing.

---

## Authoring

A package instance is a small value created **before** the design block, so an unregistered
definition raises at the `let` rather than somewhere inside a macro expansion:

```nim
let u10 = packageInstance("NE5532", "U10")   # raises if NE5532 is not registered
```

**Instances on different sheets** — the target case, `designs/riaa_preamp.nim`:

```nim
  instance XL, riaaChannel(), [inL, outL, vp, vn, gnd], with = u10.section("A", "U1")
  instance XR, riaaChannel(), [inR, outR, vp, vn, gnd], with = u10.section("B", "U1")
```

`u10.section(name, localDesignator)` returns a `proc (nl: Netlist)` closure. `handleInstance`
(`netlist/dsl.nim:430,457-460`) already accepts an arbitrary expression for `with =` and
calls it with `instVar.subNetlist`, so **no DSL macro change is needed** — the closure
receives the instance's own clone and the only name it uses is the module's own local
designator, which is exactly what `with =` is documented for (`netlist/dsl.nim:441-456`).

**Flat components on one sheet** — `designs/aa_filter.nim`, no instance to hang a hook on.
Assign after the block, the shape `spice/boundary.driveConnector` already established:

```nim
u1.assign(d.netlist, "A", "U1A")
u1.assign(d.netlist, "B", "U1B")
```

with a `Component` overload for a caller that has the object in hand.

Both paths funnel into `assignSection(nl, inst, sectionName, comp)`, which **raises
immediately** on what it can see: a section name the definition does not declare (naming the
ones it does), a duplicate section letter within one `package.ref`, over-assignment beyond
the definition's section count, and a component already assigned to a different package.
Raising at the statement is the `addRole` precedent.

### Global pins stay on their sections

`designs/lib/riaa.nim:105-106` and `aa_filter.nim` both already write `V+`/`V-` on each
amplifier, and **that must not change**: `spice/models/opamp.nim:18` `supplyRailsOf` reads
the rails off *the component's own* supply pins and `opampModel` uses them for the
saturation clamp. Move them onto a package carrier and the clamp is silently dropped and a
large-signal measurement changes.

So `PackageDef.globalPins` buys a **check, not a restructuring**, and a package-level pin
that only one section wires (an `EN`) is authored on that section — `globalPins` is what
says it belongs to the package rather than to that section. No carrier `Component` is
created, so nothing new can reach a deck as a stray `U10` line (which ngspice reads as a
uniformly-distributed RC line).

---

## Validation

`validatePackages(nl): seq[Issue]` in `packages.nim`, reported from `verify.readiness`
alongside `validateAnnotations`/`validateEnvironment` (`src/nimcir/verify.nim:245-247`),
landing in the report's `STRUCTURE` section and grading `exitCode` through the existing
`sevError` / `strict && sevWarning` rule (`verify.nim:325-328`).

An `Issue`, not a raise, for anything a netlist can legitimately be *in* — `netlist/issue.nim`
states that rule. Not a `contract` role: none of these is a measurement, there is no quantity
and no evaluator, and routing it through `contract` would put the answer somewhere `pcb`
cannot read it.

| finding | severity |
|---|---|
| `package.def` names no registered definition | error |
| members of one `package.ref` disagree on `package.def` | error |
| section name not declared by the definition | error |
| duplicate section letter within one package | error |
| more sections assigned than the definition declares | error |
| a section carries a pin the definition declares neither as a section pin nor as global | error |
| **a global pin resolves to different nets across sections** | error |
| a declared section pin the component does not have | warning |
| a member's `partNumber` disagrees with the definition's | warning |

**The global-pin check is the subtle one and needs its own test.** In `riaa_preamp`,
`XL.U1`'s `V+` and `XR.U1`'s `V+` are *different `Net` objects* — clones of the template's
`VP` — joined only through each instance's pin to the parent's `vp`. Comparison must
therefore resolve each pin upward through `Pin.hierNet` to the outermost net and compare by
**object identity**, never by name: both clones are named `VP`, so a name comparison would
pass a genuinely miswired board, which is the exact defect this check exists to catch.

A missing section pin is a *warning* and the message says **unconnected**, not *missing*:
pins are created on demand at `graph.connect`, so a section whose `IN-` is simply unwired
has no `Pin` object at all.

---

## Board and BoM

`pcb/graph.bindComponent` (`src/nimcir/pcb/graph.nim:230`) raises unless
`Placement.designator == Component.designator`. That invariant gains a second branch; it is
the one existing rule that genuinely has to move.

1. **`src/nimcir/pcb/types.nim:219`** — one additive field on `Placement`:
   ```nim
   sections*: OrderedTable[string, Component]
     ## Section name -> the netlist component that is that section, for a
     ## multi-channel package. Empty for the 1:1 case, where `component` is
     ## the whole part.
   ```

2. **`bindComponent`** — keep designator equality as the first branch, unchanged. Add:
   when `packageRef(c).value == p.designator`, record `p.sections[packageSection(c).value] = c`
   and **leave `p.component` nil**. Nil is deliberate — `Placement.component` means "the
   netlist component this placement *is*", and for a dual op-amp there is no such component;
   setting it to whichever section bound first is the drift hazard `addSimModel`'s doc
   refuses. Grow the mismatch message to name `package.ref` as the other way a placement and
   a component may agree.

3. **`pcb/graph.addLand` (`graph.nim:247`)** — this is where the full pinout pays off. Today
   it keys `Placement.lands` by pin name and binds `c.pin` from `p.component.pins[pinName]`.
   For a sectioned placement, look the pad id up in the definition's `pins` map, get
   `(section, logical)`, and bind from `p.sections[section].pins[logical]`. That makes pad
   `"7"` on an NE5532 resolve to section B's `OUT` — the join no board reader can make on its
   own. A pad id the definition does not declare leaves `c.pin` nil rather than guessing.

4. **`pcb/bom.nim`** — `valueOf`/`partNumberOf`/`defaultKey` (`bom.nim:51-83`) fall back to
   `p.component`, now nil for a package. Add a `p.sections` fallback reading the shared
   `packageDefName` and its `PackageDef.partNumber`/`footprint`. **`buildBom` (`bom.nim:85`)
   needs no change**: one placement was always one `BomLine`, so N components collapsing to
   one placement collapses to one line with the right quantity, for free.

---

## Schematic

Small. `SchematicPart` (`src/nimcir/schematic/scene.nim:25`) gains `label*: string`, set at
its single construction site in `schematic/routing.nim` to `displayDesignator(c)` — `"U10A"`
for a packaged part, `""` otherwise. `schematic/finish.nim` and `schematic/svg.nim` draw
`label` when non-empty, else `designator`; `schematic/json.nim` carries it so
`render.writeScenePair` scenes still round-trip.

**Do not overwrite `SchematicPart.designator`.** It is a join key — `finish.nim` builds
`partIdxByDesig` from `c.designator` and looks it up by `p.component.designator`, so changing
the rendered string in place silently breaks net-label anchoring on every packaged part.

A composite is **not** the mechanism and never will be: `docs/composites.md` requires
recognizers to key on `Pin.kind` topology, and `isTraversable` requires exactly two connected
pins with `subNetlist == nil` — an op-amp qualifies for neither, and the sections are on
different sheets anyway so there is nothing to draw adjacently. Record that in
`schematic/CLAUDE.md` so it is not re-derived.

---

## Steps

Each lands independently.

1. **The model.** New `src/nimcir/netlist/packages.nim`: types, registry, accessors,
   `assignSection`, `packageInstance`/`section`/`assign`, `packages`/`packageMembers`,
   `validatePackages`. New `tests/test_netlist_packages.nim` covering every row of the
   validation table, the `registerPackage` definition checks, and — the important one — the
   `hierNet` identity comparison across two `instantiate` clones. At the end of this step the
   feature is usable directly from Nim.
2. **Report it.** One block in `verify.readiness` beside `validateEnvironment`
   (`verify.nim:245-247`). Cases in `tests/test_verify_readiness.nim` for the issue reaching
   `STRUCTURE` and for `exitCode` grading.
3. **Authoring ergonomics.** Confirm `with = u10.section("A", "U1")` composes with the
   existing `handleInstance` with no macro change (it should — `with =` takes an arbitrary
   expression); add the `assign` overloads for the flat case. Cases in
   `tests/test_netlist_dsl.nim` for both paths and for assignment across an instance boundary.
4. **A real definition and the target design.** An `NE5532` def in `designs/lib/` (a new
   `designs/lib/opamps.nim`, since `lib/parts.nim`'s header reads as ".MODEL cards"), then
   package `designs/riaa_preamp.nim`'s two `U1`s into one `U10`. Note the design currently
   states `partNumber = "NE5534"` — a *single* op-amp — so this step must either move it to a
   genuine dual or keep the resulting warning as a documented finding. Also package
   `aa_filter.nim`'s `U1A`/`U1B` under an `OPA1642` def, which costs nothing and exercises
   the flat path.
5. **Schematic label.** `SchematicPart.label` and its four touch points; cases in
   `tests/test_schematic.nim`.
6. **Board rollup.** `Placement.sections`, `bindComponent`'s second branch, `addLand`'s
   pin-number resolution, `bom.nim`'s fallbacks. Cases in `tests/test_pcb_bom.nim` (three
   components, one placement, one line) and `tests/test_pcb_core.nim` (bind by `package.ref`,
   still raises on a real mismatch, pad `"7"` resolves to section B's `OUT`).
7. **Docs** — not optional, see below.

---

## Verification

```
nimble test 2>&1 | grep -cE "FAILED|Error:"     # must print 0 — read the output, never the exit code
nimble verify
nim c -r --path:./src tests/test_netlist_packages.nim
nim c -r --path:./src tests/test_netlist_dsl.nim
nim c -r --path:./src tests/test_verify_readiness.nim
nim c -r --path:./src tests/test_pcb_bom.nim tests/test_pcb_core.nim
./bin/nimcir check designs/riaa_preamp.nim
./bin/nimcir check designs/aa_filter.nim
```

**Proving no number moved** — the claim in §Context, checked rather than asserted:

```
git stash && NIMCIR_KEEP_DECKS=/tmp/before ./bin/nimcir check designs/riaa_preamp.nim
git stash pop && NIMCIR_KEEP_DECKS=/tmp/after ./bin/nimcir check designs/riaa_preamp.nim
diff -r /tmp/before /tmp/after     # must be empty
```

If no deck differs, no measured number can have moved. Repeat for `aa_filter`.
`tests/test_spice_keep.nim` is the existing precedent for pinning that shape of claim.
`tests/test_spice_flatten.nim`, `test_spice_isolate.nim` and `test_spice_transform.nim` must
pass untouched — those are what would catch `package.*` failing to survive a transform.

## Docs to update

- `src/nimcir/netlist/CLAUDE.md` — a `packages.nim` bullet written the way the
  `environment.nim` one is: what it stores, why in `attrs` rather than `types.nim`, why
  definitions are a registry and membership is not, and the `hierNet`-identity rule for the
  global-pin check. Extend the `dsl.nim` bullet to note `with =` now carries section assignment.
- `src/nimcir/pcb/CLAUDE.md` — the "placement and component join on reference designator"
  statement is now false in one case; name `package.ref` as the second join key, and
  `Placement.sections` / `addLand`'s pin-number path.
- `src/nimcir/schematic/CLAUDE.md` — `label`, and why a composite is not the mechanism.
- `designs/CLAUDE.md` — the `riaa_preamp` entry gains a clause about the package.
- `docs/authoring.md` — a section **"One part, several channels"**: the definition, the two
  assignment paths, why it cannot live inside a `subckt`, and what the checks mean.
- `docs/findings.md` — multi-channel packaging is not on the "Feature gaps" list; add it with
  what stays deferred (below).
- `docs/composites.md` — one sentence closing the "is a package a composite" question.

## Deferred, deliberately

- **Unused-section tie-off.** An unused half of a dual op-amp must have its inputs tied off or
  it rails or oscillates into the used half — a real board defect nothing here will see. Out
  of scope by your call; worth writing into `findings.md` as the obvious next check.
- **Package pin count vs. footprint.** Needs a board reader, which `pcb/formats` does not have.
- **Intra-`subckt` packaging.** A `subckt` is deep-cloned per instance, so a package declared
  inside one would be a different physical part in every instance while a package designator
  is a board-global join key. Which chip a module's channels land in is a board decision —
  the argument `parts/CLAUDE.md` already makes about who chooses a part.
- **Cross-sheet reference on the symbol** ("U10B — sheet RIAA_CHANNEL"). Genuinely useful,
  since the sections are on different sheets by construction, and `render.explorerSheet`
  already knows the sheet names — but it is a second layout pass with its own placement
  question.
- **Renaming the registered `package` (case size) key to `case_size`.** A separate mechanical
  change if the adjacency proves confusing.
