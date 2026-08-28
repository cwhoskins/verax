# Open findings

What is **still open**. Everything already fixed — §1–§43 and §45, each with
what it was and what the fix was — lives in `RESOLVED_FINDINGS.md`, and the
designs themselves are described there. The numbering is shared and continuous across
the two files, so a `§n` cross-reference means the same thing in either.
(§27 was the last of the §1–§43 block still open; it is now in the resolved
file with the rest.)

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
resistance are all claimable, and §63 and §65 are unblocked. §27 is the
oldest one and is now closed too: `analyzeCurrent` and the `current_path`
role make **current** a quantity — `i_peak`, `i_rms`, `i_avg`, `i_pp`, plus
the two derating fractions that read a part's own `isat` and `current_rating`
back off it — so `lt8640a_buck` claims its inductor's 905 mA triangle and its
49% of saturation, and §64's efficiency figure is the half still open —
further off than a second `current_path` claim, since a converter's input
current runs through no single two-terminal part; §64 now records why. §58
built on that immediately: `analyzeLoadStep`,
`analysis/psrr.nim` and the `regulator` / `linear_regulator` /
`switching_regulator` roles ask a power supply the three questions it is
actually specified by — what the rail does when the load jumps, how much of
the input's ripple reaches it, and whether the part is being run past its
rating. Doing that turned up **§66** and **§67**, both of them findings rather
than proposals: the models had to be fixed before the measurements meant
anything. §66 (`designs/lib/lt8640a_sw.nim`'s switch edge collapsed a fine
`.tran` print step, so `lt8640a_buck` could not claim `fSw`) is fixed and in
the resolved file; §67 stays below for its one remaining case. What is below
is what is left.

---

## What checking designs found, in order

1. **Capacitor tempco is not modelled** (§28). Half the argument for a Class 1
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

2. **A phase margin for the LT8640A.** §40 delivered the switching model and
   the ripple claim with it, and deliberately stopped short of stability: the
   compensation in that model is chosen for a sensible loop rather than fitted
   to the part's, which ADI does not publish. Measuring a margin through it
   would be a claim about `gmc` and `rzc`. What would make it real is either
   the internal network or a bench correlation, and neither is a code change.

3. **Slew rate and output current limit.** The macromodel now saturates at its
   rails, so headroom is measurable; what it still cannot do is run out of
   *speed* or *current*. Both are ordinary macromodel additions, and both
   would be read straight out by `designs/wien_osc.nim` and
   `designs/ts808_drive.nim`, which is the useful property.

4. **A bus edge is simulated and never claimed** (§44). `designs/i2c_eeprom.nim`
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

6. **A regulator model can reject perfectly and mean nothing by it** (§67).
   Two of the three regulator models here could not show input feedthrough at
   all, so a PSRR measurement through them was a confident number about the
   model:

   - `designs/lib/adjreg.nim` drove the output net straight off the error
     amplifier. There was **no element between IN and OUT**, so rejection
     measured infinite and the input current was a declared constant.
   - `designs/lib/lt8640a_avg.nim` commanded a switch *voltage*
     (`output(sw) = aol * (vr - vf)`) with `partial(sw, vin) = 0` while in
     regulation, so rejection was `aol` — a statement about a parameter.

   Both are fixed, and both fixes were structural rather than a number being
   corrected. `adjreg` now closes its loop through a floating series VCVS fed
   from the IN net, so line response is `1 / (1 + aol)` and the input draw is
   whatever the load takes; `lt8640a_avg` commands a **duty** and multiplies
   it by the input. What falls out is measurable and checks against the
   datasheet rather than against the model: the LM317 rail's line regulation
   comes to 0.0107 %/V against a 0.01 %/V typical, and its rejection to
   62.9 dB at 120 Hz by a `.tran` tone and 62.9 dB by an `.ac` sweep — two
   solvers, agreeing to 0.002 dB.

   **What is left open is the third case, and it cannot be fixed the same
   way.** `spice/models.regulatorModel` stands an unmodelled `regulator`,
   `ldo` or `buck` in as an ideal source at its output voltage, which by
   construction has no input path — `templates/regulator.nim` is exactly
   that. There is no loop to give it: the part number is all anybody stated.
   So `analysis/psrr.nim` refuses instead, reporting `not evaluated` with
   `KindNoFeedthrough` when the output sits at the solver's noise floor while
   the input does not. That is honest, and it is not the same as a warning at
   authoring time — a design can still state the claim, get the refusal, and
   have to read the report to find out. A structural check that a PSRR claim's
   regulator carries a model with a live input would be better.

