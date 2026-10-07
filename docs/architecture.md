# verax architecture

How the submodules relate, and what happens between `verax check board.nim`
and the report it prints.

This is the design document. `authoring.md` is the guide for someone *writing*
a design; this is for someone changing the library, or trying to work out why
a number came back the way it did. `findings.md` and `RESOLVED_FINDINGS.md`
record what checking real boards taught us, which is where most of the
reasoning below originally came from.

---

## 1. The shape of the whole thing

A design is an **ordinary Nim program**. It states what a circuit *is*
(topology, part values, annotations) and what it must *do* (claims), and ends
with `quit(verifyMain(d))`. Compiling it produces a binary; running that binary
checks the circuit and exits with a graded code.

So there are two distinct phases, and confusing them is the source of most
questions about this codebase:

| | when | what it produces | what catches a mistake |
|---|---|---|---|
| **Authoring** | Nim compile time | a `Design` object in memory | the Nim compiler — a misspelled net identifier, an unknown `spec:` key, a unit mismatch |
| **Verification** | process run time | a `Readiness` report + exit code | the registries — an unknown role name, a quantity nothing produces, a claim that fails |

The line between them is not arbitrary. Everything that can be a **compile
error is made one**, because the alternative is a runtime message about a
circuit that was never the problem. Everything that depends on a *runtime
registry* — roles, evaluators, behavioural models, designator prefixes — cannot
be, because a macro cannot see a table that a third party may add to at
startup, and keeping those tables open at runtime is what makes the layer
extensible.

The invariant the whole tool exists to protect: **silence must never read as
approval.** A claim nobody could check is not a claim that passed, and it gets
its own report section, its own exit code, and a status that is neither pass
nor fail.

---

## 2. The dependency spine

Arrows point from a module to what it depends on. There are no cycles and no
back-edges: nothing below ever learns about anything above it.

```
                          cli.nim              (the `verax` binary)
                             |
                          verify.nim           (the runner + the catalog)
                        /            \
                       /              \
              contract/            analysis/   (+ analysis/evaluators/, the join)
                       \              /
                        \          spice/  --> spice/xspice/
                         \          /
                          netlist/    schematic/    parts/     pcb/
                             |   \________|___________|________/ | \
                             |                          ibis/ <-/   \-> fem/
                             |                            (over pcb + netlist)
                    units.nim   eng.nim       (below everything)
```

`ibis/` (reads a vendor `.ibs` buffer model) and `fem/` (interface to an
external finite-element field solver, EM + thermal) are the two newest
submodules. Both sit above `pcb/`: `fem/` meshes board geometry, `ibis/`
binds a parsed buffer model to a `Placement`. Neither is imported by anything
above them, and both are opt-in per import like every other hub. `fem/` has
an MFEM call path only (`fem/mfem`, opt-in, stage 0: load + a validation Laplace solve; no meshing or physics yet); `ibis/` is a no-op past its parser.

Three rules produce that picture.

**Two root modules sit below every submodule.** `units.nim` (typed electrical
quantities: `Volts`, `Ohms`, `Farads`, …) and `eng.nim` (engineering-notation
rendering for report text) are needed by more than one submodule and may be
owned by none. `units` exists for exactly one reason: `esr = 20.mohm` cannot be
misread, whereas `"20m"` and `"0.02"` differ by a thousand and look equally
plausible.

**One root module sits above every submodule.** `verify.nim` needs `contract`
and `analysis` at once, and neither may depend on the other. That separation is
load-bearing: `contract` depends only on `netlist`, which is what keeps a
design authorable, readable and inspectable **with no simulator in the build**.
An edge from `contract` to `analysis` would quietly destroy that property.

**Everything expensive is opt-in per import.** A hub module (`netlist.nim`,
`spice.nim`, `analysis.nim`, `contract.nim`, `pcb.nim`) exports only what runs
with no external toolchain. The backend (`spice/ngspice`), the file formats
(`netlist/formats/*`, `pcb/formats/*`), the simulation-backed analyses
(`analysis/analyses/pdn`, `analysis/analyses/opamp`, …) and the XSPICE authoring tools are each
imported by path. `src/verax.nim` is deliberately **not** a re-export hub for
the same reason, and the nimble package builds its binary from
`src/verax/cli.nim` so that `import verax` in an unrelated program does not
drag in `osproc` and the whole analysis tree.

### What each submodule owns, and what it is not allowed to know

| submodule | owns | must not know about |
|---|---|---|
| `netlist/` | the electrical graph: nets, components, pins, hierarchy, annotations, environment, SPICE file format | simulation, geometry, intent |
| `schematic/` | a renderer-neutral schematic scene and deterministic placement/routing, with SVG/JSON writers | simulation, geometry, intent (it is a leaf over `netlist`) |
| `spice/` | turning a netlist into something a simulator can solve, and running it | what question is being asked |
| `analysis/` | asking a question and extracting a number from the answer | what claim the number is for |
| `contract/` | what the circuit must do, and comparing a number against it | how any number is produced |
| `pcb/` | the physical board: layers, copper, holes, placements, BoM, routing and closed-form transmission-line characterization | anything electrical beyond a forward reference into a `Netlist` |
| `parts/` | choosing a real part for a computed value | the circuit it lands in |
| `ibis/` | reading what a vendor says a buffer does (`.ibs`: I/V curves, edge rates, package RLC) | how that behaviour gets simulated, or whether a design meets it |
| `fem/` | stating a field problem over a board and running it through an external solver | what question the field answers |
| `verify.nim` | joining the last two, and rendering | — |

Two of those are worth stating plainly because it is easy to assume otherwise:

* **`pcb/` has a real reader, a router and a closed-form solver now, but
  still does not participate in *verification*.** `formats/kicad.nim` reads
  and writes `.kicad_pcb` (byte-exact for an unmodified board; a bounded set
  of edits -- tracks, vias, nets, zone scalars, a placement's
  position/side/reference/pad nets -- regenerated for a modified one,
  everything else refused by name rather than fabricated or silently
  dropped); `formats/odbpp.nim` is still unwritten. `pcb/trace.nim` stitches
  a net's copper into a routing tree that mirrors physical branching and
  resolves each run's reference plane; `pcb/impedance.nim` solves a
  microstrip or stripline cross-section in closed form (Hammerstad-Jensen,
  IPC-2141); `pcb/tline.nim` joins the two into per-frequency Z0, loss,
  propagation delay and an S-matrix. All three are read-only over a `Pcb`
  and none of them registers a contract quantity or touches `Design` --
  `intra_pair_skew`/`inter_pair_skew`/`z_diff` (`contract/evaluators/diff.nim`)
  are now *computable* from a `Pcb` but still decline every claim, because
  nothing wires a `Pcb` into a `Design` or into an evaluator yet. `fem/extrude.nim`
  imports `pcb` (see the `fem/` row above), so a board reaches a field solve
  from a real file today -- but nothing in the *verification* path
  (`verify.readiness`, the contract evaluators) reads a `Pcb` yet. The join
  for that is already designed, not yet wired: a `Pcb` *owns* a `Netlist`
  and every PCB entity holds a forward reference into it, so
  `netlist/types.nim` stays geometry-free and a layout analysis can walk
  from a trace to the pins it connects in one hop; the route in for a
  `contract`-side check is `EvalContext.scratch`, the same type-erased slot
  `Pcb.source` itself uses to hold `formats/kicad`'s round-trip state
  without `pcb/` gaining an edge back to a format module. What that adapter
  still needs, precisely: a `Pcb` reachable from a `Design` (nothing holds
  one today), and a `diff.nim` evaluator that calls `trace.traceTree` +
  `tline.characterize`/`skew` instead of declining -- both are now thin
  wiring over code that exists, not open questions about what the numbers
  even are.
* **`parts/` is used by design libraries, not by the pipeline.** A
  parameterized module states a `CapRequest` carrying a value and a *use*; a
  board supplies a `PartPolicy` that answers with a `Choice`; `applyChoice`
  writes the answer as ordinary registered annotations. The module knows the
  part's function, the board knows its environment, and neither can choose
  alone — that asymmetry is the whole reason the submodule exists.

---

## 3. Authoring: a `.nim` file becomes a `Design`

`contract/dsl.nim`'s `design(...)` macro accepts everything `netlist/dsl.nim`'s
`netlist(...)` accepts — by *reusing* `buildNetlistBody`, not by duplicating it
— plus two statements of its own.

```
design("board"):
  net / component / pin / model / instance / environment: / spec:
        |
        +--> expands only into calls on netlist/graph.nim
        |
  role "power_rail", vdd_rail, rail = vdd, voltage = 3.3.V
        |
        +--> design.addRole  ->  validate, tag membership, run RoleDef.apply
        |
  require z_max_in_band(vdd) <= 100.mohm, f_from = 100.kHz, ...
        |
        +--> design.assertThat
```

Four mechanisms carry most of the weight here.

**The DSL only ever expands into `graph.nim` calls.** `graph.nim` is the single
place allowed to mutate the graph's bidirectional back-references
(`Pin.component`/`Pin.net`, `Net.pins`, `Component.pins`, parent/child). Code
that hand-sets `.net` or `.pins` gets the two directions out of sync, and the
graph is deliberately walkable from any starting point rather than only through
the name-keyed tables.

**Bare identifiers become real Nim `let`s.** `net vdd, ...` binds `vdd`, so a
typo later is a compile error rather than a silently-created second net.

**`spec:` is validated at compile time against `netlist/annotations`.** `attrs`
is an open-ended `OrderedTable[string, string]` so no file format ever has to
extend the core schema — and the price of that openness is that **a typo in a
key is indistinguishable from an absent key**. Write `ESL` for `esl` and the
model pass silently uses a package default *and reports it as an assumption*,
so it looks like it worked. Inside `spec:` there is no open-ended bag for an
unknown key to mean anything, so the strictness boundary is drawn syntactically:
head-of-statement `key = value` pairs are permissive and land in `attrs`,
`spec:` keys are strict. The registry is a runtime table seeded from a `const`:
the `const` is what the macro reads at compile time, the table is what keeps
runtime registration possible.

**A role is a parameterized bundle of assertions, not a tag.** `RoleDef` has
two halves, and the split is deliberate:

* `apply(inst, netlist)` writes annotations onto the graph. This half has a
  life independent of checking — `spice/isolate` reads
  `Net.attrs["voltage"]` to terminate a cut rail long before anything asks
  whether that rail is *correct*. It runs at `addRole` time, so by the time
  the design object exists the annotations are already in the graph.
* `expand(inst)` is pure and returns `seq[Assertion]`. It runs at plan time.

Both are **proc values on a data object**, so a role built at runtime registers
and behaves identically to a built-in. The built-in roles use no privileged
mechanism, and a test pins that down by defining a role in the test file and
checking it takes the identical path — a built-in that cheats makes
user-defined roles second-class, and then nobody writes them.

### What a claim actually is

Three shape decisions in `contract/types.nim` carry the forward-compatibility
story, and none of them should be traded away for convenience:

* **`Assertion.subjects` is a `seq`**, not one subject plus a second-operand
  field. Setup/hold is inherently one signal *versus* another, so a two-subject
  quantity must not be a special case bolted on later. The `channel_match`
  role and its `spice.channel_match` evaluator (`arity: 2 .. 2`, subjects of
  kind `skClass`) are the first to use it — `designs/riaa_preamp.nim` claims
  its two channels agree, over and above each reaching its own gain.
* **`Assertion.quantity` is an open string naming an analysis `Measurement`**
  (`dc_voltage`, `bw_3db`, `z_min`). That is what turns evaluation into "run
  whatever analysis produces this name, then compare", with one comparison
  (`satisfies`) shared by every quantity; the failing witness comes free,
  because the `Measurement` already exists. It also keeps the coupling honest —
  a quantity nothing can produce is a claim nobody can check, and that shows up
  immediately. A bench result is also a `Measurement`, so correlating measured
  against simulated is later the same comparison with a different source.
* **`Expectation` is a variant object**, so the cases that do not exist yet are
  additive (see §8).

A `NaN` never satisfies anything: "the measurement did not happen" must not
read as a pass. And `Assertion.rationale` is in practice the most valuable
field in the object — a limit whose reason is lost gets relaxed the first time
it fails.

---

## 4. Verification: `verifyMain` → `readiness` → a report

`verify.readiness(d, allowed)` is the whole run. It is **pure with respect to
the design**: nothing it does mutates `d` or its netlist.

```
readiness(d, allowed)
  |
  1. capabilities   allowed * availableCapabilities(ngspiceVersion())
  |
  2. STRUCTURE      validateAnnotations(nl)      vocabulary: misspelled/wrong-scope keys
  |                 analyzeIO(nl)                output conflicts, DC paths, rail voltages
  |                 validateEnvironment(nl)      an inverted or half-stated ambient range
  |
  2b. CONTEXT       ctx = newEvalContext(d, usable)   one per run, shared below
  |
  3. PLAN           plan(ctx)                    pure: nothing runs, nothing is simulated
  |                   for each assertion in d.expandAll():
  |                     evaluatorFor(quantity)   -> else rejected, esNotEvaluable
  |                     arity / subject kinds    -> else rejected, esNotEvaluable
  |                       (arity is a `Slice[int]`: 1 .. 1 for almost all,
  |                        2 .. 2 for `spice.channel_match`)
  |                     ev.needs <= allowed      -> else rejected, esNotEvaluated
  |                     group by (evaluator, setupKey(ctx, a))  -> one PlanStep
  |
  4. RUN            runPlan(ctx, plan)           one batch of results per step
  |
  5. COLLECT        one `Check` per step: setupDoc, deduped assumptions, results
  |                 claimLint(results)           a claim with no unit against a measured one
  |
  6. RENDER         render(readiness)            +  exitCode(readiness, strict)
```

