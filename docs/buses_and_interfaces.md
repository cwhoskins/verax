# Buses and interfaces implementation plan

> **Status:** approved implementation plan. This document specifies planned work only; it does not
> claim that buses or interfaces are implemented. It consolidates and replaces two earlier drafts,
> `docs/buses_and_interfaces.md` and `docs/buses_interfaces_plan.md`, which were written
> independently of each other and are recoverable from git history at commit `aef9865`.

## Context

A netlist today has exactly one wiring primitive: the scalar `Net`. Anything with more than one wire
is written out a wire at a time, and the grouping exists only in the author's head and in comments —
`designs/xbar_control.nim:52` literally says `# RMII between MCU and PHY -- carried as ports, not
simulated`, because there is no way to say it in the language. Three costs follow:

1. **Repetition at the port boundary.** A `subckt` port list is one identifier per wire, and an
   `instance` is one net per wire in the same order. An 8-bit bus is 8 chances to transpose two.
2. **Direction is unstated almost everywhere.** `Pin.kind` carries `ptInput`/`ptOutput`/`ptInOut`,
   but `graph.instantiate` (`src/verax/netlist/graph.nim:451`) creates every hierarchical instance
   pin as `newPin(portName)` — `ptUnknown`. Five consumers read direction and get nothing:
   `analysis/io_check`, `schematic/placement.portDirection`, `schematic/symbols`,
   `spice/models/pin_models.byKind`, `formats/spice.pinTemplates`.
3. **A shared bus is indistinguishable from a fault.** `analysis/io_check.nim:49` warns on any net
   with two driver-capable pins, and its own docstring names I2C as the case it cannot resolve.
   `designs/i2c_eeprom.nim` emits two unavoidable false `output_conflict` warnings today.
   Symmetrically, `contract/evaluators/static.nim:9` refuses `controller_count` outright — "every
   device on an I2C bus has an inout data pin, and nothing in a netlist distinguishes the controller
   from a target".

