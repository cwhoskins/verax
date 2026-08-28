---
name: spice-model
description: Add a new simulation-only device model to src/nimcir/spice/models/ — a parasitic expansion, a synthesized primitive plus a .MODEL card, or a behavioural stand-in. Use when a Component.kind reaches the deck as itself and ngspice misreads it, when a part with no model needs to keep a signal path, or when a real part's ideal form hides the thing an analysis is run to find. Covers the kinds.nim / formats/spice.nim / annotations.nim edits, the ordering that makes it work, the convergence traps, and the tests and docs it is not done without.
---

# Adding a model to `spice/models/`

Every file here **invents numbers the netlist does not carry** and returns
`seq[Assumption]` for them. Every one **mutates the netlist it is given** — it
runs on a `materializeSimNetlist` / `isolate` / `extract` clone, never the
design netlist. Read `src/nimcir/spice/CLAUDE.md`'s `models/` bullet and the
closest existing file before writing: `ferrite_bead.nim` (parasitic
expansion), `switch.nim` (`expandSwitches` = synthesized primitive + `.MODEL`;
`muxModel` = behavioural), `regulator.nim` / `buffer.nim` (behavioural
stand-ins), `magnetics.nim` (a pinless device and a new `isPassive` carve-out).

## 1. Which of the three shapes is it?

| shape | example | signature | wired in where |
| --- | --- | --- | --- |
| **parasitic expansion** — one real 2-terminal part → several R/L/C primitives | `ferrite_bead`, `wire`/`jumper`/`fuse` | `expandFoo(nl, d = defaultFooModel()): seq[Assumption]` | a `result.add expandFoo(nl)` line in `pin_models.expandPinModels`, beside `expandFerriteBeads` |
| **synthesized primitive + `.MODEL` card** — part → an `S`/`D`/… device and `setModel(nl, name, card)` | `expandSwitches` | same | same |
| **behavioural stand-in** — part with a path through it → a network keeping its *function* | `regulatorModel`, `bufferModel`, `opampModel`, `muxModel` | `proc (nl: Netlist, c: Component, gnd: Net): BehavioralResult {.nimcall.}` | `registerBehavioralModel(kind, fooModel, passesSignal = …)` in `models.registerBuiltinBehavioralModels` |

A part that carries a design-authored `SimReplacement` (a `simReplace` DSL
block, or `newSimReplacement(buildProc)` set by an `equip*` helper) is honoured
first and never reaches any of these — that is the right route for a part
whose stand-in is design-specific (`designs/lib/oring.nim`, `buildIdealBuck`).

Then, in `models.nim`: `import ./models/foo` and add `foo` to the two
`export` lines.

## 2. `src/nimcir/netlist/kinds.nim` — is it `isPassive`, and why

`isPassive` is the question *"can `spice/isolate` absorb this part wholesale
without a model for it?"*. Decide deliberately; it is load-bearing in both
directions — `expandPinModels` stands in for every part `isPassive`
**rejects**, `spice/isolate` absorbs every part it **accepts**.

- `conductiveKinds` — an ideal always-conducting two-terminal part. `io_check`
  walks *through* it; `isolate` traverses it. Only add here if the part is a
  DC wire.
- `blockingKinds` — blocks DC (`capacitor`, `current_source`).
- Neither → `condAmbiguous` → `io_check` stops at it, `isolate` cuts it (into
  `dropped`) **unless** `isPassive` is true another way.
- **Survives isolation but is not a DC path** (a transformer's winding-to-
  winding barrier, a `K` card that has no nodes at all): add a dedicated
  `const fooKinds*` and OR it into `isPassive`, leaving `classifyConductivity`
  ambiguous. This is `couplingKinds`. The split is the whole point — `io_check`
  must keep refusing to cross a barrier that genuinely has no path.
- A synthesized primitive that ends up carrying a `.MODEL` card reaches
  `isPassive` through `hasDeviceModel` **for free** — no kind-list entry, no
  const. `vswitch` works this way.

`builtinDesignatorPrefixes` is the *schematic* refdes letter (`FB`, `U`
fallback) — cosmetic, and **deliberately not** `formats/spice.prefixByDeviceKind`.
They disagree on purpose (`FB` on a board, `L` in a deck). Deriving one from
the other is how `FB1` came to be simulated as a current-controlled current
source.

