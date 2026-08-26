# Open findings

What is **still open**. Everything already fixed — §1–§43 and §45, each with
what it was and what the fix was — lives in `RESOLVED_FINDINGS.md`, and the
designs themselves are described there. The numbering is shared and continuous across
the two files, so a `§n` cross-reference means the same thing in either.

**Two kinds of entry, deliberately not mixed into one list.** Everything up to
§44 is a *finding*: a real design was checked, the tool gave an answer that was
wrong, missing or unclaimable, and the entry carries the measurement that
proves it. §45 and up are *proposals* — a survey of what the registries reach
against what a board actually needs, with no design yet demanding them. A
finding says the tool is broken; a proposal says it is narrow. Both are worth
doing, only one of them has evidence, and the day a proposal acquires evidence
it should be rewritten as a finding and moved up.

§23 was the last structural gap and is closed: `analyzeOscillation` and the
`oscillator` role reach a circuit whose intent is instability, `charge_pump`
and `wien_osc` state their central claims, and `analyzeStartup` honours a
regulator's own model so the LT8640A can claim its soft start. §45 is the
first proposal to be built: there is a `.dc` capability now, so line
regulation, load regulation, dropout, a transfer ratio and a DC output
resistance are all claimable, and §63 and §65 are unblocked. What is below is
what is left.

---

## What checking designs found, in order

1. **`current_rating` / `isat` have no consumer** (§27), and it is the check a
   converter most wants. Both keys are registered and both are set by the part
   policy; nothing reads either. A branch current is not in a `.op` for
   anything but a voltage source, and an inductor's peak needs a `.tran` and a
   probe.

   This is closer than it was and is now the *next* thing rather than a
   distant one. The LT8640A's switching model puts a real 0.94 A triangle on
   L1, so the number exists in the simulation. What is missing is a way to get
   at it, and §23 found the shape of the problem: `spice/probes.addCurrentProbe`
   splits a pin off its net, which needs a pin it may move — and it now refuses
   a code model outright, because an `A` line's ports are rendered from the
   model spec rather than from its pins. An inductor is not a code model and
   ngspice reports its branch current natively, so the probe is not even
   needed there; what is needed is a quantity (`i_peak`, `i_rms`), a
   measurement over the settled window, and a role that names the part. The
   same run `settled_rail` already makes would answer it.

   **The general shape of it: current is not a first-class quantity anywhere
   here.** `inrush_peak` and `t_inrush_peak` are the entire inventory, and both
   belong to `spice.startup`. Everything else this library measures is a
   voltage. That is also why `--save-currents` exists and is read by nobody but
   a person: it puts `@r1[i]` and `@d2[id]` into an archived rawfile for
   someone to `load` in ngspice, and no evaluator has ever asked for one. So
   the plumbing that gets a device current out of a run is already built and
   already tested; what is missing above it is the quantity, the window
   statistic and the role. The role wants a name — `current_path` — and wants
   to bind a part rather than a net (`isat`, `iRmsMax`, `iAvgMax`, plus the
   `tSettle`/`tWindow` pair `settled_rail` already spells). Doing it also
   unblocks §64, which needs an input current and an output current to say
   anything about efficiency.

2. **Capacitor tempco is not modelled** (§28). Half the argument for a Class 1
   timing capacitor is temperature drift, and nothing here represents it. The
   inputs such a model needs now exist and are the *only* part that does:
   `netlist/environment` carries a board's ambient range (`environment:`, with
   `t_ambient_min`/`t_ambient_max`) and a part's rise above it (`delta_t`,
   defaulting to 0), and `partTemperatureRange(c, env)` joins them. What is
   missing is the curve itself — capacitance against temperature per
   dielectric, alongside the DC-bias derating §26 added — plus the same
   question for an electrolytic's ESR at the cold end. A `delta_t` is authored
   today; deriving one from a dissipation and a thermal resistance is a
   separate step, and that key stays the override when it lands. See §47 for
   the cheaper half of the same problem.

3. **A phase margin for the LT8640A.** §40 delivered the switching model and
   the ripple claim with it, and deliberately stopped short of stability: the
   compensation in that model is chosen for a sensible loop rather than fitted
   to the part's, which ADI does not publish. Measuring a margin through it
   would be a claim about `gmc` and `rzc`. What would make it real is either
   the internal network or a bench correlation, and neither is a code change.