A **bus** (an ordered array of nets) fixes 1. An **interface** (a named dict of nets) plus a
**modport** (a per-side direction view, SystemVerilog's word for it) fixes 2 and 3: the same two
wires are an output and an inout seen from an I2C controller, and an input and an inout seen from a
target, and *that* is the fact none of the five consumers can currently be told.

The intended outcome: an author writes the bundle once, wires it once per device with the side it
plays, and the library lowers it to exactly the scalar nets and ports the deck already understands —
while keeping enough recorded to check direction and to stop lying about open-drain buses.

## Provenance

Two drafts existed. The **structural** draft was written top-down from a spec ideal; the
**diagnostic** draft was written bottom-up from the three costs above, each anchored to a line. This
plan takes the diagnostic draft as its spine and imports four things from the structural one. Two
differences decided the spine, and both are worth keeping recorded because they will come up again.

**Net naming.** The structural draft named bus members `data[0]`. There is **no net-name
sanitization anywhere** in `netlist/` or `spice/` — a net name reaches the deck verbatim, and
`probes.nim:38` builds `"v(" & net.name & ")"` verbatim. ngspice already reads `[...]` as parameter
access, which `ngspice.nim:294` itself relies on (`i(@r1[i])`). So `data[0]` yields the probe
expression `v(data[0])`, which ngspice misparses, and fixing it means a permanent name-mangling
layer between graph names and deck names. `data_0` costs nothing and needs no such layer. It also
dissolves that draft's own stated hardest problem — "must distinguish Nim indexing/slicing from
literal bracketed scalar net names" — because brackets then never appear in a net name at all.

**What direction is for.** The structural draft's non-goals excluded "direction/ERC checking beyond
recording declared pin types," so it paid the full cost of declaring direction and collected none of
the return: the two false `output_conflict` warnings stay and `controller_count` keeps refusing.
Those are the motivating complaints, and the `shared` flag plus modports is precisely the
information `PinType` cannot carry — which is what both call sites say they are missing.

Imported from the structural draft: **zero-width rejection**, **slice mappings**, **an explicit
policy for unwired ports**, and **the flatten non-aliasing invariant**. Its nested interfaces
(`inout i2c: I2c` inside another interface) are deferred — the most expensive part of its macro work
and not needed by i2c, spi or uart.

## Fixed decisions

1. **Buses and interfaces are authoring constructs that lower entirely to scalar `Net`, `Pin` and
   `ports`.** Nothing new reaches a SPICE deck; `formats/spice.nim` is untouched. A bus port is N
   ordinary port names in index order, and `Netlist.ports` iteration order remains the positional
   contract with `formatInstanceLine`.
2. **No new fields on `netlist/types.nim`.** Membership and direction are recorded in the existing
   `attrs` bags under an owned `iface.*` / `bus.*` namespace, following the rule in
   `netlist/CLAUDE.md` that bare means registered and dotted means owned. This is the
   `environment.nim` precedent exactly: `attrs` are copied wholesale by `graph.clone`
   (`graph.nim:378,385,398`), so membership survives `clone`, `instantiate`, `flatten`,
   `extractSubcircuit` and `isolate` for free, whereas a new `Netlist` field would have to be added
   to `clone` by hand and a side-car table keyed by name would break at the first `renameNet`.
3. **`Bus` and `Interface` are *views*, reconstructible from the graph.** `findBus(nl, "dq")`
   rebuilds one by scanning nets for `bus.name`, ordered by `bus.index`. Object identity is never
   the source of truth, so a view survives a rename and a clone. A copied, sliced or reordered `Bus`
   value therefore carries **no authority** — membership is what the `bus.*` attrs say, and
   `findBus` is the way to ask.
4. **Member nets are named with an underscore**: `dq_0 .. dq_7`, `i2c0_scl`, `i2c0_sda`,
   `spi0_cs_2`; an interface array is `ports_0_sda`. Authoring is `dq[0]` and `i2c0["sda"]`, so the
   ugly spelling is confined to decks, schematics and reports. `[` is refused for the reason in
   Provenance; `.` is refused because it is `graph.hierSep`, so `XA.dq.0` would be indistinguishable
   from net `0` in child `dq` of `XA`. A collision with a hand-authored `dq_0` raises in `addNet`,
   loudly, which is the correct failure. **A width-1 signal is unsuffixed** (`spi_cs`, not
   `spi_cs_0`), matching `SignalDef.width == 1` meaning scalar; only width > 1 suffixes.
5. **Direction is stated relative to the side declaring it**, exactly as a SystemVerilog modport is,
   and is carried as the existing `PinType`. No new direction enum. `ptInOut` *is* bidirectional.
6. **A modport may expose a subset of the interface's signals.** An omitted signal is one that side
   does not see. A modport naming a signal the interface does not declare is an error.
7. **A signal may be declared `shared`** (open-drain / multi-drop). This is the one piece of
   information `PinType` cannot carry — `io_check` says so — and it is what lets a declared I2C bus
   stop producing a false conflict warning without blinding the check to a real one.
8. **The DSL statement is `iface`, not `interface`**: `interface` is a reserved Nim keyword.
9. **Width ≤ 0 is rejected** — at macro expansion when the width is a literal, in `addBus`
   otherwise, with a `NetlistError` naming the bus.

Non-goals: protocol *semantics* (no timing, no arbitration, no transaction modelling), nested
interfaces, bus glyphs in the schematic renderer, recovering a bus from a read-back SPICE deck, and
any change to what a deck contains.

## Data model — `src/verax/netlist/interfaces.nim` (new)

One new module, importing `types`, `graph`, `annotations`, `issue`; imported by `netlist/dsl.nim`.
It sits above `graph` and below `dsl`, and adds no edge out of the `netlist` submodule.

```nim
type
  Bus* = object
    name*: string
    nets*: seq[Net]          ## index order; index i is `nets[i]`

  SignalDef* = object
    name*: string
    width*: int              ## 1 = scalar, and its port is unsuffixed
    shared*: bool            ## open-drain / multi-drop; see decision 7
    doc*: string

  Modport* = object
    name*: string
    dirs*: OrderedTable[string, PinType]   ## signal -> direction from this side
    controller*: bool        ## this side is the one that drives the bus

  RoleClaim* = object        ## see "Roles implied by an interface"
    role*: string                          ## a contract role name; netlist never resolves it
    binds*: OrderedTable[string, string]   ## role part -> interface signal, or a modport name
    params*: OrderedTable[string, string]

  InterfaceDef* = object
    name*: string
    doc*: string
    signals*: seq[SignalDef]               ## declaration order IS port order
    modports*: OrderedTable[string, Modport]
    implies*: seq[RoleClaim]

  Interface* = object                      ## a realized instance
    def*: InterfaceDef
    name*: string
    signals*: OrderedTable[string, Bus]    ## a scalar is a width-1 Bus

  InterfaceView* = object                  ## an Interface seen through a Modport
    iface*: Interface
    modport*: string
```

Public API (exact spelling may be refined; the concepts are fixed):

- Registry, same shape as `roleRegistry` (`contract/roles/core.nim:96`) and the annotation registry:
  `registerInterfaceDef`, `interfaceDefOf(name)`, `registeredInterfaceDefs()`. Re-registering a name
  replaces it, and that is the documented override path. Registration validates: no duplicate
  signal, `width >= 1`, every modport signal declared.
- Construction: `addBus(nl, name, width, kind = ntSignal): Bus`,
  `busOf(nl, name, nets: openArray[Net]): Bus` (group nets that already exist),
  `addInterface(nl, name, def): Interface`, `addInterfaceArray(nl, name, def, count): seq[Interface]`.
- Access: `` `[]`(b: Bus, i: int): Net ``, `` `[]`(b: Bus, s: HSlice): seq[Net] ``,
  `` `[]`(i: Interface, signal: string): Net `` (raises on a wide signal, naming it),
  `bus(i: Interface, signal: string): Bus`, `len`, `view(i, modport)` and the DSL-facing
  `` `.`(i: Interface, modport) `` sugar if it can be made unambiguous — otherwise
  `view(i2c0, "target")` only.
- Recovery: `findBus(nl, name): Bus`, `findInterface(nl, name): Interface`, `interfacesOf(nl)`.
- Wiring: `connectPort(c: Component, v: InterfaceView, pins: openArray[(string,string)] = [],
  prefix = "")` — one `graph.connect` per exposed signal, with the modport's `PinType`.
- Ports: `addPorts(nl, label, x)` overloaded on `Net` / `Bus` / `Interface` / `InterfaceView`.
- Lowering helpers used by the DSL: `netsOf(x)` and `wiringOf(label, x)`, each overloaded on `Net`,
  `seq[Net]`, `openArray[Net]`, `Bus`, `Interface` and `InterfaceView`; `promotePortDirections(inst:
  Component)`.
- ERC: `validateInterfaces(nl, recursive = true): seq[Issue]`.
- Rendering for the catalog: `$`(InterfaceDef) and `describeInterfaceDef`.

### What gets recorded, and where

| entity | key | value |
| --- | --- | --- |
| member `Net` | `bus.name`, `bus.index`, `bus.width` | bus membership and order |
| member `Net` | `iface.instance`, `iface.def`, `iface.signal` | interface membership |
| member `Net` | `iface.shared` | `"1"` when the signal is open-drain |
| port `Net` | `iface.dir` | the child-relative `PinType`, so `promotePortDirections` can set the instance pin |
| generated no-connect `Net` | `iface.nc` | `"1"` when created by an `open` token |
| `Pin` | `iface.instance`, `iface.signal`, `iface.modport` | which side this pin plays |

All dotted, so `annotations.isNamespaced` short-circuits every check and no registry change is
needed. The cost, stated plainly: a typo in one of these keys is invisible, exactly as
`netlist/CLAUDE.md` warns. They are written only by this module, never by hand in a design.

## Authoring surface

Definition — a top-level macro returning a value, shaped like `subckt`:

```nim
let I2C = interfaceDef("i2c"):
  signal scl, shared = true
  signal sda, shared = true
  modport controller, controller = true:
    scl = ptOutput
    sda = ptInOut
  modport target:
    scl = ptInput
    sda = ptInOut
  implies "i2c"
```

A **parameterized** interface is an ordinary proc returning an `InterfaceDef`, the same trick
`designs/lib/filters.nim` uses for subcircuits — `proc spiInterface(nCs = 1): InterfaceDef` with
`signal cs, width = nCs`. No macro support is needed for it.

Inside a `netlist`/`subckt`/`design` body:

```nim
bus dq, width = 8                 # nets dq_0 .. dq_7,   dq[3] is a Net
bus addr, nets = [a0, a1, a2]     # group nets that already exist
iface i2c0, I2C                   # nets i2c0_scl, i2c0_sda
iface chans, I2C, count = 4       # seq[Interface]; chans[2]["sda"] is net chans_2_sda

component U1, kind = "mcu":
  port i2c0, controller           # pins SCL(ptOutput), SDA(ptInOut) -- named from the signals
  port dq, prefix = "D"           # a bus with no modport: pins D0..D7, ptUnknown
  pin "VDD", vdd, kind = ptPower

component U2, kind = "eeprom", partNumber = "M24C64":
  port i2c0, target, pins = {"scl": "SCL", "sda": "SDA"}
```

Exposing an interface as a subcircuit boundary, and wiring it:

```nim
let SENSOR = subckt("SENSOR", [vdd, gnd, i2c.target]):
  net vdd, kind = ntPower
  net gnd, kind = ntGround, name = "0"
  iface i2c, I2C
  component U9, kind = "sensor":
    port i2c, target
    ...
# ports: vdd, gnd, i2c_scl, i2c_sda -- the last two carry iface.dir = ptInput / ptInOut

instance X1, SENSOR, [vdd, gnd, i2c0]                        # positional: splices in signal order
instance X2, SENSOR, {"vdd": vdd, "gnd": gnd, "i2c": i2c0}   # by name: the group name
```

Semantic boundaries the grammar must keep:

- The **port group name is the interface instance name in the child**. That is the same rule a
  scalar port already follows, and it is what makes `{"i2c": i2c0}` resolvable: the value's
  `InterfaceDef` supplies the signal names, the key supplies the prefix, and the pair reconstructs
  the child's `i2c_scl` / `i2c_sda`.
- `port` inside a `component` takes an interface *or* a bare bus. With a modport it sets `Pin.kind`;
  without one it sets `ptUnknown` and records nothing about direction, because nothing was said.
- `bus` and `iface` bind a real Nim `let` from a bare identifier, exactly as `net` does
  (`dsl.nim:195-197`), so a typo stays a compile error.
- Both are legal inside the `for`/`if`/`case`/`when` control flow the dispatcher already recurses
  through, with the same consequence: the `let` is scoped to the branch, so address anything built
  there through `findBus`/`findInterface` afterwards.
- `role` and `require` remain rejected inside control flow, unchanged.

## Partial wiring: three cases, only one of which is an omission

The motivating example — a multi-peripheral SPI bus where a child sheet only cares about its own
chip select — is three separate problems, and conflating them is what made the structural draft
reach for generated open nodes as a blanket policy.

**Case 1 — a slice, not an omission.** The child exposes a width-1 `cs`; the parent holds
`bus cs, width = 4` and wires `cs[2]`. Every child port *is* mapped:

```nim
instance X1, SPI_PERIPH, {"spi": spi0, "cs": cs[2]}       # cs[2] is a Net
instance X2, WIDE_SLAVE, {"d": hostData[4..7]}            # a seq[Net]
```

Because brackets never appear in a net name, the slice lives entirely in Nim value space and the
macro never sees one. Implementation is overload arms on `netsOf`/`wiringOf` only — no macro work —
and `instantiate`'s existing arity check (`graph.nim:439`) already reports a width mismatch naming
the subcircuit.

When the slice is *one member of a wide signal inside an interface* — a memory owning one line of a
shared chip-select bus — `narrow` presents the whole interface with that signal cut to width 1:

```nim
instance X1, SPI_MEMORY, {"vdd": vdd, "gnd": gnd, "spi": spi1.narrow("cs", 0)}
```

`spi1.narrow("cs", 0)` is a pure value-space copy (it never touches the netlist or the registry, so
it survives `clone`); `wiringOf(label, Interface)` then member-suffixes each signal — `spi_sclk`,
`spi_mosi`, `spi_miso`, `spi_cs` — onto the child's port list. `spi1["cs", 0]` is the same member
as a bare `Net`. `designs/spi_memories.nim` is the worked example.

**Case 2 — an optional signal is a modport, not an omission.** A write-only display with no MISO, or
a device that ignores a reset line, is a property of that *side*, not of that instance site.
Decision 6 covers it: define `peripheral_wo` without `miso` and the child's port list simply lacks
it. Prefer this over per-instance omission every time — it is declared once, validated at
registration, reusable, and cannot be got wrong two different ways at two instance sites.

**Case 3 — the only true no-connect.** The child has the pin and nothing above connects to it at
this site (an interrupt output nobody listens to). A *silently* missing key stays an **error**; the
fix is one token:

```nim
instance X3, SENSOR, {"spi": spi0, "cs": cs[1], "irq": open}
```

The reason is specific to this codebase rather than general strictness: the by-name `instance` form
exists *because* of miswiring — `dsl.nim:400-405` records that two boards routinely both call a port
`vin`, and swapping them "raises nothing and simulates happily." A form added to make a silent
wiring mistake impossible must not itself accept a silently missing key.

`open` lowers to a freshly generated unique net named `nc_<designator>_<port>`, **not** a pruned pin.
Two reasons: `instantiate` requires one net per port and `connect`s each (`graph.nim:449-453`), so
pruning would mean editing `graph.nim`, which this plan deliberately avoids; and a real net keeps the
pin visible to `io_check` and gives `flatten` an ordinary merge to do. The net carries `iface.nc` so
`validateInterfaces` does not fire `interface_signal_dangling` on a deliberate one.

The structural draft's non-aliasing worry turns out to be structurally impossible already:
`flatten.nim:70` merges per-pin off `hierNet` and only when `p.net != nil`, so unmapped leaves cannot
join each other. Keep its test anyway — it is cheap and it pins the property down.

## Lowering

`instance`'s positional port list changes from a macro-built `@[a, b, c]` to a runtime
`netsOf(a) & netsOf(b) & netsOf(c)`. For a list of plain `Net`s that is the identical seq, so every
existing design is unaffected; for a `Bus` or `Interface` it splices in index/declaration order, and
a width that is only known at runtime therefore costs nothing. The by-name form becomes
`wiringOf("vdd", vdd) & wiringOf("i2c", i2c0)`. Both are pure overload resolution — the macro never
needs to know a width.

`handleInstance` additionally emits `promotePortDirections(<inst>)` after `instantiate`, which walks
the instance's pins and copies `pin.hierNet.attrs["iface.dir"]` onto `pin.kind`. It is a no-op for
every netlist that declares no interface, and it is the fix for the `ptUnknown` at `graph.nim:451`.
`graph.nim` itself is not modified.

## Direction checking

**`validateInterfaces`** returns `Issue`s and is hooked in beside `validateEnvironment` /
`validatePackages` at `verify.nim:247-249`, so it lands in the readiness report's STRUCTURE section
with no new plumbing:

| kind | severity | condition |
| --- | --- | --- |
| `interface_signal_undriven` | warning | a member net with an input-facing modport pin and no output- or inout-facing one |
| `interface_direction_conflict` | error | two or more `ptOutput` modport pins on one member net |
| `interface_no_controller` | warning | an instance whose def has a `controller` modport, but no pin plays it |
| `interface_signal_dangling` | warning | a member net with fewer than two pins, unless it carries `iface.nc` |
| `interface_modport_unknown` | error | a `port` statement naming a modport the def does not declare (raises at construction; reported here for a netlist built by other means) |

**`analysis/io_check.checkOutputConflicts` learns one exception**: when every driver-capable pin on a
net is `ptInOut`, and all of them carry the same `iface.instance`, and that signal is marked
`shared`, the warning is suppressed — an open-drain bus was declared, so the ambiguity its docstring
describes has been resolved. Two `ptOutput` pins still error, and an undeclared multi-driver net
still warns. This removes the two standing false warnings from `designs/i2c_eeprom.nim`.

Reading direction from `attrs` keeps `io_check` free of an import of `netlist/interfaces`; the two
keys it needs are read as raw strings, the same way `designs/lib/i2c_parts.nim` reads `i2c.analog`.

## Roles implied by an interface

`RoleDef.parts` and `InterfaceDef.signals` are the same vocabulary declared twice: the `i2c` role's
parts are `sda`, `scl`, `controller` (`roles/digital.nim`), and the i2c interface's signals plus its
controller modport are the same three names. Linking them only at the use site (`from = i2c0`, below)
still means knowing which role pairs with which interface and writing it per instance. Link them at
the *definition* as well.

**Carrying it across the layer.** `InterfaceDef` is in `netlist/`, `RoleDef` in `contract/`, and the
dependency may not run backwards. `RoleClaim` (see the data model) uses the same device
`Assertion.quantity` already uses — an open string naming something the declaring layer cannot see,
resolved at the far side. Inert data to `netlist`; `contract` reads it and raises on an unknown role
name. No new edge either way.

**Resolution point.** Not the `iface` statement — `buildNetlistBody` cannot tell a netlist from a
design (`contract/dsl.nim:425-441` splits the statements before calling it). Instead
`buildDesignBody` appends `addImpliedRoles(d)` after `trailing`, walking `interfacesOf(d.netlist)`
and adding one role instance per interface whose def carries `implies`, named for the interface
instance. Three consequences fall out with no extra rule:

- **Explicit wins.** `trailing` (the authored `role` statements) runs first, so `addImpliedRoles`
  skips any instance name already present, and `explain` shows which survived.
- **Control flow works.** An `iface` inside a `for` binds a branch-scoped `let`, but `interfacesOf`
  recovers every one.
- **`iface chans, I2C, count = 4` yields four role instances**, `chans_0 … chans_3`.

**Why this is not inventing a claim.** `contract/CLAUDE.md` rejects defaults that manufacture a claim
the designer never made — the stated reason `power_rail`'s `targetZ` adds nothing when omitted. The
distinction is who is speaking. A decoupling target is a design decision, so a default fabricates
one; the `i2c` role's four claims (a pull-up exists, the RC corner clears the clock, VOL is sinkable,
one controller) are true of every working I2C bus. They are what the protocol means, and
`iface i2c0, I2C` says it.

