# Authoring a footprint's geometry: a manifest, and what can emit one

`pcb/footprint.nim` can only get a `Footprint` from one place: a vendor
`.kicad_mod` file read by `formats/kicadmod.nim`. There is no way to
*author* a land pattern from inside verax — no way to state a pad set, a
courtyard, silkscreen, paste and mask apertures, text, or a 3D body.

`footprint.nim`'s own module comment and `layout_variants.md`
("The OpenSCAD obstacle") both name OpenSCAD as the candidate for this and
rule it out: its exports (STL/3MF mesh, or `projection()` to SVG/DXF) carry
no channel for pad identity, and `FootprintPad.id` is the join key
`graph.addLand`/`PackageDef.pins` match a netlist pin on — a source that
cannot say which polygon is which pad cannot place a single real
connection.

That rejection is right about the formats it evaluated and incomplete in
two ways, both found by this research and both changing the answer. It did
not consider `.csg`, OpenSCAD's own flattened node tree and the surface
every real integrator (FreeCAD included) actually uses — which has exactly
one metadata channel, `color()`, so identity is *possible*, just awkward
(§4). And it framed the question as "integrate OpenSCAD", when the thing
verax actually needs is a **manifest** — a pad table with ids — and
geometry authoring is only how that manifest gets produced; several tools
can emit one, and none needs to be privileged in the design (§1).

This is a research document. **No code changes accompany it**, and the
choice of engine is explicitly left to a later stage (§7).

Settled going in and not reopened here: **STEP is a reference, never
geometry.** A 3D body is a path plus `offset`/`scale`/`rotate`, exactly as
`.kicad_mod`'s `(model ...)` node already carries it — verified on
`/usr/share/kicad/footprints/Package_QFP.pretty/LQFP-144_20x20mm_P0.5mm.kicad_mod`,
whose `(model "${KICAD10_3DMODEL_DIR}/Package_QFP.3dshapes/LQFP-144_....step"
(offset ...) (scale ...) (rotate ...))` is exactly that shape. verax never
parses STEP, in this document or after it.

## 1. The contract, stated before any tool is named

**verax specifies a JSON manifest and a subprocess. Any engine that emits
the manifest qualifies; none is privileged.**

```
fp.py  --(subprocess)-->  fp.json  -->  Footprint
```

```json
{"name": "R_0603",
 "mount": "smd",
 "pads": [{"id": "1", "at": [-0.95, 0], "rot": 0,
           "aperture": {"kind": "rect", "w": 1.0, "h": 1.2},
           "layers": ["F.Cu", "F.Mask", "F.Paste"]}],
 "graphics": [{"layer": "F.SilkS", "kind": "stroke", "path": [...]}],
 "courtyard": [[-1.6, -0.8], [1.6, -0.8], [1.6, 0.8], [-1.6, 0.8]],
 "model": "${KICAD10_3DMODEL_DIR}/R_0603.step"}
```

