# Multi-part components implementation plan

> **Status:** approved implementation plan. This document specifies planned work
> only; it does not claim that multi-part components are implemented.

## Approved semantics and scope

A physical package (for example, a quad logic IC) may be represented by
several concrete functional units located in different child `Netlist`s below
one root design. Package membership is design metadata over those existing
components; it is not a new electrical hierarchy and does not merge their
nets.

Each package declaration contains:

- named **functional units** (for example `A` through `D`), each assigned to
  at most one concrete `Component`; and
- one explicit **global-pin gate**, which names the package pins shared by the
  functional units (commonly supply, ground, enable, reference, or thermal
  pins) and their ordinary `Pin`/`Net` connectivity.

The global-pin gate is explicit package metadata, not a synthetic SPICE device
or an implicit connection. It is required so the package's shared pins have a
single identifiable owner and can be exposed when only one child is simulated.
It must name existing pins/concrete graph objects; it must not create nets,
attach a default source, or infer a logic value.

The following decisions are fixed:

1. A package registry belongs to the root `Netlist`. Its members may be in the
   root itself or in any concrete descendant child netlist, but may not cross
   roots.
2. Assigning the same functional unit twice is a `NetlistError`. Registering a
   second global-pin gate is likewise an error. Assigning one concrete
   component to incompatible package/unit identities is an error.
3. Package completeness concerns declared functional-unit assignments and the
   presence of the explicit global-pin gate. It **does not** report a missing
   global-pin *connection* as a special package-completeness problem.
4. A disconnected global pin is ordinary pin connectivity/validation input,
   reported (or permitted) by the same generic electrical validation policy as
   any other disconnected pin. Package validation must not duplicate it with a
   package-specific diagnostic.
5. SPICE serializes and re-parses the electrical graph, not package metadata.
   A SPICE round trip must preserve the package's electrical connectivity, but
   intentionally loses all package/unit/global-gate metadata. There is no
   attempt to encode it in comments, invented devices, or names.
6. Extracting/simulating a child that contains a member of a package must add
   that package's global pins as named boundary ports of the extracted child.
   The caller must explicitly bind or stimulate those ports. The simulation
   must never inherit an implicit root-level driver or invent a high/low,
   supply voltage, ground, termination, or leak beyond existing explicit
   simulation policy.

Non-goals are package symbol drawing, PCB footprint/unit placement policy,
automatic inference of package membership from reference designators, parsing
package metadata from SPICE, and changing existing scalar hierarchy or SPICE
semantics outside the required child-extraction boundary.

## Proposed data model and public API

Add `src/nimcir/netlist/multipart.nim`, exported by `src/nimcir/netlist.nim`.
Keep the persistent registry field and reference-safe clone support in
`src/nimcir/netlist/types.nim`; keep every mutation in
`src/nimcir/netlist/graph.nim`.

The exact field spelling may be refined during implementation, but the public
model should have these concepts:

```nim
type
  PackageUnitKind* = enum
    pukFunctional, pukGlobalPins

  PackageUnit* = ref object
    name*: string                 # e.g. "A", "B", "PWR"
    kind*: PackageUnitKind
    component*: Component         # existing concrete component
    pins*: OrderedTable[string, Pin] # populated for pukGlobalPins only

  MultipartPackage* = ref object
    designator*: string           # physical-package identity, e.g. "U1"
    partNumber*: string
    units*: OrderedTable[string, PackageUnit]

# Stored only on root Netlist:
# Netlist.packages*: OrderedTable[string, MultipartPackage]
```

A functional unit points at its concrete component. The global-pin gate is a
separate `PackageUnit` with `kind == pukGlobalPins`; it owns a named map of
existing pins. That makes the shared-pin declaration explicit without adding a
fake component to the electrical graph. A global-gate pin may be unconnected;
its `Pin.net == nil` remains the ordinary graph fact validation sees.

Provide root-oriented graph APIs along these lines:

- `addPackage(root, designator, partNumber = ""): MultipartPackage`
- `addPackageUnit(pkg, name, component): PackageUnit`
- `addPackageGlobalPinGate(pkg, name, pins: openArray[(string, Pin)]):
  PackageUnit`
- `findPackage(root, designator): MultipartPackage`
- `packageOf(component): MultipartPackage` and `packageUnits(pkg)` lookup
  helpers, without forcing callers to search raw tables;
- `validatePackages(root): seq[Issue]` for package-structure/completeness
  findings only; and