7. **A start-up transient is not sampled the way a settled one is.**
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

8. **`tolerance` is written by the part policy and read by nothing** (§46).
   `parts/annotate.applyChoice` sets it on every part the policy chooses,
   `annotations.nim` registers it, and no analysis, evaluator or report ever
   looks at it — the same registered-and-unconsumed smell `current_rating` had
   in §27, and now the only one of its kind left.

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

9. **`environment:` is stated, validated, and consumed by nothing** (§47).
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

10. **No machine-readable report output** (§48). `verify.readiness` renders one
   text report and there is no other shape. A `--format=json` (or `--junit`)
   carrying each claim's id, quantity, subjects, expectation, measurement,
   status and assumptions makes the tool CI-native, costs nothing electrical,
   and cannot move a number. It is also the precondition for §49, which is
   where the real value is. Smallest item on this list.

11. **A claim that passes by 40% and one that passes by 0.5% print
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

12. **`explainPlan` is written and has no caller** (§50). `plan` is pure and
    `explainPlan` renders it, both for the stated reason that an assertion set
    you cannot inspect before it executes is the failure mode this layer
    exists to prevent — and nothing in `cli.nim`, `verify.nim` or any design
    ever calls it. A `nimcir check --dry-run` printing what would be simulated,
    with what setup, for which claims, before any of it is spent. A `.tran`
    through the LT8640A's switching model at fifty timepoints a cycle is not
    free, and the tool already knows the bill before it runs up.

13. **Nothing is cached; every run re-simulates from scratch** (§51). The
    derived deck is a deterministic function of the design and the analysis
    setup, and `--keep-runs` already writes it *before* handing it to ngspice —
    which means the exact bytes that determine the answer are already in hand
    at exactly the right moment to hash. Key a rawfile cache on that hash and
    an unchanged design re-reports instantly. Two consequences beyond the edit
    loop: it makes §46's corner multiplication affordable, and it makes §55
    (sweeping a parameter over many candidate designs) practical rather than
    theoretical. The invalidation story is unusually clean here because the
    hash is over the derived artifact rather than over the source.

    A concrete second customer landed with §53: `spice.channel_match` sweeps
    each of two stages exactly the way `spice.opamp_response` does, so
    `designs/riaa_preamp.nim` now runs **four** `.ac` sweeps where two would
    do — the two `gain_stage` steps and this evaluator's own two, over the
    same fragments. Routing one step's curve into another is planner work
    (§52-shaped); a rawfile cache keyed on the derived deck absorbs it with no
    planner change at all, because the two pairs of sweeps produce
    byte-identical decks.

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
it still lack". One more role is described where its blocking finding is:
`logic_net`, under §44. (`current_path` was one of the others, and §27 built
it; `load_step` was the third, and §58 built it — as parameters on
`regulator` rather than as a role of its own, because a load step is a thing
a regulator is asked and not a thing to bind separately.)

19. **`passive_filter`** (§57) — the response role with no amplifier binding.
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

20. **`sequencing`** (§59) — two rails and an ordering claim: core up before
    I/O, or the two within 10 ms of each other. A real and common way to
    destroy an FPGA or a PHY, and nothing here can currently express it.
    Multi-subject — **no longer blocked**: §53 shipped `arity: 2 .. 2` and the
    `skClass` subject path, and `channel_match` is the worked precedent. It
    remains the natural first customer for `ekRelative` in §52 — "rail A
    reaches 90% before rail B leaves 10%" is a comparison between two
    measurements and not against a constant. What is still missing is a
    `t_reach_frac` quantity per rail, over the start-up run `analyzeStartup`
    already performs, and a design in-repo that demands it.