4. **Slew rate and output current limit.** The macromodel now saturates at its
   rails, so headroom is measurable; what it still cannot do is run out of
   *speed* or *current*. Both are ordinary macromodel additions, and both
   would be read straight out by `designs/wien_osc.nim` and
   `designs/ts808_drive.nim`, which is the useful property.

5. **A bus edge is simulated and never claimed** (§44). `designs/i2c_eeprom.nim`
   carries a real analog I2C bus -- pull-ups, bus capacitance, a `bidi_bridge`
   at each line -- and the exchange over it is measured end to end. The bus's
   own *electrical* behaviour is not: SCL rises through 0.3 Vdd to 0.7 Vdd in
   a measured 60 ns against the specification's 1 us for standard mode, and a
   pulled-down line bottoms at 43 mV against a 400 mV VOL budget, and neither
   number is a claim because no registered quantity fits. `rise_time_10_90`
   belongs to `spice.startup` and wants a regulator binding.

   What is missing is a quantity (`t_rise_edge`, `v_ol`), a measurement over a
   named net's transitions in the settled window, and somewhere to state the
   limits against. That would also close the gap the design documents:
   `static.rc_corner` rests on an invented 10 pF per pin and says so, and this
   is the first circuit here that could measure the real answer instead of
   estimating it.

   **Where the limits are stated should not be the `i2c` role.** The obvious
   move is a parameter on `i2c`, and it is the wrong one: nothing about a rise
   time, a VOL or an input threshold is specific to I2C, and putting it there
   means writing it again for SPI, again for a reset line, and again for every
   CMOS input that has to be driven past `VIH`. A net-level `logic_net` role —
   bind a net, optionally bind the rail so the thresholds can be stated as
   fractions of it, then `maxRiseTime`, `maxFallTime`, `vOlMax`, `vOhMin` —
   covers all of those with one definition, and `i2c` can stay what it is.
   That role is the deliverable; the quantity and the measurement are what it
   needs underneath.

6. **A start-up transient is not sampled the way a settled one is.**
   `analyzeStartup` derives its print step from the run length
   (`tStop / 2000`), where §23 established that the derived step is *also*
   ngspice's ceiling on its own timestep. That is defensible for a rise time,
   which is a slow measurement, and it is not obviously defensible for the
   `overshoot_pct` of a rail ringing on an LC — the statistic undersampling
   shortens is exactly a peak. `analyzeTransient` sizes from the *window*
   instead and `analyzeOscillation` takes ten times that density; nobody has
   checked what the third one costs.

---

## Feature gaps

Proposals, from §46 — §45 was the first of them and is now built, in
`RESOLVED_FINDINGS.md`. No design has failed for want of any of these; each is
a thing the library cannot currently be asked. Ordered roughly by value per unit
of work rather than by size, and several of them are each other's
prerequisites — the dependencies are stated where they exist.

7. **`tolerance` is written by the part policy and read by nothing** (§46).
   `parts/annotate.applyChoice` sets it on every part the policy chooses,
   `annotations.nim` registers it, and no analysis, evaluator or report ever
   looks at it — the same registered-and-unconsumed smell as `current_rating`
   in §27, and it has been there longer.

   What it should buy is a corner run: each toleranced part at its extremes,
   the worst case per measurement reported alongside the nominal, so
   `measured 5.00 V, expected 5 V ±5%` becomes `4.87 – 5.12 V over stated
   tolerances`. That is the question a 5% band was asked in the first place,
   and it is the difference between a design that passes and one that passes
   *when built*. The honest cost: a corner axis has to join the evaluator setup
   key, so "one analysis run per distinct setup" becomes one run per setup per
   corner, and a full ±corner on every part is 2^n. A defensible first cut is
   min/typ/max on one axis at a time, or a stated worst-case direction per
   claim; Monte Carlo rides the same axis afterwards. Also the strongest
   argument for §51, because it multiplies run count by exactly the factor
   caching would absorb. §62 is the design that would prove it.