The safeguard is that **the definition decides, not the instance**: `implies` is where a definition
author asserts something unconditionally true of that shape, and a def without it adds nothing —
which is what every user-written def gets unless they opt in. An instance backs out through machinery
that already exists: `without` is reserved on every role, so `iface i2c0, I2C, without = "rc_corner"`
routes into `RoleInstance.declined` and `explain` prints the decline instead of going quiet.

**Two constraints to enforce.** A `RolePart` is a single `Subject`, so a **width > 1 signal cannot
bind one** — raise naming the signal rather than binding index 0; the case that wants it is one role
instance per link, which is the interface-array path. And add one optional field
**`RoleDef.expects: string`**, the interface def a role is written against, so
`role i2c, "u0", from = spi0` fails with one message naming both rather than a pile of unbound-part
errors — and so `verax role i2c` can print the interface and `verax interface i2c` the roles.

**The payoff** is `controller_count`: declaring the bus becomes enough, and the check
`static.nim:9-13` currently refuses to attempt starts working with no author action.

## Contract integration

Two further bounded changes, both aimed at the same gap:

1. **`contract/evaluators/static.nim` — `runControllerCount` gains a second source.** Today it can
   only count components bound to a role's `controller` part (`static.nim:279-317`). It additionally
   counts distinct components with a pin on the net whose `iface.modport` names a modport marked
   `controller`. The refusal messages keep their current wording when neither source says anything.
