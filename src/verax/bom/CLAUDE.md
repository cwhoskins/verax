# `bom` submodule

`src/verax/bom/` compiles a bill of materials from a design: which real,
orderable part each component is. `docs/bom_compiler_plan.md` is the whole
plan; this file records what has shipped and the decisions that are not
visible from the code. **Shipped: Stage 2 (collection and classification).**
Stages 3–6 — the catalogue source interface and resolver, the report/lockfile/
CLI, network sources — are not built yet.

**Placement.** Above `parts/` and below `verify.nim`; imports `netlist` (and
`units`), never `pcb`, `spice` or `contract`. It takes a `Netlist`, never a
`Design` or a `Pcb`, and it is not in the verification path — nothing in
`readiness` requires it. `pcb/bom.nim` compiles a BOM from a *board file* and
is a separate concern; reconciling the two is a stated non-goal, because it
would give `bom/` an edge to `pcb/`.

- **`types.nim`** — `PartFamily` and `BomItem` only. The plan's
  `Candidate`/`Resolution`/`BomResult`/`BomLine` arrive with Stage 3, the
  first code that reads them. `PartFamily` adds **`pfNotAPart`** beyond the
  plan: simulation-only elements (stimulus and controlled sources, `K`
  couplings, voltage/current-controlled switches) are left off the BOM *by
  kind*, so a design never flags its own test bench. Every float on
  `BomItem` that a part can leave unstated is **`NaN` when unstated**, not 0 —
  a zero tolerance and an unstated one must not look alike to a resolver.
  `designators` is the board designator a BOM line prints (the hierarchical
  path, or `package.ref` for a packaged part); `members` is every section's
  path — a deliberate split from the plan's single field, since a dual
  op-amp is bought as `U9`, not as `U9A,U9B`. `partNumber` is kept verbatim
  and **never promoted to `mpn`** (the plan's fact 2: `Component.partNumber`
  is as often a free-text label as an MPN).
- **`classify.nim`** — `familyOf` (a runtime table seeded from
  `builtinPartFamilies`, extended by `registerPartFamily`; `Component.kind` is
  an open string, so never a `case`) and **`caseCodeOf`, the
  standard-footprint gate**: an imperial chip case code or `""`. A stated
  `footprint` is the only authority when present — a QFN footprint with
  `package = "0805"` beside it is `""` — and a footprint name is read only
  when the imperial code sits beside its own metric twin
  (`R_0402_1005Metric`), because `0603` alone is both a real imperial and a
  real metric size (metric 0603 is imperial 0201). Without a footprint,
  `package` is accepted only as a bare imperial code. `""` is what will make
  Stage 3 refuse to search rather than return a part that does not fit.
- **`collect.nim`** — `collect(nl): seq[BomItem]`, one item per physical
  part in netlist order. Walks leaves with a local copy of
  `pcb/assemble.collectLeaves` (no `pcb` edge); groups sections by
  `package.ref`, taking a footprint/part number from the `PackageDef` when no
  section states one; reads `value` with `parseSpiceMagnitude` **only for
  the four parametric families** — anything else's `value` is a model name,
  and `1N4148` is lexically valid RKM — so RKM (`2k2`) is refused with
  `bom_value_unparseable` and read as neither 2200 nor 2000. `dnp`/
  `bom_exclude` (registered `akBool` annotations, so `spec: dnp = true` is
  compile-time checked) set `doNotPopulate`/`excluded`; an excluded part is
  kept with the flag, so Stage 3 can say what it left out, and a package
  with only some sections marked `dnp` is `bom_package_dnp_conflict` and
  treated as DNP whole. **Defaults:** each item takes `bomDefaults` of the
  netlist its first member lives in (most specific wins — see
  `netlist/bomdefaults.nim`), fills only what the part left unstated, only
  for parametric families, and records each fill as an `Assumption`. A
  default package is applied only when the part states neither `package` nor
  `footprint` — beside a footprint it would decide nothing and its
  assumption would mislead. `series`, `derating` and `manufacturers` are
  resolver inputs, not item fields, and are not read here. Findings live on
  `BomItem.issues` rather than a side list, so the resolver can carry each
  part's own findings into its `Resolution`.

`tests/test_bom_collect.nim` pins all of the above.
