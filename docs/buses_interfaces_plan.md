# Buses and interfaces feature plan

> **Status:** approved implementation plan. This document proposes work; it does
> not claim that any of the described API or behaviour is implemented.

## Goals and approval decisions

The netlist DSL will gain first-class *authoring notation* for bundles of
scalar nets and for named, reusable interface shapes. The graph and all
backends will still operate on scalar nets and pins.

The approved decisions are:

- A bus of width `N` expands to scalar nets named `data[0]` through
  `data[N - 1]`; index zero is the first/lowest declared member.
- An interface may contain scalar ports, buses, and nested interface ports.
  Every interface-port declaration is explicitly `input`, `output`, or
  `inout`, and its direction is stated **relative to the child** that exposes
  it (not relative to the parent wiring it).
- Instances accept complete or partial mappings. A mapping may select an
  individual leaf or same-width slices of buses. Unmapped leaves are legal.
- A bus value exposed to ordinary Nim code is a normal `seq[Net]` or fixed
  `array[N, Net]` as appropriate, not a new vector type. Consequently, a
  copied/reordered/sliced collection has no retained bus-name, direction, or
  interface-path metadata; that metadata belongs only to declarations and
  expanded scalar graph objects.
- Width zero is invalid everywhere it can be declared or selected. Reject it
  at macro expansion when statically knowable, otherwise before graph
  mutation with a useful `NetlistError`.
- Interfaces and buses lower completely to scalar `Net`, `Pin`, `ports`, and
  `hierNet` relationships. Existing consumers need not become bus-aware.
- When producing a SPICE deck, each unmapped interface leaf may be assigned a
  distinct generated open node so leaves cannot accidentally short together.
  Pruning an unmapped leaf instead is also an acceptable implementation-time
  choice, provided it cannot create a connection or alter mapped leaves.

## Proposed API and DSL

The exact macro spelling should follow the existing `netlist`/`subckt` style.
The proposed public vocabulary is `bus`, `interface`, and directional
interface members:

```nim
interface I2c:
  inout sda
  input scl

interface ChildPorts:
  input enable
  output data[8]
  inout i2c: I2c

let CHILD = subckt("child", ChildPorts):
  # `enable`, `data`, `i2c.sda`, and `i2c.scl` name child-side leaves.
  # A `bus` declaration creates ordinary scalar Nets `data[0]` ... `data[7]`.
  bus data[8]
  net enable
  net i2c.sda
  net i2c.scl
  # components use these scalar nets as they do today

let top = netlist("top"):
  bus hostData[8]
  net enable
  net sda
  instance X1, CHILD, {
    "enable": enable,
    "data[0..3]": hostData[4..7],
    "i2c.sda": sda
  }
```

Implementation may refine superficial syntax (for example, whether bus
members are declared by the interface alone rather than repeated in the
`subckt` body), but must preserve these semantics:

1. A bus declaration binds a usable normal Nim collection of its scalar
   `Net` values in index order and creates graph names with bracketed indexes.
   `data[0]` in DSL paths always means the scalar net with that literal name,
   not a hierarchy separator or a new graph node kind.
2. An `interface` is a reusable, ordered declaration schema. Nested members
   form leaf paths such as `i2c.sda`; buses form paths such as `data[3]`.
   Declaration order is the canonical deterministic leaf order.
3. A subcircuit using an interface exposes one scalar port per leaf, with the
   declared child-relative `PinType` (`ptInput`, `ptOutput`, or `ptInOut`).
   Existing positional subcircuit port lists remain supported for compatibility;
   interface instances use named leaf mappings.
4. A mapping key may be a leaf path or an inclusive bus slice (`[lo..hi]`).
   The value may be the matching scalar net or a normal Nim collection/slice
   of nets. Both sides must be non-empty and the same width. Mapping order is
   index order; reversed/strided slice semantics are not part of this feature.
5. Omitted leaves create no parent-side electrical connection. They remain
   distinguishable leaf ports in the child hierarchy so diagnostics and
   lowering can identify which leaf was omitted.

The implementation should expose a small graph-level schema/expansion API,
not require consumers to inspect macro ASTs. Likely additions include an
interface-definition type, flattened leaf descriptors (path, direction, and
scalar net), validation/expansion helpers, and an interface-aware
instantiation entry point. The DSL must expand exclusively through those graph
APIs, consistent with the existing DSL rule against hand-maintaining graph
back-references.

## Invariants

- Scalar graph integrity remains owned by `netlist/graph.nim`: all created
  nets, pins, hierarchy links, and connections use its mutation procedures.
- Bracketed bus names are ordinary unique `Netlist.nets` keys. They must work
  with `findNet`, flattening, cloning, annotations, and writers unchanged.
- An interface leaf path is unique after nested expansion. Duplicate member
  names, duplicate expanded paths, unknown mapping keys, duplicate mappings,
  width mismatches, and invalid slices are errors.