2. **`contract/dsl.nim` — `role` accepts `from = <Interface>`.** `handleRole` recognises it as a
   third key alongside bindings and params, and emits `addRoleFromInterface(d, roleName, instName,
   iface, binds, params)` (new, in `contract/design.nim`). That proc binds a role part to the
   interface's net of the same name (`sda` -> `sda`), and binds a `skComponent` part named
   `controller` to the component holding the controller modport. Explicit bindings written alongside
   `from` win. Unmatched parts are left for `validate` to report as it already does, so nothing is
   silently invented. This is the manual form of `implies`, and it is what a netlist not built from a
   declared interface needs.

`contract/` keeps its single dependency on `netlist`, and the interface never becomes a `Subject` — a
claim is still about a net, a component or a pin. `subjectOf` is unchanged.

## Standard definitions — `src/verax/netlist/interfaces/std.nim` (new)

Opt-in per import, like every format module. Registers three definitions on module init:

- **i2c** — `scl`, `sda`, both `shared`. Modports `controller` (`scl = ptOutput`, `sda = ptInOut`,
  `controller = true`) and `target` (`scl = ptInput`, `sda = ptInOut`). `master`/`slave` registered
  as aliases so either vocabulary works. Carries `implies "i2c"`.
- **spi** — `proc spiInterface(nCs = 1): InterfaceDef`: `sclk`, `mosi`, `miso`, `cs` of width `nCs`,
  none shared. Modports `controller` and `peripheral`. This is the case that exercises a bus *inside*
  an interface, and the chip-select slice of Case 1.