### 4.1 Structure comes first, and it is not an assumption

A misspelled `esr` makes every impedance number below it meaningless, so the
vocabulary check runs before any claim is considered.

`checkRailVoltages` is the sharpest example of why this section exists
separately from the assumption list. A rail with a stated voltage gets an ideal
source at an isolation boundary; a rail *without* one is cut loose as a
floating node — which changes the topology rather than substituting a value. In
`designs/ts808_drive.nim` a divider-derived 4.5 V bias initially carried no
voltage, so the drive stage's gain leg was detached: an amplifier with a gain
of 65 measured as a unity-gain follower, every claim passed, exit 0. The
floating rail *was* reported — as one assumption among fifteen, reading exactly
like the package-typical ESR two lines above it. Being reported and being
noticed are different things, and the difference is which section it lands in.

### 4.2 The plan is pure, and separated on purpose

`plan(d, allowed)` routes every assertion — authored and role-expanded alike —
to an evaluator and groups them. Nothing runs. `explainPlan` prints it.

The grouping is the interesting part. Quantity-to-evaluator is
**many-to-one**: `analyzePdn` emits eight measurement names from a single `.ac`
sweep. So an `EvalProc` takes a *batch*, and steps are keyed by
`(evaluator, setupKey)`. "One analysis run per distinct setup" is therefore a
property of the planner, provable by counting steps, rather than something each
evaluator has to reimplement — a single `.op` answers every `dc_voltage` claim
in a design.

`Evaluator.needs` is a **`set[Capability]`**, and the gate is
`ev.needs <= allowed`. It was a scalar, which forced two built-ins to
under-declare — `spice.pdn` said `.ac` while solving an operating point for
its bias derating, `spice.large_signal` said `.tran` while solving one to find
its stimulus bias — so `--caps=ac` and `--caps=tran` each ran an analysis the
caller had withheld. That is invisible while everything is available and a
wrong answer the moment something is not, which is exactly what a bench host
is. An omitted declaration normalises to `{capStatic}` rather than the empty
set, since `{} <= allowed` would make "declared nothing" mean "runs anywhere".

A rejection carries **which of two different things went wrong**, and they are
not interchangeable:

* `esNotEvaluable` — nothing can produce this quantity for these subjects. The
  claim is unreachable as written.
* `esNotEvaluated` — an evaluator exists but did not run or did not return a
  number: its capability was withheld, the simulation raised, or the
  measurement came back `NaN`.

When nothing produces a quantity, `didYouMean` ranks the registered quantities
by edit distance, because a misspelling is the likeliest way to write an
uncheckable claim and `no evaluator produces 'z_ripple'` alone says the door is
locked without mentioning that a door exists.

### 4.3 Running: an evaluator is handed a batch

`runStep` calls `ev.run(ctx, step.assertions)` inside a `try`. An evaluator that
raises, or returns the wrong number of results, is a bug in the evaluator — but
it must not take down the whole run, because then one bad plugin costs every
other verdict in the design. Results that do come back are matched by assertion
id and the rest are accounted for as `notEvaluated`.

`verdict()` is the single place pass/fail semantics live, so every evaluator
gets identical behaviour. Three decisions are pinned there:

* a `NaN` measurement is `esNotEvaluated`, **not** `esFail` — `z_antiresonance
  = NaN` means no interior peak was found, which is the *good* outcome;
* a unit mismatch is `esNotEvaluable`, rather than a silent comparison of volts
  against hertz;
* both declining paths carry the analysis's `assumptions` **and its `issues`**
  out with them. `reason` is written inside `verdict` and cannot name a cause
  `verdict` does not know, while the analysis usually does know and said so in
  an `Issue`. Dropping those once stranded a Sallen-Key's phase margin behind
  "the quantity was not found in the range that was analysed" — true, and it
  sends the reader to widen a sweep that is not the problem, while the issue one
  field away said the loop break never opened the loop.

**One operating point is shared across the run.** The cache lives in
`EvalContext.scratch`, so its lifetime is exactly one run — which is what makes
it correct rather than merely conventional. It was a module-level `var` keyed on
`Design` *reference identity* with no content invalidation, so an edited design
silently got its first answer back, two designs checked in one process shared a
slot, and `readiness` had to bracket every run with a clearing call. A design
does not change under a run, so there is now no window in which the entry can be
wrong — and a sweep over candidate component values, which is the obvious way to
have hit the old bug, is safe by construction. `scratch` is type-erased
(`Table[string, RootRef]`) because `contract` may not name an `OperatingPoint`
or a `Pcb` without gaining an edge to `analysis` or `pcb`: a module owning such
a type declares `ref object of RootObj`, stashes it under a key it owns, and
downcasts on the way out. This can be a straight line rather than a
fixed point because **at DC a capacitor is an open circuit, so the operating
point cannot depend on capacitance**. Solve the `.op` first, derate every
Class 2 ceramic from its *actual* node voltages, then run the `.ac`/`.tran`
against the derated values. No iteration, no ordering ambiguity.

### 4.4 The report is rendered fresh, and its centre of gravity is `NOT CHECKED`

`render` does **not** concatenate `report`/`summary`/`explainPlan`/`explain`.
Each of those answers one question in isolation and each re-lists the same
assertions, so concatenating them prints one failing claim three times. The
ordering and the de-duplication *are* the product.

Sections run in order of how much each undermines everything below it:
**structure → checks → failures → not checked.**

The body is `CHECKS`: **one block per test, where a test is one analysis run.**
That grouping is the plan step seen after running, and it recovers three facts
a flat list of results loses — which claims came out of one simulation (so a
single wrong setup explains all of them at once), what that simulation *was*,
and which invented values it rested on. It cannot be recovered afterwards: an
`AssertionResult` carries its evaluator's name but not its setup key, and two
steps of one evaluator are two different runs. Each block carries:

* **`ran:`** — from `Evaluator.setupDoc`. The setup *key* exists to group;
  `vdd|100000.0|100000000.0` is a correct key that says nothing about what was
  simulated, and the fragment handed to ngspice is derived rather than authored,
  so it needs saying.