- Direction is descriptive interface metadata and is never inverted merely
  because wiring is viewed from the parent. It must survive template cloning
  and be assigned to the corresponding child-exposed scalar pins.
- Partial wiring never aliases omitted leaves to each other or to a mapped
  leaf. This is especially important during flattening and SPICE lowering.
- Flattening merges only mapped parent/child leaf nets. It preserves the
  existing `hierNet` navigation for every exposed scalar leaf until flattening.
- Collections are convenience values only. Code must not infer interface
  membership or direction from an arbitrary `seq[Net]`/`array`; use the schema
  or scalar leaf descriptors when metadata is required.
- No zero-width bus, interface expansion, slice, or mapping reaches the
  graph or backend.

## Affected files

Planned primary changes:

- `src/nimcir/netlist/types.nim` — interface schema/leaf metadata types, if
  persistent metadata belongs in the core model.
- `src/nimcir/netlist/graph.nim` — validated scalar expansion and
  interface-aware partial instantiation while retaining ownership of all graph
  mutation.
- `src/nimcir/netlist/dsl.nim` — `bus`, `interface`, directional declarations,
  and named partial/slice mapping macro parsing and diagnostics.
- `src/nimcir/spice/flatten.nim` — ensure only mapped leaves merge and that
  unconnected interface leaves remain distinct through lowering.
- `src/nimcir/netlist/formats/spice.nim` and/or the SPICE lowering path — emit
  distinct generated open nodes for unmapped leaves, or deliberately prune
  them under the approved alternative.
- `tests/test_netlist_core.nim` and `tests/test_netlist_dsl.nim` — core and DSL
  coverage.
- `tests/test_netlist_spice.nim` — scalarized hierarchy/deck coverage.

No change is planned to the public meaning of existing scalar `net`,
`subckt`, positional `instance`, or ordinary component pin declarations.
Other formats, schematic rendering, PCB, contract, and analysis are not in
scope unless scalar lowering exposes a concrete regression.

## Concrete test plan

Add focused tests covering:

1. A width-4 `data` bus creates exactly `data[0]` through `data[3]`, binds an
   index-ordered normal Nim collection, and can be found by its scalar names.
2. Bus declarations reject width zero (both literal and dynamic-width paths);
   empty/reversed/out-of-range slices and zero-width mappings also fail before
   partial graph construction.
3. A nested interface expands deterministically to all expected leaf paths;
   `input`, `output`, and `inout` directions are represented relative to the
   child on the instance/child scalar pins.
4. A clone and a nested instance retain leaf paths, directions, and independent
   per-instance scalar net/pin objects just as existing subcircuits do.
5. Full named mapping connects every leaf; a partial mapping connects only the
   stated scalar leaves and leaves all other child-side leaves unconnected from
   the parent.
6. Single-leaf mappings and `data[0..3]` to `hostData[4..7]` mappings connect
   index-for-index. Width mismatch, unknown path, duplicate mapping, and
   mapping a scalar to a multi-leaf slice fail with actionable diagnostics.
7. Passing arrays/sequences, including copied or reordered ones, works as a
   collection of nets but does not invent or preserve interface metadata.
8. Flattening a partially mapped nested interface merges mapped leaves only;
   unmapped leaves do not become mutually connected.
9. SPICE output for partial mappings either contains distinct generated nodes
   for every retained unmapped leaf or omits those leaves through the selected
   pruning policy; in either case the deck contains no accidental shared open
   node and mapped scalar node names/connections remain correct.
10. Existing scalar hierarchy, positional instances, named scalar mappings,
    clone, flatten, and SPICE tests continue to pass unchanged.

## Risks and non-goals

**Risks:** Macro parsing must distinguish Nim indexing/slicing from literal
bracketed scalar net names without weakening current DSL diagnostics. Nested
path and slice expansion can create confusing errors, so validation should
report the interface name, instance, offending path, and expected leaf set or
width. Persisting metadata across clone/flatten must not break direct object
reference invariants. SPICE has no native open-interface concept; generated
nodes must be unique and deterministic if that alternative is chosen.

**Non-goals:** This plan does not introduce vector-valued electrical nets,
bus-level connectivity objects, automatic bus-name inference, implicit width
conversion, bit reversal, strided slices, protocol semantics, direction/ERC
checking beyond recording declared pin types, or support for non-SPICE file
format round-tripping of interface metadata. It also does not promise that an
arbitrary Nim `seq`/`array` can recover bus/interface metadata after it has
been copied, transformed, or reordered.

## Implementation approval boundary

Implementation is approved only for the scalar-lowering buses-and-interfaces
scope above. Before coding, choose and document the precise surface syntax and
the SPICE treatment of unmapped leaves (unique generated open nodes or safe
pruning), then implement the corresponding tests. Do not broaden the feature
into vector simulation, interface protocol validation, or changes in unrelated
subsystems.