- **uart** — `txd`, `rxd`. Modports `dte` (`txd = ptOutput`, `rxd = ptInput`) and `dce`, which is the
  crossover the definition exists to make un-get-wrong.

## Discovery

`verax interfaces` and `verax interface <name>` mirror `roles`/`role`: `describeInterfaces` and
`describeInterface` live in `verify.nim` beside `describeRoles`, `cli.nim` gains the two verbs, the
usage text and a count line in `verax env`, and `cli.nim` imports `netlist/interfaces/std` so the
built-ins are listed. Both `interface` and `role` print the pairing, in whichever direction they are
asked. Root `CLAUDE.md`'s discovery line gains them.

## Sequencing

Roughly ten files plus four new test files. Land it in four phases, each independently green.

**Phase 1 — buses, slices and lowering.** `src/verax/netlist/interfaces.nim` with `Bus`, `addBus`,
`busOf`, `findBus`, `[]`, `[a..b]`, `len`, and the `netsOf`/`wiringOf` overload sets. In `dsl.nim`:
the `bus` handler, one `elif` arm in `buildNetlistBody`, and the `handleInstance` change from
`@[a, b, c]` to `netsOf(a) & netsOf(b) & …` (positional, `dsl.nim:410-411`) and to `wiringOf(k, v)`
(by-name, `dsl.nim:412-418`). Both are pure overload resolution — for a plain `Net` the result is the
identical `seq[Net]`, so no existing design changes.