## 3. `src/nimcir/netlist/formats/spice.nim` — spelling the primitive

Only if the model synthesizes a device SPICE reads by letter:

- `prefixByDeviceKind[kind] = 'X'` — **write-side only**, next to `E`/`G`/`F`/`H`.
  Keep it out of `deviceKindByPrefix` unless a reader test covers round-tripping
  it; inventing an unread mapping is a claim the module cannot back.
- `pinTemplates[kind]` — pins in **deck order**, when the line is positional
  over nodes. A token that is *not* a net — a `.MODEL` name, an `F`/`H`
  controlling-source name, a `K` card's inductor names — does **not** go in the
  template. Either it rides in `attrs["value"]` (appended verbatim after the
  nodes, the way a diode's model name does) or it needs a special case.
- `formatDeviceLine` special case — for a line with **no nodes** (`K`) or
  non-positional ports (`A`): a branch keyed on a namespaced attr, resolving
  every device name through `comp.netlist` to its `deckDesignator` **at write
  time**. Never bake a designator string: `flatten` prefixes it and a rename
  moves it, and the baked one rots silently.

## 4. `src/nimcir/netlist/annotations.nim` — the parameters

- Every **bare** parameter the model reads: an `AnnDef` in the
  `builtinAnnotations` **const** (the const is what the DSL's compile-time
  `spec:` check sees). `unit` must be a `units.unitOf` symbol. Doc it in the
  register's own voice — what it is *for* and what goes wrong without it.
- **Structural / topology options** (select-pin names, an active-low flag, a
  termination value): namespaced (`foo.select_pins`), never validated, read via
  `attrs.getOrDefault` or `annotationFloat(c, "foo.key")`.
- Add the bare keys to the vocabulary list in `src/nimcir/netlist/CLAUDE.md`.

Reading: `annotationFloat(c, "key")` → `AnnValue[float]{source, value}`.
`.has` is `source != annAbsent`. **Never default in the accessor** — inventing
a stand-in is the model's job, and it must emit an `Assumption` when it does.

## 5. Model-writing rules (house style is load-bearing here)

- **A stated value produces no assumption. An invented one always does** —
  `assumption(entity, key, value, unit, annDefaulted, "detail in your own
  words")`. The detail carries its own connective.
- **No defensible default → refuse.** `note("<desig> states no `lpri`… so it
  was left unmodelled. There is no defensible default magnetising inductance —
  state `lpri`.")` and `continue`. A magnetising inductance, a regulator's
  output voltage: guessing gives a barrier / rail that silently passes whatever
  you made up. `regulatorModel` is the reference refusal.
- **Snapshot every net *name* before `removeComponent`.** It calls
  `disconnect` on each pin, which nulls `Pin.net` — the `Net` objects survive
  (still wired to other parts) but the pins stop pointing at them. Reading
  `pin.net.name` afterward silently drops the term (this is the bug that
  deleted the enable from every mux decoder). `bufferModel` captures its nets
  up front for the same reason.
- **Name synthesized parts `<letter><origDesignator>_<suffix>`** (`"L" & desig
  & "_PRI"`), so `deckDesignator` is the identity on them and a dotted
  flattened `desig` still produces a legal line.
- **Mark modelling-only reactive elements** `attrs["parasitics.expanded"] =
  "true"` — so `expandCapacitorParasitics` never gives a stand-in a
  self-resonance the real part does not have. Mark per-pin stand-ins
  `attrs["models.pin.expanded"] = "true"`.
- **Behavioural `handled = false` means "leave the part exactly as it is"** —
  emphatically *not* "fall through to per-pin impedances". A part known to
  carry a path, stood in for by two resistors to ground, reports its output at
  0 V: a confident wrong answer where refusing was honest.
- **Smooth, never a hard step.** A `bsource` gate is
  `1/(1+exp(-(v(n)-vt)/vs))`, not `v(n) > vt`. A step has a zero derivative on
  each side (an `.ac` linearises the live path to no gain) and an infinite one
  at the corner (a `.tran` earns "timestep too small"). `opampModel`'s
  `min`/`max` clamp documents the same trap.
- **`passesSignal` is declared, not inferred.** It is what lets
  `analysis/opamp`'s static feedback walk cross the part *without simulating*.
  A regulator's output is a source, not a connection to its input → `false`. A
  buffer or a mux keeps the path → `true`.
- A `.MODEL` card goes in through `graph.setModel(nl, name, card)`, never
  `nl.models[name] =` (that would force every design to `import std/tables`).
  The card body is **passed through unparsed** — the datasheet is the
  authority, not this module.

## 6. Ordering — why the model runs where it does

Every analysis does `materializeSimNetlist` → `flattenForSim` →
`expandPinModels` (**your model runs here**) → `isolate`. So the part is
already flattened to its top-level dotted designator with fresh local nets, and
isolation has not yet decided what to keep. A synthesized primitive with a
`.MODEL` card is `isPassive` via `hasDeviceModel`, so isolation keeps it;
`graph.clone` copies `nl.models` by reference, so the card survives
`extractSubcircuit`. A pinless device (`mutual_inductance`) is never reached by
the isolation net-walk — `growSelection` has a closing pass that pulls one in
when everything it references was already selected; a new pinless kind needs
the same.

## 7. Convergence — every node needs a DC reference

If the model can leave a node floating — a dangling control input, an
isolation island, a winding whose other end goes nowhere — ngspice answers with
`singular matrix`. Give it a reference, and **prefer high impedance** (1 MΩ /
1 GΩ) that carries no current. A *low*-impedance bond is only correct when real
DC current must flow through it — and then it is not a "reference", it is a
connection the design has, and the design netlist should show it. The xbar PoE
lesson: an ideal source returning to one ground while its load returns to
another forced current through the bond; the fix was to reference the source to
the load's ground, not to lower the bond.

## 8. Tests — `tests/test_spice_<name>.nim`

- **Expansion shape**: the components created, the nets wired in series
  (`nl.components["LFOO_PRI"].pins["2"].net.name == "FOO_PMID"`), the pinless
  device's `spice.couples` / port attr.
- **Parameters**: stated → no assumption; derived → `annDerived` assumption;
  absent → `annDefaulted` assumption *or* a `note` and the part left in place.
- **The refusal path**: missing data → exactly one `note`, part untouched.
- **An ngspice run**, gated `if findExe("ngspice").len == 0: skip()` — write
  the deck with `writeNetlist(nl, s, @[".op", ".control", "set filetype=ascii",
  "run", "print v(x)", "quit", ".endc"])`, `execCmdEx("ngspice -b " & deck)`,
  and assert the number. This is what proves the deck the model produces is one
  ngspice actually reads.
- **`tests/test_spice_spellable.nim`**: if the kind reaches `isPassive` outside
  `conductiveKinds` / `blockingKinds` / `behaviouralKinds`, add its const to
  `passiveKinds()` or add an explicit case. The invariant: *a kind `isPassive`
  accepts must be spellable* — a letter, or a pass rewrites it away.

## 9. Verify

```bash
nim check --path:./src src/nimcir/spice/models.nim
nim c -r --path:./src tests/test_spice_<name>.nim        # read the [OK] lines
nimble test 2>&1 | grep -cE "FAILED|Error:"              # must print 0 — never the exit code
nimble verify                                            # if any design uses the kind
```

Inspect what actually ran: `NIMCIR_KEEP_RUNS=/tmp/m ./bin/nimcir check
designs/foo.nim`, then read `/tmp/m/run*.cir` — the derived deck is not the one
anyone wrote.

## 10. Docs — the model is not done without them

- `src/nimcir/spice/CLAUDE.md`, `models/` bullet: what the file does, the
  decision you made and the one you rejected, and **a before/after number you
  measured** ("the same rail read 173 mohm nominal and 1.23 ohm derated").
- `src/nimcir/netlist/CLAUDE.md`: any new `prefixByDeviceKind` letter or
  `kinds.nim` const, and the annotation keys.
- `docs/RESOLVED_FINDINGS.md` if it closes a finding; strike the bullet in
  `docs/findings.md`.
- If it needed a new evaluator/quantity (an isolation-barrier claim, a
  measured property): that is `contract/evaluators/` or `analysis/evaluators/`
  work with its own registration and `nimcir quantities` reachability — a
  separate concern from the model.