* **`assuming:`** — the batch's own invented values, deduplicated,
  `annAuthored` excluded. Pooled at the foot of a report they said forty values
  were invented *somewhere*; under the run that rests on them the question of
  which number each one moved is answered. `foldAssumptions` collapses records
  sharing `(key, value, unit, detail)` onto one line naming every entity —
  lossless, and worth 39 lines down to 21 on one design's PDN block.
* **the claims** — an identity line, a comparison line putting `expect` and
  `measured` together with the tolerance rendered as the interval it accepts,
  and `because …` (the assertion's `rationale`) whenever the claim did not pass.

`FAILED` and `NOT CHECKED` render through the same `renderClaim`, so a limit is
never spelled two ways in one report. `NOT CHECKED` is never collapsed.

A `Readiness` holds `AssertionResult`s and `Issue`s and **never an
`AnalysisReport`** — `AssertionResult` has no field for one, so a sweep's
thousands of curve points cannot leak into a report. A test pins the rendered
size so that a future "attach the curve for context" change fails loudly.

### 4.5 Exit codes are graded

Precedence runs most-fundamental first, so a caller can branch on *why*:

| code | meaning |
|---|---|
| 0 | clean |
| 1 | a claim was checked and failed |
| 2 | the netlist itself is wrong in a way that makes its numbers untrustworthy |
| 3 | a claim nothing could check |
| 4 | a requested capability is unavailable on this machine |
| 5 | the design did not compile — **only `verax check` produces this** |

5 is separate on purpose. Told only "it failed", a reader edits the circuit to
fix what is actually a syntax error. That is also why `cli.nim` compiles and
runs the design as **two processes, never `nim c -r`**: that would merge "this
file does not compile" and "an assertion failed" into one exit status.

`esNotEvaluated` alone stays clean — withholding a capability is a deliberate
act, not an oversight — unless `--strict`.

---

## 5. Inside one simulated check: the transform chain

This is where a board actually meets a simulator. Every simulation-backed
analysis follows the same shape, and **the ordering is load-bearing at every
step**. `analysis/analyses/pdn.analyzePdn` is the canonical one:

```
  d.netlist                        the design as authored -- never mutated, never simulated
      |
      | materializeSimNetlist(nl, purpose = spSmallSignal)
      v                            clone, then apply each part's simReplace for this purpose
  work
      |
      | flattenForSim(work, ...)
      v                            dissolve subcircuit instances into the top level
  work (flat)
      |
      | expandPinModels(work)
      v                            every part isPassive rejects becomes per-pin impedances
  work (all-passive)
      |
      | isolateNets(work, [rail], spec)
      v                            grow a fragment outward; ground -> node "0";
  frag                             other rails -> ideal sources; open nets -> 1 Gohm leak
      |
      | expandCapacitorParasitics(frag, bias)   C -> C + ESR + ESL, DC-bias derated
      | expandSourceImpedance(frag)             every source gets a finite rout/lout
      | addImpedanceProbe(frag, rail, "0")      DC 0 AC 1 across the rail
      v
  deck  --  writeNetlist(frag, cards = [".ac dec 20 1e3 1e9", ".control ... .endc"])
      |
      | ngspice -b -o log deck.cir
      v
  rawfile  --  parsed into SimResult / SimVector  (sdReal | sdComplex)
      |
      | analysis/measure.nim: pure curve math over openArray[float]
      v
  AnalysisReport { measurements, issues, assumptions, raw }
      |
      | the evaluators/ harvest adapter (common.harvest)
      v
  seq[AssertionResult]
```

### Why that order and no other

**`materializeSimNetlist`, not a bare `clone`.** A component's `simReplace` is
the design's own statement of how it wants that part simulated. A part may
carry *several*, because which model is right depends on the question: an
averaged model of a switching regulator answers the rail voltage in
milliseconds of wall clock and has no ripple in it to find, while a switching
one answers the ripple and costs fifty timepoints a cycle. Neither is better,
and a design forced to pick one would be choosing which question it is allowed
to ask. `selectSimModel` picks by `purpose` — `spOperating`, `spSmallSignal`,
`spStartup`, `spSteadyState`, `spLargeSignal` — which names **what is being
asked, not which SPICE card gets written**. Both LT8640A models are `.tran`
models; naming the card would put them in one bucket and leave the choice to a
coin toss.

**Flatten before any model pass.** `expandPinModels`, `expandSourceImpedance`
and `expandCapacitorParasitics` all walk only `nl.components`, so a part inside
a subcircuit instance is invisible to every one of them. Left un-flattened, an
op-amp inside a subcircuit never gets a macromodel and reaches the deck as
`U1` — which ngspice reads as a uniformly-distributed RC line. `flatten` lives
under `spice/` rather than beside `graph.instantiate` because it destroys the
hierarchy the designer wrote: it is a simulation-only concession, and putting
it in `netlist/` would invite someone to flatten a real design.

**Stand in for unmodellable parts *before* isolating, not after.** `isolate`
refuses to traverse a component whose behaviour is not fully described by its
value and records it in `dropped` — so by the time isolation has run there is
nothing left to model. Once each such part is a per-pin impedance it is
passive, and the rail sees what it actually hangs off instead of an open
circuit.

**Model substitution runs most-specific first.** A `subNetlist` or a
`simReplace` is honoured and never reaches the registry; a kind registered in
the behavioural-model registry gets its model; only a part with neither falls
through to per-pin impedances, which is the **last** resort and not the first
answer. `BehavioralResult.handled = false` means *leave the part exactly as it
is* — emphatically not "fall back to per-pin impedances", because an LDO stood
in for by two independent resistors to ground reports its rail at 0 V, which is
a confident wrong answer where refusing to simulate was an honest one.

**Parasitics after isolation, on the fragment.** They are not a refinement: an
ideal capacitor's impedance falls monotonically forever, so a PDN sweep over
ideal caps shows no ESR floor, no self-resonance and no anti-resonance — none of
the three things such a sweep is run to find.

### Where the boundary falls is the whole result

`spice/isolate` cuts a simulatable fragment out of a full design. Two rules do
the work, and `maxHops` is a backstop rather than the mechanism:

* **a rail is a boundary and is never traversed through**, unless it was named
  a seed — every bypass cap on a board shares VDD, so one hop through it
  absorbs the entire design;
* **an unmodellable component is never traversed through** either.

Terminating the cut is the other half: ground becomes node `"0"`, every other
rail gets an ideal source at its nominal voltage (from `IsolationSpec` or
`Net.attrs["voltage"]` — never guessed), and every open or excluded net gets a
1 Gohm leak to ground so it has a DC reference instead of producing a singular
matrix.

`excludeRails` exists because **an ideal source is a dead short at AC**.
Terminating the rail whose impedance you are measuring would report Z = 0 at
every frequency. The same field carries the transient twin of that hazard:
leave a ferrite-filtered analog rail out of a start-up seed set and it becomes a
stiff ideal source at 3.3 V driving current backwards through the filter into a
rail still at zero — measured, **2.8 kA of inrush against a true 163 mA**.

The related trap, recorded because the fix is easy to undo: `voltage_source` is
in `conductiveKinds`, so `isPassive` accepts it and an isolation *absorbs* a
supply rather than cutting it. Measured, the same rail read 129 mohm with no
source and **0 ohm with one**, passing every target that could be set.
`expandSourceImpedance` is what stops that.

### The print step is also the solver's step ceiling

Every `.tran`-backed analysis here derives a print step when the caller states
none, and it is easy to read that as a display setting. It is not: ngspice
defaults its own **maximum internal timestep** to the print step, so the figure
sets how accurately the circuit is *solved* and not merely how often the answer
is written down.

Which quantities notice differs, and the split is clean. A settling voltage and
a peak-to-peak barely do. Anything **phase-sensitive** does — a frequency
directly, and a distortion figure through the window it integrates over.
Measured on `designs/wien_osc.nim`, whose 20 ms window is 31 whole periods: at
`analyzeTransient`'s thousand samples across the window the oscillation reads
1568.4 Hz, at ten thousand 1573.26, and at a hundred thousand 1573.31. The
ordinary default was therefore wrong by 0.31%, three times the band that
design's frequency claim is worth stating at, and wrong in a way that looks
like a circuit measurement rather than like a setting.

So `runWindow` takes a `windowSamples` parameter and `analyzeOscillation`
passes ten times what `analyzeTransient` does; the cost on that design is
0.42 s against 0.06 s. `TransientSpec.tStep` and `tMax` remain the caller's
own overrides — `tMax` in particular exists for a design where the caller
knows the switching rate and the parts do not.

The same argument has not been made for `analyzeStartup`, which still sizes
from the run length rather than from a window; see `docs/findings.md`.

### Sweeping and running are different questions

The `.ac` family measures by hanging an ideal source on a stage's input net.
That is exactly right at an input and catastrophic at a node the feedback
returns to, because an ideal source **holds** the node: a Wien bridge returns
its positive feedback straight to `IN+`, so driving there shorts the bridge out
of the circuit. Before it was caught, `gain_stage` reported `f_hi_3db` of
289 kHz for a circuit whose entire behaviour is at 1.59 kHz, and **the claim
passed at exit 0**. `opamp.checkInjectionPoint` now refuses it by name.

But the deeper point is that no version of a swept measurement answers the
question. An oscillator has no transfer function, because there is nothing to
sweep it *from*. So `analysis/analyses/transient` holds three analyses over one run:
`analyzeTransient` reports what a node **settled to**, `analyzeOscillation`
reports what it is **running at**, and `analyzeCurrent` reports what is
flowing **through a part**. They share `runWindow` deliberately — having the
questions diverge in the simulator setup as well as in the arithmetic is how
one of them quietly measures a different circuit.

Reaching a circuit that will not start is the other half.
`TransientSpec.initialConditions` emits an `.ic` and forces `uic`, which puts
the state somewhere the circuit has to move away from; the `oscillator` role's
optional `kick` part is how a design says where and how hard. `uic` is not free
— it skips the operating-point solve, so every node not named starts at zero
rather than at its bias — and that cost is declared as an assumption on every
run that uses it. `analyzeStartup` reaches for the same mechanism for the
opposite reason: a regulator that brings its own model soft-starts, and an
operating point would find the state that ramp settles *to*, so the run would
begin at the end of the thing being measured.

### A current is not a node

Everything else this library measures is a voltage, and for a long time that
was not a choice so much as a consequence: a branch current is not in a `.op`
for anything but a voltage source, so `current_rating` and `isat` sat
registered, set by the part policy on every inductor it chose, and read by
nobody. For a converter that is the check that matters most, because
saturation is its failure mode.

`analyzeCurrent` closes it, and the shape of the fix is dictated by one fact:
**a net has one voltage that every part on it shares, and no current at all**
— only the several different currents of the parts hanging off it. So
`spice.current_path` is the only evaluator here declaring
`subjectKinds: {skComponent}`, and its setup key is the measurement window and
*nothing else*: one `.tran` answers every claimed part, because the currents
are all readings of one set of waveforms. Keyed by part, as every other
evaluator here is keyed by its subject, `lt8640a_buck` would run its switching
model twice at fifty timepoints a cycle to read one run two ways.
`Measurement.at` carries the designator through the batch, which is what stops
one part's claim being answered with another's number.

Two smaller decisions carry the honesty. The three figures a rating is quoted
against — `i_peak`, `i_rms`, `i_avg` — are **magnitudes**, because a rating is
one and the sign of a branch current is a deck convention: an inductor's
follows whichever pin the design wrote first, and ngspice reports a voltage
source's current positive when it flows *into* the + terminal. And a device
with more than one terminal current is **refused rather than resolved** —
"the current through Q1" does not say collector, emitter or base, and the rest
of the batch is measured anyway.

### A difference is not a bias

Every analysis above answers a question at *one* operating point.
`analysis/analyses/operating` solves a single `.op` and `analysis/analyses/derating` reads it
back; `analysis/analyses/pdn` and `analysis/analyses/opamp` linearise about it. So the whole
family answers "what does this do *there*" — and a large part of what a
datasheet specifies is instead a difference between two biases: line
regulation, load regulation, dropout, a divider's ratio, an output resistance.
None of those is in an operating point however many of them you solve, which
is why `capSpiceDc` is its own capability rather than a mode of `capSpiceOp`.

`analysis/analyses/dcsweep` has two procs, and the split is about **where the stimulus
comes from**. `analyzeLineSweep` sweeps a source the design already contains,
resolved through `findComponent` after flattening and identified by
`deckDesignator`, so a source inside an instance works and a part whose `kind`
does not reach the deck as a `V` line is refused by name rather than swept as
whatever letter it got. `analyzeLoadSweep` sweeps a constant-current sink it
**injects** at the measured node — the same idiom `probes.addImpedanceProbe`
uses for an `.ac`, and for the same reason: a test load belongs to the
measurement, not to the board, and a part added to the netlist to be swept
would be a part on the BoM and in the layout. A sink and not a resistor,
because a resistor's current follows the node it hangs on, so sweeping one
sweeps the load and the drive together.

Neither expands capacitor parasitics — at DC a capacitor is an open circuit,
so its ESR is in series with nothing — and neither expands source impedance,
because `expandSourceImpedance`'s default 10 mohm is an *invented* series
resistance that a load sweep would add to the very output resistance it is
measuring. And neither isolates, following `runDcVoltage`'s precedent: a cut
rail is terminated at its nominal, which on a regulation measurement is the
answer.

Two results are worth stating because they are decisions rather than
arithmetic. **`dropout_v` is `NaN` when the output never left regulation**,
with an issue saying to sweep lower: "no dropout was found" and "the dropout
is small" are opposite conclusions, and `verdict` reads a `NaN` as
*notEvaluated* rather than as a pass. That is also exactly what an idealised
regulator model reports over any range at all, which is the honest outcome
rather than a flattering one. And **the swept range joins the setup key**, so
two claims over two ranges are two runs: on `templates/dc_sweep.nim` the same
Zener reference measures 1.67% of line regulation over its specified 6–16 V
and 41.6% over 3–16 V, because most of the wider range is below the knee.
Neither number is wrong; they are answers to different questions, and a
planner that pooled them would report one of them as the other.

### A regulator is not a node voltage

Everything up to here holds the input still and the load still. A regulator is
specified the other way round — by what it does when they move — and three
things a datasheet's front page is written around were unaskable however many
operating points were solved.

**The load step** is the time-domain twin of `power_rail`'s `targetZ`, and the
thing a target impedance is a *proxy* for. `analyzeLoadStep` is the only
analysis here that changes the circuit to ask its question: it injects a
pulsed constant-current sink through a `mutate` hook on `runWindow`, called
after the model passes and before the probe resolves. A sink rather than a
resistor, for the same reason `analyzeLoadSweep` gives, and pulsed rather than
swept because the answer is a shape in time. Two decisions carry it. The
baseline is what the rail was *actually* sitting at before the edge, not what
the design says it should be. And the recovery is measured against where the
rail settles **under the new load**: load regulation moves that point, and
counting the shift as a failure to recover reports a correct regulator as an
unstable one. Its band defaults to 1% and has to be stated tighter whenever
the droop is smaller than that, or the rail never leaves it and the recovery
reads a confident zero — which is the one wrong answer of this shape that
looks like a right one.

**Ripple rejection** is `analysis/analyses/psrr.nim`, and it is two measurements rather
than one with a mode. The `.ac` sweep finds a curve's worst point; the `.tran`
tone answers at one frequency with a real amplitude, which matters because a
`.tran` is not linear and a ripple big enough to move a duty cycle gets a
different answer. They need different capabilities, and `Evaluator.needs` is a
single set, so one evaluator declaring `{capSpiceAc, capSpiceTran}` would be
refused on a host offering only one. Two evaluators, disjoint quantities.

How the ripple gets in follows `probes.addCurrentProbe` rather than rewriting
the supply's value string: the supply's output pin is re-netted onto a fresh
net and the ripple source goes between that and the original input net. The
value string may be anything, and this composes correctly with
`expandSourceImpedance` — whose 10 mohm and 1 uH then sit in series with the
ripple, which is physical rather than an artefact.

The honesty here is a **refusal**. `spice/models.regulatorModel` stands an
unmodelled part in as an ideal source at its output voltage, which by
construction has no path from its input to its output; so does a behavioural
model that commands a voltage rather than a duty. Measured, an `.ac` sweep
through an XSPICE code model returns exactly zero output, because a code model
contributes to the AC matrix only if it sets `AC_GAIN`. In every one of those
cases the output sits at the solver's noise floor while the input does not,
and that is reported as *not evaluated* naming the missing feedthrough. The
difference between "this regulator rejects perfectly" and "nothing was
simulated that could fail" is the whole product.

**Output current against the rating** needed no new analysis at all.
`spice.current_path`'s setup key is the window, so a regulator's output-current
claims batch into whatever `.tran` was already running — and one quantity was
added to it, `i_out_derating`, which divides the *sense* part's RMS by the
*regulator's* stated `current_rating`. `runCurrent` already had both halves in
hand: the subject gives the sense part and `Assertion.origin` gives the role
binding that names the regulator.

That last point is why all of this lands in `roles/power.nim` as parameters on
`regulator` rather than as three more roles. A load step needs a rail *and*
knowledge that something is regulating it; a rejection needs a supply and an
input pin; an output current needs a sense part and a rated regulator. All of
those are bindings a regulator role already has or can take, and
`linear_regulator` and `switching_regulator` expand the base whole before
adding their own, so a claim added to the base cannot drift between the three.

### What crosses the process boundary

`spice/ngspice.run(nl, analysis, setup, codemodels)` takes **one analysis card
and any number of setup cards**, and the split matters. One analysis per call
is a real limit: ngspice's default `write` keeps only the last analysis's plot,
and a `SimResult` holds exactly one plot with one `dataKind`. But `.ic`,
`.nodeset`, `.options`, `.param` and `.temp` are not analyses — they configure
the analysis that follows and produce no plot — and the guard used to count
cards, so one analysis plus one setup line was refused as "two cards". That is
what blocked `.ic`, and `.ic` is the only way to reach a circuit that will not
start from its own operating point: an oscillator's operating point is a
balance it never leaves, so a `.tran` from it reports a flat line. A known
analysis card in the `setup` slot raises; an unknown card is passed through
rather than guessed at.

`run` synthesizes a `.control` block, sets `filetype=ascii`, writes a rawfile, and
treats **"a parseable rawfile exists"** as the success signal rather than the
process exit code — a clean run with benign warnings can exit non-zero, and a
malformed deck can SIGABRT.

But **a parseable rawfile is not the same as a solution**, and the difference
cost a real answer. ngspice reports a failed DC solve as a *warning*, writes
whatever its last iterate was, and exits zero — so the numbers arrive looking
exactly like an answer. The LT8640A reference design's 5 V rail read **1.71 V**
as a clean FAIL because one node had no DC path. The log is now scanned for
`singular matrix`, `iteration limit reached`, `too many iterations` and `no
convergence`, and the run raises naming the node. The marker list is
deliberately narrow: `gmin stepping failed` and `source stepping failed` are
*strategy* notes ngspice usually recovers from.

`VERAX_KEEP_DECKS=<dir>` copies every deck handed to ngspice into a directory.
This is the primary debugging loop, and it is not a convenience: the fragment
simulated is *derived* — cloned, flattened, model-substituted, isolated — so it
is not the netlist anyone wrote, and reasoning about a surprising number from
the design file alone is guesswork.

### The run archive

`--keep-runs=<dir>` (or `$VERAX_KEEP_RUNS`) keeps the **results** as well as
the deck. Per simulation it leaves `run000.cir`, `run000.raw` and `run000.log`,
plus a `run000.svg` -- a self-contained schematic of the *derived* fragment
that ran, laid out and routed by `schematic/` (see
docs/netlist-converter-research.md) -- and a `run000.json` holding the same
routed scene through the public JSON API, writable *and* readable back by
`schematic`'s strict `jsonToScene` reader (which is what lets a scene-based
fallback diagnostic ask, from the archive alone, why a dashed marker is
there) -- and one `index.txt` row naming the
run's label, analysis card, netlist, plot, whether the data is real or complex,
and its vector, point and byte counts:

```
slot    status  label            analysis                 netlist       plot              data     vectors  points
run000  ok      operating point  .op                      sensor_node   Operating Point   real     12       1
run001  ok      pdn:vdd          .ac dec 20 1e+03 1e+09   pdn_vdd       AC Analysis       complex  38       121
run002  ok      startup:vdda     .tran 2.5e-06 5e-03      startup_vdda  Transient Analy.  real     15       2027
```

The index is the part that makes a directory of `run000` … `run012` usable at
all: a rawfile does not say which circuit or which analysis produced it, and
here the circuit is derived rather than authored. `run` knows the netlist but
not which claim it is serving, so it takes an optional `label` that the ten
analysis call sites pass.

Two properties are worth stating because they came from design decisions rather
than falling out. The destination is chosen **before** anything is written, so
ngspice writes all three files straight into the archive instead of them being
copied afterwards — which means the archived deck *is* the one that ran, its
`write` line names the rawfile beside it, and re-running it in place reproduces
that rawfile byte for byte apart from the header timestamp. And a **failed** run
gets an index row and keeps its deck and log, because that is precisely the run
someone wants to read; both files are already on disk by the time anything
raises.

One file in the archive is not a run at all: `runFULL.svg`, a schematic of the
*authored* `Design.netlist` written by `verify` before `readiness` runs
anything, with its `runFULL.json` scene written from the same routed layout.
The per-run `runNNN.svg`/`runNNN.json` files are the derived fragments —
isolated, flattened, model-substituted — so none of them is the circuit the
author wrote; `runFULL.svg` is, drawn once and overwritten every check. It is
best-effort (a rendering failure cannot fail the check), gated only on
`$VERAX_KEEP_RUNS`, and deliberately absent from `index.txt`: the index names
one analysis run per row, and this picture is not a run, so it takes no
`runNNN` slot either. A hierarchically-authored design also gets one
`runFULL.<subckt>.svg`/`runFULL.<subckt>.json` per distinct subcircuit it
instantiates — deduplicated by the `.SUBCKT` name, so a block used twice is
drawn once — each with its interface drawn as Altium-style port symbols
(direction taken from pin kinds, or from whether anything on the sheet drives
the net). These are subject to the same gate, best-effort handling and
index exclusion. `--schematic-layout=constrained-layered` (or
`$VERAX_SCHEMATIC_LAYOUT=constrained-layered`) names the layout policy these
archived SVG/JSON artifacts already use by default -- the only policy, and
the same one an ordinary `layout` call uses. `LayoutPolicy` stays an enum of
one value rather than being deleted, so a future second policy has somewhere
to land; the flag is a no-op until one exists.

