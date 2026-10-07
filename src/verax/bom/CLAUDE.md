# `bom` submodule

`src/verax/bom/` compiles a bill of materials from a design: which real,
orderable part each component is. `docs/bom_compiler_plan.md` is the whole
plan; this file records what has shipped and the decisions that are not
visible from the code. **Shipped: Stage 2 (collection and classification),
Stage 3's source registry, offline JSON catalogue and resolver, and Stage 4's
report, lockfile and `verax bom` CLI.** Still to build: Stages 5–6 (network
sources, docs). The disk
cache the plan put in Stage 3 moves to Stage 5: it caches network answers,
and there is no network source yet.

**Placement.** Above `parts/` and below `verify.nim`; imports `netlist` (and
`units`), never `pcb`, `spice` or `contract`. It takes a `Netlist`, never a
`Design` or a `Pcb`, and it is not in the verification path — nothing in
`readiness` requires it. `pcb/bom.nim` compiles a BOM from a *board file* and
is a separate concern; reconciling the two is a stated non-goal, because it
would give `bom/` an edge to `pcb/`.

- **`types.nim`** — `PartFamily`, `BomItem`, the catalogue's
  `Candidate`/`Availability`, and the resolver's `Resolution`/`LockEntry`/
  `BomLine`/`BomResult`. `BomLine` copies `pcb/bom.BomLine`'s field names
  without importing it, plus `resolutions`; `Resolution` adds `candidates`
  (how many parts met the requirement) beyond the plan. `Candidate`
  gains a **`family`** field the plan's sketch lacked — a search cannot
  filter on what a candidate does not say. Unknown stock and MOQ are **`-1`,
  not 0**, for the same reason unknown floats are `NaN`: a low-stock finding
  must be skipped for an unknown, not raised on it. `PartFamily` adds
  **`pfNotAPart`** beyond the plan: simulation-only elements (stimulus and controlled sources, `K`
  couplings, voltage/current-controlled switches) are left off the BOM *by
  kind*, so a design never flags its own test bench. Every float on
  `BomItem` that a part can leave unstated is **`NaN` when unstated**, not 0 —
  a zero tolerance and an unstated one must not look alike to a resolver.
  `designators` is the board designator a BOM line prints (the hierarchical
  path, or `package.ref` for a packaged part); `members` is every section's
  path — a deliberate split from the plan's single field, since a dual
  op-amp is bought as `U9`, not as `U9A,U9B`. `partNumber` is kept verbatim
  and never written into `mpn`; `effectiveMpn` reads the two in order.
  **`description`** (a registered annotation, 2026-10-06) holds what the part
  is in words — the free-text labels (`"USB-C 2.0 receptacle"`, `"hdr-2"`,
  `"Tx PA"`) that used to overload `partNumber` (the plan's fact 2) were
  moved there in every design and template, so `partNumber` now means a part
  number. A BOM line prints a catalogue's description, else the design's.
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
- **`source.nim`** — the `CatalogSource` registry, a copy of
  `pcb/footprint`'s shape: registration order is resolution order, `nil`
  `search`/`lookup` members are skipped, and **nothing registers on import**.
  Unlike `FootprintSource` the procs are **closures**, because a source
  carries state (a loaded catalogue, later credentials and a cache).
  `newPartQuery` exists because a default-constructed `PartQuery` has `0.0`
  where "no requirement" must be `NaN`. **`matches` is the one definition of
  a match**: family and case code equal (a `""` case code or `NaN` value
  matches nothing), value within `valueTolerance` (exact when unstated), and
  a stated minimum rating, dielectric or maximum tolerance **rejects a
  candidate that leaves it unknown**. `manufacturers` is a hint, never a
  filter — preference is the resolver's ranking. `searchAll` de-duplicates
  on `partKey` (case-insensitive manufacturer + MPN), keeps the first
  source's record and fills only the availability it left unknown; both it
  and `lookupAll` hand out `copyCandidate`s so a caller cannot edit a
  source's stored record. `clearCatalogSources` exists for tests and for
  re-running with another catalogue in one process.
- **`sources/local.nim`** — the hermetic source: a `verax.catalog/1` JSON
  file loaded whole and scanned linearly. **Why not a database:** a house
  preferred-parts list is hundreds to a few thousand rows, microseconds to
  scan, and `db_sqlite` left the stdlib in Nim 2, so SQLite would break the
  standard-library-only rule for nothing; the million-part catalogue is a
  distributor's, reached by a network source. **Strict:** values are numbers
  in SI base units (a string such as `"10k"` is refused — the RKM ambiguity
  stays out of the catalogue as it is out of `collect`), tolerance is a
  fraction (`>= 1` is refused as a likely percentage), unknown fields,
  families, lifecycles and case codes are refused, a parametric row must
  state `value` and a non-parametric one must not, and a duplicate
  `(manufacturer, mpn)` is refused. Every problem is collected and raised as
  one `CatalogError` naming each row; nothing is loaded from a bad file. A
  missing `caseCode` is derived from a bare imperial `package`; a parametric
  row with neither (a 4×4 mm inductor) is legal and found by MPN only.
  `lookup` ignores case, and with no manufacturer returns the first match in
  file order. **Not registered on import**, a deliberate change from the
  plan: a file-backed source has nothing to answer with until it is given a
  file, so `registerCatalogFile(path)` loads then registers (and registers
  nothing if loading fails). `--bom-catalog=`/`$VERAX_BOM_CATALOG` wiring
  belongs to the Stage 4 CLI.

- **`resolve.nim`** — `resolve(items, opts): BomResult` and
  `resolveItem`. Order per item: **excluded** (`bom_excluded`, on no line)
  → **MPN, for every family** (a stated `mpn` is authoritative; unknown to
  every source is `bom_part_not_found`, a *warning*, and the line keeps the
  MPN as stated; with no `mpn`, `partNumber` stands in for it — `effectiveMpn`
  — always with `bom_partnumber_used_as_mpn`: info when a source recognises
  it, a *warning* when none does and it is ordered unverified. Changed
  2026-10-06 at the user's request from "tried, and ignored unless a source
  recognises it" — safe only because labels now live in `description`, not
  `partNumber`; an IC with a part number but no `mpn` is a warning, not an
  error) → **parametric
  search** → nothing (`bom_mpn_required`/`bom_no_match`, `sevError` only when
  the part reaches assembly). The plan put the MPN path under `pfOther`
  only; a passive stating an MPN is bought by it too, and
  `bom_mpn_spec_mismatch` warns when the part contradicts what the design
  also states (comparing only what both sides state). **A candidate's whole
  band must fit**: the query lets the nominal sit within the item's
  tolerance, then `fitsBand` requires nominal ± the candidate's own
  tolerance inside the item's band (9.76 k 1 % fits 10 k 5 %; 9.76 k 5 %
  does not); no stated tolerance means the exact value. **Ranking puts
  lifecycle first** (active/unknown, NRND, obsolete) — a deviation: a
  preferred manufacturer's obsolete part must not beat a current one — then
  preferred manufacturer, exact value, stock (unknown last), MPN,
  manufacturer. `signatureOf` is the lock key (requirement only, never the
  designator); a lock wins only if its part is still among the candidates
  and not obsolete, else `bom_lock_stale` and ranking. A search still runs
  under a lock, so `alternates`/`candidates`/`bom_uncommon_part` stay
  meaningful. Roll-up keys on `partKey` plus DNP; unresolved items share a
  line per signature so the BOM still lists what is missing. `bom_low_stock`
  is per *line* (quantity × `stockFactor`) and lives on `BomResult.issues`;
  unknown stock is never flagged. Of the `bom:` defaults only
  `manufacturers` is read here — `collect` applied the rest — and **`series`
  and `derating` are not read**: the resolver buys the stated value, and
  derating needs the voltage across the part, which a BOM does not know.
  `bom_no_sources` is raised once when nothing is registered.

