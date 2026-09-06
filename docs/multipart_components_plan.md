# Multi-channel (multi-part) components — implementation plan

> **Status:** approved implementation plan. This document specifies planned work
> only; it does not claim the feature is implemented. It consolidates two earlier
> drafts (`docs/claude_multipart_components.md` and the previous contents of this
> file); those are superseded and removed.

## Context

A dual op-amp is one chip, one footprint, one BoM line, one silkscreen designator.
`nimcir` today models it as N unrelated `Component`s that happen to share a
`partNumber`:

- `designs/aa_filter.nim:105,130` writes `U1A` and `U1B` as two independent
  components on one sheet, each restating `V+`/`V-`, with nothing saying they are
  the same die.
- `designs/riaa_preamp.nim:89-90` is the harder case: its two channels are two
  `instance`s of one `subckt` (`designs/lib/riaa.nim:101`), so `XL.U1` and `XR.U1`
  are separate objects in separate child netlists — *different sheets* — and a
  stereo board built from a dual op-amp cannot currently say so at all.

Nothing in `src/nimcir/netlist/` has a package, section, gang or channel concept.
The registered `package` annotation (`netlist/annotations.nim:170`) means **case
size for parasitic lookup** (`"0402"`, `"film"`), not physical package identity.

**Outcome:** a design can declare a physical package with numbered pins and named
sections, assign those sections to components that live on different sheets, have
the tool check that the shared pins really are shared, and get one placement and
one BoM line for the part that actually gets soldered.

**Simulation does not change and no measured number moves.**
`spice/models/opamp.nim:44` `idealOpAmp` documents that it does not connect to
supply rails at all, so packaging two amplifiers together alters no deck. This is a
physical/structural feature; §Verification proves that rather than asserting it.

## Approach, and why

The design follows draft A (`attrs`-based membership + a package definition
registry) rather than draft B (a typed `Netlist.packages` root registry). The
reasons, each verified against the code:

1. **Membership survives every transform for free.** `graph.clone` copies `attrs`
   verbatim at every level (`src/nimcir/netlist/graph.nim:378` netlist, `:398`
   component, `:412` pin) and rebuilds nothing else. Storing membership in `attrs`
   means it survives `clone`/`instantiate`/`flatten`/`extractSubcircuit`/`isolate`
   with zero new code — the same argument `netlist/CLAUDE.md` already makes for
   `environment.nim` and `contract/design.nim`'s `role.*` tags. A root registry of
   direct `Component`/`Pin` references would need remapping written and tested
   across all of those, and `extractInstance` (which clones a child *alone*) would
   strand it entirely.
2. **A package needs a definition.** Only a full pinout lets `pcb/graph.addLand`
   resolve pad `"7"` on an NE5532 to section B's `OUT` — a join no board reader can
   make on its own — and lets `bom.nim` fall back to a shared part number when
   `Placement.component` is nil.
3. **The shared-pin check is by object identity, not by name.** In `riaa_preamp`
   both channels' `V+` nets are distinct `Net` objects that share the name `VP`
   (clones of one template net). A name comparison would pass a genuinely miswired
   board — the exact defect the check exists to catch.

Folded in from draft B: an explicit SPICE-lossiness regression test, lifecycle
tests (clone-child-alone, remove/rename a member), an explicit single-root rule,
and — **deferred by decision** — B's child-extraction global-pin ports and
required-binding check.

## Fixed decisions

| | Choice |
|---|---|
| Package definition | Full physical pinout: sections, per-section logical pins, global pins, package pin numbers |
| Membership storage | Three dotted `attrs` keys on each member component; no side-car store, no `types.nim` change |
| Assignment | Per-instance `with =` closure (reuses the existing `instance` hook); a post-block `assign` for the flat case |
| Board join | One `Placement` per package; `bindComponent` gains a second branch |
| Checks | Over-/mis-assignment and global-pin net agreement. Unused-section tie-off and footprint-pin-count are out (deferred) |
| `riaa` worked example | Move `designs/lib/riaa.nim` from `NE5534` (single) to `NE5532` (genuine dual); number-neutral, must be proven so |
| Child-extraction boundary | Deferred to `docs/findings.md` with B's design recorded |

---

## 1. The model — `src/nimcir/netlist/packages.nim`

