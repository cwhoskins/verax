# Resolved findings

Findings that are fixed, each with what it was and what the fix was. Anything
still open lives in `findings.md`. The numbering is shared and continuous
across the two files, so a `§n` cross-reference means the same thing in either.

---

# What three real designs found

Three non-trivial designs were written against this library and checked, and
this is what checking them turned up. They live in `designs/` and all three
pass `nimble verify` today. The point of the exercise was not to get them
green — it was to find where a real board runs out of road, so the list of
gaps below is the actual product.

**Status: §1–§13 are fixed** (see each entry), and §14 (hierarchy) was
decided and fixed by §16.
Every fix carries tests; `nimble test` and `nimble verify` are green.

| design | what it is | why it was chosen |
|---|---|---|
| `ts808_drive.nim` | Ibanez TS808 "Tube Screamer" drive stage | single-supply, AC-coupled, synthesised half-rail bias, clipping diodes in the loop |
| `sensor_node.nim` | USB → LDO → MCU + I2C sensor, ferrite-filtered analog supply | exercises start-up, PDN and bus checks at once, and a custom role |
| `aa_filter.nim` | 4th-order Butterworth anti-aliasing filter, split rails | DC-coupled and low-pass — the case the op-amp quantities were defined for |

Where the tool is right, it is *precisely* right, and that is worth recording
alongside the faults. Section 1 of the filter measured a 15.7 kHz corner
against 15.63 kHz from the closed form for a 2nd-order section at
f₀ = 21.3 kHz, Q = 0.549; section 2 measured 3.07 dB of peaking against
2.92 dB predicted for Q = 1.291, the difference being the finite GBW of the
macromodel. The TS808's bias node measured 4.48 V against 4.478 V hand-
calculated for a 10k/10k divider loaded by R4 into the op-amp's input
stand-in. Negative rails work. The planner batches correctly — the sensor
node's 14 claims collapse into 4 simulation runs and 5 graph walks.

---

## 1. The deck writer spells a device from the designator, not from `kind`

**Fixed.** `deckDesignator` takes the letter from `Component.kind`, prepending
it when the designator disagrees. Tests in `tests/test_netlist_spice.nim`.

**What it was: this silently simulated a different circuit.**

`formatDeviceLine` emitted `comp.designator` verbatim. SPICE infers device type
from that first letter, so the declared `kind` is discarded:

```nim
component FB1, kind = "inductor",       value = "600n"   # -> FB1 a b 600n
component BT1, kind = "voltage_source", value = "DC 9"   # -> BT1 b 0 DC 9
component J1,  kind = "voltage_source", value = "DC 5"   # -> J1 a 0 DC 5
```

ngspice reads those as a current-controlled current source, a behavioural
source and a JFET. Every standard EDA designator that is not also a SPICE
device letter collides: `FB` (ferrite), `BT` (battery), `J` (connector),
`SW` (switch), `TP` (test point), `Y` (crystal).

Those three at least fail loudly, though the message points at SPICE syntax
rather than at the cause — the TS808 first reported `mal formed B source
instance` and three unrelated claims came back "not evaluated". **The silent
cases are worse:**

```nim
component C12, kind = "inductor", value = "600n"   # -> a 600 nF capacitor
component L7,  kind = "resistor", value = "10k"    # -> a 10 kH inductor
```

Both parse, both simulate, both give a confident wrong answer, and nothing
anywhere reports it.

The invariant was already enforced for parts the tool *synthesises* —
`spice/transform.replaceComponent` derives its prefix and `spice/probes`
validates one — and only the authored path was unguarded. The letter now
comes from `kind` and is **prepended, not substituted** (`FB1` → `LFB1`,
never `L1`): designators are unique as a set and a truncated one need not be,
so substituting would merge `FB1` and `L1` on a board carrying both.
`deckInstanceDesignator` does the same for hierarchical instances, always
spelling them `X`, since ngspice reads `U` as a distributed RC line.

**This one had already bitten, unnoticed.** `designs/ts808_drive.nim` uses
`VR1` for its drive pot — the standard designator for a variable resistor,
and also SPICE's voltage source. 250 kΩ of feedback network was going out as
a 250 kV source, so the stage measured a gain of 12 where the circuit has 65,
and its reported peaking was 20.6 dB against a true 31.6 dB. Nothing anywhere
said so. The design's claim was corrected along with the writer.

## 2. Start-up reports impossible inrush when a downstream rail is annotated

**Fixed.** `analyzeStartup` seeds and un-terminates every rail downstream of
the regulator (`downstreamRails`). Tests in `tests/test_analysis_startup.nim`.

**What it was: a wrong number, off by 17,000×.**

In `sensor_node.nim`, `vdda` sits behind a 600 nH ferrite and is annotated
`voltage = 3.3.V` because it *is* a rail. With the inrush claim's subject on
`vdd`:

```
poweron.inrush -- inrush_peak(net 'vdd') <= 2.00 A
    measured 2.80 kA
```

Drop the annotation and the same design measures **163 mA**.

`analyzeStartup` seeds the isolation with `@[outputNet]` plus the measure net.
A rail outside that seed set becomes a *boundary termination* — an ideal
source — so `vdda` is held stiff at 3.3 V and drives current backwards
through the ferrite into a rail still ramping from zero.

This is the transient twin of a trap the AC path already guards against:
`pdn.excludeRails` exists precisely because "an ideal voltage source is a
dead short at AC". `analyzeStartup` had no equivalent. Here the answer was
absurd enough to catch by eye; swap the ferrite for a small series resistor
and it would have been merely plausible.

The walk crosses `isPassive` parts only, so it stops dead at the regulator
and never reaches the *input* rail — which genuinely is up before start-up
begins and must keep its ideal source. Seeding rather than merely excluding
is what pulls the downstream rail's own capacitor bank into the fragment,
which the regulator really does have to charge. The inrush figure is now the
same wherever the rail is judged, which it was not before.

## 3. `phase_margin_deg` returns 450° for a Sallen-Key — and passes

**Fixed.** Three validity checks; both margins now come back `NaN` with a
`KindLoopBreakInvalid` issue. Tests in `tests/test_analysis_opamp.nim`.

**What it was: a stability claim that cannot fail.**

`analyzeLoopGain` breaks the loop at the amplifier's inverting input, which
opens the only feedback path a plain amplifier has. A Sallen-Key has two:
C1 feeds from the R1/R2 junction back to the *output*, and that positive path
is what produces the section's Q. Breaking at the inverting input leaves it
closed, so the measured T is not a loop transmission. Its phase starts at
**+79°** rather than 0, and passes through +180 while |T| is still above
0 dB:

```
      1.000 Hz  |T|  85.76 dB   phase   78.81 deg
  1.585e+04 Hz  |T|   8.74 dB   phase  170.80 deg
  3.162e+04 Hz  |T|   8.59 dB   phase -159.80 deg
  1.000e+06 Hz  |T|  -0.20 dB   phase  -90.08 deg     <- crossover
```

`unwrapDeg` carries the crossover phase to +270, and `180 + phaseAtX` gives
**450°** — which then satisfies `minPhaseMargin >= 45` without complaint.

A plain follower and a gain-of-2 stage both measure a correct 90°, so the
loop machinery is sound; it is the second feedback path it cannot see.

All three guards are now in: a phase margin outside (−180, 180]; more than
one 0 dB crossing; and a low-frequency phase not within 30° of 0 or 180,
which is the signature of a break that actually opened the loop. Any of them
withholds both margins and attaches an issue naming which fired.

`NaN` reads as *notEvaluated* downstream, deliberately not a failure — the
circuit may well be fine, it is this measurement that cannot say. The
closed-loop peaking measured alongside is still a real indicator.

**Two follow-on defects, found by trying to use the fix and both now fixed.**
`verdict`'s declining paths dropped the analysis's `issues` and
`assumptions`, and `renderResult` never printed a result's issues at all —
so the diagnosis this fix exists to produce reached nobody, and the reader
saw only "the quantity was not found in the range that was analysed", which
points at the sweep range rather than the topology. Issues now print under
failed and unchecked results, de-duplicated across the report because
evaluation is batched. A passing result's issues stay hidden: it passed.

## 4. Only one op-amp per analysis gets a macromodel

**Fixed.** `opampModel` gives any unmodelled op-amp the same macromodel.
Tests in `tests/test_spice_models.nim` and `tests/test_analysis_opamp.nim`.

**What it was: multi-stage signal chains could not be measured at all.**

An analysis substitutes a macromodel for the single amplifier it is named,
and every *other* op-amp in the path goes through `expandPinModels` — 1 MΩ
on each input, 50 Ω on the output, all to ground. That destroys the path
through it.

Measuring the 4th-order filter end-to-end (`input = vin, output = vout`)
therefore reports **82 dB of peaking and a 2.04 MHz corner** for a circuit
whose real answer is maximally flat to 20 kHz. Each section measured
separately is correct to better than 1%.

That blocked any active filter above 2nd order, instrumentation front ends,
multi-stage preamps, and any buffer-plus-gain chain — most analog boards.
The filter now measures **19.7 kHz and 655 mdB** end to end, against ~19.8 kHz
by hand, and `designs/aa_filter.nim` makes that claim.

The substitution chain now runs most-specific first, which is the shape worth
keeping: a `subNetlist` or a `simReplace` is honoured and never reaches the
registry; a registered kind gets its model; only a part with neither falls
through to per-pin impedances, which is the **last** resort rather than the
first answer.

Two things had to follow. The macromodel is emitted **flat, not as an
instance of `idealOpAmp`** — `spice/isolate` refuses to traverse anything
carrying a `subNetlist`, so a macromodel dropped in as a subcircuit is cut at
the very boundary it was added to bridge, which cost that filter 11 kHz
instead of 20. And `detachDrivers` now removes whatever already drives the
net a sweep is about to drive: a preceding stage's output is a VCVS, and
putting the stimulus across it is two ideal sources on one node, which
ngspice answers with a singular matrix and which surfaced as `key not found:
frequency`.

## 5. Every gain and bandwidth quantity is DC-referenced

**Fixed.** `gainMax`/`bandEdges` in `measure.nim`, four new measurements plus
`gain_at_f` in `analyzeOpAmpResponse`, and a `gain_stage` role to claim them.
Tests in `tests/test_analysis_measure.nim`, `tests/test_analysis_opamp.nim`
and `tests/test_contract_roles.nim`.

**What it was: no AC-coupled stage could be described.**

`measure.corner3dB` measures relative to *the first swept point*, documented
as "which for a sweep started well below the corner is the DC/passband
value". For a single-supply stage the first swept point is in the
**stopband**, because the gain-setting leg is capacitively coupled — that is
what makes single-supply operation possible. The TS808 drive stage reports:

| quantity | measured | what it means here |
|---|---|---|
| `gain_dc_db` | 0.001 dB | true, and useless — the stage's actual gain is ~21 dB |
| `bw_3db` | 710 kHz | 3 dB below *unity*, on the far side of the hump |
| `peaking_db` | 20.6 dB | the intentional mid hump, not resonance |

None of the three is wrong arithmetically and none answers a question anyone
would ask about the circuit. Worse, `peaking_db` cannot distinguish an
intentional band-pass shape from instability, which is exactly what it is
used for on the `opamp_stage` role.

Missing: midband/passband gain, low corner, high corner, centre frequency,
and gain at a stated frequency. This affects essentially every audio,
guitar-pedal and single-supply sensor front end.

## 6. Ten advertised quantities cannot be claimed by anything built in

**Fixed.** Reachability is reported per quantity, the common specs gained
role parameters, and the custom-role path is documented. Tests in
`tests/test_cli_discovery.nim`.

**What it was.** `verax quantities` listed 26. A design with a bare `require` for all 26 gets
**10 evaluated and 16 `not evaluable`** — the 16 need topology the assertion
does not carry (which component drives the rail, which part is the
amplifier), recovered from the role that expanded the claim.

The built-in roles expose 6 of those 16. The remaining **ten are advertised
and unclaimable** by any built-in path:

```
inrush_peak  t_inrush_peak  rise_time_10_90  settle_time
crossover_hz  gain_margin_db  loop_gain_dc_db
f_unity  gain_bw_product  gain_dc_db
```

There *is* a way through, and it works: write a role. `sensor_node.nim`
defines a `power_on` role that reaches `inrush_peak`, `rise_time_10_90` and
`settle_time`, and `aa_filter.nim` defines a `filter_section` role — both
using no privileged mechanism, exactly as the design intends. But nothing
tells a reader that. The error message says "bind a `regulator` part on the
role that expands this claim" without mentioning that no built-in role does.

Suggested: mark reachability in `verax quantities`; add the missing
parameters to the built-in roles; document the custom-role path in
`docs/authoring.md`, since it turned out to be the single most useful
extension point and is currently undocumented.

## 7. A role's always-claims cannot be declined

**Fixed.** `without` is reserved on every role. Tests in
`tests/test_contract_roles.nim`.

**What it was.** `opamp_stage` claims `phase_margin_deg` unconditionally. For
a Sallen-Key that measurement is invalid (see §3), and the only way not to
make it was to write a whole replacement role — which is what
`aa_filter.nim` did, for a stage that is otherwise exactly what
`opamp_stage` describes.

```nim
  role "opamp_stage", filt, opamp = U1B, input = vin, output = vout,
       minBandwidth = 18.kHz, maxPeaking = 1.0,
       without = "phase_margin"
```

`without` is reserved on every role rather than declared by each one — a
role should not have to opt into being declinable. It takes a
comma-separated list of claim suffixes.

Two things keep it from becoming a way to hide claims. Declining is
**stated**: `explain` prints `declines phase_margin`, and everything that
reads a design's claims goes through one `expandInstance`, so what is
printed and what is checked cannot drift. And a suffix that matches nothing
**raises**, naming what the role does claim — the same hazard as a
misspelled annotation key, caught by expanding once at `addRole`, which is
free because an expander is pure:

```
role 'opamp_stage' instance 'sec2' cannot decline 'phase_margn':
it does not claim that. It claims phase_margin, peaking
```

`aa_filter.nim` now uses `opamp_stage` on all three stages and its custom
`filter_section` role is gone — 7 claims, none unchecked, ~65 fewer lines.

## 8. `deg` and `dB` have no unit literal

**Fixed.** `Degrees` and `Decibels` in `verax/units`. Tests in
`tests/test_units.nim`.

**What it was.**
`verax role opamp_stage` advertises `minPhaseMargin [deg]` and
`maxPeaking [dB]`, but `verax/units` has no such suffix, so:

```nim
role "opamp_stage", drive, ..., minPhaseMargin = 50.deg   # compile error
role "opamp_stage", drive, ..., minPhaseMargin = 50.0     # what you must write
```

A bare float in a list of unit literals is precisely the misread hazard the
units module exists to remove.

## 9. An `ntPower` net with no voltage is silently cut loose

**Fixed.** `checkRailVoltages` reports it in STRUCTURE. Tests in
`tests/test_analysis_io_check.nim`.

**What it was.** The TS808's 4.5 V bias rail comes from a 10k/10k divider, so no `power_rail`
role fits it and it initially carried no `voltage`. The isolation then cut it
loose as a floating node, which detached the gain leg and turned the drive
stage into a **unity-gain follower**. Peaking measured 5.9 mdB, bandwidth
390 kHz, and the report said `6 passed, exit 0 (clean)`.

Adding one annotation moved peaking to 20.6 dB — the real circuit.

The ASSUMPTIONS section did say `rail 'vref' left floating (no nominal
voltage known)`, so the tool was honest. But that line reads like the
package-default ESR two lines above it, and it is not the same kind of thing:
the others substitute a *value*, this one changes the *topology*. Being
reported and being *noticed* are different, and the difference is which
section it lands in.

It now lands in STRUCTURE, at the top of the report, naming the components
that would lose their connection — R6, the gain leg that was the actual
casualty, among them:

```
STRUCTURE  1 issue(s)
  [warning] rail_voltage_unknown
      net 'vref' is a power rail with no stated voltage, so an analysis that
      cuts a fragment out around it leaves it floating rather than driving it
      -- which changes the topology rather than substituting a value. State it
      with `spec: voltage = ...` on the net, or give it a `power_rail` role.
      R9, R10, R1, R4, R6 terminate on it and would lose that connection.
```