The rawfile is ngspice's own ASCII format, so it goes straight back in:

```
ngspice
  load run001.raw
  display
  plot v(vdd)
```

### What ngspice saves, and the one thing it doesn't

Worth knowing before reaching for a knob: **verax is not saving a subset.**
With no `save` card at all ngspice's output stage starts at `saveall` and only
drops to an allowlist once one exists, and `write <path>` with no vector list
dumps the whole plot — so every rawfile here already carries every node voltage
and every voltage-source and inductor `#branch` current. The genuinely absent
category is device *internals* (`@r1[i]`, `@d2[id]`, `@m1[gm]`), which are
computed from the solution rather than being part of it and never appear unless
asked for.

`--save-currents` (or `$VERAX_SAVE_CURRENTS`) asks, by emitting a `.save` card
built from the netlist. Two things about it are load-bearing:

- **`all` leads the list.** Naming any vector turns the default set off, so a
  card that said only `@r1[i]` would archive a resistor's current and throw away
  every node voltage.
- **It is never emitted for an `.ac`-family analysis.** A `@r1[i]` is
  real-valued; in a complex plot ngspice writes it as a bare real token among
  the `real,imag` pairs, and `parseRawfile` rejects that line as malformed. An
  unguarded version of this would turn every frequency sweep in the library into
  a parse error.