A new module, sibling to `environment.nim`: it stores its data in namespaced
`attrs`, imports `types`/`graph`/`annotations`/`issue`, and adds **nothing** to
`netlist/types.nim`.

### 1.1 Definitions — a runtime registry of plain data

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

- Pin ids are **strings, not ints** — BGA pads are `"A1"`, and both KiCad and
  ODB++ carry pad names as text.
- `PackageSection.pins` is per-section so a heterogeneous package (dual comparator
  plus a reference) stays expressible; `newPackageDef` fills the homogeneous case.
- A definition holds **no procs** (unlike `RoleDef`) — a package computes nothing —
  so it could later be read from a file.

Registry, mirroring `contract/roles/core.nim:96-111` and
`netlist/kinds.registerDesignatorPrefix`:

```nim
var packageRegistry: OrderedTable[string, PackageDef]

proc registerPackage*(def: PackageDef)      ## raises on empty/duplicate name; validates the def
proc packageDef*(name: string): PackageDef  ## raises "no such package: <name>", naming knownPackages()
proc knownPackages*(): seq[string]
proc newPackageDef*(name: string, sections, pins: openArray[string],
                    global: openArray[string] = [], partNumber = "",
                    footprint = "", doc = ""): PackageDef
```

`registerPackage` **validates and raises**: every section pin and every global pin
must appear in `pins` exactly once, and every entry in `pins` must name a section
the def declares (or be global). A datasheet transcription error is what this
catches.

**No built-ins are registered.** There is no generic multi-channel package the way
there is a generic `power_rail` role; every one is a specific part number. This
library owns the mechanism; `designs/lib/` owns the catalogue — the line
`parts/policy.nim` already draws.

### 1.2 Membership — three dotted keys on the member component

`const packagePrefix* = "package."`. Dotted keys are never seen by
`validateAnnotations` (`annotations.isNamespaced` = `'.' in key`,
`annotations.nim:326`), so nothing new needs registering there.

| key | meaning |
|---|---|
| `package.ref` | the physical package's board designator, e.g. `"U10"` |
| `package.section` | which section this component is, e.g. `"A"` |
| `package.def` | the `PackageDef` name it was assigned under, e.g. `"NE5532"` |

`package.def` is redundant with the group and stored anyway: an `isolate`d fragment
retains one member and must still be able to say what part it is (the same reason
`annotations` stores provenance per key).

**No side-car store, no attachment step.** The netlist-side truth is entirely these
attrs; `validatePackages` reconstructs each group by walking `nl` and its
`children` recursively and grouping on `package.ref`. That is what makes cross-sheet
packaging work without a design-global registry that `pcb` (which does not import
`contract`) could not read.

Accessors — pure, never defaulting, following `annotations.nim`'s discipline:

```nim
proc packageRef*(c: Component): AnnValue[string]
proc packageSection*(c: Component): AnnValue[string]
proc packageDefName*(c: Component): AnnValue[string]
proc isPackaged*(c: Component): bool
proc displayDesignator*(c: Component): string    ## "U10A", else c.designator
proc packageMembers*(nl: Netlist, pkgRef: string): seq[Component]
proc packages*(nl: Netlist): OrderedTable[string, seq[Component]]   ## walks children
```

`assignSection` is the **only** writer of `package.*` (the rule `graph.nim` has for
back-references).

### 1.3 `assignSection` — the one writer

```nim
proc assignSection(nl: Netlist, inst: Netlist, sectionName, localDesignator: string)
```

Resolves `localDesignator` in `inst` (an instance's own clone, or the design
netlist for the flat case), then writes the three `package.*` keys. **Raises
immediately** on what it can see at the statement:

- a section name the definition does not declare (naming the ones it does);
- a duplicate section letter within one `package.ref`;
- over-assignment beyond the definition's section count;
- a component already assigned to a different package;
- **cross-root**: the resolved component's `root(c.netlist)` is not the design root
  the package belongs to (draft B's explicit rule).

Raising at the statement is the `addRole` precedent (`contract/roles/core.nim:79`).

### 1.4 Authoring helpers

A package instance is a small value created **before** the design block, so an
unregistered definition raises at the `let` rather than inside a macro expansion:

```nim
let u10 = packageInstance("NE5532", "U10")   # raises if NE5532 is not registered
```

```nim
type PackageInstance* = object
  def*: PackageDef
  designator*: string

proc packageInstance*(defName, designator: string): PackageInstance
proc section*(pi: PackageInstance, name, localDesignator: string): proc (nl: Netlist)
  ## returns a closure `proc (nl: Netlist) = assignSection(nl, nl, name, localDesignator)`
  ## — but see note below on the flat vs. instance path
proc assign*(pi: PackageInstance, nl: Netlist, name, localDesignator: string)
proc assign*(pi: PackageInstance, c: Component, name: string)   ## caller holds the object
```

**Instances on different sheets** — the target case, `designs/riaa_preamp.nim`:

```nim
instance XL, riaaChannel(), [inL, outL, vp, vn, gnd], with = u10.section("A", "U1")
instance XR, riaaChannel(), [inR, outR, vp, vn, gnd], with = u10.section("B", "U1")
```

Verified: `handleInstance` (`netlist/dsl.nim:430,457-460`) already accepts an
arbitrary expression for `with =` and calls it with `instVar.subNetlist`. So the
closure receives the instance's own clone, and the only name it uses is the
module's own local designator — exactly what `with =` is documented for
(`netlist/dsl.nim:441-456`). **No DSL macro change is needed.**

**Flat components on one sheet** — `designs/aa_filter.nim`, no instance to hang a
hook on. Assign after the block, the shape `spice/boundary.driveConnector`
(`boundary.nim:311`) already established:

```nim
u1.assign(d.netlist, "A", "U1A")
u1.assign(d.netlist, "B", "U1B")
```

### 1.5 Global pins stay on their sections

`designs/lib/riaa.nim:105-106` and `aa_filter.nim` already write `V+`/`V-` on each
amplifier, and **that must not change**: `spice/models/opamp.nim:18` `supplyRailsOf`
reads the rails off *the component's own* supply pins, and `opampModel` uses them
for the saturation clamp. Move them onto a package carrier and the clamp is
silently dropped and a large-signal measurement changes.

So `PackageDef.globalPins` buys a **check, not a restructuring**. A package-level
pin that only one section wires (an `EN`) is authored on that section;
`globalPins` is what says it belongs to the package rather than to that section.
**No carrier `Component` is created**, so nothing new can reach a deck as a stray
`U10` line (which ngspice reads as a uniformly-distributed RC line).

### 1.6 `validatePackages(nl): seq[Issue]`

An `Issue`, not a raise, for anything a netlist can legitimately be *in*
(`netlist/issue.nim` states that rule). Not a `contract` role: none of these is a
measurement, there is no quantity and no evaluator, and routing it through
`contract` would put the answer somewhere `pcb` cannot read it.

`Issue.kind` strings are namespaced by prefix, e.g. `"package_unknown_def"`.

| finding | severity |
|---|---|
| `package.def` names no registered definition | error |
| members of one `package.ref` disagree on `package.def` | error |
| section name not declared by the definition | error |
| duplicate section letter within one package | error |
| more sections assigned than the definition declares | error |
| a section carries a pin the definition declares neither as a section pin nor as global | error |
| **a global pin resolves to different nets across sections** | error |
| a member lives under a different root than the rest of its package | error |
| a declared section pin the component does not have | warning (message says **unconnected**, not *missing*) |
| a member's `partNumber` disagrees with the definition's | warning |

**The global-pin check.** For each `globalPins` entry, collect the corresponding
`Pin` on every section's component, resolve each **upward through `Pin.hierNet` to
the outermost net**, and compare by **object identity**. Never by name: in
`riaa_preamp` both clones are named `VP`, so a name comparison passes a genuinely
miswired board.

A missing section pin is a *warning* and the message says **unconnected**: pins are
created on demand at `graph.connect`, so a section whose `IN-` is simply unwired
has no `Pin` object at all.

### 1.7 The `package` key adjacency

`package = "0402"` (case size, registered) and `package.ref = "U10"` will sit side
by side in one `attrs` bag meaning different things. Accept it and document it
loudly. Renaming the registered key to `case_size` with `package` in its
`AnnDef.aliases` is the tidier end state but touches ~15 design files and
`spice/models/capacitor.nim`'s defaults table — a separate mechanical change if the
adjacency proves confusing (deferred).

### 1.8 Tests — `tests/test_netlist_packages.nim` (new)

- Every row of the §1.6 table.
- `registerPackage`'s definition checks (missing pin, extra pin, unknown section).
- **The `hierNet` identity comparison across two `instantiate` clones** — build a
  root with two children, each an instance of one template; package a section in
  each; wire both `V+`s to the same parent net (passes) and to different parent
  nets (fails); confirm two same-named clone nets on the *same* rail still pass.
- **Cross-root rejection**: a component from another root raises.
- **Lifecycle (from draft B):** clone a packaged root and confirm every member's
  `package.*` points at the clone; `clone` a child alone and confirm it carries no
  misleading partial group; remove or rename a member and confirm the group
  reconstruction from `packages(nl)` simply omits it (no dangling reference,
  because there are no references — this test *proves* the `attrs` choice).

At the end of this step the feature is usable directly from Nim.

---

## 2. Report it

One block in `verify.readiness` (`src/nimcir/verify.nim:245-248`), immediately
after the `validateEnvironment` loop:

```nim
for i in validatePackages(d.netlist): result.structural.add i
```

`exitCode` already grades `result.structural` through the existing
`sevError` / `strict && sevWarning` rule (`verify.nim:325-328`) — no change there.
Findings land in the report's `STRUCTURE` section.

Cases in `tests/test_verify_readiness.nim`: an error reaching `STRUCTURE`, and
`exitCode` returning `exitStructural`.

---

## 3. Authoring ergonomics

- Confirm `with = u10.section("A", "U1")` composes with `handleInstance` with no
  macro change (it should — `with =` takes an arbitrary expression).
- Add the `assign` overloads for the flat case (`Netlist` + local designator, and
  `Component` for a caller with the object in hand).
- Cases in `tests/test_netlist_dsl.nim`: the instance path, the flat path, and
  assignment across an instance boundary producing the same three `package.*` keys.

---

## 4. A real definition and the target designs

1. New **`designs/lib/opamps.nim`** (`lib/parts.nim`'s header reads as ".MODEL
   cards", so it is the wrong home). Register an `NE5532` def (dual, 8-pin DIP/SOIC
   pinout: `1=OUT` A, `2=IN-` A, `3=IN+` A, `4=V-` global, `5=IN+` B, `6=IN-` B,
   `7=OUT` B, `8=V+` global) and an `OPA1642` def (same pinout family).
2. **Swap `designs/lib/riaa.nim:101`** `partNumber` from `"NE5534"` to `"NE5532"`.
   The design states `gbw = 10.MHz` (`lib/riaa.nim:107`); the NE5532 is also a
   10 MHz part, so this is number-neutral — and §Verification proves the deck is
   byte-identical afterward.
3. Package `designs/riaa_preamp.nim`'s two `U1`s into one `U10` via
   `with = u10.section(...)` — the cross-sheet case.
4. Package `aa_filter.nim`'s `U1A`/`U1B` under `OPA1642` via the flat `assign`
   path — costs nothing and exercises the other path.

---

## 5. Schematic label

`SchematicPart` (`src/nimcir/schematic/scene.nim:25`) gains `label*: string`.

- **Set** at `schematic/routing.nim:37`, the point a `SchematicPart` is built from
  a `Component`: `label = displayDesignator(c)` — `"U10A"` for a packaged part,
  `""` otherwise.
- **Carry** through `schematic/json.nim`: write it beside `designator`
  (`json.nim:103`) and read it back in the scene reconstruction (`json.nim:282`),
  defaulting to `""` when absent so old scenes still parse. This keeps
  `render.writeScenePair` scenes round-tripping.
- **Draw** it where the designator is currently drawn as the visible label —
  `schematic/finish.nim:123,138` and `schematic/svg.nim:161` — using `label` when
  non-empty, else `designator`. `schematic/render.nim`'s explorer sidebar
  (`render.nim:172,188`) likewise.

**Do not overwrite `SchematicPart.designator`.** It is a join key: `finish.nim:159`
builds `partIdxByDesig` from `c.designator` and looks it up by
`p.component.designator`; `routing.nim:55` and the whole of `placement.nim` key on
it. Changing the rendered string in place silently breaks net-label anchoring on
every packaged part.

A composite is **not** the mechanism: `docs/composites.md` requires recognizers to
key on `Pin.kind` topology and `isTraversable` requires exactly two connected pins
with `subNetlist == nil` — an op-amp qualifies for neither, and the sections are on
different sheets anyway. Record that in `schematic/CLAUDE.md`.

Cases in `tests/test_schematic.nim`: `label` set for a packaged part, empty
otherwise, round-trips through JSON, and `designator` unchanged.

---

## 6. Board and BoM rollup

`pcb/graph.bindComponent` (`src/nimcir/pcb/graph.nim:231`) raises unless
`p.designator == c.designator`. That invariant gains a second branch — the one
existing rule that genuinely has to move.

1. **`src/nimcir/pcb/types.nim:219`** — one additive field on `Placement`:
   ```nim
   sections*: OrderedTable[string, Component]
     ## Section name -> the netlist component that is that section, for a
     ## multi-channel package. Empty for the 1:1 case, where `component` is
     ## the whole part.
   ```

2. **`bindComponent`** — keep designator equality as the first branch, unchanged.
   Add: when `packageRef(c).value == p.designator`, record
   `p.sections[packageSection(c).value] = c` and **leave `p.component` nil**. Nil
   is deliberate — `Placement.component` means "the netlist component this
   placement *is*", and for a dual op-amp there is no such component. Grow the
   mismatch message to name `package.ref` as the other way a placement and a
   component may agree.

3. **`pcb/graph.addLand` (`graph.nim:247`)** — today it keys `Placement.lands` by
   pin name and binds `c.pin` from `p.component.pins[pinName]`. For a sectioned
   placement (`p.component == nil and p.sections.len > 0`), look the pad id up in
   the definition's `pins` map, get `(section, logical)`, and bind from
   `p.sections[section].pins[logical]`. That makes pad `"7"` on an NE5532 resolve
   to section B's `OUT`. A pad id the definition does not declare leaves `c.pin`
   nil rather than guessing.

4. **`pcb/bom.nim`** — `valueOf`/`partNumberOf`/`defaultKey` (`bom.nim:57-83`) fall
   back to `p.component`, now nil for a package. Add a `p.sections` fallback that
   reads the shared `packageDefName` off any section and returns its
   `PackageDef.partNumber` / `footprint`. **`buildBom` (`bom.nim:85`) needs no
   change**: one placement was always one `BomLine`, so N components collapsing to
   one placement collapses to one line with the right quantity, for free.

5. **Audit every `p.component` dereference** — not just `bom.nim`.
   `pcb/graph.placementOf` (`graph.nim:239`) reads `result.component` and already
   null-checks; sweep `pcb/` and `pcb/formats/` for any other reader and confirm
   each tolerates nil (or guard it). This is an explicit step, not a spot check.

Cases in `tests/test_pcb_bom.nim` (three components, one placement, one line with
quantity 1 and the def's part number) and `tests/test_pcb_core.nim` (bind by
`package.ref`; still raises on a real designator mismatch; pad `"7"` resolves to
section B's `OUT`).

---

## 7. SPICE lossiness — explicit contract (from draft B)

`attrs` never reach a deck, so this is already true; make it a *named test* so it
cannot regress.

`tests/test_netlist_spice.nim` (or the existing SPICE-format test file): build an
electrically connected packaged graph, render to SPICE, parse it back, and assert:

- the reparsed netlist has **no** `package.*` keys on any component;
- no synthetic device, node, or comment encodes package identity;
- the electrical graph (component pins, nets, deck lines) is unchanged.

Document in `netlist/CLAUDE.md` and `docs/authoring.md` that a SPICE round trip
**intentionally** loses package metadata; a consumer that needs it keeps the Nim
source.

---

## 8. Docs

- **`src/nimcir/netlist/CLAUDE.md`** — a `packages.nim` bullet written the way the
  `environment.nim` one is: what it stores, why in `attrs` rather than `types.nim`,
  why definitions are a registry and membership is not, the `hierNet`-identity rule
  for the global-pin check, and the intentional SPICE metadata loss. Extend the
  `dsl.nim` bullet to note `with =` now carries section assignment.
- **`src/nimcir/pcb/CLAUDE.md`** — the "`Placement`/`Component` join on reference
  designator" statement (line 5) is now false in one case; name `package.ref` as
  the second join key, and `Placement.sections` / `addLand`'s pin-number path.
- **`src/nimcir/schematic/CLAUDE.md`** — `label`, and why a composite is not the
  mechanism.
- **`designs/CLAUDE.md`** — the `riaa_preamp` entry gains a clause about the
  package and the NE5534→NE5532 change.
- **`docs/authoring.md`** — a section **"One part, several channels"**: the
  definition, the two assignment paths, why it cannot live inside a `subckt`, what
  the checks mean, and the SPICE round-trip caveat. Also `nimble guide`.
- **`docs/findings.md`** — add multi-channel packaging with what stays deferred
  (below), *including B's child-extraction design* so it is not re-derived:
  extracting a child that contains a package member should add the package's global
  pins as deterministic boundary ports named `<ref>.<section-or-gate>.<pin>`
  (e.g. `U10.PWR.VCC`); child-only simulation must reject a missing binding by name
  before ngspice sees a deck; no root supply is inherited and no logic level is
  invented. Revisit when something other than a test calls `extractInstance`.
- **`docs/composites.md`** — one sentence closing the "is a package a composite"
  question.

---

## Steps (each lands independently)

1. §1 — `packages.nim` + `tests/test_netlist_packages.nim`. Usable from Nim.
2. §2 — one block in `verify.readiness` + `tests/test_verify_readiness.nim`.
3. §3 — confirm `with =` composes; add `assign` overloads + `tests/test_netlist_dsl.nim`.
4. §4 — `designs/lib/opamps.nim`, the `riaa.nim` swap, package both designs.
5. §5 — `SchematicPart.label` and its touch points + `tests/test_schematic.nim`.
6. §6 — `Placement.sections`, `bindComponent` branch, `addLand` resolution,
   `bom.nim` fallbacks, `p.component`-reader audit + `tests/test_pcb_bom.nim`,
   `tests/test_pcb_core.nim`.
7. §7 — the SPICE-lossiness regression test.
8. §8 — docs.

---

## Verification

```
nimble test 2>&1 | grep -cE "FAILED|Error:"     # must print 0 — read the output, never the exit code
nimble verify
nim c -r --path:./src tests/test_netlist_packages.nim
nim c -r --path:./src tests/test_netlist_dsl.nim
nim c -r --path:./src tests/test_verify_readiness.nim
nim c -r --path:./src tests/test_schematic.nim
nim c -r --path:./src tests/test_pcb_bom.nim tests/test_pcb_core.nim
./bin/nimcir check designs/riaa_preamp.nim
./bin/nimcir check designs/aa_filter.nim
```

**Proving no number moved** — the §Context claim, checked not asserted:

```
git stash && NIMCIR_KEEP_DECKS=/tmp/before ./bin/nimcir check designs/riaa_preamp.nim
git stash pop && NIMCIR_KEEP_DECKS=/tmp/after ./bin/nimcir check designs/riaa_preamp.nim
diff -r /tmp/before /tmp/after     # must be empty — includes the NE5534->NE5532 swap
```

Repeat for `aa_filter`. `tests/test_spice_keep.nim` is the existing precedent for
pinning that shape of claim. `tests/test_spice_flatten.nim`,
`tests/test_spice_isolate.nim` and `tests/test_spice_transform.nim` must pass
untouched — those catch `package.*` failing to survive a transform.

---

## Deferred, deliberately

- **Child-extraction global-pin boundary ports + required-binding check** (draft
  B's §"Child extraction"). A good design, but `extractInstance`/`extractSubcircuit`
  are called from tests only — no CLI, no analysis path drives them. Recorded in
  `docs/findings.md`; revisit when a production path extracts a child for
  simulation.
- **Unused-section tie-off.** An unused half of a dual op-amp must have its inputs
  tied off or it rails into the used half — a real board defect nothing here sees.
  The obvious next check; write it into `findings.md`.
- **Package pin count vs. footprint.** Needs a board reader `pcb/formats` does not
  have yet.
- **Intra-`subckt` packaging.** A `subckt` is deep-cloned per instance, so a
  package declared inside one would be a different physical part in every instance
  while a package designator is a board-global join key. Which chip a module's
  channels land in is a board decision (`parts/CLAUDE.md`'s argument about who
  chooses a part).
- **Cross-sheet reference on the symbol** ("U10B — sheet RIAA_CHANNEL"). Useful,
  since the sections are on different sheets by construction, but a second layout
  pass with its own placement question.
- **Renaming the registered `package` (case size) key to `case_size`.** A separate
  mechanical change if the adjacency proves confusing.