Bypass capacitors are skipped from that list: a rail carrying only power pins
and decoupling loses little by floating, one with a signal path returning to
it loses the path. `sevWarning`, so it is visible without being fatal —
`--strict` promotes it. Both shipped templates gained a rail voltage as a
result, which they should have had anyway.

## 10. An assertion's subject can disagree with what was measured

**Fixed.** `Measurement.at` names where a number came from when that is not
the subject. Tests in `tests/test_analysis_startup.nim`.

**What it was.**
`inrush_peak` is probed on the source driving the role's `output` net. The
assertion's subject selects the isolation's seed set, not the probe point —
so `inrush_peak(net 'vdda')` prints as though vdda were where the current
was measured, and it is not. (In `sensor_node.nim` the subject must stay on
the judged net anyway, for the reason in §2.)

## 11. No device models, and no way to attach a `.MODEL` card

**Fixed**, both halves — the `.MODEL` statement, and then a large-signal
analysis to make use of it.
Tests in `tests/test_netlist_dsl.nim` and `tests/test_spice_models.nim`.

**What it was.** `Netlist.models` carried `.MODEL` cards verbatim, but the
design DSL had no statement that wrote one. So a diode was stood in per-pin
like any unmodelled part.

```nim
  model "1N4148", "D(IS=2.52n RS=0.568 N=1.752 CJO=4p M=0.4 VJ=0.4 " &
                  "BV=110 IBV=100u TT=20n)"

  component D1, kind = "diode", partNumber = "1N4148", value = "1N4148":
```

The card body is **never parsed** — tracking every parameter of every device
type in every SPICE dialect means getting one wrong silently simulates a
different part, whereas passing it through means the simulator reads exactly
what the datasheet said. What reads it is `kinds.hasDeviceModel`, which only
asks whether the name is present (case-insensitively, as SPICE is). That is
what makes the statement matter beyond reaching the deck: `isPassive` accepts
a part with a model, so `spice/models` stops standing it in and
`spice/isolate` traverses it.

**And the stand-in was not a small error.** Without a card each TS808 diode
became two 1 MΩ resistors to ground, and the pair shunted the inverting node
with 500 kΩ — a second gain leg, which lifted the stage's gain at the bottom
of the sweep from unity to 4.2 dB. That is where a reported 31.6 dB of
peaking came from, against a real 35.3.

For the small-signal sweep the old behaviour was defensible — off diodes are
approximately open — but it meant the clipping, the thing that makes an
overdrive an overdrive, was outside what could be checked at all.

### Large signal

`.ac` cannot see clipping *at all*: it linearises about the operating point,
where the diodes are off. So `analyzeLargeSignal` drives a sine and measures
what comes out — `thd_pct`, `output_swing`, `clip_high`/`clip_low`,
`gain_compressed_db` — claimed through a `large_signal` role where `driveV`
and `driveF` are **conditions rather than limits**, because the answer is a
function of them.

On the TS808 drive stage at 1 kHz:

| drive | swing | THD | gain |
|---|---|---|---|
| 10 mV | 0.55 V | 14.7% | 29.8 dB |
| 50 mV | 0.81 V | 26.7% | 19.7 dB |
| 200 mV | 1.24 V | 25.5% | 10.9 dB |

That is the pedal: output clamped to about a diode drop either side of the
4.5 V bias, and the gain collapsing from 35 dB small-signal as the drive
rises. A 20× increase in drive buys 2.3× more swing.

Two decisions carry it. **The stimulus carries the node's own DC bias**,
found with a `.op` on the same fragment first — a single-supply stage sits at
a mid-rail operating point, and a `SIN(0 ...)` source on its input would
clamp that node to zero and measure a circuit biased into its own stop.
(Coupling through a large capacitor also preserves the bias and is worse: the
settling time constant becomes the input resistance times that capacitor,
seconds for an ordinary input network.) And **the harmonic integration reads
the samples' own timestamps** rather than resampling, because a `.tran`
result is not uniformly sampled and ngspice takes its smallest steps exactly
where the harmonics live.

The role offers `minThd` as well as `maxThd`, which is not a slip: on an
overdrive, too *little* distortion is the defect — a stage measuring clean
has lost its clippers.

### The amplifier can now run out of swing

That limit is closed. Unbounded, the macromodel's output buffer is a VCVS —
an ideal source, which cannot saturate however hard the loop drives it.
Given the part's stated rails it becomes a `B` source carrying
`min(max(V(N2), lo), hi)`. (Clamping the VCVS's *output* with diodes does
nothing: an ideal source holds its node regardless of what is hung across
it. The clamp has to sit between the pole and the buffer.)

A gain-of-11 stage on ±5 V rails, driven at 1 V peak:

| rails | swing | clip | THD |
|---|---|---|---|
| unstated | 22.0 V | ±11.0 V | 0.0001% |
| stated ±5 V | 10.0 V | ±5.000 V | 42.9% |

42.9% is what a hard-clipped sine gives. Small-signal results are bit-identical
either way, so the change is invisible where the amplifier never approaches
its rails.

**The clamp is applied only by a large-signal caller**, and that is not an
optimisation — it is required. `min`/`max` has a zero derivative at its
limit, so an `.ac` linearisation of a stage whose operating point sits on a
rail returns *no gain at all* rather than the small-signal gain it has. A
single-supply stage with a ground-referenced input sits exactly there, which
the existing test suite demonstrated immediately.

Still not modelled: slew rate and output current limit. And at the default
`vsatHeadroom` of 0 the model saturates exactly at the supply, which no real
amplifier does — so it bounds the swing rather than predicting it, and says
so as an assumption. The same
applies to every transistor: `ts808_drive.nim` declares its 2SC1815 emitter
followers as `kind = "buffer"` to keep the signal path closed, which is a
reasonable stand-in and is not the part.

Large-signal behaviour generally — clipping, slew limiting, distortion — is
absent, and for an audio circuit that is most of what matters.

## 12. Nothing bounds an I2C pull-up from below

**Fixed.** A `pullup_sink_current` quantity, claimed by the `i2c` role.
Tests in `tests/test_contract_evaluate.nim`.

**What it was.**
The `i2c` role checks `pullup_count >= 1` and `rc_corner >= 10 × fclk`, both
of which catch a pull-up that is too *weak*. Nothing catches one too strong.
The I2C spec requires a target to hold VOL ≤ 0.4 V while sinking 3 mA, which
puts a floor near 1.1 kΩ at 3.3 V. `sensor_node.nim` runs 1.2 kΩ — chosen
because 1.5 kΩ failed the RC check — and is therefore close to the opposite
limit with nothing to say so.

## 13. `assertionId` is private

**Fixed.** Exported.

**What it was.**
A user-defined role must hand-build assertion ids and cannot produce the
`<instance>.<suffix>` convention through the same helper the built-ins use.
Both custom roles written here duplicate it as `inst.name & ".inrush"`.

## 14. `isolate` refuses to traverse a subcircuit, and need not

`growSelection` folds `comp.subNetlist != nil` into a variable called
`unmodellable`, which is close to backwards — a subcircuit is the most
thoroughly modelled thing in the graph. The consequence is that a
hierarchically-authored board has every block cut at its boundary, so there
is nothing left to simulate.

**Nothing structural prevents it.** Flipping that one term and pushing a
signal through a two-section Sallen-Key whose first amplifier is a
hierarchical instance of `idealOpAmp`:

| | `bw_3db` | `peaking_db` | `gain_dc_db` | dropped |
|---|---|---|---|---|
| today | 11.2 kHz | 0.082 dB | −3.02 dB | `XU1` |
| flipped | **19.67 kHz** | **0.655 dB** | −0.0002 dB | none |