This is the load-bearing decision, and it is what makes every tool question
below reversible. It is also the shape `footprint.FootprintSource` already
has: `registerFootprintSource` with no built-in source registered
(`footprint.nim`'s own doc comment calls this out explicitly) was designed
for exactly this — a manifest-backed source is a new module, not a new
mechanism, and `findFootprint`'s first-registered-source-wins resolution
order needs no change to accommodate it.

Three consequences worth stating plainly:

- **Pad identity is not a geometry problem.** It is a property of the
  *script's own data*, written to the manifest directly by whatever authored
  it. Every identity difficulty discussed below (§4) exists only for an
  engine that cannot simply write a file — which turns out to be a narrower
  set than "everything that isn't verax."
- **The engine is swappable without touching verax.** PythonSCAD today,
  build123d tomorrow, a plain Python script with no CAD kernel at all for a
  part whose pads are a computed grid (§2's third bullet).
- **The manifest is the thing to get right, and it is bounded, not by any
  engine's expressiveness, but by `geometry.Aperture`'s closed enum** (§6).
  A kernel that can do more than that enum expresses buys nothing for a pad;
  it only ever pays off for the 3D body, which this document has already
  scoped to a reference.

## 2. Engines that can emit the manifest

Compared on install weight, geometry kernel, strictness, STEP, and
maturity. **No recommendation** — that decision belongs to whichever later
stage actually commits to one (§7).

### PythonSCAD

A direct fork of OpenSCAD that embeds a full CPython, so a model script is
ordinary Python with the whole standard library available to it: it can
`import json` and write the manifest itself, with no separate export/parse
step. It keeps OpenSCAD's geometry engine and its genuinely useful
primitives for this job — `offset()` is *literally* what a courtyard is
(union the pads and the body outline, offset outward by the clearance),
plus `hull()` and `text()`.

It gained **STEP export** in March 2026
([HN thread](https://news.ycombinator.com/item?id=47578752)), OCCT-backed.
It is distributed as a real pip package (`pythonscad`, 1.1.2 as of July
2026) that carries the actual engine rather than being a thin code
generator, and as a standalone AppImage.

Costs: a single-maintainer fork rather than upstream OpenSCAD, so it trails
or diverges from upstream fixes on its own schedule; a dependency dragging
in CPython *and* OCCT; STEP **import** is unconfirmed — only export is
documented; and
[pythonscad#1031](https://github.com/pythonscad/pythonscad/issues/1031)
records `_openscad` not being importable in the AppImage's
`pythonscad-python` runner, which is exactly the headless path this
document's contract needs — the GUI path is not an option for a subprocess
call from Nim.

### build123d (or CadQuery)

Python plus OCCT B-Rep: exact booleans, real STEP read *and* write, no
approximate quasi-static exports to worry about. One counter-intuitive
detail worth recording: build123d deliberately carries **no** persistent
feature tags. It uses selectors instead, because a name bound to kernel
topology goes stale as a model is edited (the classic topological-naming
problem). That does not bite here — the pad id lives in the authoring
script's own Python data structures and is written straight to the
manifest; the kernel itself is never asked to remember which face was which
pad.

Heaviest install of the three (OCP wheels run to roughly 400 MB). Worth one
licensing sentence given verax is MIT-licensed: OCCT is
LGPL-2.1-with-exception, and a binary that merely *runs* a
subprocess never links against it — the sidecar shape this document's
contract already commits to is the licence-clean one regardless of which
engine sits behind it.

### Plain Python, no CAD kernel

For a large fraction of real land patterns — a two-pad SMD passive, a
regular pin grid — the pads are a computed loop and the courtyard is a
rectangle. `json.dump` over that loop needs no geometry library at all.
Worth naming explicitly so this document does not imply a CAD kernel is a
prerequisite for authoring a footprint; for the common case, it is not.

## 3. Why a subprocess-and-manifest, and not "integrate OpenSCAD"

The research that produced §1's framing, recorded so it does not need
re-deriving:

**There is no embeddable OpenSCAD.** No `libopenscad`, no stable C API —
[openscad#193](https://github.com/openscad/openscad/issues/193) has been
the open request for exactly this since 2012, unresolved. OpenSCAD is a Qt
application built over CGAL, Manifold and Clipper2; nothing ships a way to
link its evaluator into another program.

**FreeCAD does not embed an OpenSCAD compiler either** — the premise this
research started from, and worth correcting in writing since it is easy to
assume otherwise. `src/Mod/OpenSCAD/importCSG.py`'s `open()` method calls
`callopenscad(filename)`, which runs the `openscad` **binary** as a
subprocess to convert a `.scad` file to `.csg`, then parses that `.csg`
itself with a hand-written Python `ply` grammar (`importCSG.py`'s own
parser handles `union`/`difference`/`intersection`, `multmatrix`,
`linear_extrude`/`rotate_extrude`, the primitives, `color`, `group`,
`text`, `import`, `surface`, `projection`, `offset`, `hull`, `minkowski`,
and the `#!*%` modifiers). The executable's path is a user preference in
FreeCAD's settings. This is subprocess-plus-parse, not linkage — exactly
the shape `spice/ngspice` already has in this codebase, down to tests
skipping outright when the tool is not on `PATH`
(`tests/test_spice_ngspice.nim`). `openscad` is not installed on this
machine, incidentally, which is a second, unrelated reason none of this was
exercised here — not the reason any candidate is ruled out.

**If linking a kernel were ever wanted anyway**, the kernels are the thing
to link, not the application: **Manifold** (the 3D mesh-boolean library
OpenSCAD itself has used since 2025, with a C API) and **Clipper2** (2D
polygon booleans and offsetting, which Manifold also uses internally for
its own 2D support). Both are named here because they are the honest answer
to "why not just link something", and both are set aside because either
breaks `requires "nim >= 2.2.10"` and nothing else — this codebase's stated
rule that a nimble dependency can only be opt-in per *package*
(`python/` is the existing example), not per import, inside the core library.

## 4. Appendix: plain OpenSCAD and `.csg` — the only no-Python option

Kept as an appendix because it is the one candidate in this document
needing no Python runtime at all, and because its findings are exactly what
corrects `layout_variants.md`'s current claim.

`.csg` is the fully-evaluated node tree OpenSCAD's compiler produces:
variables, loops (`for`), conditionals (`if`) and user module bodies are
all resolved, and every primitive is left with exact numeric parameters.
FreeCAD's `importCSG.py` grammar is the authoritative list of what actually
appears in one, given above.

Two consequences for a footprint reader:

- **`text()` survives as text**, not as polygons — landing directly on
  `geometry.Shape`'s existing `shText` variant, which is a better fit than
  any path that polygonises glyphs first.
- **User module names are lost.** Every user-defined module call collapses
  to a bare `group()`; only OpenSCAD's own built-ins (`cube`, `circle`, ...)
  return a shape with a recognisable head token.
  [openscad#5277](https://github.com/openscad/openscad/issues/5277)
  proposes a `group(name=..., id=...)` syntax to fix exactly this; it has
  not shipped. So an identity scheme has to ride on `color()`, which is the
  only piece of metadata that survives into `.csg` at all — and, per
  [openscad#4671](https://github.com/openscad/openscad/issues/4671), `.csg`
  is the *only* export format OpenSCAD preserves colour into, which is
  itself informative about how load-bearing that channel already is for
  other tooling. `echo()` on stderr is the other, out-of-band channel.
  The alternative is one invocation per tag
  (`openscad -D 'layer="pads.A1"' -o out.csg fp.scad`, with the top level
  dispatching on `layer`), where identity is free because verax chose the
  string — viable per *layer set* (five runs: pads, courtyard, silk, paste,
  mask) but not per pad, since a 144-pin QFP would mean 144 process
  launches.

What this option costs that §2's engines do not: a **CSG parser written in
Nim** (FreeCAD's grammar is the size guide); a `verax.scad` prelude that
reserves a colour space for tagging and — the failure mode worth naming —
must make the parser **refuse** an unreserved colour appearing under a
tagged block rather than silently letting a user's own `color()` steal the
tag; and **2D polygon clipping**, needed to reduce something like
`difference() { square(...); circle(...); }` down to a single `Polygon`.
The alternative to writing a clipper is **recognise-or-refuse**: match a
single primitive, optionally under one `multmatrix`, against
`geometry.ApertureKind` directly, and refuse by name anything more compound
than that. That covers essentially every real land pattern — pads are
rectangles, rounded rectangles, ovals, circles — and fails loudly rather
than silently on the rest, which is the discipline this codebase already
applies everywhere else (`spice/CLAUDE.md`'s named-refusal pattern,
`formats/kicad.nim`'s refusal table).

**Language strictness is the other real cost, and it is not cosmetic.**
OpenSCAD propagates `undef` silently through a script: a mistyped variable
name evaluates to `undef`, arithmetic on `undef` produces more `undef`, and
a pad placed `translate(pos) circle(...)` where `pos` was never assigned
either vanishes from the render or lands at the origin — with no error at
any point. There is no static typing and no exception mechanism, and
`$`-prefixed special variables use dynamic rather than lexical scoping,
which is its own separate source of "which value did this actually see"
surprises. A footprint silently missing a pad is exactly the failure class
`pcb/assemble.nim`'s `footprint_pad_unmatched` check exists to catch — but
only after the fact, from the netlist side. Every engine in §2 embeds a
language (Python) that raises on the equivalent mistake instead of
producing a plausible-looking wrong answer, which is a meaningfully
different guarantee for a footprint author to rely on, not a matter of
taste.

## 5. The no-subprocess alternative: a Nim `footprint:` DSL

Precedent already in the codebase: `netlist/dsl`, `contract/dsl`. Identity
is free by construction (`pad "1":` *is* the join key
`graph.addLand`/`PackageDef.pins` match on — no channel is needed because
there is nothing to smuggle it through), and it is compile-time-checked,
which nothing else in this document gets. No external dependency at all,
consistent with the package's stdlib-only rule.

It pays for that in two ways: polygon offsetting (a courtyard from pads
plus clearance) has to be written by hand rather than borrowed from
`offset()`, and there is no visual preview — nothing here gives an author
the equivalent of OpenSCAD's live render while placing pads, and no reuse
of any existing SCAD or STEP part library.

Not mutually exclusive with §1–§4: `FootprintSource`'s registry already
supports several sources side by side with first-registered-wins
resolution, so a Nim DSL as an always-available baseline and a
manifest-backed subprocess source registered alongside it (or ahead of it,
to shadow it for specific specs) cost nothing extra in the existing
mechanism.

## 6. The ceiling nobody notices, and two repo-local blockers

**`geometry.Aperture` is a closed enum**: `akCircle`, `akRect`,
`akRoundRect`, `akChamferRect`, `akOval`, `akTrapezoid`, `akCustom`, plus
`Polygon` and `Shape`'s four kinds (`shStroke`, `shFill`, `shPad`,
`shText`). Whatever geometry any engine in this document produces has to
land in one of those. A kernel materially more expressive than that buys
nothing for a *pad* — it only ever pays off for the mechanical body, which
this document has already scoped as a reference path (`(model ...)`'s
verbatim bytes), never geometry verax reasons about. Stated once here
because it is the single fact that collapses most of the option space in
§2, and it is invisible from outside this codebase — nothing about
OpenSCAD, PythonSCAD or build123d's own documentation would tell a reader
that their extra expressiveness is being discarded on arrival.

**`formats/kicadgen.spliceFootprintNode` does `parseSexp(fp.source,
p.designator)`** (`formats/kicadgen.nim:65`) — it splices a library
footprint's verbatim bytes into the synthesized board and never regenerates
one from scratch, deliberately: the same bet `formats/sexp.nim` already
makes for a whole board, that an untouched node needs no escape rule, no
quoting policy and no number formatter because its raw bytes already are
correct. **A `Footprint` produced by any authoring path in this document
has an empty `source` and therefore cannot be written to a board today**,
regardless of which engine produced it. Every candidate above inherits this
exact same second piece of work, with two shapes to choose between: write a
real `(footprint ...)` emitter — reproducing KiCad's own graphics syntax by
rule, which is precisely what `kicadgen.nim`'s own doc comment says this
codebase avoids doing, and that trade needs to be stated explicitly rather
than discovered later — or have the authoring path itself emit
`.kicad_mod`-shaped text as its own `Footprint.source`, so `kicadgen.nim`
needs no change at all. The second is cheaper and is the shape a future
stage should default to; it still means someone writes that text emitter,
just confined to one small module rather than touching the splice path.

**`Footprint` has no field for a 3D-model reference** — its fields are
`name`, `mount`, `pads`, `courtyard`, `bodyBox`, `height`, `graphics`,
`source`, `attrs` (`pcb/footprint.nim:73`). That is harmless today because
every footprint comes from a `.kicad_mod` file whose `source` already
carries `(model ...)` verbatim. It becomes a real gap the first time a
`Footprint` is authored rather than read from a file, since there is then
nowhere on the type itself to put the STEP-reference path this document
scoped in §0.

## 7. Stages, if and when this is picked up

Exit criteria, kept engine-agnostic where the stage does not require
otherwise:

1. **The manifest.** Write the JSON schema down for real (§1's sketch is
   illustrative, not final) and hand-write one `.json` file for a 0603,
   with no engine involved at all. Exit: a `Footprint` built from it whose
   `pads[i].id` matches a real vendor `.kicad_mod`'s pad ids for the same
   part, exactly.
2. **A `FootprintSource`.** New module under `pcb/formats/`, registering
   itself on import per this codebase's opt-in-per-import rule, with no
   change needed to `findFootprint` or any existing caller. Subprocess,
   skip-when-absent — the `spice/ngspice` pattern, tests included.
3. **One engine, end to end.** Prove it on a two-pad SMD part and on one
   part with 48+ pads, since §4's per-pad-invocation trap and any real
   engine's headless rough edges (§2's PythonSCAD note) only show up at
   that pin count.
4. **Layer sets.** courtyard / silk / paste / mask / fab, into
   `Footprint.graphics` and the `courtyard`/`bodyBox` fields.
5. **Emission.** Close §6's `source`-emptiness blocker; add the 3D-model
   reference field `Footprint` currently lacks; a `designs/` example
   placing an authored footprint on a board that survives `nimble
   generate`.

## Verification

This document changes no `.nim` behaviour, so verification is that nothing
regressed and that the claims made here hold against the tree:

- `nimble test 2>&1 | grep -cE "FAILED|Error:"` returns `0` — per
  `CLAUDE.md`, `nimble test`'s own exit code is not trustworthy.
- `nimble verify` still passes; `footprint.nim`'s module comment was
  amended alongside this document, so `nim check --path:./src
  src/verax/pcb/footprint.nim` confirms it still compiles.
- Every repo-local claim here is checkable directly against the tree with
  no external tool installed (`openscad`/`freecad`/`cadquery` are all
  absent from this machine, and that absence is not why anything was ruled
  out): `Aperture`'s enum at `src/verax/pcb/geometry.nim:68`,
  `spliceFootprintNode`'s `parseSexp(fp.source, ...)` at
  `src/verax/pcb/formats/kicadgen.nim:65`, `Footprint`'s field list at
  `src/verax/pcb/footprint.nim:73`, and the `(model ...)` node in the
  LQFP-144 `.kicad_mod` under `/usr/share/kicad/footprints/`.
- `layout_variants.md` and `footprint.nim`'s module comment no longer state
  the unqualified "OpenSCAD's outputs carry no pad identity" claim, and
  both point here.