- `packageGlobalPinsFor(child): seq[(package, gate, pinName, pin)]`, resolving
  members against the root and returning a deterministic package/gate/pin
  order for extraction.

`addPackage*` and `addPackageUnit` must verify that the supplied root is
`root(component.netlist)`, that a component is not assigned twice, that unit
names are unique, and that a global gate occurs exactly once. APIs accept
references rather than hierarchical strings so a rename or flatten-like
transform cannot silently retarget membership. Diagnostics should include the
package designator, unit/gate name, and both conflicting component paths where
available.

`validatePackages` should only diagnose structural facts: unknown/duplicate
unit identity (defensively, for imported/programmatic graphs), a declared
functional unit not assigned, no global-pin gate, a gate that names a pin not
owned by its declared component, and cross-root/stale references. It must not
inspect `Pin.net` to produce a package-completeness finding. Generic
connectivity validation remains responsible for unconnected pins according to
pin kind and existing policy.

## Authoring surface

Extend `src/nimcir/netlist/dsl.nim` after the graph API exists. Use a
root-level `package` statement that declares a physical identity and registers
already-created concrete units by their bound component names or explicit
hierarchical lookup. Use an explicit `globalPins` gate block rather than
special-casing pin names:

```nim
package U1, partNumber = "74HC00":
  unit A, childA.UA
  unit B, childB.UB
  globalPins PWR, childA.UPWR:
    pin "VCC"
    pin "GND"
```

The final grammar should permit references to units in concrete child
netlists, including a runtime graph-building alternative for file readers,
but must retain these semantic boundaries:

- `unit` always means a functional unit; `globalPins` is the only global-pin
  gate declaration.
- `globalPins` identifies existing pins and does not connect them. A pin may
  have no net at authoring time.
- The macro expands only to `multipart`/`graph` APIs; it must not set package
  maps, `Pin.net`, parent links, or child links directly.
- Duplicate unit/gate declarations are rejected by the same runtime graph
  checks as programmatic construction; statically obvious DSL duplicates may
  additionally receive macro diagnostics.
- Existing `netlist`, `subckt`, `instance`, component, and pin syntax remains
  unchanged. Multipart syntax is opt-in.

Before implementation, settle whether package declarations are accepted only
at root `netlist` scope (preferred) or are parsed in a child and explicitly
registered on `root(nl)`. The implementation must not permit a detached
subckt template to own a package registry, because its later instances would
make package identity ambiguous.

## Child extraction and simulation boundary

Extend `src/nimcir/spice/extract.nim` rather than teaching ordinary hierarchy
or SPICE serialization about package semantics.

1. Make `extractInstance` able to receive the source/root context (or add a
   clearly named multipart-aware overload). The existing overload remains
   source-compatible for packages-free callers.
2. After cloning the requested child, find packages at the original root with
   at least one functional member in that child subtree.
3. For each applicable global-gate pin, add a deterministic, collision-checked
   boundary port to the extracted child. The port name must contain the
   package designator, gate name, and pin name (for example
   `U1.PWR.VCC`), rather than relying on a local pin name that could collide
   across packages.
4. Preserve an explicit mapping from the new boundary port to the original
   gate pin/net for the extraction caller. If the original global pin is
   disconnected, retain it as an unbound boundary port; do not manufacture a
   net connection merely to make a port exist.
5. Provide or reuse an explicit binding API for the extracted fragment. It
   must reject absent required bindings before a child-only simulation starts,
   naming all unbound package-global ports. A binding can attach a caller-made
   parent net or an explicitly stated `PortDrive`/stimulus through the existing
   boundary/harness mechanisms.
6. Do not call `harness` with root-derived drives and do not promote root nets
   as identity-shared globals. A root supply is context outside the extracted
   child and must be stated by the caller.

This work should compose with `spice/boundary.asSubcircuit` and `harness`:
ports remain ordinary `Netlist.ports`, and existing `PortDrive` choices retain
their meaning. The multipart-aware extraction API owns the stricter
"bindings required" check; ordinary connector-derived subcircuits continue to
permit an intentionally open port as they do today.

## SPICE and transform behavior

Changes are limited and deliberate:

- `src/nimcir/netlist/formats/spice.nim`: do not serialize `packages` or
  recreate them while reading. Keep current component/pin/net and subcircuit
  behavior. Add regression coverage proving the emitted/reparsed circuit is
  electrically equivalent while `packages.len == 0` after parse.