8. **`environment:` is stated, validated, and consumed by nothing** (§47).
   `validateEnvironment` checks what was stated, `partTemperatureRange` joins
   an ambient range to a part's rise, and no analysis reads the result. §28 is
   the expensive way to fix that — a capacitance-versus-temperature curve per
   dielectric family, plus an electrolytic's cold ESR — and it is not the
   cheapest.

   The cheapest is a junction temperature. `analysis/derating` already computes
   V²/R across every resistor from the shared `.op`, so the dissipation half
   exists; add `theta_ja` as an annotation and `t_junction = t_ambient_max +
   P·θJA` is arithmetic over two numbers with no curve anywhere in it. Deliver
   it as a `thermal` role (bind a component; `maxPower`, `thetaJA`, `tJMax`)
   producing `p_dissipated` and `t_junction`. That gives the environment block
   its first consumer, gives `delta_t` something to be checked against rather
   than merely authored, and leaves §28 exactly where it is.

9. **No machine-readable report output** (§48). `verify.readiness` renders one
   text report and there is no other shape. A `--format=json` (or `--junit`)
   carrying each claim's id, quantity, subjects, expectation, measurement,
   status and assumptions makes the tool CI-native, costs nothing electrical,
   and cannot move a number. It is also the precondition for §49, which is
   where the real value is. Smallest item on this list.

10. **A claim that passes by 40% and one that passes by 0.5% print
    identically** (§49). The report says `PASS` and moves on, so the single
    most useful piece of information about a healthy design — how close it is
    to not being one — is computed and thrown away on every run. `acceptance`
    already renders the interval and the measurement is already in hand, so the
    margin is a subtraction.

    Two features fall out. A **margin column** on each passing claim in
    `CHECKS`. And `--baseline=prev.json` (on §48) reporting which measurements
    moved since the last run and by how much, which catches the class of defect
    a pass/fail gate structurally cannot see: a part substitution that halves
    the phase margin while leaving it above 45°. Neither is worth much without
    the other.

11. **`explainPlan` is written and has no caller** (§50). `plan` is pure and
    `explainPlan` renders it, both for the stated reason that an assertion set
    you cannot inspect before it executes is the failure mode this layer
    exists to prevent — and nothing in `cli.nim`, `verify.nim` or any design
    ever calls it. A `nimcir check --dry-run` printing what would be simulated,
    with what setup, for which claims, before any of it is spent. A `.tran`
    through the LT8640A's switching model at fifty timepoints a cycle is not
    free, and the tool already knows the bill before it runs up.

12. **Nothing is cached; every run re-simulates from scratch** (§51). The
    derived deck is a deterministic function of the design and the analysis
    setup, and `--keep-runs` already writes it *before* handing it to ngspice —
    which means the exact bytes that determine the answer are already in hand
    at exactly the right moment to hash. Key a rawfile cache on that hash and
    an unchanged design re-reports instantly. Two consequences beyond the edit
    loop: it makes §46's corner multiplication affordable, and it makes §55
    (sweeping a parameter over many candidate designs) practical rather than
    theoretical. The invalidation story is unusually clean here because the
    hash is over the derived artifact rather than over the source.

13. **`ekRelative` and `ekPredicate` are documented as the escalation path and
    do not exist** (§52). `contract/types.nim` names both in a comment
    explaining that the `Expectation` variant is what makes them additive
    rather than a redesign; the variant has `ekNominal`, `ekMin`, `ekMax` and
    `ekRange`, and `satisfies` and `acceptance` branch over those four.

    `require z_max_in_band(vdda) <= 0.2 * z_max_in_band(vdd)` — "the analog
    rail must be five times quieter than the digital one" — is the shape a
    large fraction of real claims take, and today it has to be written as an
    absolute number somebody computed by hand from the other rail's result.
    That is precisely the arithmetic-done-twice this library exists to remove,
    and the hedge that was taken to keep it cheap has never been spent.
    `ekRelative` also wants a second measurement in scope at comparison time,
    which is a planner question rather than a types question, and that is the
    part nobody has thought through.

14. **No quantity takes more than one subject** (§53). `Assertion.subjects` is
    a `seq` for the explicit reason that setup/hold is inherently one signal
    *versus* another and must not be a special case bolted on later — and every
    registered evaluator, built-in and static alike, declares `arity: 1 .. 1`.
    So the shape decision is paid for and unused.

    What it would reach: channel matching (§60), rail sequencing (§59),
    setup/hold, differential balance, and any claim of the form "these two are
    the same to within". `designs/riaa_preamp.nim` instances one channel twice
    and can say nothing whatever about the pair, which is the single most
    obvious thing to want to know about a stereo board.