That second point is also why the card is built here rather than by asking for
`.options savecurrents`, which injects at parse time whatever analysis follows —
and which the *simulator's* option table does not know, it being a frontend-only
keyword, so it reports `unknown option` into the log of every run that uses it.

Selecting more output cannot move a solved number: a `.save` is read after the
matrix is solved. It does multiply an archived rawfile's size — 701 KB to 1.9 MB
on `sensor_node`'s start-up transient.

### Assumptions are the pipeline's output too

Every simulation-backed analysis works by filling in data a netlist does not
carry: an assumed soft-start ramp, a package-typical ESL, a substituted ideal
op-amp, an ideal rail source, a leak resistor on an open port. A number derived
from an invented input has to say so where the reader will see it.

They are `Assumption` **records** from `netlist/annotations`, not prose, so a
consumer can count them or filter by provenance. `AnnSource` distinguishes
`annAuthored` (the design said so), `annDerived` (computed from what the design
said) and `annDefaulted` (nobody stated this). `invented(results)` returns
exactly the values nobody stated — a question that is unanswerable while
assumptions are strings.

Provenance lives in the accessor's **return type** (`AnnValue[T]{source,
value}`), which is why it could not have been added later without touching every
call site. Accessors are pure and **never default**: inventing a stand-in is a
policy decision belonging to whichever consumer knows what a sensible stand-in
is.

---

## 6. The four registries

Extensibility here is uniformly "a runtime table of data objects carrying proc
values", never a compile-time construct. The reason is a stated product goal:
ship compiled, and let a user add their own without recompiling the library.

| registry | keyed by | added with | consulted by |
|---|---|---|---|
| roles | role name | `registerRole(RoleDef)` | `design.addRole`, `plan` |
| evaluators | quantity name | `registerEvaluator(Evaluator)` | `plan`, `runStep` |
| behavioural models | `Component.kind` | `registerBehavioralModel` | `spice/models.expandPinModels` |
| annotations | `attrs` key | `registerAnnotation(AnnDef)` | the DSL (at compile time) and `validateAnnotations` |

Two guard rails matter.

**`registerEvaluator` raises when a quantity is already produced by a
*different* evaluator.** `quantityIndex` is a flat map, so a second registration
would take over every claim on that quantity in every design, with nothing said
— the same quantity name in the report either way, and a different analysis
behind it. Re-registering under the *same* name still replaces, because that is
the documented way an application overrides a built-in: an override says so by
keeping the name, a collision is an accident, and once it has happened the two
are indistinguishable.

**`Evaluator.binds` is declared, not inferred.** It names the role *parts* an
evaluator reads back off `Assertion.origin`, beyond the assertion's own
subjects. Something has to answer "can a bare `require` reach this quantity?"
*without running anything*, and only the evaluator knows. `overshoot_pct(vdd)`
names the rail but not the regulator driving it, and nothing in a netlist
recovers that. This is what `verax quantities` reports in its third column,
and its three answers — `require`, `role: X`, `-- needs a role binding` — are
genuinely different; conflating any two is how a reader writes a claim nothing
will check.

Setup topology is recovered the same way at run time: the role expanders' code (`roles/power.nim` and its siblings) stamps the
role-instance name into `Assertion.origin`, so an evaluator reads the bindings
back off `Design.roles[origin]`. Resolution order is **subjects → origin-role
bindings → `condition` → `notEvaluable` naming what was missing**. That last
message is the product when a claim cannot be checked.

---

## 7. Invariants

Things that are true today, that something depends on, and that are easy to
break silently. Most were violated at least once before being written down.

1. **`graph.nim` is the only writer of back-references.** Everything else goes
   through `addComponent`/`connect`/`adoptNet`/… or the two directions drift.
2. **The design netlist is never mutated and never simulated.** Every analysis
   clones first. Probe insertion and model expansion run on the clone.
3. **A kind `isPassive` accepts must be something the deck writer can spell** —
   either `designatorPrefix` knows its letter, or a model pass rewrites it into
   parts that do. `expandPinModels` stands in for every part `isPassive`
   *rejects*, so those never reach a deck as themselves; `isolate` absorbs every
   part it *accepts*, so those do. `tests/test_spice_spellable.nim` generates
   this from the kind tables rather than reciting a list.
4. **The deck's device letter comes from `Component.kind`, not from the
   authored designator.** SPICE infers device type from that first letter and
   nothing else. `VR1` for a drive pot emitted 250 kohm of feedback network as a
   250 kV source; the stage measured a gain of 12 instead of 65 with nothing
   reported anywhere. The letter is **prepended, never substituted**
   (`FB1` → `LFB1`, never `L1`), because designators are unique as a set and a
   truncated one need not be.
5. **A value written into a deck goes through `spiceValue`**, which always emits
   an explicit exponent. SPICE reads a trailing letter as a unit multiplier, so
   `15.9M` in a deck is 15.9 *milli*. `eng()` is presentation only.
6. **Annotation values are SI base units and suffixes are rejected**
   (`parseAnnFloat`), while deck values *are* suffixed (`parseSpiceMagnitude`).
   `"20m"` is 20 milli in a deck and 20 units read naively; picking either
   silently is the failure the annotations module exists to prevent.
7. **`.MODEL` card bodies are never parsed.** Tracking every parameter of every
   device type in every SPICE dialect means getting one wrong silently simulates
   a different part. `kinds.hasDeviceModel` only asks whether the name is
   present — which is what makes the statement matter beyond reaching the deck,
   since `isPassive` accepts a part with a model.
8. **Bare annotation key means registered, dotted means owned.** `value`,
   `esr`, `package`, … are the shared vocabulary; `xspice.*`, `role.*`,
   `boundary.*`, `parasitics.*`, `kicad.*` are namespaced and never validated.
9. **Role membership lives on the entity** (`net.attrs["role.i2c0"] = "sda"`),
   so it survives `clone`, `extractSubcircuit` and `isolate` — including
   isolation's rename of ground to `"0"`, which a name-keyed side-car store
   would have lost.

---

## 8. Deliberate non-goals

Stated so nobody re-litigates them, and so the boundaries of an answer are
legible.

* **`units.nim` is not a dimensional-analysis system.** No unit arithmetic, no
  derived units, no compile-time dimension checking. That is a much larger
  design and buys nothing for the job at hand.
* **The contract layer is not an expression language.** Almost every claim is
  "quantity Q of subjects S under conditions C lies in interval I", and
  `ExpectKind` today is exactly `ekNominal`/`ekMin`/`ekMax`/`ekRange`/
  `ekRelative`/`ekPredicate`. When a claim is not that shape, the escalation
  is: put the arithmetic in a Nim proc emitting a *derived quantity* (an SPI
  setup margin is a computation over datasheet numbers, not a measurement),
  then `ekRelative` (a bound referring to another measurement —
  `number * measurement` on the right), then `ekPredicate` (a non-capturing
  Nim proc over named dependencies). `Expectation` is a variant object, so
  the two added without touching the evaluator ABI: the planner decomposes
  them into hidden measurement requests and folds them back. **Nim is the
  expression language** — at the cost of no parser, no evaluator and no
  bespoke error messages.
* **`netlist/environment` models nothing.** It carries a board's ambient range
  and a part's rise above it, and joins them. There is no tempco here, and the
  figures are deliberately **not** passed to the deck as `.options temp`, which
  would change how every semiconductor behaves and silently move every number
  this repo has measured.
* **`pcb/Zone` models both the authored outline and, now, the derived fill**
  (`Zone.fills`, populated by `formats/kicad.readPcb` from `(filled_polygon)`).
  `fills` is empty on an unfilled board or a keepout, and a caller must treat
  empty as "not answerable", never "no copper" — plane-shape, return-path
  and power-integrity analysis are answerable once a board has been read
  with fills present, and `fem/extrude.extrudeZones` is the first consumer.
* **Reading an XSPICE `A` line back into ports is not supported** and cannot be
  without the model's `.ifs` — with `%type` omitted the node count per port is
  unknowable from the deck alone. Writing works.
* **A fuse blowing is not modelled.** A design check asks whether the circuit
  works, not what it does while failing.

---

## 9. Where to look next

| question | file |
|---|---|
| how do I write a design? | `docs/authoring.md` |
| what is still broken or unclaimable? | `docs/findings.md` |
| what did checking real boards teach us? | `docs/RESOLVED_FINDINGS.md` |
| what roles/quantities/annotations exist *right now*? | `verax roles`, `verax quantities`, `verax annotations` |
| what was actually simulated? | `VERAX_KEEP_DECKS=<dir> verax check <design>` |
| what did the simulation actually return? | `verax check --keep-runs=<dir> <design>`, then `load <dir>/run000.raw` in ngspice |