`tests/test_netlist_bus.nim`:
1. `addBus(nl, "dq", 8)` creates `dq_0 .. dq_7`, in order, all `ntSignal`, all registered in `nl.nets`.
2. `dq[3].name == "dq_3"`; `len(dq) == 8`; an out-of-range index raises.
3. `busOf` groups pre-existing nets and records `bus.index` in the given order.
4. `findBus` after `renameNet` on a member still returns 8 nets in index order.
5. A bus whose member name collides with an existing net raises `NetlistError` naming the net.
6. A bus in a `subckt` port list produces 8 ports in index order; the `.SUBCKT` header lists them.
7. `instance` splices a bus positionally; a width mismatch raises with the port-count message.
8. `width = 0` and a negative width are refused, at compile time for a literal.
9. `{"d": hostData[4..7]}` connects index-for-index; a mismatched slice width raises.

**Phase 2 — interfaces and modports.** `SignalDef`/`Modport`/`InterfaceDef`/`Interface`/
`InterfaceView`, the registry (shaped like `roleRegistry`, `contract/roles/core.nim:96`), the
`interfaceDef` macro, `iface` and the `port` statement inside `component`, `subckt` port lists
accepting `iface.modport`, and `promotePortDirections` emitted after `instantiate`.
`src/verax/netlist/interfaces/std.nim` with i2c, spi, uart. The `open` token and its
`nc_<designator>_<port>` lowering land here.

`tests/test_netlist_interface.nim`:
10. `interfaceDef` registers, and `registeredInterfaceDefs()` lists it; re-registering replaces.
11. A modport naming an undeclared signal raises at registration, naming the signal.
12. A modport exposing a subset connects only those signals (Case 2).
13. `iface i2c0, I2C` creates `i2c0_scl`/`i2c0_sda` with `iface.instance`/`iface.signal`/`iface.def` set.
14. `port i2c0, controller` gives `SCL` `ptOutput` and `SDA` `ptInOut`; `target` gives `ptInput`/`ptInOut`.
15. `pins = {...}` renames the pins; `prefix =` prefixes them; a width-4 signal yields `cs_0..cs_3`,
    and a width-1 signal is unsuffixed.
16. `subckt(..., [i2c.target])` exposes `i2c_scl`/`i2c_sda` carrying `iface.dir`, and
    `promotePortDirections` sets the *instance* pin kinds to match — the `ptUnknown` regression test.