21. **`bias_point`** (§61) — bind a three-terminal device; claim `v_ce` or
    `v_ds`, `i_c`, and headroom to the rail. The voltage claims are pure reads
    off the shared `.op` — no new analysis, no new capability — and they are
    what a discrete stage is designed around in the first place. The natural
    home, later, for "this device is in its active region" as a derived
    quantity rather than something the reader infers from two voltages.

    **`i_c` is the part that is not free — it wants a pin subject.**
    `Assertion.subjects` already has an `skPin` kind, `design.resolve` handles
    it through `graph.findPin`, and `contract/dsl.subjectOf(Pin)` routes a pin
    binding — but no evaluator declares `subjectKinds: {skPin}`, so a pin-bound
    claim is rejected at plan time today. ngspice exposes per-terminal device
    current directly (`@q1[ic]`, `@m1[id]`; `ngspice.currentParamsFor`), and
    `branchCurrentVector` refuses `Q`/`M`/`J` precisely because "the current
    through Q1" does not name a terminal — a pin subject is that
    disambiguation. The work is one `skPin` evaluator mapping a pin to its
    `@dev[term]` vector (real-valued, so saveable on an `.op`/`.tran`/`.dc`
    plot, not `.ac`) plus lifting `analyzeCurrent`'s three-terminal refusal for
    a pin-addressed claim. That same evaluator generalises `current_path` (§27)
    to transistors, and §64 and §65 need it for their current claims.

22. **`precision_divider`** (§62) — `designs/divider_net.nim`'s claims as a
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

23. **`comparator_threshold`** (§63) — trip point and hysteresis width from a
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

24. **`switching_converter`** (§64) — bind the switch node and the output;
    params `fSw`, `dutyRange`, `minEfficiency`, `maxRipple`. Ripple is already
    claimable through `settled_rail`, and duty and switching frequency fall out
    of the same window. Efficiency is the piece still missing, and it is
    further off than §27 left it looking. The *output* current is one
    `current_path` claim away — for a buck it is the inductor's `i_avg`, which
    `lt8640a_buck` already measures. The *input* current is not: an input
    capacitor carries only the switching ripple, not the DC draw, and a board
    routinely splits its input bulk across several caps, so no two-terminal
    part necessarily carries the whole of it — the current that matters is the
    one into the converter's VIN pin. A part-scoped `current_path` cannot name
    a pin (§61), and `lt8640a_buck`'s converter is an XSPICE code model with no
    addressable terminal current anyway, so the input side needs either a pin
    subject on a converter that reaches the deck as a real device, or a
    deliberate series sense element in the design. Efficiency is then still the
    *product* of a voltage and a current — arithmetic over two measurements,
    the same shape §52's `ekRelative` needs.

25. **`esd_clamp` / `protection`** (§65) — bind the protected net and the
    clamp; sweep past the clamp voltage and claim the clamped level and the
    leakage below it. **No longer blocked**: §45's `source_sweep` and its
    `dc_out_max` already reach the clamped level, so what is missing is a role
    saying which net is protected, plus a leakage quantity. For a two-terminal
    clamp (a TVS diode) §27 already makes the current measurable and what
    remains is a `.dc`-swept counterpart of `i_avg`. A multi-terminal clamp (a
    rail-to-rail diode pair, a clamp array) carries the same three-terminal
    ambiguity as §61 and wants the pin-subject evaluator described there.