- **`report.nim`** — `render` (text: lines, then findings by severity,
  then a summary), `renderCsv` (RFC 4180; quantities sum to the populated +
  DNP part count, excluded parts on no row) and `renderJson`
  (`verax.bom/1`, hand-built, every float through `jnum` so `NaN` is `null`,
  unknown stock/MOQ `null` not `-1`). The JSON holds `parts[]` — one per
  item, excluded included, with requirement, signature, chosen, alternates,
  assumptions and issues — and `lines[]` naming parts **by index**, so
  nothing is written twice. **It is also the lockfile**: `parseLock`/
  `loadLock` read back every resolved part with a `signature` (only a search
  produces one — a part bought by MPN is already named by the design), and
  refuse a file tying one signature to two parts rather than pick by order.
  Anything unusable is a `LockError`, which `verify.compileBom` turns into a
  usage error.
- **CLI** (in `verify.nim`/`cli.nim`, not here): `verax bom <file> [-o out]`
  forwards `--bom` plus the `--bom-*` flags through `cmdCheck`, the
  `cmdLayout` shape. Inside the design binary `--bom` *or any `--bom-*`
  flag* selects `compileBom`, which runs before `readiness` and stops;
  an unknown `--bom-*` flag is an error, not left for the design, so a typo
  cannot silently drop a catalogue. Catalogues come from repeatable
  `--bom-catalog=` or else `$VERAX_BOM_CATALOG` (`PathSep`-separated), each
  registered under its file's base name. Exit: `exitStructural` when a part
  that reaches assembly is unresolved, else `exitClean`; an unreadable
  catalogue or lock is `exitCompile`. With CSV/JSON on stdout, findings go
  to stderr so the document pipes clean.

`tests/test_bom_collect.nim` pins collection; `tests/test_bom_catalog.nim`
the loader and search against `tests/fixtures/catalog.json`;
`tests/test_bom_sources.nim` the registry; `tests/test_bom_resolve.nim`
the resolver against the same fixture; `tests/test_bom_report.nim` the three
renderers; `tests/test_bom_lock.nim` the lock round trip, including that
renumbering generated designators invalidates no lock.