- `src/nimcir/spice/flatten.nim`: package metadata must not affect flattening
  or cause a synthetic component/net. Simulation flattening acts on the
  concrete graph as today. If a work clone needs package lookup before
  extraction, clone/remap metadata references before flattening; once the
  graph is flattened, package metadata is allowed to be dropped from the
  simulation work copy because it has no electrical meaning.
- `src/nimcir/netlist/graph.nim` `clone`: clone package registry only when
  cloning a complete root and remap every `Component`/`Pin` reference to the
  new graph. Cloning a child in isolation must not carry a misleading partial
  root registry; multipart-aware extraction supplies only the derived boundary
  information it needs.
- `src/nimcir/spice/transform.nim`, models, isolation, and ngspice deck
  execution need no package-specific electrical model. They operate on the
  explicit ports/bindings and concrete components produced above.

## Implementation sequence

1. **Document invariants and choose names.** Finalize the root-only registry,
   gate naming, deterministic port naming, and the multipart-aware extraction
   API before adding DSL syntax. Record these in `netlist/CLAUDE.md` and
   `spice/CLAUDE.md` with the clone/extraction ownership rules.
2. **Core persistence.** Add types and the root package registry; implement
   safe construction, lookup, duplicate/cross-root rejection, and package
   structural validation in `multipart.nim`/`graph.nim`.
3. **Lifecycle correctness.** Update `clone` to remap root package references;
   add explicit behavior for cloning a child alone; verify remove/rename
   operations either reject removal of registered components/pins or remove
   membership through one graph-owned cleanup path. Do not leave dangling
   metadata references.
4. **DSL.** Add root-level package/global-gate syntax that calls the new APIs,
   with useful compile-time syntax errors and runtime graph diagnostics.
5. **Validation integration.** Invoke `validatePackages` from the normal
   design-readiness/validation aggregation at the appropriate netlist layer.
   Keep generic pin connectivity separate; do not add a special
   "package-global-pin-unconnected" issue kind.
6. **Extraction/binding.** Implement package-global boundary-port derivation,
   explicit binding enforcement, and child-only simulation preparation in
   `spice/extract.nim` (and `boundary.nim` only if a small shared binding helper
   is genuinely needed).
7. **SPICE lifecycle.** Confirm writer/readers ignore metadata intentionally,
   retain electrical hierarchy behavior, and ensure clone/flatten work copies
   cannot retain stale package references.
8. **Documentation and regression sweep.** Update authoring documentation and
   module guidance only for the finalized syntax/API; run focused checks and
   preserve existing package-free tests unchanged.

## Affected paths

Primary planned changes:

- `src/nimcir/netlist/types.nim` — root registry storage and persistent types
  if they must be visible to the core graph.
- `src/nimcir/netlist/multipart.nim` — package types, lookup, structural
  validation, root/subtree resolution, and public package API.
- `src/nimcir/netlist/graph.nim` — graph-owned registration/removal/clone
  remapping and root ownership checks.
- `src/nimcir/netlist.nim` — export the multipart API.
- `src/nimcir/netlist/dsl.nim` — root package/unit/global-pin-gate authoring.
- `src/nimcir/netlist/formats/spice.nim` — explicit non-persistence contract
  tests; no metadata encoding.
- `src/nimcir/spice/extract.nim` — child extraction that derives package-global
  boundary ports and binding requirements.
- Potentially `src/nimcir/spice/boundary.nim` — a narrowly shared explicit
  port-binding helper, only if `extract.nim` cannot use its existing API
  without duplicating validation.
- `src/nimcir/spice/flatten.nim` and `src/nimcir/spice/transform.nim` — only
  lifecycle guards/tests needed to avoid stale metadata; no package model.
- `src/nimcir/verify.nim` or the existing validation aggregation point — add
  package-structure findings without conflating them with connectivity.
- `docs/authoring.md`, `src/nimcir/netlist/CLAUDE.md`, and
  `src/nimcir/spice/CLAUDE.md` — finalized API and invariants.

## Compatibility

Existing flat netlists, subcircuits, positional/named instances, clone,
flatten, extraction, SPICE decks, and analysis APIs keep their meaning.
`Netlist.packages` is empty for all existing designs. The new DSL is opt-in.

SPICE is intentionally lossy for this feature: importing a SPICE deck creates
a valid electrically equivalent netlist with no multipart registry. Consumers
that need physical-package intent must keep the original Nim/netlist source;
they cannot depend on a SPICE round trip preserving it.