26. **What `designs/xbar_switch.nim` could not be asked** (§66). The
    Ethernet-controlled RF crossbar is the first *product* under `designs/`,
    and building it turned up seven things the library cannot express, ordered
    by how much this one board wanted them:

    - **No transmission lines / characteristic impedance / S-parameters.** The
      largest gap for any RF board, and the reason *every* RF claim on the
      crossbar — insertion loss, isolation, return loss, VSWR, the two-stage
      cascade's cumulative loss, port match — is on the cannot-check list.
      Needs a new device kind, a `prefixByDeviceKind` letter, a `pinTemplates`
      entry and a new evaluator + role; `tests/test_spice_spellable.nim` will
      name a half-done addition.
    - ~~**No coupled inductors** (`K` card).~~ **Shipped.**
      `src/nimcir/spice/models/magnetics.nim`: `transformer` /
      `common_mode_choke` / `coupled_inductor` expand to two windings and a
      `mutual_inductance` component that `formats/spice` renders as a `K`
      card; `mutual_inductance` joins `couplingKinds` (accepted by `isPassive`,
      still `condAmbiguous` so `io_check` never crosses the barrier) and
      `spice/isolate` gained a closing pass that pulls a `K` in when both its
      inductors are selected. `designs/xbar_poe.nim` now carries a real
      flyback `T1` and a common-mode choke `LCM`; the isolation barrier is a
      checked claim (`dc_path_exists(vpoe, poe5v) == 0`, a new
      `static.dc_isolation` evaluator). Still not modelled: a *switching*
      flyback primary (so the Si3402-B is still an ideal isolated source),
      core saturation, and the MagJack's MDI transformers (nothing drives an
      MDI pair to measure).
    - ~~**No switch or relay device model.**~~ **Shipped.**
      `src/nimcir/spice/models/switch.nim`: `switch`/`relay`/`load_switch`
      expand to a `vswitch` `S` element plus a `.MODEL SW` card
      (`prefixByDeviceKind` gained `S`/`W`/`K`); a multi-throw `analog_switch`
      /`rf_switch`/`mux` is a behavioural-registry model (`muxModel`) that
      decodes the select pins, gates on the enable, and terminates each open
      throw when the part is absorptive. `designs/xbar_rf.nim`'s eight ADG904s
      are `kind = "rf_switch"` and make four new `.op` claims -- a routed path
      and an off path's isolation. Still not modelled: off-isolation vs.
      frequency (`Roff` is flat), charge injection, break-before-make timing.
    - **`sequencing` role** (already §20). "The switch enables come up only
      after 3v3 is up" is a real requirement here; the pulldowns make it true
      structurally and nothing checks the dynamic ordering.
    - **No logic-state quantity** (related to `logic_net`, §44). "This pin is
      low at boot" has to be a `dc_voltage` claim, and "this pin is high-Z"
      cannot be spelled at all — it is a `driveOpen()` bench assumption rather
      than a netlist property. It also means `safe_default` only catches a line
      *pulled toward the rail*, not a genuinely floating one: `expandPinModels`
      grounds every unmodelled pin, so an undriven enable reads low regardless.
    - **`esd_clamp` role** (already §65). Four TVS parts on this board and
      nothing to say about any of them; the derating claims check the working
      voltage, not the clamp under a surge.
    - **`passive_filter` role** (already §57/§19). The ferrite-and-capacitor
      filter making `v3v3rf` can be swept for its impedance but not its
      response.

    Two convergence notes, not gaps but worth recording: a whole-system `.op`
    carrying the LT8640A switching code model *and* the 48 V PoE rectifier
    bridge does not converge (the system swaps an ideal source in for the buck
    via `buildIdealBuck`); and the switching model's steady-state `.tran`
    collapses ("timestep too small") when its input is fed through the OR-ing
    diodes rather than a stiff source, which is why the chunk bench declines
    ripple/PSRR/load-step and `lt8640a_buck` keeps them.

---

## If the order is up for grabs

**Cheapest real value:** §48 then §49. No circuit knowledge, no new analysis,
and margin-to-limit is information the tool computes and discards on every
passing claim today.

**Best leverage from one small change:** was §45, and it was spent — one
capability enum member and one analysis module, and it unblocked §63 and §65
and turned `divider_net`'s ratio and output resistance from asserted numbers
into measured ones. Of what is left, §61 (`bias_point`) is the closest
equivalent for its voltage claims: pure reads off the shared `.op`, no new
analysis and no new capability, for the thing a discrete stage is designed
around. Its `i_c` claim is not that cheap — it needs the `skPin` evaluator
§61 now describes — but the voltage half stands alone.

**Highest value overall:** was §27 with `current_path`, and it was spent — it
closed the oldest open finding, made the registered-and-unchecked `isat` and
`current_rating` mean something, and left §64 needing only a product of two
measurements. Of what is left, §57 (`passive_filter`) is the biggest single
jump in what the library can be pointed at.

**The one that quietly gates everything else:** §51, because §46 and §55 are
both impractical without it — and §53 was its companion here until it shipped
(`arity: 2 .. 2`, `skClass` subjects, `roleRef`, and `channel_match` on
`designs/riaa_preamp.nim`), which unblocked §59 and closed §60.