17. By-name `{"i2c": i2c0}` wires the same nets as the positional form (assert net-name equality).
18. `iface chans, I2C, count = 4` yields 4 instances; `chans[2]["sda"].name == "chans_2_sda"`.
19. A `bus`/`iface` inside a `for` loop builds N of them and is reachable by `findBus`/`findInterface`.
20. A missing by-name key raises naming the port group; `open` produces a distinct net per port, and
    two `open`s on one instance do not share one.
21. The SPI worked example: a width-4 `cs` bus in the parent, three peripherals each taking `cs[k]`
    through a width-1 child port.
22. `not compiles(block: ...)` for: `bus` with neither `width` nor `nets`; `port` with no interface.

**Phase 3 — the checks (this is where the value lands).** `validateInterfaces`, hooked into
`verify.nim` beside `validatePackages`; the declared-shared-bus exception in `checkOutputConflicts`,
read from raw attrs so `io_check` needs no new import; rewrite `designs/i2c_eeprom.nim` to declare
the bus, as the worked before/after.

`tests/test_netlist_interface_erc.nim`:
23. Each of the five `validateInterfaces` kinds fires on a minimal netlist that earns it, and none
    fires on a correctly wired I2C bus.
24. `checkOutputConflicts` no longer warns on a declared shared bus with two `ptInOut` pins.
25. It still errors on two `ptOutput` pins, and still warns on two undeclared `ptInOut` pins.
26. A hierarchy with two `open` ports flattens with mapped leaves merged, the two no-connect nets
    still distinct, and nothing else joined.

**Phase 4 — contract and discovery.** `controller_count`'s second source in `evaluators/static.nim`;
`role … from = <Interface>` in `contract/dsl.nim` + `contract/design.nim`; `InterfaceDef.implies` +
`RoleDef.expects` + `addImpliedRoles` appended in `buildDesignBody`, with `implies "i2c"` on the std
i2c def; `verax interfaces` / `verax interface <name>`; and the docs.

`tests/test_contract_interface.nim`:
27. `controller_count` returns 1 from modports alone, with no `controller` role binding.
28. It still refuses, with the existing message, when neither a role nor an interface says.
29. `role i2c, "i2c0", from = i2c0` produces the same bindings as the hand-written form, and an
    explicit binding alongside `from` wins.
30. `iface i2c0, I2C` inside a `design` produces an `i2c` role instance named `i2c0` with
    `sda`/`scl` bound and no `role` statement written.
31. An explicit `role i2c, "i2c0", …` suppresses the implied one, and `explain` shows which survived.
32. `iface chans, I2C, count = 4` yields four role instances.
33. `without = "rc_corner"` reaches `RoleInstance.declined`.
34. A width > 1 signal bound to a scalar role part raises naming the signal.
35. A `from =` whose interface def disagrees with `RoleDef.expects` raises naming both.
36. A def with no `implies` adds no roles at all.

### Regression checks
37. `nimble test 2>&1 | grep -cE "FAILED|Error:"` returns 0 — the exit code means nothing here.
38. `nimble verify` passes for every design and template, and `designs/i2c_eeprom.nim` reports two
    fewer structural warnings than before, with the same assertion verdicts.

## Affected paths

- `src/verax/netlist/interfaces.nim` — new; the whole model, wiring, lowering helpers and ERC.
- `src/verax/netlist/interfaces/std.nim` — new; i2c, spi, uart.
- `src/verax/netlist/dsl.nim` — new `interfaceDef` macro; `bus`, `iface` and (inside `component`)
  `port` handlers; two `elif` arms in `buildNetlistBody` plus the two error strings at `:502`/`:546`;
  `subckt`'s port loop accepts a bus/interface/`iface.modport` value; `handleInstance` builds its port
  list through `netsOf`/`wiringOf`, accepts `open`, and emits `promotePortDirections`.
- `src/verax/analysis/io_check.nim` — the declared-shared-bus exception in `checkOutputConflicts`.
- `src/verax/verify.nim` — `validateInterfaces` into `structural`; `describeInterfaces`/`describeInterface`.
- `src/verax/cli.nim` — two verbs, usage, `env` count, the std import.
- `src/verax/contract/evaluators/static.nim` — the second source for `controller_count`.
- `src/verax/contract/roles/core.nim` — the optional `RoleDef.expects` field.
- `src/verax/contract/design.nim`, `src/verax/contract/dsl.nim` — `from = <Interface>` on `role`,
  and `addImpliedRoles` appended in `buildDesignBody`.
- `designs/i2c_eeprom.nim` — rewritten to declare the bus, as the worked before/after.
- Docs: `src/verax/netlist/CLAUDE.md` (the module, the naming rule, the attrs it owns, and that a
  copied `Bus` carries no authority), `src/verax/contract/CLAUDE.md`, `docs/authoring.md` and
  `cli.nim`'s `guideText`, `docs/architecture.md` §9's table, and a `docs/findings.md` entry for
  nested interfaces and for bus glyphs.