15. **Noise** (§54). No capability, no analysis, no quantity. For
    `designs/riaa_preamp.nim` this is not a refinement, it is *the*
    specification — a phono preamp is chosen on its input-referred noise —
    and the library cannot express the claim at all. `ngspice.analysisCards`
    already lists `noise`, and the output-noise plot is `.ac`-shaped, so the
    rawfile parser is likely to need nothing; that is worth checking rather
    than assuming, since ngspice writes two plots for a noise run and only one
    of them is the spectral density. Quantities: `vn_out_rms` over a band,
    `vn_density_at_f`, and a noise figure if a source resistance is stated.

16. **Nothing sweeps a parameter** (§55). The `EvalContext` refactor was
    justified in part by making a sweep over candidate designs *safe* — the
    shared operating point is scoped to one run, so two designs checked in one
    process can no longer share a cached solve — and nothing sweeps.
    `designs/lib/filters.sallenKeyLP(fc, r, q)` is fully parameterized and
    `designs/param_filter.nim` states its claims against the design equations
    rather than against arithmetic, so the machinery to ask "at which `q` does
    the peaking claim start failing" is entirely present except for the asking.
    The design-side hook is the unclear part: a design is a program that ends
    in `quit(verifyMain(d))`, so either the sweep lives inside the design file
    or `verifyMain` grows a way to be called more than once with different
    bindings. Wants §51 to be affordable.

17. **Two missing CLI surfaces** (§56), both small and neither electrical.
    `nimcir bom <design>` — `pcb/bom.buildBom` exists and the part policy
    computes real choices with real provenance, and there is no way to print
    any of it without writing a program. And `nimcir netlist <design> [-o
    out.cir]` — exporting the deck without running a check, which
    `$NIMCIR_KEEP_DECKS` currently does only as a side effect of checking, and
    only for the *derived* fragments rather than for the design as authored.
    Both are plumbing over things that already work.

---

## Roles not yet written

Proposals, from §57. A role is a parameterized bundle of assertions and the
built-ins use no privileged mechanism, so each of these is ordinary code
against the existing registry — which makes the interesting question for each
one not "how" but "what does it bind, and what does the evaluator underneath
it still lack". Two more roles are described where their blocking finding is:
`current_path` under §27, and `logic_net` under §44.

18. **`passive_filter`** (§57) — the response role with no amplifier binding.
    `opamp_stage` and `gain_stage` both require an `opamp` component and the
    evaluators behind them declare `binds: @["opamp", "input"]`, so an LC EMI
    filter, a ferrite-and-capacitor rail filter, an RC anti-alias front end, or
    the passive network sitting *around* a stage cannot be swept at all —
    there is no path to an `.ac` response for a circuit with no active part in
    it. Params: `fc` and `band`, `minAtten` at a stated `atF`, `fLoMax` /
    `fHiMin`, `maxPeaking`.

    What it needs underneath is an `.ac` evaluator that drives `input` and
    measures `output` with nothing to macromodel, which is less work than it
    sounds: `checkInjectionPoint` and `detachDrivers` already exist and already
    handle the two ways driving a net goes wrong. Probably the largest increase
    in what the library can be pointed at, per line of code, on either list.

19. **`load_step`** (§58) — the time-domain twin of `targetZ`, and the thing a
    target impedance is a *proxy* for. Bind the rail and the sink; params
    `iFrom`, `iTo`, `tEdge`, `maxDroop`, `maxOvershoot`, `maxRecover`.
    `spice/boundary.driveSink` already builds a constant-current sink and
    already documents why it is not a resistor (a sink is an open circuit at
    AC and damps nothing, which is the same reason it is the right stimulus
    here); this is that, pulsed, plus a `.tran` and three window statistics.
    It answers "does the rail hold up when the MCU wakes" directly, instead of
    by an impedance argument the reader has to complete themselves.

20. **`sequencing`** (§59) — two rails and an ordering claim: core up before
    I/O, or the two within 10 ms of each other. A real and common way to
    destroy an FPGA or a PHY, and nothing here can currently express it.
    Multi-subject, so it is blocked on §53, and the natural first customer for
    `ekRelative` in §52 — "rail A reaches 90% before rail B leaves 10%" is a
    comparison between two measurements and not against a constant. Quantity:
    `t_reach_frac` per rail, over the start-up run `analyzeStartup` already
    performs.