No dependency direction changes are allowed: multipart core code stays under
`netlist`; `spice` consumes it for extraction only; `analysis`, PCB, contract,
and schematic must not become prerequisites for package registration. Use only
the Nim standard library and retain Nim 2.2.10 compatibility.

## Risks and mitigations

- **Dangling object references after clone/remove/flatten.** The registry holds
  direct `Component`/`Pin` references, so lifecycle operations must remap or
  reject cleanup atomically. Centralize every mutation in graph APIs and test
  clone/remove paths.
- **Ambiguous child membership.** A package may span descendants, so detect
  membership by object/root ancestry, not designator spelling or a fragile
  hierarchical-name string.
- **Accidentally energizing a fragment.** Root-level power is not an implicit
  simulation fixture. Require explicit child boundary bindings and test that
  a missing one fails before ngspice receives a deck.
- **Wrong diagnostic category.** Keep `validatePackages` structural. Reuse
  normal pin validation for disconnected global pins so users do not see two
  errors for one electrical fact.
- **Port-name collisions and instability.** Derive names from package, gate,
  and pin identifiers; reject collisions deterministically and never use a
  generated logic value to resolve them.
- **SPICE metadata illusion.** Do not write comments or pseudo-devices that
  appear to preserve package data but fail on another reader. State and test
  intentional metadata loss.

## Concrete test plan

Add focused tests; do not require ngspice except for a narrow optional
simulation smoke test where the toolchain is available.

### `tests/test_netlist_multipart.nim` (new)

1. Build one root with two concrete children, register `U1.A` in one and
   `U1.B` in the other, add `U1.PWR` as the explicit global-pin gate, and
   verify root lookup, direct references, deterministic unit order, and
   root/subtree discovery.
2. Verify a package may also contain a root-level concrete unit, while a
   component from another root is rejected.
3. Verify duplicate functional-unit assignment, duplicate global-gate
   declaration, duplicate gate pin name, and reusing a component for a second
   package/unit all raise `NetlistError` with identifying context.
4. Verify package structural validation flags a missing declared functional
   assignment and a missing gate, but does **not** issue a package finding when
   a global-gate pin has `net == nil`.
5. Run existing/general pin-connectivity validation over the same disconnected
   pin and verify its ordinary connectivity result (or documented absence for
   that pin kind), with no multipart-specific duplicate.
6. Clone a root package graph and prove every package member/gate pin points
   at the clone's objects, not originals; clone one child alone and prove it
   does not retain a partial root package registry.
7. Exercise component/pin removal or replacement after registration and prove
   the selected lifecycle contract rejects it or cleans package membership
   without stale references.

### `tests/test_netlist_dsl.nim`

8. Author a package from DSL with units in two instantiated children and an
   explicit `globalPins` block; verify it produces exactly the programmatic
   graph above.
9. Verify DSL rejects malformed/missing gate syntax and duplicate visible unit
   declarations, while existing package-free DSL fixtures compile unchanged.

### `tests/test_netlist_spice.nim`

10. Build an electrically connected multipart graph, render it, parse it, and
    compare the relevant hierarchical component pins/nets and deck lines.
    Verify the reparsed root has no package metadata. This is the required
    electrical-preservation/metadata-loss round trip.
11. Verify a disconnected global gate pin does not cause writer-created nodes,
    synthetic devices, or a package annotation in the deck.

### `tests/test_spice_extract.nim` and `tests/test_spice_boundary.nim`

12. Extract a child containing one functional unit from a package whose gate
    lives elsewhere. Verify all applicable global pins appear as deterministic
    boundary ports, including an originally disconnected pin.
13. Verify a child with no package member gains no multipart ports; verify
    multiple packages/gates with the same local pin name do not collide.
14. Verify child-only simulation preparation rejects every missing required
    package-global binding and lists its port names. Bind each port explicitly
    to caller-provided nets/drives and verify no root driver or guessed logic
    level/source appears.
15. Verify an explicit open binding remains an explicit caller decision (and
    follows the existing harness semantics), rather than being silently
    substituted by a root net or default stimulus.

### Regression checks

16. Run the focused core, DSL, SPICE-format, extraction, boundary, flatten,
    and validation test files. Then run `nimble test` and inspect its output
    using the repository-required failure scan. Existing hierarchy, flatten,
    connector-boundary, and SPICE tests must remain unchanged unless a test is
    specifically extended to assert the new opt-in behavior.