19.67 kHz matches the flat macromodel exactly and ~19.8 kHz by hand. The
machinery is all there already: `clone` recurses into nested hierarchy,
`removeComponent` deletes the `children` entry, `extractSubcircuit`'s
boundary computation is parent-level (correct — internal nets are not in the
parent's `nets`), `terminate`/`renameNet` work at the parent level, and the
writer already emits `.SUBCKT` blocks and `X` lines.

Two real costs, neither structural:

- **The model passes do not recurse into children.** `expandPinModels` and
  `expandSourceImpedance` do not, and `expandCapacitorParasitics`
  deliberately does not — correctly, because `idealOpAmp`'s pole capacitor
  must not be given an ESL. But that reasoning holds for a *synthesized
  macromodel* and fails for a *design-authored block* full of real 0402s,
  which would silently get ideal capacitors and make a PDN sweep meaningless
  above a megahertz. Note this hazard is **already reachable**: seed
  designators go straight into `selected` with no passivity check, and
  `analyzeOpAmpResponse` explicitly supports a design bringing its own
  macromodel. The guard only stops the walk from *wandering* into one.
- **Fan-out.** Everything traversable today is 2-terminal (R/C/L) or
  4-terminal (a controlled source), so branching is naturally bounded. A
  subcircuit instance is an arbitrary N-terminal element: crossing a 60-pin
  block enqueues 60 nets in one hop. `maxHops` backstops it and rails still
  cut, but the bound is far looser.

The distinction that actually matters is **synthesized macromodel vs.
design-authored hierarchy**. `attrs["parasitics.expanded"]` already marks
modelling elements, so the concept exists — it is just applied per-component
rather than per-subtree. An `IsolationSpec.traverseSubcircuits` (default
false), plus recursion in the model passes that skips synthesized subtrees,
is the shape.

### Measured, decision deferred

**No route has been chosen.** What follows is the evidence gathered so the
choice can be made later without redoing it.

A prototype flattener (inline each child, mangle internal names, keep global
nets shared, depth-first) was run against the same two-section Sallen-Key:

| | `bw_3db` | `peaking_db` | dropped |
|---|---|---|---|
| today | 11.2 kHz | 0.082 dB | `XU1` |
| traversal predicate flipped | 19.67 kHz | 0.655 dB | none |
| **flattened** | **19.67 kHz** | **0.655 dB** | **none** |

Two results beyond "it gives the right answer":

- **`maxHops` stops mattering.** Identical at 3, 6 and 12, nothing dropped at
  the default. That kills the fan-out objection raised against traversal:
  after flattening there is no N-terminal opaque element to cross, so the
  walk sees the two-terminal passives it was designed around and the hop
  budget means something physical again.
- **`attrs["parasitics.expanded"]` is already per-component**, which is
  exactly the granularity flattening needs. `idealOpAmp`'s pole capacitor
  carries it, so flattening plus the *existing* model passes gets both cases
  right — real 0402s inside a design-authored block get an ESR, modelling
  elements do not. The traversal route instead needs four passes taught to
  recurse **and** a per-subtree notion of "synthesized" that does not exist.

**The one real reason to avoid it**, and it is specific rather than general:
flattening dissolves any component something else refers to *by designator*.
A role binds `opamp = U1`; `findOpAmpPins` needs that component present with
named `+`/`-`/`OUT` pins; and `analyzeOpAmpResponse` has an explicit branch
honouring a design's own subcircuit macromodel untouched. Flatten
unconditionally and it is gone:

```
before flatten: XU1 present = true, subNetlist = true
after flatten:  XU1 present = false
  -> analysis FAILED: no such component: XU1
```

So the shape is `flatten(nl, keep)` — never dissolve a part a role binds or
an analysis names, flatten everything below it. That is a constraint the
traversal route does not have, and it is the only one found.

Costs that are real but do not decide it: a block instantiated 40 times
becomes 40 copies rather than one `.SUBCKT` and 40 `X` lines; and an issue
points at `XU1_R1` rather than "R1 inside XU1", which a provenance attribute
would recover. It also solves the documented "cannot probe inside a nested
subckt instance" limit for free, since every internal node becomes a
top-level one.

**Still unchecked before shipping either:** whether `checkFeedback` can walk
through a flattened amplifier's internal RC and report feedback that is not
there. It skips `subNetlist` components today, and after flattening there is
nothing to skip.

**Pre-flattening, in the original framing:** Rather than
teaching the walk to cross hierarchy, a pass that inlines every child into
its parent — mangling internal net and designator names, hoisting the
contents, keeping global nets shared — would let every existing pass work
unchanged, including the model passes and their per-component
`parasitics.expanded` marking. It is plausibly the smaller change and it
removes a whole class of "does this pass recurse?" question rather than
answering it once per pass. It costs the ability to report a finding against
the hierarchy the designer wrote, which may matter for messages. Worth
measuring both before committing: the flattener is ~one graph walk, while
the traversal route touches four passes and an `IsolationSpec` field.

---

# What four more designs found

`designs/charge_pump.nim`, `designs/wien_osc.nim`, `designs/riaa_preamp.nim`
(with `designs/lib/riaa.nim`) and `designs/lt8640a_buck.nim` (with
`designs/lib/lt8640a*.nim`). They were chosen for what they are *unlike*: the
first three designs were all small-signal amplifiers and rails, and nothing in
the tree switched, oscillated on purpose, transferred charge, spanned more than
one file, or reached the simulator through a code model.

Status: §15–§22, §25–§30 and §32–§38 are fixed; §31 is closed by §32 and §33.
§23 and §24 are recorded and are not — they are in `findings.md`.

## 15. `global = true` could not compile, and nobody had noticed

`net gnd, name = "0", global = true` expanded to `globals[name] = net` — a bare
`OrderedTable` assignment — so any design using it failed with
`attempting to call undeclared routine: '[]'` unless the design file imported
`std/tables`.

This is *precisely* the hazard `graph.setModel`'s doc comment describes and
guards against for `.MODEL` cards, in the same file. The global path was written
the way `setModel` explicitly says not to, and it survived because **`global =
true` is only worth stating when there is a child netlist to share a net with**,
and no design had one until now.

**Fixed** by `graph.registerGlobalNet`, which the DSL calls instead.

## 16. §14, decided: flatten for simulation

`spice/flatten.nim`. Depth-first, innermost first; port nets merge through
`Pin.hierNet`; ground merges rather than becoming `XL.0`; `clone`-shared globals
are left alone; `keep` protects an instance something names, and a `keep` entry
matching nothing **raises**.

The separator is **`.`** — `XL.U1`, `XL.XA.R1`. It is what ngspice itself
produces when it expands a subcircuit, so this also closes the documented
"cannot probe inside a nested subckt instance" limit; and `contract` already
spelled `DESIGNATOR.pin` with the same meaning, so one dot uniformly means
"descend one level". The cost is that pin resolution can no longer split on the
first or last dot — XSPICE names a differential port's pins `name.p`/`name.n` —
so `graph.findPin` searches split points right to left, longest component prefix
winning.

It runs **on the work clone, before any model pass**, and that ordering is the
argument for the whole route: `expandPinModels`, `expandSourceImpedance` and
`expandCapacitorParasitics` all walk only `nl.components`, so a part inside an
instance is invisible to every one of them. Left un-flattened, the RIAA
channel's op-amp never got a macromodel and reached the deck as `U1` — which
ngspice reads as a **uniformly-distributed RC line** and rejects with `Unable to
find definition of model vp`. Flattened, all three passes work on hierarchy
unchanged, which is what §14 measured and predicted.

**§14's open question, answered.** It asked whether `checkFeedback` could walk
through a flattened amplifier's internal RC and report feedback that is not
there. Not for a design-authored block: `checkFeedback` runs on the design
netlist, before `prepare` substitutes any macromodel, so what it walks is the
designer's own network. The case that must be guarded is a design bringing its
*own* subcircuit macromodel, and that instance goes in `keep`.

**What it does and does not resolve about designators.** The conflicts *hierarchy* creates it resolves by construction: an instance designator is a key in the parent's `components` table, so it is already unique among its siblings, and prefixing with it makes `XA.R1`/`XB.R1` distinct without any search or counter. Duplicates within one netlist never arise — `addComponent` refuses them. What it cannot resolve is a name the design already spelled the way flatten is about to generate one, and there it **raises** rather than renaming: the message names the instance being flattened *and* describes what already held the name, because a reader told only "that name is taken" has no way to see that one side of the clash was generated. See §25 for the case that survives all of this.

Tests: `tests/test_spice_flatten.nim` (12), including a deck round-trip pinning
that a flattened `XA.R1` is emitted as `RXA.R1` — `deckDesignator` prepends the
letter from `kind`, the same invariant that turns `FB1` into `LFB1`, now
load-bearing far more often.

## 17. A role could not bind anything inside an instance

`Design.resolve` looked only at `d.netlist.components`, and the identifier for a
part inside a `subckt` in another module is not in scope at the design site. So
a stereo board instancing one channel twice had **no way to say which
amplifier** a claim was about.

**Fixed**: `resolve` goes through `graph.findComponent`/`findNet`/`findPin`,
which try the flat key first and then descend — so one call finds the entity
before flattening *and* after, and nothing holding such a name has to know which
world it is in. `Component.innerComponent`/`innerNet`/`innerPin` build the
`Subject`, walking the child immediately so a typo raises here naming what the
instance actually contains. A one-line `subjectOf(Subject)` identity overload
opens the DSL's existing `when compiles(subjectOf(value))` binding test to them
with no macro change. Tests: `tests/test_contract_dsl.nim`.

## 18. An `.ac` sweep silently opened the loop it was measuring

Every `.ac` proc here measures a stage by hanging an ideal source on its input
net. An ideal source **holds that node** — which is what you want at an input
and catastrophic at a node the feedback returns to.

`designs/wien_osc.nim` is the clean case: its positive feedback lands directly
on `IN+`. Driving there shorts the whole Wien bridge out of the circuit, and
what got measured was a flat gain of 3.2 rolling off at GBW/3.2. The tool
reported `f_hi_3db` of **289 kHz** for a circuit whose entire behaviour happens
at **1.59 kHz**, the claim `fHiMin = 1.53.kHz` passed on it, and the design
exited **0 (clean)**. A wrong number that passes is worse than no number.

**Fixed** by `opamp.checkInjectionPoint`, run before the sweep. The test is a
**conjunction** and both halves are needed: the driven net is one of the
amplifier's own input pins' nets, *and* the output reaches it through passives.
Either alone over-triggers — an ordinary inverting amplifier's input net reaches
the output through `Rin`+`Rf` but is not an op-amp pin, and a non-inverting
amplifier's input *is* `IN+` but nothing feeds back to it.

The passive walk for this test additionally **refuses to traverse a rail**, the
same rule `spice/isolate` applies. The TS808 settled that: `vout` genuinely does
reach `vamp` through the 47 uF-bypassed 4.5 V bias rail, which is an AC ground
and not feedback. Without that guard the fix reported five false unevaluables on
a design that was clean.

Tests: `tests/test_analysis_opamp.nim`, six cases including both over-trigger
shapes.

## 19. A subcircuit's port net was reported as a floating rail

`checkRailVoltages` recurses into children, and a channel's `VP` port net
carries no voltage of its own — the parent states it. A stereo board therefore
reported `rail_voltage_unknown` **once per instance** for a rail that is stated.
§9 exists to make a genuinely floating node impossible to overlook; burying it
among false ones undoes that. **Fixed**: a net that is a port of its netlist is
skipped, its identity being the parent's.

## 20. The substituted op-amp's GBW could not be stated

`spice/models.idealOpAmp` defaults to 1 MHz and `OpAmpSpec.idealGbw` is
unreachable from a contract. The RIAA stage is 39.8 dB, so its loop gain at
1 kHz is Aol(1k)/98 and the default cost **0.7 dB** there — against an NE5534,
which is a 10 MHz part. Measured 39.1 dB where the network gives 39.77.

Seven times the accuracy the equalisation network was designed to, and it would
have been reported as the circuit's gain rather than the model's. **Fixed**: a
`gbw` annotation, registered like `gain` and read in preference to the default,
with the assumption suppressed when it is stated. `designs/lib/riaa.nim` states
it and now measures 39.7 dB.

## 21. A code model could never reach the simulator

`spice/xspice` could build a `.cm` and instantiate an `A` device, and
`ngspice.run` took a `codemodels` argument — but **none of the eight call sites
passed it**, so no design could ever be verified through a code model. Worse,
`kinds.hasDeviceModel` returns true for a code-model component (its `value`
names a card in `nl.models`), so `isPassive` is true and `isolate` cheerfully
absorbed it into a fragment that then died inside ngspice with `unable to find
definition of model` — an error about a model name, three steps from a missing
file path.

**Fixed** by putting the answer on the component (`attrs["xspice.cm"]`, dotted
so the registry never validates it) and having `run` union
`instance.collectCodeModels(nl)` with its explicit argument. Every call site is
unchanged. An attribute rather than a `Netlist` field because the netlist
reaching ngspice is never the one the design built — it is a fragment from
`clone` → `flatten` → `expandPinModels` → `isolate` — and `attrs` rides through
all of those for free.

Three things fell out of making it work end to end:

- **`SimReplacement` could not express a code model.** Its `kind`/`pinNets`
  shape reaches `replaceComponent`, which never touches `nl.models`, so the
  `.MODEL` card would be lost and the part would stop being passive — the exact
  failure the model was added to fix. Added `SimReplacement.build`, an optional
  proc handed the materialized clone and the part to stand in for.
- **Importing a code model dragged in the FFI**, which needs ngspice's MIF
  headers — so a design instantiating one could not compile on a machine with
  ngspice but not its sources. The entry point is only ever wanted by
  `buildCodeModel`; `verax check` now passes `-d:xspiceSpecOnly` and gets the
  `ModelSpec` without the implementation.
- **`findToolchain` required `$NGSPICE_SRC`** even when a configured tree sat in
  the cache directory. Forgetting the variable did not fail loudly, it made the
  design quietly report `not evaluated` for the one part the tree was fetched
  for.

## 22. A failed DC solve was reported as an answer

`run` treats "a parseable rawfile exists" as the success signal, because
ngspice's exit code is not reliable. But ngspice reports a failed DC solve as a
**warning**, writes whatever its last iterate was, and exits zero — so the
numbers arrive looking exactly like an answer.

`designs/lt8640a_buck.nim` found it. The datasheet circuit hangs C_BST between
BST and SW and nothing else, and the averaged model had no BST pin, so that node
had no DC path anywhere. ngspice printed `singular matrix: check node bst` and
carried on; the 5 V rail was reported as **1.71 V**, as a clean FAIL against a
real number.

**Fixed**: the log is scanned for `singular matrix`, `iteration limit reached`,
`too many iterations` and `no convergence`, and the run raises naming the node.
The marker list is deliberately narrow — `gmin stepping failed` and `source
stepping failed` are *strategy* notes, and ngspice usually recovers after them.
Treating those as fatal declared the TS808's bias-finding `.op` a failure, which
took its large-signal drive offset to 0 V and its output swing with it. Tests:
`tests/test_spice_ngspice.nim`, both directions.

Also added while chasing this: `$VERAX_KEEP_DECKS` copies each deck handed to
ngspice into a directory. Every fragment simulated here is *derived* — isolated,
terminated, model-substituted — so it is not the netlist anyone wrote, and
reasoning about a surprising number from the design file alone is guesswork.

## 25. Graph uniqueness does not imply deck uniqueness

Asked whether flattening resolves reference-designator conflicts, and testing
rather than reasoning about it, turned up one that survives every check above.

`deckDesignator` **prepends** the device letter from `kind` rather than
substituting it. That is deliberate and §1 explains why: substituting would
merge `FB1` and `L1` into one device on a board carrying both. But prepending is
**not injective**. A resistor designated `XA.R1` and a resistor designated
`RXA.R1` are two distinct components in the graph, pass every uniqueness check
the graph has, and emit one line:

```
graph designators: RXA.R1, XA.R1
deck: RXA.R1 a 0 9k
deck: RXA.R1 a 0 1k
```

ngspice sees one device defined twice. Nothing raised, and the fragment
simulated is not the circuit.

This predates flattening — the non-injectivity was always there — but it was
unreachable in practice while every designator was hand-written and short.
`spice/flatten` makes generated, dotted designators ordinary, which moves it
from theoretical to reachable.

**Fixed**: `writeNetlist` calls `checkDeckDesignators` on the top level and on
each `.SUBCKT` block, raising and naming both graph designators and the deck
spelling they share. Per level rather than per deck, because SPICE scopes
designators inside a `.SUBCKT`. There is no safe way to guess which one was
meant, so it refuses rather than renaming. Tests:
`tests/test_spice_flatten.nim`.

## 26. A dielectric is not paperwork -- it changes the capacitance

Asked to look at ratings on passives, and measuring before designing: the same
decoupling bank, once at its nominal values and once with its Class 2 ceramics
where DC bias actually puts them.

| | `z_max_in_band` |
|---|---|
| nominal 10 uF + 2x100 nF | **173 mohm** |
| same parts, X5R at ~65% of rating | **1.23 ohm** |

**Seven times**, and larger than every other correction in `spice/models` put
together. A design claiming `targetZ = 250.mohm` passes on nominal values and
misses by 5x on the board. That settles what category `dielectric` is in: it
belongs beside ESR and ESL in the model-substitution path, not in a BoM field.

The vocabulary gained five keys — `dielectric`, `voltage_rating`,
`current_rating`, `isat`, `power_rating` — under a rule the existing registry
had already broken: **a key enters the bare vocabulary only when something
consumes it.** The evidence was sitting there. `tolerance` has been registered
since the beginning, is stated by `designs/lt8640a_buck.nim` on its feedback
divider, and **is read by nothing**. Five more like it would make the registry a
place where keys go to look meaningful.

`expandCapacitorParasitics` now derates before it expands.
`dcAcrossCapacitor` takes only the unambiguous case — one plate on the
reference, the other on a rail with a stated voltage — and returns 0 for a
coupling capacitor between two signal nets, meaning *not known here*, because
knowing would need an operating point this pass runs before. A package naming a
non-ceramic family is never guessed into a ceramic. Both the assumed dielectric
and the assumed rating are declared.

**The caveat belongs with the number**: real DC-bias loss depends far more on
case size and capacitance density than on the dielectric letter. A 10 uF 0402
X5R can be a fifth of its label at rated voltage while a 100 nF 1206 X7R barely
moves, and both are "Class 2". Class 1 is the exception that is exact rather
than typical, and that is what makes a timing capacitor's C0G a physics decision
rather than a preference.

It caught a fixture immediately. `tests/test_analysis_pdn.nim` builds bare
ceramics on a 3.3 V rail and checks closed-form identities against them --
SRF = 1/(2*pi*sqrt(LC)), |Z| = 1/(2*pi*f*C). Those are statements about the
capacitance a part *has*, so derating moved `f_z_min` by 25% and `z_at_100kHz`
by 54% and the tests failed. Correctly: the fixtures are now C0G, which is what
they always meant.

## 27. Ratings had no consumer, and the check is per family

`analysis/derating.nim`, one `.op` over the whole design -- **not isolated**,
for the same reason `runDcVoltage` is not: a fragment terminated with ideal
sources would check parts against voltages the boundary invented. It checks
`voltage_rating` against the DC across each part and `power_rating` on a
resistor against V^2/R, and `power_rail` gains an opt-in `maxDerating`.

Ceilings are **per dielectric family**, and the reason is not tidiness: a
tantalum is held to 50% because it fails *short* and takes the rail down with
it, whereas a ceramic's headroom is mostly about capacitance -- which §26 now
models directly. Applying the tantalum rule to ceramics would double-count the
same physics under two names.

A design stating no rating anywhere is **told so** rather than passed. An
operating point cannot tell a 6.3 V part from a 50 V one, so a silent pass would
be the tool inventing the answer.

**`current_rating` and `isat` are registered, set by the part policy, and
checked by nothing.** A branch current is not in a `.op` for anything but a
voltage source, and an inductor's peak needs a `.tran`. That is the gap that
matters for a converter, where saturation is the failure mode -- and it
compounds rather than averaging out, because an inductor near saturation has
less inductance than its label, so the ripple is larger than designed, which
pushes it further in.

## 28. A parameterized module cannot choose its own parts

The question `designs/lib/filters.sallenKeyLP(fc, r, q)` could not answer: it
computes that it needs 22.5 nF, and cannot compute *what part that is*.

The asymmetry is the whole finding. The module cannot choose, because the choice
depends on rail voltage, temperature range, space and cost, none of which it can
see. **The board cannot choose either**, because it cannot see which of the
module's capacitors sets a corner and which is a bypass -- and that distinction
decides the answer: a timing capacitor must be Class 1 or its corner moves, a
decoupling capacitor should be Class 2 because that is where the density is. So:
**the module knows the part's function, the board knows its environment, and
neither can choose the part alone.**

Both obvious answers fail concretely. Per-component builder parameters
(`c1Package`, `c1Dielectric`, `c1VoltageRating`, ...) multiply out with every
part in the module *and* still leave the board guessing at function. A pass that
annotates the netlist afterwards loses the compile-time checking a `spec:` block
gives and has to address parts by generated name.

`verax/parts` is the answer: the module states a `CapRequest` carrying a value
and a **use**, the board supplies a `PartPolicy`, `applyChoice` writes the result
as ordinary registered annotations. Proc-valued like `RoleDef`, so a policy built
at runtime from a preferred-parts database is not second class.

The default policy draws the line `spice/models` already draws for stand-ins --
**guess where the guess is forced, refuse where it is a choice**. C0G for a
timing part is physics and is defaulted silently. X7R for a decoupling part is a
judgement, is defaulted, and is noted every time, because it is exactly where a
wrong guess cost the 7x in §26. A rating is derived from the working voltage
when the module states one and **left unset when it does not**, since a coupling
capacitor in an unbiased stage genuinely has no known working voltage.

One thing fell out that is better than what was designed. `sallenKeyLP` passes
no `working` for its bypass capacitors -- it does not know the supply. It does
not need to: §26's pass computes the DC across each capacitor from the netlist
at simulation time, when rail voltages are stated. The policy answers "what kind
of part", the netlist answers "what is across it", and neither has to know the
other's business. An earlier sketch added a `supply` parameter to every builder;
it is not needed and would have been a second place for the rail voltage to
drift out of step.

Measured, on the split-rail Sallen-Key: the timing capacitors come out C0G and
the bypass capacitors X7R from the same policy call, and a deliberately
function-blind policy makes both X7R. Worth stating plainly: on **split rails**
the timing capacitors sit at 0 V DC, so the dielectric choice costs nothing
there and the corner does not move either way. It is the single-supply case, and
the bypass capacitors, where it bites -- and the tempco half of the argument for
C0G is real and is **not modelled at all**.

## 29. One operating point, shared -- and why it is not a fixed point

§26 derated capacitors from a **stated** rail voltage, which meant a capacitor
on any node nobody had annotated was not derated at all. That blind spot covers
exactly the nodes where bias is worst: a biased single-supply stage, a
divider-derived reference, a charge pump. Measured, a 10 uF rated 6.3 V across
the lower leg of a 12 V / 10k / 10k divider -- 6.00 V, **95% of its rating** --
came through at its full nominal value, because `mid` carried no `voltage`.

Chaining simulations usually means iterating to a fixed point. **It does not
here, and the reason is the whole finding: at DC a capacitor is an open circuit,
so the operating point cannot depend on capacitance.** Verified rather than
assumed --

```
v(mid) with 100p: 6.000000000000001   with 1000u: 6.000000000000001   identical: true
```

-- so `.op` -> derate -> `.ac` is a straight line. No convergence question, no
ordering ambiguity, no iteration. That same capacitor now derates to **3.29 uF**,
a factor of three that nothing could previously see.

`analysis/operating.nim` solves it once. It is deliberately **not isolated**, for
the reason `runDcVoltage` has always carried: isolation terminates a cut rail
with an ideal source at the rail's nominal voltage, which is the number half the
consumers are trying to find out. `voltageAt` returns **`NaN` for a node the
solver never saw**, which is a different answer from zero and must stay one.

The arithmetic came free. `dc_voltage` solved its own `.op`, `analysis/derating`
solved one per claimed rail, and every one was the same design with the same
answer -- `templates/rail.nim` went from three decks to two, and
`designs/sensor_node.nim` now runs **exactly one `.op`** across two rails and
several `dc_voltage` claims.

**The cache is keyed by design identity with no content invalidation**, and that
is a stated rule rather than an oversight: nothing inside `contract_eval` can
tell that a caller edited a netlist between two evaluations. Within one
`evaluate` the design does not change, so it is exactly right there;
`verify.readiness` calls `clearSharedOperatingPoint` on both sides to make every
entry start clean. `tests/test_analysis_operating.nim` pins that with a design
whose source is changed between two `readiness` calls -- it would fail if those
calls were removed.

**Stated limit: a `.tran` bias moves with time.** A charge pump's flying
capacitor and a rail that is still soft-starting have no single DC across them,
so one number from t = 0 does not describe them. Derating those from this is
less wrong than not derating them at all, and still wrong; anything that cares
should recompute per operating region.

## 30. Designators you did not write, and the injection that makes them safe

Two features that only work together, and the reason is worth stating before
either of them.

**Post-hoc override is the only thing that forces stable identifiers.** If the
way to vary an instantiated module is to reach into it from the board -- 
`findComponent(d.netlist, "XA.C1")` -- then every part it might want to reach
needs a name that is unique across the design and stable against edits. That is
exactly the identifier nobody wants to hand-author, and generating it makes the
handle as unstable as the generation. Name-based override and generated
designators are in direct conflict.

`instance ..., with = <proc (Netlist)>` removes the conflict rather than working
around it. The proc runs against **that instance's own clone**, immediately after
`instantiate` and before anything else sees it, so the variation happens at
construction and nothing ever addresses an individual anonymous part. Inside it
the only names are the module's **local** designators -- few, author-controlled,
and never leaving the module. That splits one impossible namespace into two easy
ones: hand-authored and local inside a module, generated and anonymous at board
level, never meeting.

An earlier sketch used `Component.name` as a stable handle. Rejected, and
correctly: it replaces one globally-unique-string-you-must-invent with another.
The distinction that matters is *who is responsible for uniqueness* -- the
compiler or the person -- and a second string field is still the person.

With that in place, `component kind = "capacitor", value = "100n":` may omit its
label. `graph.addGenerated` picks the designator from `kind` at **construction**,
not at macro expansion, because `kind` is an expression and a `for` loop's
iteration count is not knowable to the macro. Numbering is **per netlist**: a
subcircuit gets its own `C1`, so adding a part to one module cannot renumber
another. Hand-authored designators are respected, an explicit `designator =`
still wins, and omitting both a label and `kind` is a compile error rather than a
guess.

Generated ones are **marked** and listed by `generatedDesignators`, because a
designator is the join key to a board (`pcb/graph.bindComponent` raises on a
mismatch), a BoM line and silkscreen text -- and a generated one is positional.
Safe for a part nothing names and nothing places; wrong for anything already laid
out. That is self-selecting: needing to refer to a part is the signal to write
its designator.

The prefix table is **separate from the SPICE one and must stay separate**. They
disagree: `FB` on a schematic and `L` in a deck, `BT` and `V`. Deriving either
from the other is how §1 happened.

## 31. `kind = "ferrite_bead"` reaches a deck as a current source -- NOT FIXED

Found by a test written for §30, asserting what the documentation claims.

```
deck line: FB1 a b 600
```

`netlist/kinds.conductiveKinds` blesses `ferrite_bead` as a kind the library
understands, but `formats/spice.deviceKindByPrefix` has no entry for it, so
`designatorPrefix` raises, `deckDesignator` leaves the designator alone by
design ("a `kind` with no known letter is left alone, since there is nothing to
correct it against"), and ngspice reads the leading `F` as a
**current-controlled current source**. Exactly the §1 hazard, still live for any
kind the electrical classifier knows and the deck writer does not.

`designs/sensor_node.nim` sidesteps it by modelling its bead as
`kind = "inductor"` with designator `FB1`, which prepends correctly to `LFB1`.
So no design is affected today -- but §30 makes the bad path *more* reachable,
because generation now produces `FB1` from `kind = "ferrite_bead"` where before
somebody had to type it.

**Deliberately not fixed here, because the obvious fix is wrong.** Mapping
`ferrite_bead -> 'L'` would emit `LFB1 a b 600`, and a bead's `value` is
impedance at a frequency (600 ohm at 100 MHz), not inductance -- so the deck
would say 600 **henries**. The question "what does `value` mean for a part SPICE
has no device for" needs answering before the prefix does, and it is a different
decision from designator generation. The same gap covers `fuse`, `wire` and
`jumper`, which `conductiveKinds` also blesses.

`checkDeckDesignators` (§25) does not catch it: there is no collision, just a
wrong device.

## 32. A ferrite bead, modelled as one -- and §31 closed

§31 recorded that `kind = "ferrite_bead"` reached a deck as `FB1`, which
ngspice reads as a current-controlled current source, and deliberately did not
fix it: the obvious fix (map the kind to `L`) would have emitted `LFB1 a b 600`
and a bead's `value` is impedance, not inductance, so the deck would have said
600 **henries**. The question to answer first was what a bead actually is.

It is three numbers, and they build a model exactly:

    R = z_peak - dcr        L = R / (2*pi*f_peak*Q)
                            C = Q / (2*pi*f_peak*R)

a series DC resistance into a parallel R-L-C. At `f_peak` the reactances cancel
and the impedance *is* `R`, so the peak lands where the datasheet says **by
construction rather than by fitting**. Verified:

```
zpk = 6.00000e+02 at = 1.00000e+08      600.00 ohm at exactly 100 MHz
zdc = 6.08171e-01                       0.61 ohm at 100 kHz -- inductive, as a bead is
```

**Why it matters that this is not an inductor.** An inductor's impedance climbs
without limit; a bead's peaks where the core goes lossy and falls again, and that
peak is the entire reason a bead is chosen instead of an inductor. An inductor
model shows none of it. It also has no DC resistance, and on a supply rail that
is a steady IR drop and a floor the filter can never get below.

`Q` is the one thing the headline numbers cannot pin down -- `z_peak` and
`f_peak` fix the height and the location of the peak, not its width -- and
defaults to 1.0, which is broad. Beads are deliberately lossy; a high-Q bead
would be the inductor it was chosen instead of. A datasheet's impedance curve is
what pins it down properly.

`value` is read as ohms when `z_peak` is absent, following the convention a bead
is *sold* by, and `f_peak` defaults to the 100 MHz datasheets quote. Both are
declared as assumptions rather than silently applied.

§31 closes as a side effect rather than by a special case: after the pass there
is no `ferrite_bead` component left for the deck writer to misletter.

**Measured, on a real design.** `designs/sensor_node.nim` had modelled its bead
as `kind = "inductor", value = "600n"` -- the inductance a 600 ohm bead has well
below resonance -- because something had to reach the deck. Switched to the real
part with a stated 350 mohm `dcr`:

| | before | after |
|---|---|---|
| `overshoot_pct` on `vdda` | 109 m% | **0** |
| `inrush_peak` | 163 mA | 161 mA |
| `z_max_in_band` on `vdd` | 129 mohm | 125 mohm |

The overshoot is the interesting one and the new answer is the right one: an
ideal inductor into a capacitor bank is a lossless resonator, so the old model
rang at anything. A real bead's DC resistance damps it, and against a 1 ms
soft-start ramp -- two hundred times slower than the 196 kHz resonance -- there
is nothing to ring.

**A NaN nearly walked straight through the guard.** `parseSpiceMagnitude` sets
its out-parameter to NaN when it refuses, and `NaN <= 0.0` is **false**, so a
sign test alone let an unparseable `value` through and every element came out
NaN. Caught by the test written for it, and the check is now explicit about why
it tests for NaN as well as for sign.

## 33. The rest of §31, and the invariant that should have existed first

§32 modelled the ferrite bead. The obvious next step was three more
macromodels; the useful one was asking the machine *which* kinds were exposed,
and then pinning the answer so the question cannot come back.

Enumerated rather than read off:

```
resistor R    inductor L    voltage_source V   capacitor C   current_source I
vcvs E        vccs G        bsource B
wire  -- NONE --   jumper -- NONE --   fuse -- NONE --
cccs  -- NONE --   ccvs   -- NONE --
```

Two different problems wearing one symptom.

**`cccs` and `ccvs` were plain omissions** from the write-side table, next to
`vcvs`/`vccs`. Added, but for a narrower reason than those two: an `F`/`H` line
is *not* positional over nets -- its third token names the controlling voltage
source -- so writing one still emits the wrong arguments. Nothing synthesizes
either kind today, so that is latent. What was not latent is the letter: a
`cccs` designated `CCCS1` reached the deck unchanged and ngspice read the
leading `C` as a **2 F capacitor**, silently. A loud failure about a device that
exists beats that.

**`wire`, `jumper` and `fuse` needed models**, and they collapse to the same
resistor, differing only in where the number comes from -- which is the whole
hazard. **A link's `value` is ohms and a fuse's is amps.** A "0 ohm jumper" is
sold in ohms; a "2 A fuse" is sold in amps, and reading that as 2 ohms would put
forty times its real cold resistance in series with a rail and quietly explain
away a drop nobody would otherwise accept. So a fuse's resistance comes from
`dcr` and its `value` is read as `current_rating` -- the same question the bead
had to answer before it could be modelled at all.

Two things deliberately not modelled, stated rather than discovered: a fuse
**blowing** (an I^2t integral over a fault -- a design check asks whether the
circuit works, not what it does while failing), and trace inductance (roughly a
nanohenry a millimetre, and a netlist carries no length; that is `verax/pcb`'s
question).

### The part that matters

`tests/test_spice_spellable.nim` holds the invariant three separate bugs had
already violated:

> A `kind` that `kinds.isPassive` accepts must be something the deck writer can
> spell -- either `designatorPrefix` knows its device letter, or a model pass
> rewrites it into parts that do.

Passivity is what makes it load-bearing, and the reason is worth keeping
together in one place: `expandPinModels` stands in for every part `isPassive`
**rejects**, so those never reach a deck as themselves; `spice/isolate` absorbs
every part it **accepts**, so those do. A kind on the accepted side with no
device letter lands in the deck under its own first letter and is read as
whatever that letter means.

It is **generated, not listed** -- it iterates `conductiveKinds`,
`blockingKinds` and `behaviouralKinds` rather than reciting them, for the same
reason `verify.describeQuantities` computes reachability instead of writing it
down: a hand-kept list is exactly the thing that drifts from the tables it is
meant to describe. Verified to bite by adding a `solder_bridge` kind:

```
kind 'solder_bridge' has no SPICE device letter and was not expanded:
  it reaches a deck as itself
[FAILED] each one either has a device letter or is expanded away
```

§31 is now closed in full.

## 34. A connector is a boundary, and the board behind it is a subcircuit

There was no connector *type*: `"connector"` appeared in exactly one place in
`src/`, the designator-prefix table, so `isPassive` rejected it and
`expandPinModels` fell through to its last resort -- an independent impedance
from each pin to ground.

That is wrong in a specific way rather than approximate. `expandPinModels` is
documented as destroying any path through the part, which is right for asking
what a part *loads* a rail with and wrong for anything a signal must pass
through -- and a connector is nothing but a pass-through. Measured on a USB
inlet:

```
today, with no boundary handling:  v(vbus) = 0.0 V
with the port driven:              v(vbus) = 4.995 V
```

Zero, because VBUS was a megohm to ground and the board had no supply at all.

**The reason no macromodel fixes this**: each connector pin touches exactly one
net, so there is nothing on the other side to pass through *to*. A connector's
behaviour is entirely whatever is plugged into it, and only the designer knows
that. `designs/sensor_node.nim` had already worked around it by declaring its
USB inlet as `kind = "voltage_source"` with `rout`/`lout` -- modelling what is
*behind* the connector rather than the connector -- which is a legitimate choice
and also a sign the vocabulary was missing something.

`spice/boundary.nim` splits it in two, and the halves are separable:

* `asSubcircuit` promotes every connector pin's net to a port and drops the
  connectors. A **composition** feature: it changes no measurement. Ports are
  named after the **net**, matching `extract.extractSubcircuit`, because a net
  name is already unique where `J1.VBUS` would have to be invented and checked
  for collisions. Ground is never a port -- node `"0"` is global, so promoting
  it would create a second reference.
* `harness` attaches what is outside: a source of stated stiffness, a load, or
  nothing. The **simulation** feature, and the one that turns 0 V into 4.995 V.

A source is attached through its own `rout`/`lout` and never directly, for the
reason `expandSourceImpedance` exists: an ideal source is a dead short at AC, so
a port driven by one reports the rail behind it as 0 ohm at every frequency and
passes any decoupling target. A port nobody described is left alone rather than
defaulted -- inventing a supply for a pin nobody mentioned is how a rail comes
to measure its own assumption back -- and an unknown port name raises.

**`harness` does not build itself by instantiating `asSubcircuit`'s template.**
That was the obvious implementation and it is pointless: `flatten` would undo
the round-trip immediately and the result is identical for more work. The
subcircuit is for export and for saying where the boundary *is*, not for making
the sums come out. Worth writing down because the two goals sound like one.

**A gap the composition half exposed**: `writeNetlist` silently drops
`Netlist.ports`. Correct for a board -- a top-level SPICE deck has no port
concept, so there is nowhere to put them -- and silently wrong for a template
built to be reused, which is exactly what `asSubcircuit` returns. Added
`formats/spice.writeSubcktDefinition`.

**It is symmetric.** An *outgoing* connector -- a board that supplies something
else -- is expressed the same way, with `driveLoad` or `driveSink` instead of
`driveSource`. And those two are **not interchangeable**, which is worth stating
because they agree at the operating point and nowhere else: a resistor's current
follows the rail, so it damps the decoupling network, while a constant-current
sink is an **open circuit at AC** and damps nothing. Measured on one board:

| external load | `z_antiresonance` |
|---|---|
| resistive 33 ohm | 3.57 ohm |
| constant 100 mA | **4.01 ohm** |

Modelling a regulated load -- an MCU, a module with its own converter, which is
most of what hangs off a power connector -- as a resistor therefore understates
by 12% the very peak a PDN sweep exists to find.

**Stating the drives on the design**, done, and it arrived somewhere better than
the annotation scheme first sketched. `SimReplacement.build` is `{.nimcall.}`
and therefore has no environment to capture a drive in -- so the drive had to
become *data*, recorded on the `Pin` as namespaced `boundary.*` attrs. That is
the better property regardless: it survives `clone`, it is visible in the
netlist, and anything can read it back, where a closure could not be. Going
through `simReplace` keeps the connector in the **design** netlist, so a BoM and
a layout still see the part that gets soldered while only the simulation copy
sees the supply behind it.

**A prerequisite that turned out to be a real bug.** `analysis/pdn`, `startup`
and `opamp` plain-`clone`d their work copy, so **`simReplace` was silently
ignored by three of the six analyses** -- a component's own statement of how it
wants to be simulated, dropped. Switched to `materializeSimNetlist`, which
needed an `exclude` parameter because `startup` applies the regulator's
replacement itself, on the fragment and after isolation, so it can take over the
designator the inrush probe measures.

`designs/sensor_node.nim` converted from `kind = "voltage_source"` with
`rout`/`lout` -- which modelled what was *behind* the connector and put a part
on the BoM nobody solders -- to a real connector plus a stated drive. **Every
measured number is unchanged** (5.00 V, 3.30 V, 125 mohm, 0% overshoot, 161 mA,
801 us / 981 us), which is the correct outcome: the two descriptions are the
same electrical situation, and a refactor that moved a number would have meant
one of them was wrong.
## 35. Boards as a system, and boards on their own

A board has to answer two questions -- what it does on the bench, and what it
does plugged into the rest of the product -- and §34 only answered the first.
The pieces for the second already existed (`asSubcircuit`, `graph.instantiate`,
`flatten`); assembling two boards showed what was missing.

**What system modelling actually buys**, measured on a supply board feeding a
sensor board:

| | `vout` |
|---|---|
| supply alone, assuming a 100 mA draw | 4.89 V |
| supply alone, assuming 200 mA | 4.78 V |
| supply alone, assuming 400 mA | 4.56 V |
| **wired to the real sensor board** | **4.781 V** |

The isolated answer is a function of the assumption and nothing else. Wired
together, the sensor board's actual 24 ohm is in the circuit and the answer is
the board's rather than the guess's. Both descriptions come from the same design
-- the boards keep their own connectors, only the copies lose them, so nothing
is rewritten to move between them.

**The gap it exposed: ports were wired positionally.** `graph.instantiate` takes
a bracket in port-declaration order, which is fine for a subcircuit whose ports
a person just wrote and a trap for one produced by `asSubcircuit`, where the port
list came from whichever nets the connectors happened to sit on. Both boards in
this system call a port `vin`. **Swapping two same-shaped nets raises nothing
and simulates happily.**

So `graph.instantiateByPort`, and the DSL's `instance` now accepts a table as
well as a bracket:

```nim
instance XA, asSubcircuit(supplyBoard(), "SUPPLY"), {"vin": usb, "vout": rail}
instance XB, asSubcircuit(sensorBoard(), "SENSOR"), {"vin": rail}
```

Every port must be named. An unwired one **raises**, listing what the board
exposes, rather than being quietly left open -- an open port on a board-to-board
connection is a disconnected system, and the entire point of assembling one is
that the connection exists. A named port the board does not have raises too.

Ground is shared through `globalNets` as it always was, which is what keeps the
two boards on one reference; without it they would be electrically isolated and
every cross-board measurement meaningless.

## 36. A design that is two boards, and the defect only the pair has

`designs/system_sensor_rig.nim`, with the boards themselves in
`designs/lib/carrier.nim` and `designs/lib/sensor_head.nim`. Each board is an
ordinary `netlist` carrying no claims; `boundary.asSubcircuit` turns its
connectors into ports and the system file wires the ports together, by name.

**The boards make their own claims too** (see §37, which corrected this section's first version). A board
checked on its own is checked against an assumed other end -- measured on
exactly these two, the carrier alone reports its output at 4.89 V, 4.78 V or
4.56 V depending only on the sink assumed, and none of those is a statement
about the product.

The cable is modelled explicitly, as components in the system file: 300 mm of
28 AWG twisted pair, there and back, is about 40 mohm and 300 nH. A netlist
carries no length so nothing else can know it is there, and joining the two
boards port-to-port would have silently asserted a perfect connection.

### What it found

The sensor head first carried only 1 uF and 100 n of ceramic, on the reasoning
that the carrier's 22 uF was "the" bulk. The system reported the head's rail
impedance as **8.71 ohm** against a 900 mohm target.

Not the cable's resistance, and not an artefact. It is the anti-resonance
between 300 nH of cable and 886 nF of local ceramic: it lands near 1 MHz and
peaks at `L/(R*C)` = 300n/(0.04 * 886n), about **8.5 ohm** -- damped by nothing
but the cable's own 40 mohm. The closed form and the simulation agree.

**Neither board could have found it.** The carrier's own rail is fine. The
sensor head's own decoupling is fine. The defect exists only in the pair, and
only once the cable between them is real.

The fix is one 22 uF tantalum at the head, and a *tantalum* specifically: its
200 mohm of ESR is what damps the peak, where a third ceramic would have added
charge and left the ringing exactly where it was. Measured after: **211 mohm**,
a factor of 41.

### Why the claim is made at the far rail

`targetZ` is claimed at the sensor head's rail rather than the carrier's,
because once a cable is between them they are not the same rail -- and the
carrier's is the convenient one to measure and the one that looks fine.
Measuring it would have reported the decoupling as better than the sensor sees
it, which is the failure mode this whole layer exists to prevent.

## 37. A board is a module and a program, and §36 was half a design

§36 made the two boards claim-free netlists and put every claim in the system.
That was wrong: a board still has to be verifiable on its own, and saying it
could not was a choice mistaken for a limitation.

**`when isMainModule` is the mechanism**, and it fits the question exactly:
"is this board the thing under test, or part of something bigger" is a property
of how the file was compiled, so `when` answers it and nothing at runtime has to
be told which world it is in. `designs/carrier.nim` and
`designs/sensor_head.nim` each export a `proc` returning their netlist, and
under `when isMainModule` state what is plugged into each connector and make
their own claims.

**The bench drives cannot leak into a system**, and that falls out rather than
needing a guard: a drive is recorded on a connector pin, and `asSubcircuit`
drops the connectors.

### Both checks are needed, and here is the proof

The sensor head, before its damping capacitor existed:

| | `z_max_in_band` at its rail | |
|---|---|---|
| `designs/sensor_head.nim`, bench supply | **10.00 mohm** | passes by 30x, exit 0 |
| the same board in `system_sensor_rig.nim` | **8.71 ohm** | fails by 10x, exit 1 |

A board-level check on a bench supply cannot see it, because a bench supply
sitting beside the board has none of the 300 nH the cable has. A system-level
check alone would not have told you *which* board to change. Fixed, the same
rail reads 9.56 mohm standalone and 211 mohm in the system -- still a factor of
22 between the two contexts, which is the cable and is real.

Boards moved from `designs/lib/` to `designs/` so that `nimble verify` -- whose
`listFiles` is not recursive -- checks them.

## 38. A drive attached at a port was given a microhenry nobody asked for

Found while writing §37, by not believing a number.

`boundary.attachDrives` builds a source as `V -> R -> L -> port`, so the stated
output impedance is explicit in the netlist. But the `V` it created carried no
`rout`/`lout` annotation, so `models.expandSourceImpedance` saw a bare
`voltage_source` and added **its own default 10 mohm and 1 uH in series** --
on top of the impedance already there.

A microhenry is not a rounding error. A bench supply stated as 10 mohm rang
against a board's 865 nF and reported:

```
z_max_in_band = 10.5 ohm at 178 kHz     (anti-resonance, entirely invented)
```

against a true 10.00 mohm. **A factor of a thousand**, built out of impedance
nobody asked for, and it looked plausible -- an anti-resonant peak at a
believable frequency is exactly what a PDN sweep is supposed to find.

**Fixed** by annotating the created source `rout = 0`, `lout = 0`, which
`models` already documents as the way to opt back into an ideal source. The
right fix is not to suppress `expandSourceImpedance`: it exists because an
ideal source is a dead short at AC, and every *unannotated* source should still
get its default. What was wrong was creating a source with explicit impedance
beside it and then not saying so.


## 24. Two evaluators producing one quantity silently overwrote

`registerEvaluator` maintained `quantityIndex[q] = it.name`, a flat map. A
second evaluator declaring an existing quantity replaced the first with no
diagnostic, and every claim on that quantity in every design silently changed
which analysis answered it -- reported under the same quantity name either
way, so the report could not show the difference.

Nothing did it, which is why it never bit. §39 was the first realistic chance:
`analyzeTransient` measures a `final_v` and `spice.startup` already produces
one.

**Fixed** by raising when a quantity is already owned by a **different**
evaluator. Re-registering under the *same* name still replaces, because that
is the documented way an application overrides a built-in -- an override says
so by keeping the name, and a collision is an accident. The two are
indistinguishable after the fact, which is the whole reason to catch it at
registration. `spice.transient` therefore declares `settled_v`, `ripple_pp`,
`settled_min` and `settled_max` and **not** `final_v`, even though the
analysis measures one and the report shows it.

## 39. A part needs more than one model, and the choice is not the SPICE card

The LT8640A design carried an averaged behavioural model (§ the design notes
in `designs/lt8640a_buck.nim`) and could not claim its output ripple, because
an averaged model emits the switch node's cycle *average* -- there is no
ripple in it to find. It also could not claim it with a switching model
instead, because a switching model runs at about fifty timepoints per cycle
and the same design's soft-start claim needs five milliseconds of circuit
time, which is a quarter of a million of them.

So neither model is the better one, and the design was being asked to pick
which question it was allowed to ask.

**The mechanism.** `Component.simModels` is an ordered table of
`SimReplacement`s keyed by a new `SimReplacement.name`, and `simReplace`
became an accessor pair over it -- the getter returns the default, the setter
still means "this is *the* model", so every call site that predates this reads
and writes exactly as it did. One table rather than a field beside a table of
alternatives: two places to look for a model is the drift hazard this codebase
avoids everywhere else, and "what stands in for this part" must not have two
answers that nothing keeps in step.

**The selection.** `SimReplacement.suits` names the *purposes* a model is
preferred for, and `spice/transform.selectSimModel(c, purpose)` picks. The
vocabulary is `spOperating`, `spSmallSignal`, `spStartup`, `spSteadyState`,
`spLargeSignal` -- **what is being asked, not which card gets written**, and
that distinction is the whole design. Both LT8640A models are `.tran` models;
naming the card would put them in one bucket and leave the choice to a coin
toss. Every analysis in the library passes its own purpose, so a design that
labels a model gets it without any call site knowing the design.

Three rules, each chosen against a specific failure:

* A model naming the purpose wins.
* No match falls back to the default rather than refusing. `suits` is
  advisory, because a model that declared itself for steady-state only would
  otherwise make a `.op` on the same design impossible, and an analysis
  blocked by a preference is worse than one run against the default.
* **Two models naming one purpose raises**, listing both. That is not a
  preference, it is an ambiguity, and picking either would decide silently
  which analysis the design gets.

`clone` carries every model, not just the default, or the alternative would be
dropped one transform before the analysis that asked for it.

## 40. The LT8640A switching model, and what it can and cannot be asked

`designs/lib/lt8640a_sw.nim`, the counterpart §39 made reachable. Peak current
mode, which is the part's real architecture and is also what makes the model
work at all:

* **`sw` is a conductance port, not a voltage one.** The model is a Thevenin
  source at `son * V_IN` behind the conduction-weighted on-resistance, so the
  switch node has a real source impedance -- and, decisively, **the model
  knows the inductor current**, because it is the current through whichever
  switch is conducting. A voltage-output switch node hides it and a netlist
  has nowhere else to find it.
* `vin` is a conductance port too and draws that current, so the input
  capacitors see the real trapezoidal draw. Measured: 2.22 A average, 5.4 A
  peak-to-peak, 92.4% efficiency on conduction loss alone.

Four things were found by not believing a number, and each is recorded in the
model:

1. **A crossfade between two switch conductances is a shoot-through path.** At
   the crossover point it is 105 mohm across 12 V; measured, 60 A spikes
   through the input capacitors' ESL on every edge. The Thevenin form has no
   such path by construction, and is identical at `son` of 0 and 1.
2. **A linear switching edge does not converge.** Its corners are a delta in
   the driven node's second derivative, and truncation-error control answers a
   delta by halving the timestep until it gives up: `Timestep too small; time
   = 2.2e-09, timestep = 3.4e-20` on the first edge of the run. A raised
   cosine leaves the slope continuous at both ends.
3. **Slope compensation costs command headroom.** Sized as a fraction of the
   *current limit* rather than of the inductor's own downslope, 0.5 pinned the
   error amplifier against its clamp and left the loop running on its
   proportional term: a 12.7 mV static droop on a rail whose integrator should
   leave none. 0.15 is comfortably above half the downslope here.
4. **Breakpoints are not optional.** Between edges the interesting nodes are
   smooth, so the step controller walks straight over a clock edge unless the
   model places one.

The `.op` and the transient's `t = 0` run the *averaged* form of the same
arithmetic, which is what makes t = 0 continuous with the operating point
ngspice solved just before it -- and what lets the compensation state be
seeded from the load current the circuit is already drawing, so a run set up
to skip a start-up transient does not open with one of the model's own.

**What may be claimed from it, and what may not.** The ripple is trustworthy:
it is set by V_IN, V_OUT, L, f and the output capacitor, all board values.
Verified by measuring the same rail across a 4x range of `nsub`, a 4x range of
`tedge`, half the `rzc` and half the `gmc`: **7.10 to 7.29 mV**, and 4.9618 V
to within 0.1 mV every time. A phase margin is not: the compensation is chosen
for a sensible loop rather than fitted to the part's, which is not published.
`rtop`, `rbot`, `ilim`, `tedge` and `tminon` are stand-ins and say so; `vref`,
`iss` and `iq` are datasheet figures.

Supporting work in `spice/xspice`: `analogAlloc`, `analogVar`,
`analogIntegrate`, `setPermBkpt` and `setTempBkpt` in `accessors.nim` -- the
analog counterparts of `eventAlloc`/`eventVar`, and the third shape a code
model comes in after memoryless and event-driven. They are rolled back with a
rejected timepoint, which `stateVar` is not, and that is exactly what a
cycle-by-cycle latch needs. `examples/xspice_integrator.nim` is the worked
example and `tests/test_xspice_build.nim` checks it against a closed form.

## 41. A `.tran` measurement that binds no driving part -- half of §23

`analysis/transient.nim`: `analyzeTransient(nl, measureNet, spec)` and the
`settled_rail` role, claiming `settled_v` and `ripple_pp`.

Every other simulation-backed analysis binds a driving part -- `analyzeStartup`
a regulator to stand up as a ramp, `analyzeOpAmpResponse` an amplifier and an
input. This one binds nothing: a net, a time by which the circuit should have
settled, and what it must then be doing. The design is simulated **as
authored, with no isolation**, following `runDcVoltage`'s precedent -- a rail
terminated at its nominal by the boundary would be a check that measures its
own assumption.

The window is stated rather than detected, because what counts as settled is a
judgement about the circuit: a converter's output is settled in a hundred
microseconds and a soft-started rail is not settled for five milliseconds, and
a detector that guessed wrong would report a start-up transient as ripple.
`tSettle` and `tWindow` ride in `Assertion.condition` and join the evaluator's
setup key, so two claims over two windows stay two runs.

This is §23's first half. The rest is §23 itself, below.

## 23. Every `.tran` quantity needed a bound driving part

Two designs reached this from opposite directions and neither could make its
central claim. `designs/charge_pump.nim` settles at 9.52 V with ripple on it;
`dc_voltage` is backed by a `.op`, and a `.op` takes a PULSE source at its DC
value, so nothing pumped and the tool reported **4.64 V** -- exactly
5 - 2*0.18, a perfectly correct answer to a question nobody asked, delivered
as a FAIL against a real number. `designs/wien_osc.nim` oscillates, and not
one of the three numbers that specify an oscillator was expressible.

The gap was structural: `regulator` wants a regulator component to stand up
as a soft-start ramp and `large_signal` wants an op-amp and an input to
drive, so nothing could ask *"run this and tell me what this node does"*.

§41 delivered the settling half (`analyzeTransient`, `settled_rail`) and
`spice/ngspice.run(nl, analysis, setup)` plus
`TransientSpec.initialConditions` delivered the `.ic`. **Fixed** here in
three pieces, none of which needed a simulator change.

**The measurement layer.** `analysis/measure.fundamentalFreq(t, v)` counts
rising crossings of the window's own **mean** -- not zero, since a
single-supply oscillator has no zero crossings at all -- with a hysteresis
band so a harmonic-rich wave is not counted at three times its rate. It is
deliberately not a spectral estimate: an FFT's resolution is one over the
window, so a 20 ms window resolves 50 Hz and would place a 1.59 kHz
oscillator to within 3%, useless against a network whose whole job is to fix
that frequency. Crossing-counting resolves to the *timestep* instead. Fewer
than two crossings is `NaN`, which is the answer for a circuit that did not
start and must stay distinguishable from 0 Hz.

**The analysis.** `analysis/transient.analyzeOscillation` shares
`analyzeTransient`'s run -- same netlist, same window, same `uic`, since
having the two questions diverge in the *simulator setup* as well as in the
arithmetic is how one of them quietly measures a different circuit -- and
reports `osc_freq`, `swing_pp` and `osc_thd_pct`. Frequency is measured
first, because the distortion integral runs over whole periods of it. A
`NaN` frequency raises `KindDidNotOscillate` naming which of the two causes
it was: the node never moved (kick it), or it is moving but not periodically
inside the window (widen it).

**The role.** `oscillator` binds `output` and an optional `kick`, whose
`kickV` becomes an `.ic` with `uic`. `kick` is optional and the evaluator
therefore declares no `binds`, so a circuit that is periodic without one pays
none of `uic`'s cost.

Worth knowing, because it looks like the kick is unnecessary: `wien_osc` does
start unkicked -- ngspice's own solver residual seeds it, and 3.2 of loop gain
grows that to full amplitude in about 30 ms. That is a property of the
solver's tolerance rather than of the board, it puts the settling time
somewhere nobody chose, and a loop with less excess gain would take
arbitrarily longer or never arrive. Measured unkicked at `tSettle = 10 ms`
that design's amplitude claim reads **57.4 nV** -- oscillating, correctly
reported at 1.58 kHz, and four orders of magnitude short. A lossless LC tank,
which has no gain to amplify a residual with, stays flat forever
(`tests/test_analysis_transient.nim`). Every claim is opt-in: there is no default frequency for an
oscillator, and inventing one would state a claim the designer never made.

**What the fix turned up on the way, and it is the part worth keeping.** The
derived print step is **also ngspice's ceiling on its own internal timestep**,
so it sets how accurately the circuit is *solved* and not merely how often
the answer is written down. A peak-to-peak barely notices; a frequency does.
On `wien_osc`, at `analyzeTransient`'s thousand samples across the window the
oscillation reads 1568.4 Hz, at ten thousand 1573.26 and at a hundred
thousand 1573.31 -- so the default was wrong by 0.31%, three times the band
that design's claim is worth stating at, in a way that looks like a circuit
measurement rather than like a setting. `runWindow` takes `windowSamples` and
`analyzeOscillation` passes ten thousand; the cost is 0.42 s against 0.06 s.

**`designs/charge_pump.nim`** now states `settled_rail` and passes -- and
stating it immediately found something the hand-run that produced the design
file's numbers could not see. The rail droops and recharges by 7.9 mV once a
cycle, which is the topology's own arithmetic, and takes a **403 mV** spike a
couple of nanoseconds wide at each clock edge. The spike is fifty times the
droop and is entirely the output capacitor's ESR and ESL: C1's plate is
stepped 5 V in 10 ns, so the pump current is limited only by the diodes' `RS`
and the two ESRs, and tens of amps for a few nanoseconds cross COUT's 10 mohm
and 1.2 nH on the way in. An ideal capacitor has neither, which is why a run
with nominal capacitors reports 5.1 mV and reports nothing about the spike.
What would make the smaller number the true one is a clock with a real driver
behind it -- a 10 ns edge into 1 uF is not something an MCU pin can do -- and
that impedance is not in the netlist because the design states the clock as
an ideal source. The claim is stated against the circuit as authored, with
the arithmetic written down beside it.

**`designs/lt8640a_buck.nim`** now claims its soft start: 4.09 ms measured
against the 4.08 ms the datasheet's 1.9 uA into 10 nF predicts. That needed
four changes to `analyzeStartup`, all of which were assumptions that only
held for the ramp it invents itself:

* the regulator is resolved through `findComponent`, so a hierarchical path
  works;
* `SimReplacement.build` is honoured. It is the only route that can express
  a code model, and `replaceComponent` would have read an empty `kind` and
  an empty `pinNets` and produced a device of no type wired to nothing;
* the inrush probe no longer assumes a pin named `"+"`. That is the pin of
  the PWL source *this analysis* builds and no other model has to have one;
  it now looks for a pin on the output net, and reports **no** `inrush_peak`
  rather than a zero when there is none. A switching regulator is the
  ordinary case: it drives a switch node into an inductor, so the current
  reaching the rail is the inductor's and no single branch carries it.
  `spice/probes.addCurrentProbe` additionally now **refuses** a code model
  outright -- an `A` line's port text is rendered from the model spec rather
  than from the component's pins, so re-netting one would move it in the
  graph and not in the deck, leaving a probe reading zero on a branch that
  is carrying current;
* `StartupStart` decides where t = 0 is, and `ssAuto` starts from zero with
  `uic` when the part brought its own model. It has to: an operating point
  finds the state the soft start settles *to*, so the `.tran` would begin at
  the end of the ramp and report a rise time of zero for a part that takes
  milliseconds.

`regulator` also gained `tRun`, a condition rather than a limit: the run
length derived from this analysis's *assumed* ramp has nothing to do with
the schedule a part's own model keeps to.

## 42. A stated `gbw` was ignored and then reported as invented

`spice/models.opampModel` -- the macromodel every op-amp gets when nothing
named it deliberately -- read `gain` off the component and carried `gbw` as a
`const 1.0e6`. The assumption line beneath it then reported that 1 MHz with
`annDefaulted` provenance, so a design that *had* stated `gbw` was told its
own value had not been used and that the tool had made one up.

That is the worst shape a default can take. `analysis/opamp` already passed
the annotation through to `idealOpAmp`, so the two paths disagreed about the
same part -- and this is the *only* path for every amplifier a `.tran` sees,
since nothing there names one stage to model deliberately.

Found by `designs/wien_osc.nim`, where it is directly readable as a
frequency: the amplifier's finite gain loads the Wien network and pulls its
peak down, so a TL072 modelled three times too slow reported an oscillator
0.5% low -- a quarter of the band that design's frequency claim is stated at,
and a claim about the model wearing the clothes of a claim about the board.

**Fixed**: the annotation is read, and the note's *provenance* now tells the
truth about where the number came from (`annAuthored` when stated), which is
what `invented()` counts on. The note itself is still always emitted, because
the model is still a substitution even when both its numbers were stated.

---

# What two parameterized-network designs found

`designs/divider_net.nim` and `designs/adj_regulator.nim` were written to push
on *composition*: building a network from a total and a ratio rather than from
resistor values, and attaching an IC's design equations to the part they
belong to. They found one thing.

| design | what it is | why it was chosen |
|---|---|---|
| `divider_net.nim` | a two-resistor voltage divider and the three-resistor network that replaces its bottom leg with a current divider | two builders parameterized the same way, so the composed network can be claimed against the same numbers as the plain one |
| `adj_regulator.nim` | two LM317 rails, 5 V and 12 V, sized from the datasheet equations | the equations, the part's constraints and the loop that makes them true all have to live in one place |

## 43. A claim about a net inside a subcircuit could be written but not checked

**Fixed.** `analysis/contract_eval.subjectNet` resolves through
`graph.findNet` instead of a flat key lookup. Test in
`tests/test_contract_eval_spice.nim`.

`contract/design.innerNet` builds a `Subject` naming a net inside a
subcircuit instance, `resolve` accepts it when the claim is attached, and
`spice/flatten` names the flattened net by exactly that path -- so
`require dc_voltage(XN.innerNet("XI", "sns")) == 30.mV` is spelled
correctly, binds correctly, and is simulated correctly.

It was then reported as:

```
[????]  REQ-DIV-SPLIT-001   dc_voltage(net 'XN.XI.sns')
         dc_voltage needs a net subject that exists in this design
```

which is false about a net that does exist, and the reader's only available
response is to delete a correct claim. `subjectNet` asked
`d.netlist.nets.hasKey(s.name)`, and `nets` is keyed flat -- the same
distinction `graph.findNet` was written for, and which `§17` had already
resolved for role bindings without this path being revisited.

It matters beyond neatness because a subcircuit's *internal* nodes are
frequently the only witnesses it has. `divider_net` is the case: both legs of
its current divider return to the same ground, so no node in the parent
netlist depends on how the current divided, and the one node that does is
two levels down inside the instance.

**Fixed** by resolving through `findNet`, which tries the flat key first and
then descends -- so the same call serves a hierarchical name and a flattened
one alike, which is what the rest of the library already relies on.

## 45. No `.dc` capability at all

**Fixed.** `capSpiceDc`, `analysis/dcsweep.nim`, the `spice.dc_sweep`
evaluator, and the `source_sweep` / `load_sweep` roles. Tests in
`tests/test_analysis_dcsweep.nim`; worked examples in
`templates/dc_sweep.nim` and `designs/divider_net.nim`.

`Capability` was `capStatic`, `capSpiceOp`, `capSpiceAc`, `capSpiceTran` and
`capBench`, and nothing above the backend had ever emitted a `.dc` — even
though `spice/backend` already documented `sdReal` as covering it,
`ngspice.analysisCards` already listed it, and `realPlotAnalyses` already
admitted it for `--save-currents`. So the backend was never the gap.

**What that cost.** Every analysis in the library answers a question at *one*
bias: `analysis/operating` solves a single `.op` and `analysis/derating` reads
it back, while `pdn` and `opamp` linearise about it. A large part of what a
datasheet specifies is instead a **difference between two** biases — line
regulation, load regulation, dropout, a comparator's trip point, an input
offset, a plain transfer curve — and no number of operating points contains
one. That is why the capability is its own enum member rather than a mode of
`capSpiceOp`: a host that can solve an operating point can also sweep one, but
an evaluator that says `.op` while running N of them is under-declaring in
exactly the way §24's `set[Capability]` was introduced to stop.

**Two procs, split by where the stimulus comes from.** `analyzeLineSweep`
sweeps a source the design already has — resolved through `findComponent`
after flattening, so a source inside an instance works, and identified by
`deckDesignator`, so a part that would not reach the deck as a `V` line is
refused by name rather than swept as whatever letter it got.
`analyzeLoadSweep` sweeps a constant-current sink it **injects** at the
measured node, which is the same idiom `probes.addImpedanceProbe` uses for an
`.ac` and rests on the same argument: a test load belongs to the measurement,
not to the board, and a part put in the netlist to be swept is a part on the
BoM and in the layout. A sink and not a resistor for the reason
`spice/boundary` already gives — a resistor's current follows the node it
hangs on, so sweeping one sweeps the load and the drive together.

Neither expands capacitor parasitics (at DC a capacitor is an open circuit, so
its ESR is in series with nothing), neither expands source impedance (the
default 10 mohm is an invented series resistance, and a load sweep would add
it to the very output resistance being measured), and neither isolates —
`runDcVoltage`'s precedent, since a cut rail is terminated at its nominal and
that is the answer a regulation measurement is looking for.

**Quantities**: `dc_transfer` (V/V), `line_reg_pct` (%), `line_reg_pct_per_v`
(%/V), `dropout_v` (V), `load_reg_pct` (%), `z_out_dc` (ohm), and
`dc_out_min` / `dc_out_max` / `dc_out_delta` (V). All nine come from one
evaluator, because `registerEvaluator` allows one producer per quantity and
the three envelope figures genuinely come out of either sweep; which one ran
is decided by a `sweep` condition the role stamps, not by the quantity.

**Two decisions worth keeping.** `dropout_v` comes back `NaN` — read
downstream as *not evaluated* — when the output never left regulation, with an
issue saying to sweep lower. "No dropout was found" and "the dropout is small"
are opposite conclusions and must not share a number, and the `NaN` is also
precisely what an idealised regulator model reports over any range at all:
`designs/lib/adjreg.nim` states in as many words that its error amplifier
driving an ideal source holds its target from an input below it, so no sweep
will find a dropout the model does not have. And **the swept range joins the
setup key**, so two claims over two ranges are two runs. That is not a
technicality: on `templates/dc_sweep.nim`'s 5.1 V Zener reference, line
regulation over the specified 6–16 V measures **1.67%** and over 3–16 V
measures **41.6%**, because most of the wider range is below the knee where
the "reference" is the supply arriving through a resistor. Both are right;
pooling them would report one as the other.

**What it found on a design already in the repository.** `divider_net` claimed
its two taps at 2.5 V, which is one point on a line — a network with the wrong
ratio and a compensating error passes it. Swept, the tap's *slope* is the
ratio itself: 250.0 m for both the plain divider and the composed
three-resistor one. And `z_out_dc` measures 18 750 ohm at both taps, which is
the other half of substitutability and the half no node voltage witnesses: the
composed network has to present the same **impedance** as the resistor it
stands in for, not merely the same tap, and if `currentDividerLegs` were wrong
`RA || RB` would not be the 25 k the tap needs. Neither number appears in the
design file or in any component value.

§63 (`comparator_threshold`) and §65 (`esd_clamp`) were blocked on this and are
now unblocked; both remain open as roles to write.

---

## 27. `current_rating` and `isat` had no consumer, and current was not a quantity

The oldest open finding, and the one a converter most wants. Both keys were
registered in `netlist/annotations`, both were set by `parts/policy` on every
inductor it chose, and **nothing read either**. `analysis/derating` said so in
its own module doc and explained why: a branch current is not in a `.op` for
anything but a voltage source, so an operating point — the only thing that
walked every part against its ratings — had no current to compare an `isat`
against.

The general shape was worse than one missing check. **Current was not a
first-class quantity anywhere here.** `inrush_peak` and `t_inrush_peak` were
the entire inventory, both belonging to `spice.startup`; everything else this
library measured was a voltage. `--save-currents` existed and put `@r1[i]` into
an archived rawfile for a *person* to load in ngspice, and no evaluator had
ever asked for one — the plumbing that gets a device current out of a run was
built and tested and had no consumer above it.

### What was added

**`analysis/transient.analyzeCurrent(nl, parts, spec)`** — a third analysis
beside `analyzeTransient` and `analyzeOscillation`, sharing their run. It
reports, per part: `i_peak`, `i_rms`, `i_avg`, `i_pp`, `i_min`, `i_max`, plus
`i_peak_derating` and `i_rms_derating`. The **`current_path` role** binds a
part (`isat`, `iRmsMax`, `iAvgMax`, `iRipple`, `maxIsatDerating`,
`maxRmsDerating`, plus the `tSettle`/`tWindow` pair `settled_rail` spells), and
`spice.current_path` evaluates it under `capSpiceTran`.

`measure.timeMean` and `measure.timeRms` are the arithmetic, weighted by
*elapsed time* rather than by sample count, on the same argument
`harmonicAmplitudes` already made: a `.tran` takes its smallest steps exactly
where the waveform moves fastest, so a plain mean over the samples weights an
edge far above the flat part either side of it. `timeRms` integrates the square
exactly for the piecewise-linear waveform the simulator reported — over one
segment `∫(v0 + s·Δ)² = dt·(v0² + v0·v1 + v1²)/3` — because a triangle sampled
coarsely between its corners is precisely the shape a trapezoid over `v·v` is
worst at, and a converter's ripple is that shape. Measured on a four-samples-
per-period triangle, the trapezoid says 0.707 against a true 0.577 -- **22%
high**, which would read as a part running hotter than it does.

### The four decisions worth keeping

**The subject is the part, not a net.** Every other quantity in this library is
about a node, and that is not stylistic: a net has one voltage that every part
on it shares, and no current at all — only the several different currents of
the parts hanging off it. An inductor's peak, an input capacitor's RMS and a
sense resistor's average are three claims about three parts on two nets, and
naming the net could not tell them apart. `spice.current_path` therefore
declares `subjectKinds: {skComponent}` and `binds: @[]`, so a bare
`require i_peak(L1) <= 6.A` reaches it with no role at all, and a claim
written against a net is refused with the sentence that says what to write
instead.

**The three figures a rating is quoted against are magnitudes, because a
rating is.** `i_peak`, `i_rms` and `i_avg` are all sign-free. The sign of a
branch current is a *deck* convention and no claim should turn on it: an
inductor's follows whichever pin the design happened to write first, and
ngspice reports a voltage source's current positive when it flows **into** the
+ terminal, so a supply delivering 330 mA reads −330 mA — verified against
ngspice-46, not assumed. What the sign does carry is the waveform's shape, and
`i_min`/`i_max` keep it: a current that reverses has `i_min < 0 < i_max`, which
no magnitude shows.

**One run answers every part.** The setup key is the window and nothing else,
so a batch of claims about different parts is one `.tran`. Keyed by part
instead — which is what every other evaluator here does, because every other
subject *is* a different setup — `lt8640a_buck` would simulate its switching
model at fifty timepoints a cycle once for the inductor and again for the input
capacitor, to read one set of waveforms two ways. `Measurement.at` carries the
designator and `harvestPart` matches on it, which is what stops one part's
claim being answered with another's number.

**A three-terminal device is refused, not guessed at.**
`ngspice.branchCurrentVector` maps a deck designator to the rawfile vector that
holds its current, and the split it encodes is whether that current is an
*unknown of the matrix* or a quantity computed from the solution afterwards: a
voltage source, an inductor and the two controlled sources carrying a branch
equation (`E`, `H`) come back as `i(l1)` in the default saved set, while
everything else is `i(@r1[i])` and needs naming in a `.save` — with `all`
leading it, for the reason `saveCurrentsCard` already states. Both spellings
were verified against ngspice-46 rather than taken from the manual, which
documents the *vector namespace* names (`l1#branch`, `@r1[i]`) and not the ones
the rawfile writer emits; the old doc comment here said `#branch` and was
wrong. A `Q`/`M`/`J` has a collector, an emitter and a base current, "the
current through Q1" does not say which, and picking one silently would answer a
question nobody asked — so it comes back with a reason naming the three, and
the rest of the batch is measured anyway. The same applies to a part that is
simply *gone* by the time there is a current to read: the netlist reaching the
deck is a materialized, flattened, model-substituted copy, so an op-amp is a
macromodel and a ferrite bead is three elements, and neither leaves a device
carrying the original designator. That is a per-probe reason, not a raise —
one unmeasurable subject must not sink a batch. A **voltage** probe still
raises on a name that resolves to nothing, and the asymmetry is deliberate: it
names the one net the whole analysis is about, so there is no partial answer
to give.

### What it measures on the design it was written for

`designs/lt8640a_buck.nim` claimed a 7.12 mV output ripple, and that figure is
0.94 A of inductor triangle across 3 mohm of ESR — so a claim on the **rail**
rested entirely on a current nothing was checking. L1 now states the two
ratings a real part is bought by (11 A saturation, 6.5 A continuous), and the
design claims:

| quantity | expected | measured |
|---|---|---|
| `i_pp` | 879 mA ±15% from `dI = Vout(1−D)/(L·f)` | **905 mA** |
| `i_avg` | ≤ 5.2 A (the 5 A load) | **4.96 A** |
| `i_peak_derating` | ≤ 0.6 of L1's own `isat` | **0.492** (5.41 A of 11 A) |
| `i_rms_derating` | ≤ 0.85 of L1's own `current_rating` | **0.764** (4.97 A of 6.5 A) |

The two derating claims state no current at all — they read L1's `isat` and
`current_rating` back off the part. That is what those keys were registered
for, and it is why the role offers both spellings: a limit the *circuit* fixes
(`iRipple` comes out of the design equations) is stated in the design file,
while a limit the *part* fixes is stated once, on the part, where a
substitution changes it.

§64 (`switching_converter`) was blocked on this for its efficiency figure and
§65's leakage half lands here too; both remain open.

---

## 58. A power supply could not be asked the three things it is specified by

A regulator was checkable as a *node voltage* and as a *ramp* and as nothing
else. Every claim any design here made about one — `dc_voltage`, `final_v`,
`rise_time_10_90`, `overshoot_pct`, `ripple_pp` — is a measurement taken with
the input held still and the load held still, and the three questions a
datasheet's front page is actually written around were unaskable:

1. **Load step.** Does the rail hold up when the load jumps? This was §58's
   original proposal, specified there down to the parameter names. It is the
   time-domain twin of `power_rail`'s `targetZ` — a target impedance is a
   *proxy* for it, and getting from one to the other is an argument the reader
   had to complete.
2. **Ripple rejection.** How much of the input supply's ripple reaches the
   rail. Not mentioned anywhere in the repository before this.
3. **Output current against the part's rating.** §27 made current a quantity,
   but nothing connected a measured current to the rating of the part that has
   to deliver it.

### What was added

**`analyzeLoadStep`** in `analysis/transient.nim`. It injects a pulsed
constant-current sink (`ILOADSTEP`, `+` on the rail and `-` on ground, so a
positive value pulls current out) and measures `step_droop_v`,
`step_droop_pct`, `step_overshoot_v`, `step_overshoot_pct`, `step_recover_s`
and the signed envelope `step_v_min` / `step_v_max`. The baseline is the
time-weighted mean over the window *before* the edge, and the recovery is
measured against where the rail settles **under the new load** — load
regulation moves that point, and counting the shift as a failure to recover
reports a correct regulator as an unstable one.

The one structural change to existing code is a `mutate: proc (work: Netlist)`
hook on the private `runWindow`, called after the model passes and before
`resolveProbe`; `analyzeTransient`, `analyzeOscillation` and `analyzeCurrent`
pass `nil`.

**`analysis/psrr.nim`**, holding *both* methods. The ripple gets in the same
way `probes.addCurrentProbe` gets a probe in: the supply's output pin is
re-netted onto a fresh net and the ripple source goes between that and the
original input net. Rewriting the supply's `attrs["value"]` would have had to
parse a string that may be anything from `"DC 5"` to a whole source spec;
splitting the pin works whatever it says and composes correctly with
`expandSourceImpedance`.

- `analyzePsrrAc` — `"DC 0 AC 1"` in series, `.ac dec`, emitting
  `psrr_min_db`, `f_psrr_min` and `psrr_at_f`.
- `analyzePsrrTone` — `"SIN(0 v f)"`, a `.tran` over a whole number of periods
  after `tSettle`, with the amplitude at exactly `f` pulled out by
  `measure.harmonicAmplitudes`. Emits `psrr_db`, `in_ripple_v`,
  `out_ripple_v`.

**Three evaluators** — `spice.load_step` (`{capSpiceTran}`),
`spice.psrr_tone` (`{capSpiceTran}`) and `spice.psrr_ac` (`{capSpiceAc}`) —
and one quantity added to `spice.current_path`: `i_out_derating`, the sense
part's RMS over the **regulator's** stated `current_rating`.

**Three roles.** `regulator` gains all of it as opt-in parameters, so the
three designs and one template that already instantiate it expand to exactly
what they did before; `linear_regulator` and `switching_regulator` expand
`regulatorExpand` whole and add what only their topology is asked.

### The four decisions worth keeping

**The input ripple is measured, never assumed.** The board's input filter
attenuates the injected ripple before the regulator sees it, and quoting
against the injected amplitude would credit the regulator with the filter's
work. Both ends are emitted so the split stays visible.

**Two PSRR evaluators, not one with a mode.** `spice.dc_sweep`'s
one-evaluator-two-modes precedent does not transfer: both of its modes are
`.dc`, whereas these need different capabilities, and `Evaluator.needs` is a
single set — one evaluator would declare `{capSpiceAc, capSpiceTran}` and be
refused on a host offering only one.

**Which method runs is chosen by which *limit* is stated, not by a mode
string.** `minPsrrDb` selects the tone; `minPsrrBandDb` selects the sweep. A
`psrrMethod = "tone" | "ac"` parameter was written first and removed, because
`verify.claimingRoles` works out what a role can claim by expanding it with
every parameter set to the placeholder `"1"` — a float placeholder still
selects a branch, a string one selects nothing, and every `.ac` quantity here
reported as claimable by no built-in role at all. It also needed value
validation that the two-limit form does not, which let `regulatorApply` be
deleted outright.

**"Swept in magnitude" is a condition, not a loop.** `step_from` and `step_to`
join the evaluator's setup key, so two claims at two magnitudes are two runs
whose answers are not pooled. A rail that holds up under 1 A may not under
3 A, and pooling would answer one claim with the other's number.

### The models had to be fixed first

Two of the three regulator models could not show input feedthrough at all, so
a rejection measured through them would have been a confident number about the
model. Both fixes are structural and are written up as §67. What matters here
is that they turned two *declared* figures into derived ones: `adjreg`'s input
current now follows the load through a floating series pass element instead of
being a constant, and `lt8640a_avg` commands a duty rather than a voltage.

### What it measures on the designs it was written for

`designs/adj_regulator.nim`, on the 5 V LM317 rail:

| quantity | claimed | measured |
|---|---|---|
| `step_droop_v` | ≤ 50 mV on a 50 mA step | **11.3 mV** |
| `step_recover_s` | ≤ 100 us, against a 0.1% band | **8.71 us** |
| `psrr_db` (tone, 120 Hz, 100 mV) | ≥ 55 dB | **62.9 dB** |
| `psrr_at_f` (`.ac`, 120 Hz) | ≥ 55 dB | **62.9 dB** |
| `line_reg_pct` over 8 V .. 20 V | ≤ 0.25% | **0.129%** |

The two rejection figures agree to 0.002 dB through two different solvers,
which is the cross-check the tone method needs: a tone measurement has a noise
floor and an `.ac` sweep has a linearisation, and neither alone says which it
hit. The line figure is 0.0107 %/V across 12 V of input against the LM317
datasheet's 0.01 %/V typical — derived from the loop the model closes rather
than read back off the part.

The 12 V rail states one claim only, the **worst point across a band**, which
is the shape that matters: the same part on the same board rejects 62.9 dB at
120 Hz, 19.9 dB by 10 kHz and 4.19 dB by 1 MHz. The loop gain has rolled off
and COUT has not taken over.

`designs/lt8640a_buck.nim` replaces its `regulator` / `settled_rail` /
`current_path` trio with one `switching_regulator` instance and adds:

| quantity | claimed | measured |
|---|---|---|
| `step_droop_v` | ≤ 150 mV on a 1 A step | **21.3 mV** |
| `step_recover_s` | ≤ 30 us, against a 0.1% band | **27.0 us** |
| `psrr_db` (tone, 100 kHz, 1 V) | ≥ 60 dB | **70.1 dB** |
| `i_out_derating` | ≤ 1.0 of U1's stated 5 A | **0.994** |

The rejection is claimed by the **tone** method and necessarily so: an `.ac`
sweep through an XSPICE code model returns exactly zero output, because a code
model contributes to the AC matrix only if it sets `AC_GAIN` and neither of
this part's does. The `KindNoFeedthrough` guard turns that into a refusal
rather than into an infinite rejection.

Two limits are set where they are for reasons the design files record. The
step is 1 A and not more because the switching model's cycle-by-cycle limit is
7 A of *peak* inductor current, and 6 A of average plus half the 0.9 A
triangle is already 6.45 A of it — a 2 A step measures 383 mV and never
recovers, which is a true statement about a part being asked for more than it
has and not the question the claim is asking. And `i_out_derating` is claimed
at **1.0** because this board is the datasheet's front page, which specifies
the part at exactly its rated 5 A: there is no headroom to claim and the only
honest statement is that the part may not be run past its rating. The last
0.6% is the ripple triangle's contribution to the RMS, which the average does
not see.

### One parameter that had to be added afterwards

`stepBand`. `step_recover_s` re-enters a band around where the rail settles
under the new load, defaulting to 1%. On the buck that is 50 mV against a
21.3 mV droop — the rail never leaves the band and the recovery reads a
confident **zero**. Both designs state it explicitly at 0.1%, and the
parameter's doc says to state it whenever the droop is smaller than the band.
A default that silently reports zero is the worst kind of wrong answer, and
this is the one place in this work where the first version produced one.

---

## 53. A quantity could not take more than one subject, and §60 with it

**Fixed.** `Assertion.subjects` was always a `seq` for a stated reason -- "setup/hold is inherently one signal *versus* another, and a two-subject quantity must not be a special case bolted on later" -- but every one of the seventeen registered evaluators declared `arity: 1 .. 1`, so the shape decision was paid for and unused, and four families of claim were unreachable: channel matching (§60), rail sequencing (§59), setup/hold, and differential balance.

`designs/riaa_preamp.nim` made it concrete. It instances one channel twice (`XL`, `XR` of `riaaChannel()`), its own module doc says "channel matching is the specification that matters", and it could say nothing whatever about the pair -- only two independent `gain_stage` claims that would both pass with the channels 3 dB apart.

### What was already in place

More than the finding suggested. The `require` macro already accepted `require q(a, b) <= x`; `plan()` already gated on `Evaluator.arity`; `defaultKey` already joined every subject name, so grouping a two-subject claim by its pair needed no change. `dsl.subjectOf(Subject)` was already an identity overload, so a helper returning a `Subject` already routed through the `role` macro as a binding. The two real gaps were that no evaluator declared `arity` wider than `1 .. 1`, and that `design.resolve`'s `skClass` branch returned three nils and validated nothing.

### What was added

* **`design.roleRef(name): Subject`** -- one line, `Subject(kind: skClass, name: name)`. It is the `skClass` counterpart of `innerComponent`: a role can now bind *another role instance* as a part.
* **`design.resolve`'s `skClass` branch raises** when the named instance is absent, listing the instances that do exist. This is what makes "declare the referenced roles first" an enforced ordering rather than a comment -- `addRole` validates bindings before an expander sees them, so a `channel_match` written above its two stages fails at attach time with a message that says so. `tagMembership` tags nothing for an `skClass` binding, which is correct: a role instance is not a netlist entity.
* **`evaluate.subjectRole` / `evaluate.subjectRoleBinding`** -- the subject-side pair beside `originRole`/`originBinding`. `originRole` answers "the role that *expanded* this assertion"; these answer "the role a subject *points at*". Both return `none` rather than raising, so the evaluator writes the refusal that names what was missing. A `RoleExpander` is pure and has no `Design`, so it cannot dereference `a`/`b` into nets -- the expander states the claim over the two `skClass` subjects and the evaluator recovers the topology, the same asymmetry `originRole` already existed for.
* **`measure.maxDeviation(x, ya, yb, xFrom, xTo)`** -- the largest `abs(ya[i] - yb[i])` over an axis two curves share, and the `x` that witnesses it. Pure, tested offline: the worst point, the windowed form, `NaN` for an empty window, a raise on mismatched lengths.
* **`analysis/match.analyzeChannelMatch`** -- its own module on `psrr.nim`'s precedent, composing rather than duplicating: it calls `opamp.analyzeOpAmpResponse` once per channel and reads the gain curve back off `raw.db(...)`. It reports `gain_delta_max_db` / `f_gain_delta_max` (the band worst and its witness), `gain_delta_at_f` (emitted only when a frequency is stated), and `f_lo_ratio` / `f_hi_ratio` (the two band edges as `max/min`, so `>= 1`). Four decisions are pinned in the module doc: a band worst and a single frequency are separate names (as `psrr_min_db`/`psrr_at_f` are); every figure is a magnitude, so which channel is "A" cannot change a verdict; both sweeps must share one frequency axis, which is *checked* elementwise and reported as an `Issue` rather than assumed; and each channel's assumptions and issues are merged and deduplicated, since both channels substitute the same macromodel.
* **`spice.channel_match`** in `analysis/contract_eval` -- `arity: 2 .. 2`, `subjectKinds: {skClass}`, `binds: @["opamp", "input", "output"]`, `needs: {capSpiceAc}`. `runChannelMatch` dereferences both subjects with `subjectRoleBinding` and refuses -- naming the missing part -- when a referenced stage binds no `opamp`/`input`/`output`. It deliberately does **not** require the referenced role to be `gain_stage`: `opamp_stage` binds the same three parts and a user role may too, and requiring a name would make the built-in privileged. Its setup key carries both stages' topology plus the band and `at_f`.
* **`channel_match`** in `contract/roles` -- parts `a`, `b`, both `RolePart(kind: skClass)`; params `maxGainDelta`, `maxEdgeRatio`, `atF`, `fFrom`, `fTo`. Every claim is `hasParam`-gated on its own limit; `atF` **redirects** `maxGainDelta` from `gain_delta_max_db` onto `gain_delta_at_f` rather than adding a second claim, the `gain_stage`/`atF` pattern.
* **`verify.describeRole`** maps `skClass` to `role` -- the generic `($kind)[2..^1]` slice printed `class`, which for a role reference is wrong. **`verify.describeQuantities`** marks a quantity whose evaluator has non-`1..1` arity `2 subjects`, so a reader can tell `gain_delta_max_db` needs the pair without running it.

### The design, and the number that is the point

`designs/riaa_preamp.nim` gains one `channel_match` instance binding the two `gain_stage`s it already declares:

```nim
role "channel_match", stereo, a = roleRef("left"), b = roleRef("right"),
     fFrom = 20.Hz, fTo = 20.kHz, maxGainDelta = 0.5.dB
```

Two instances of one `subckt` produce two byte-identical isolated fragments, and ngspice is deterministic, so the two gain curves agree to the last digit: `gain_delta_max_db` measures **exactly 0 dB** over 20 Hz .. 20 kHz. That is the point of the exercise -- anything else would mean the two sweeps are measuring different circuits and the number is about the harness, not the board. The claim can fail as well as pass: a scratch copy with a +1% error on one channel's feedback resistor R7 measures **67 mdB**, and a +20% error **1.20 dB** against the 0.5 dB limit, exit 1.

**Known cost, recorded under §51.** `riaa_preamp` now runs four `.ac` sweeps where two would do -- the two `gain_stage` steps and this evaluator's own two, over byte-identical fragments. Routing one step's curve into another is §52-shaped planner work; §51's rawfile cache keyed on the derived deck absorbs it with no planner change.

### §60 (`channel_match`), closed

§60 proposed exactly this role and named `designs/riaa_preamp.nim` as the motivating design already in the repo. It is the role above. §59 (`sequencing`) stays a proposal -- it needs a new `t_reach_frac` quantity and has no design in-repo demanding it -- but it is no longer blocked.

---

## 52. `ekRelative` and `ekPredicate` were documented but did not exist

**Fixed.** The `Expectation` variant gained `ekRelative` (a bound referring to
another measurement — "no more than a fifth of the primary filter") and
`ekPredicate` (a non-capturing Nim proc over named measurement dependencies),
without touching the evaluator ABI.

**What it was.** A claim shaped `require z_max_in_band(vdda) <= 0.2 *
z_max_in_band(vdd)` had to be written as an absolute number somebody computed
by hand from the other rail's result — the arithmetic-done-twice the contract
layer exists to remove. The variant-object hedge had been paid for and never
spent.

**What was added.**

* `contract/types.nim`: `MeasurementRef` (quantity + subjects + conditions),
  `RelativeOp` (`roLe`/`roGe`/`roEq`), `PredicateDep`, `PredicateProc` (a
  `{.nimcall.}` proc, so a capturing predicate fails to compile), and the two
  new `ExpectKind` branches. `satisfies` gained the two-value overload for
  `ekRelative`; the single-value form declines both new kinds, since neither
  has a constant bound.
* `contract/dsl.nim`: `require q(a) <= 0.2 * r(b)` parses a bare measurement
  RHS or `number * measurement` in either order for `==`/`>=`/`<=`, with the
  usual `band` setting the relative-equality tolerance; anything richer is a
  compile error pointing at the predicate form. `require pred(x = q(a),
  y = r(b), id = ...) do (x, y: float) -> bool: ...` names its dependencies
  and wraps the author's proc so the dependency values arrive in order.
  Trailing condition keys are stamped on the claim *and* every dependency
  (the runtime API can set dependency-specific conditions via
  `MeasurementRef.condition`).
* `contract/evaluate.nim`: `plan` decomposes a relative/predicate claim into
  hidden measurement requests (`Plan.hidden`, `\x1f`-prefixed ids) routed
  through the identical `routePlain` path, plus one `ResolveStep`.
  `resolveHidden` compares the two values (or runs the proc), propagates a
  dependency's `esNotEvaluated`/`esNotEvaluable` and its assumptions/issues,
  and checks the two measured units against each other. `evaluate` returns
  exactly one result per authored claim; the evaluator `EvalProc` ABI never
  sees the relative or predicate.
* `verify.nim`: `readiness` filters hidden requests out of check blocks and
  folds the resolved claim onto the run that measured its primary (or first
  dependency), skipping a run that existed only to feed another claim;
  `renderClaim` spells the relative comparison with its numeric bound and a
  predicate as `predicate(...)`. `claimLint` skips the two new kinds, which
  state no literal unit by design.

Tests: `tests/test_contract_dsl.nim` (parsing, both operand orders, relative
`==` band, predicate deps and conditions, compile-time refusals),
`tests/test_contract_evaluate.nim` (relative pass/fail, reference refusals,
unit mismatch, predicate, cross-setup folding, one-result-per-claim), and
`tests/test_verify_readiness.nim` (no hidden request leaks, predicate
rendering). See `docs/authoring.md` for the spelling.

---

## 66. The switching model collapsed a fine print step, so `fSw` was unclaimable

**Fixed.** `designs/lib/lt8640a_sw.nim`'s switch-edge shape was a raised
cosine; it is now smootherstep (`6u^5 - 15u^4 + 10u^3`). The model runs at any
`.tran` print step from ~1 ns up, and `designs/lt8640a_buck.nim` now claims
`fSw` — `osc_freq(sw)` measured 1.00 MHz against the board's 1 MHz RT setting.

**What it was.** §66 was filed as "the model runs at exactly one print step":
measured on the buck at 1 MHz / `nsub = 50`, the `.tran` was reported to fail
with `Timestep too small` at 30, 15, 12 and 10 ns and to succeed only at
20 ns — the `1 / (fsw * nsub)` sub-step grid — which made `tWindow = 20.0.us`
the one window `analyzeTransient`'s `tWindow / 1000` step could land on, and
made `fSw` unclaimable because `analyzeOscillation`'s `tWindow / 10000` is a
2 ns step.

The re-investigation on ngspice-46 did not reproduce that table. The model ran
cleanly at every print step from **3.5 ns to 1 us** (and at 1–1.5 ns), and
failed only in a narrow band around **2–3 ns** — `analyzeOscillation`'s step
lands squarely in it. So the grid story was wrong; the print-step sensitivity
was real but sat somewhere else, and the specific failing values in the
original table were most likely an artefact of a different ngspice build (the
failure band's location is build- and platform-dependent).

**The actual cause.** Every failing run died at `tclk + tedge` of the first
switching cycle — the instant `son`'s turn-on edge meets its flat top. A
raised cosine `0.5 - 0.5*cos(PI*u)` is zero in the *first* derivative at both
ends (which is why it beat the linear ramp of §40) but steps the *second*: its
curvature jumps from `-0.5*(PI/tedge)^2` to 0 where the edge goes flat.
ngspice's local-truncation-error control fights that curvature break by
cutting the timestep, and for a max internal step in the 2–3 ns range it cuts
it to ~1e-20 s and bails. ngspice's log said `delta set to truncation error
result: point rejected`, repeated — not a convergence or breakpoint problem,
so the finding's proposed fix (guarding `setTempBkpt` against re-arming a
passed breakpoint, the reverted first attempt) was aimed at the wrong
mechanism.

**The fix.** smootherstep is zero in both the first *and* second derivative at
`u = 0` and `u = 1`, so each edge joins the flat regions to second order and
there is no curvature step for LTE control to chase. The edge is 10 ns of a
1 us cycle, so the shape change barely moves the steady-state numbers:
`ripple_pp` 6.95 → 7.13 mV, `i_pp(L1)` 905 → 919 mA, `psrr_db` 70.1 → 71.3 dB,
`step_droop_v` 21.3 → 21.2 mV — every claim still passes. Comments in
`lt8640a_sw.nim` and `lt8640a_buck.nim` that described the grid constraint
were rewritten, and the design gained `fSw = 1.0e6` on its
`switching_regulator` role. No test file covers the switching model directly;
`nimble verify` exercises it through the design.

## 26 (part). No coupled inductors, and no switch device model

Two of the seven library gaps `designs/xbar_switch.nim` turned up (§26) were
device-model holes in `src/verax/spice/models/`. Both are now filled.

### Coupled inductors — `spice/models/magnetics.nim`

**What it was.** SPICE models a transformer as `Lp`, `Ls` and `K Lp Ls <k>`;
the library had none of it. The PoE flyback, the MagJack magnetics and every
common-mode choke were on the BoM and absent from the electrical model, so the
isolated half of the PoE front end was declared, not simulated.

**The fix.** `expandCoupledInductors` rewrites `transformer` /
`common_mode_choke` / `coupled_inductor` into, per winding, an `inductor` in
series with a `resistor` for its DCR, plus one `mutual_inductance` component
per winding pair. `mutual_inductance` is a pinless component — a `K` card names
two inductors and a coefficient, not nodes — rendered by a special case in
`formats/spice.formatDeviceLine` keyed on `attrs["spice.couples"]`, which
resolves each inductor to its *deck* spelling at write time (like the
`xspice.ports` escape). `prefixByDeviceKind` gained `mutual_inductance -> 'K'`
(write-side only, alongside `E`/`G`/`F`/`H`). `mutual_inductance` is in a new
`kinds.couplingKinds`: `isPassive` accepts it so `spice/isolate` absorbs it,
but `classifyConductivity` still calls it `condAmbiguous` so `io_check` never
walks "through" a barrier that has no nodes to walk through. `spice/isolate`'s
`growSelection` gained a closing pass — a pinless `K` is never reached by the
net-walk, so it is pulled in explicitly when both its inductors were selected,
or a common-mode choke would isolate into two independent windings.

Winding inductances come from `lpri` + `lsec`, else `lpri` + `turns`
(`Ls = Lp·turns²`), else 1:1; none of the three stated leaves the part
unmodelled with a note, because there is no defensible default magnetising
inductance. `k_coupling` defaults to 0.98 and says so — leakage is implicit in
`k < 1` and the answer is not sensitive between 0.95 and 0.995.

**The barrier as a claim.** A new `static.dc_isolation` evaluator
(`contract/evaluators/static.nim`) produces `dc_path_exists(a, b)` — a
two-net, `capStatic` graph walk across `condConductive` parts only. `require
dc_path_exists(vpoe, poe5v) == 0` is `designs/xbar_poe.nim`'s isolation-barrier
claim, and it passes because the flyback's two windings share no node.

**What is not modelled:** a switching flyback primary (so `equipXbarPoe` still
strips the loop and stands the Si3402-B up as an ideal isolated source), core
saturation, and interwinding capacitance.

### Switches — `spice/models/switch.nim`

**What it was.** `switch`/`relay` were designator prefixes only; neither was in
`conductiveKinds`, so the eight ADG904s in `designs/xbar_rf.nim` were stood in
pin-by-pin — no RF path through the part existed, and `safe_default` passed for
a reason unrelated to the pulldowns (an unmodelled enable pin reads low
regardless).

**The fix.** `expandSwitches` turns a two-terminal `switch` / `relay` /
`load_switch` into a `vswitch` `S` element plus a `.MODEL SW(Ron= Roff= Vt=
Vh=)` card. `muxModel` — a `passesSignal` behavioural-registry model for
`analog_switch` / `rf_switch` / `mux` — builds, per throw, a `bsource` decoder
(a product of logistic terms on the select and enable pins, smooth rather than
`>` so a `.tran` does not stall and an `.ac` does not linearise a live path to
no gain), a through `S` element, and — when `switch.off_termination` is stated
— a second `S` element and a resistor terminating the throw when it is open.
That absorptive termination is the whole electrical content of the
safe-default claim: enable low ⇒ every throw open ⇒ every RF port in 50 ohm.
`prefixByDeviceKind` gained `S`/`W`; `test_spice_spellable` covers `vswitch`,
which reaches passivity through `hasDeviceModel` rather than a kind list.

`designs/lib/adg904.nim` is the ADG904 as annotations only — no build proc,
which is the test of whether the model sits at the right altitude.
`designs/xbar_rf.nim` makes four new `.op` claims: a 1 V tone on RIN1 reaches
m1 and ROUT1 through the routed path (EN1/EN5 driven, A1/A0 grounded), while m2
and ROUT2 sit at ground in their terminations.

**What is not modelled:** off-isolation vs. frequency (`Roff` is flat), charge
injection, break-before-make timing, and R_on flatness vs. signal level.

### Tests

`tests/test_spice_magnetics.nim` (winding sizing, the `K` line's deck
spelling, a transformer left alone, isolation pulling in a `K`, and an ngspice
`.op` showing no DC path across a two-winding transformer) and
`tests/test_spice_switch.nim` (the `S` line's node order, the `.MODEL SW` card,
and an ADG904 decoding all four throws plus the all-off absorptive state). Both
gated on ngspice for the runs. `nimble verify` exercises the designs.

## 71. A wide bus drew as N port glyphs and N wires

**What it was.** `b385e8b` gave the netlist buses and declared interfaces, but
only as an *authoring* view: `netlist/interfaces.nim` lowers everything to
scalar nets and records membership in `Net.attrs`. Nothing in
`src/verax/schematic/` read any of it, so a bus was invisible to the picture.
On `designs/lib/spi_memory.nim`'s `SPI_MEMORY` sheet, one SPI link to one chip
drew as **3 port pennants + 3 thin wires**, with `U1` sized at `rows = 5`
(`bodyH` 272). `designs/spi_memories.nim`'s top drew its three shared SPI links
as 15 ordinary thin wires among an MCU and six memory instances.
`docs/buses_and_interfaces.md` had booked this as known-out-of-scope: "a bus
glyph and a ripper are a schematic-layer feature".

**The fix.** `src/verax/schematic/bundles.nim` — a read-only index built in
`prepare`, before any symbol is sized, reading the `bus.*`/`iface.*` **net**
attrs directly (never `findBus`/`findInterface`, which rescan, need a process
registry and mutate `bus.index`; never a *pin* attr, which
`promotePortDirections` pollutes with `iface.nc`). A bus or interface whose
members *uniformly* touch exactly two endpoint entities — any pair of {a
component, the sheet boundary} — collapses to one merged pin per end
(`boxSlots` gives the member pins one shared slot `Point`, so
`slotOf`/`pinWorldPositions`/`rotationScore` are untouched) and one thick
coloured wire (blue bus / purple interface). A **published** bundle that fails
that degrades to teal net-label tags at every pin; every other bus/interface
wire is merely recoloured. `SPI_MEMORY` went to **1 pennant + 1 purple wire**,
`rows = 3` (`bodyH` 192); `spi_memories`' portless top recoloured its 16 SPI
wires and moved nothing.

**The `>= 2`-member floor, and why.** A grouping candidate with fewer than two
member nets — after an interface's per-signal-bus retry — is **discarded**: its
net routes as an ordinary scalar, keeping only its membership colour. This is
what keeps `designs/i2c_eeprom.nim` byte-identical: it instantiates an
interface but never *publishes* it, so `i2c_sda`/`i2c_scl` each retry as a
width-1 bus, fall below the floor, and are discarded. Making that design's
`runFULL.json` geometry byte-identical (colours only) was an explicit
acceptance criterion. The general guarantee: a netlist with no `bus.*`/`iface.*`
net attr yields a zero-value `BundlePlan` and byte-identical historical output,
and every new downstream code path is guarded on a non-empty plan.

**Not modelled:** a genuine bus *ripper* glyph (the merged wire is drawn as one
polyline, not a labelled bundle with tick marks); deriving `groupSide` for a
non-ported merged pin from the net-mates' centroid rather than the folded
direction; and the SPICE round trip still loses the grouping (inherent, like
`Pin.kind` fidelity).

**Follow-up — grouped net labels + a bus-slice narrowing.** The
"**published** bundle that fails collapse → net-label tags" and "the `>= 2`
floor keeps `designs/i2c_eeprom.nim` byte-identical" claims above are
**superseded**. `brNetLabel` now also fires for a bus or interface whose
members span **3+ component entities** (`union.parts`, never the sheet
boundary), published or not — the conventional shared-bus schematic. The tags
merge per endpoint: a box carrying `>= 2` members gets one merged pin with one
tag (`groupText`: `spi1` for the whole interface, `spi1(cs0)` for a coherent
slice, `spi1(sclk, mosi)` for a partial tap), a single-member or two-terminal
carrier keeps its bare member tag. `laneOf` is the single source of the merged
lane string so box sizing and `svg` cannot disagree; `bundleReport` gained a
`labels` field. A `>= 3`-entity interface no longer retries per `bus.name`, so
it never gets a collapsed sub-bus. `spi_memories`' top now draws three
`netlabel` interface bundles (`runFULL.json` wires 33→17, fallbacks 17→12) and
`designs/i2c_eeprom.nim`'s sda/scl draw as grouped `i2c` tags — its **readiness
report stays byte-identical** because the `i2c` role reads the netlist, not the
picture (that is the acceptance criterion now, not `runFULL.json` geometry).
The zero-value guarantee is unchanged: a bus-free netlist still yields a
byte-identical scene.

`designs/spi_memories.nim` also lost its `spi1.bus("cs")[k]` boilerplate:
`narrow(Interface, signal, k)` presents an interface with one wide signal cut
to width 1 in pure value space, wired by name as
`{"spi": spi1.narrow("cs", 0)}`. Latent `wiringOf` bugs fixed at the same time
— a `seq[Net]`/`Bus`/whole-`InterfaceView` argument member-suffixes now
(`label_0 …`) instead of repeating the bare label, which made
`docs/buses_and_interfaces.md` item 9 true.

---

## 72. Package pin count vs. footprint

§70's list of what multi-channel packaging left out named this directly:
"Package pin count vs. footprint. Needs a board reader `pcb/formats` does not
have yet." At the time nothing in the library could read a footprint's own
pad list at all, so the check had no second list to compare the netlist's
pins against.

**The fix.** The schematic->board stage (`pcb/footprint.nim`,
`pcb/formats/kicadmod.nim`, `pcb/assemble.nim`, `pcb/formats/kicadgen.nim`,
`pcb/variant.nim`) built the missing reader as part of a larger piece of
work — a component states a `footprint` annotation (`netlist/annotations.nim`,
deliberately separate from `package`, a case size), `pcb/formats/kicadmod.nim`
resolves it against a real `.kicad_mod` library search path, and
`pcb/assemble.nim` walks a netlist to place every resolved footprint's real
pads. `footprint_pad_unmatched` (`sevWarning`) is the check §540 asked for,
run both directions: a component pin with no matching footprint pad id, and
a footprint pad id matching no component pin — a real mismatch on either
side is exactly a datasheet-vs-land-pattern transcription error, the same
class `validatePackages`' own pin-map checks catch for a package definition.
`footprint_unresolved` (`sevError`) is the companion finding for a part with
no footprint at all, naming the component, the spec it stated (if any), and
the footprint sources tried.

**Not modelled, on purpose, this stage:** placement quality, routing, and any
selection policy over more than one physical layout of a subcircuit — see
`docs/layout_variants.md` for the data model (`pcb/variant.nim`) committed so
that stage has nothing left to re-litigate about a variant's *shape* when it
arrives, and for the OpenSCAD footprint-body obstacle this stage ran into and
did not solve.