21. **`channel_match`** (§60) — bind two nets, claim `gain_delta_db <= 0.5 dB`,
    or two corner frequencies within a ratio band. Blocked on §53. The
    motivating design is already in the repository and already instances one
    channel twice, which makes this the cheapest way to prove the multi-subject
    path works on something real rather than on a fixture.

22. **`bias_point`** (§61) — bind a three-terminal device; claim `v_ce` or
    `v_ds`, `i_c`, and headroom to the rail. Pure reads off the shared `.op`,
    no new analysis, no new capability, and it is what a discrete stage is
    designed around in the first place. The natural home, later, for "this
    device is in its active region" as a derived quantity rather than something
    the reader infers from two voltages.

23. **`precision_divider`** (§62) — `designs/divider_net.nim`'s claims as a
    role: bind top, tap and bottom; params `ratio`, `band`, `zOut`,
    `maxLoadCurrent`. Reachable through the existing `dc_voltage` evaluator
    with no new analysis at all, so the work is the role definition and
    nothing else. Two reasons it is worth more than its size suggests: it turns
    a substitutability property that design currently measures by hand into one
    line, and a divider's ratio is exactly where component tolerance bites, so
    it is the right first design to point §46 at. Two of the four claims it
    would bundle now exist: §45's `source_sweep` measures the ratio as a slope
    and `load_sweep` measures the output resistance, and `divider_net` states
    both, so the role is now mostly a matter of bundling what is there.

24. **`comparator_threshold`** (§63) — trip point and hysteresis width from a
    `.dc` sweep. **No longer blocked**: §45 shipped the capability, the
    analysis and the `source_sweep` role, so what is left is the role and the
    two quantities under it. A trip point is a threshold crossing on a curve
    `analyzeLineSweep` already produces; a hysteresis width is the same
    crossing found sweeping the other way, so it needs two runs rather than
    one, and that is the interesting part of the work. Still a hole with no
    workaround today:
    `spice/models.opampModel` is deliberately *not* registered for
    `comparator`, on the grounds that the macromodel is linear and a
    comparator's entire behaviour is that it is not. So a comparator currently
    falls through to per-pin impedances, which deletes the part.

25. **`switching_converter`** (§64) — bind the switch node and the output;
    params `fSw`, `dutyRange`, `minEfficiency`, `maxRipple`. Ripple is already
    claimable through `settled_rail`, and duty and switching frequency fall out
    of the same window. Efficiency does not: it needs an input current and an
    output current, so this is mostly a statement of what §27 unlocks rather
    than independent work. Worth writing down as the destination, because
    "measure the inductor current" is a much less motivating way to describe
    the same task.

26. **`esd_clamp` / `protection`** (§65) — bind the protected net and the
    clamp; sweep past the clamp voltage and claim the clamped level and the
    leakage below it. **No longer blocked** either: §45's `source_sweep` and
    its `dc_out_max` already reach the clamped level, so what is missing is a
    role saying which net is protected, plus a leakage quantity — and leakage
    is a branch current, so that half lands on §27 rather than here.

---

## If the order is up for grabs

**Cheapest real value:** §48 then §49. No circuit knowledge, no new analysis,
and margin-to-limit is information the tool computes and discards on every
passing claim today.

**Best leverage from one small change:** was §45, and it was spent — one
capability enum member and one analysis module, and it unblocked §63 and §65
and turned `divider_net`'s ratio and output resistance from asserted numbers
into measured ones. Of what is left, §61 (`bias_point`) is the closest
equivalent: pure reads off the shared `.op`, no new analysis and no new
capability, for the thing a discrete stage is designed around.

**Highest value overall:** §27 with `current_path`, which closes the oldest
open finding, makes the registered-and-unchecked `isat` mean something, and
unblocks §64. And §57 (`passive_filter`), which is the biggest single jump in
what the library can be pointed at.

**The two that quietly gate everything else:** §51, because §46 and §55 are
both impractical without it, and §53, because §59 and §60 cannot be written at
all until a quantity may take two subjects.