## Compatibility

Every existing design keeps its meaning. `netsOf`-based port lists produce the identical `seq[Net]`
for scalar ports; `promotePortDirections` is a no-op without `iface.dir`; the `io_check` exception
requires a declared shared signal, so no existing warning disappears; a def without `implies` adds no
roles; the annotation registry, the deck writer and the reader are untouched. The one visible change
to an unmodified design is that `verax env` reports an extra count.

One widening is worth stating plainly: an `iface` statement inside `design(...)` can now create
contract obligations, which no netlist statement previously did. It stays inert inside a plain
`netlist(...)`, and only a definition carrying `implies` does it.

## Risks and mitigations

- **Bus membership is not maintained across `mergeNets`.** `graph.mergeNets` keeps the surviving
  net's `attrs` and only fills gaps, so a net merged into another silently keeps one membership. The
  mitigation is to state that membership is authoring-time metadata read before simulation
  transforms, and to run `validateInterfaces` on the authored netlist — which is where `verify.nim`
  already puts it.
- **A dotted key typo is invisible.** Mitigated by these keys being written only by
  `interfaces.nim`, never by an author, and by `findBus`/`findInterface` raising when a member set is
  incomplete rather than returning a short bus.
- **Underscore names can collide with hand-authored nets.** `addNet` raises on a duplicate, which is
  loud and correct; the plan does not add a private namespace to dodge it.
- **N stacked port symbols — landed.** `schematic/bundles.nim` reads the `bus.*`/`iface.*` net
  attrs (a read-only index built in `prepare`, before any symbol is sized) and groups the members.
  Eligibility in one sentence: a bus or interface whose members *uniformly* touch exactly two
  endpoint entities — any pair of {a component, the sheet boundary} — collapses to **one merged pin
  per end and one thick coloured wire** (blue for a bus, purple for an interface); a *published*
  bundle that fails that (three-plus endpoints, or non-uniform) drops its wires for **net labels** at
  every pin; every other bus/interface wire is merely recoloured. On `designs/lib/spi_memory.nim`'s
  `SPI_MEMORY` sheet this took 3 port pennants + 3 thin wires + `U1` at `rows = 5` (`bodyH` 272) to
  1 pennant + 1 purple wire + `rows = 3` (`bodyH` 192); `designs/spi_memories.nim`'s portless top
  recoloured its 16 SPI wires and moved nothing. **Guaranteed non-change:** a netlist with no
  `bus.*`/`iface.*` net attr, or a bundle of fewer than two member nets, yields a zero-value
  `BundlePlan` and byte-identical historical output — `designs/i2c_eeprom.nim` (an interface
  instantiated but never published) is the worked case, geometry byte-identical, colours only.
  Modport-stamped `Pin.kind` still improves `placement.portDirection` for free.
- **SPICE round-trip loses the grouping.** Inherent, like `Pin.kind` fidelity already is; stated in
  `netlist/CLAUDE.md` in the same terms rather than worked around.
- **`from = <Interface>` could bind a role part by accident.** Only exact name matches bind, explicit
  bindings win, `RoleDef.expects` catches a mismatched pairing, and `Design.validate` still reports
  every unbound non-optional part.

### Coordination note

`src/verax/netlist/packages.nim` (multipart components) adds `validatePackages` to the same
`structural` list and modifies the same `buildNetlistBody` dispatcher. No semantic conflict, but land
that work first or expect textual conflicts in both files.

## Verification

```
nim check --path:./src src/verax/netlist/interfaces.nim
nim c -r --path:./src tests/test_netlist_bus.nim
nim c -r --path:./src tests/test_netlist_interface.nim
nim c -r --path:./src tests/test_netlist_interface_erc.nim
nim c -r --path:./src tests/test_contract_interface.nim
nimble test 2>&1 | grep -cE "FAILED|Error:"     # must print 0 -- exit code means nothing
nimble build && ./bin/verax interfaces && ./bin/verax interface i2c && ./bin/verax role i2c
./bin/verax check designs/i2c_eeprom.nim       # before/after the rewrite
nimble verify
```

The end-to-end check that the feature did what it claims: `VERAX_KEEP_RUNS=1 ./bin/verax check
designs/i2c_eeprom.nim`, then confirm the emitted deck names `i2c0_sda`/`i2c0_scl` where it named
`sda`/`scl`, that the topology is otherwise byte-identical, and that the readiness report's STRUCTURE
section has lost the two `output_conflict` warnings and gained a `controller_count` verdict.

## Implementation notes

Interfaces are authored with `interfaceDef`, realised with `iface`, and wired
through `port`. Interface definitions lower to scalar nets and pins. A role can
bind matching interface signals with ``role "i2c", bus, `from` = i2c``;
backticks are required because `from` is a Nim keyword. Import
`verax/netlist/interfaces/std` for the standard I2C, SPI, and UART definitions.
Use `verax interfaces` and `verax interface <name>` to inspect the live
catalogue.
