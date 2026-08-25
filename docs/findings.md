# Open findings

What checking real designs against this library turned up that is **still
open**. Everything already fixed — §1–§22 and §25–§38, each with what it was
and what the fix was — lives in `RESOLVED_FINDINGS.md`, and the designs
themselves are described there. The numbering is shared and continuous across
the two files, so a `§n` cross-reference means the same thing in either.

---

## 23. Every `.tran` quantity needs a bound driving part — NOT FIXED

Two designs reached this from opposite directions and neither can make its
central claim.

`designs/charge_pump.nim` settles at **9.518 V with 5.1 mV of ripple**, measured.
`dc_voltage` is backed by a `.op`, and a `.op` takes a PULSE source at its DC
value, so nothing pumps and the tool reports **4.64 V** — exactly 5 − 2×0.18, a
correct answer to a question nobody asked, delivered as a FAIL against a real
number. A designer who trusts the machinery widens the band and ships a rail 51%
low.

`designs/wien_osc.nim` oscillates at **1584 Hz, ±1.19 V, 4.35% THD** (against
1591.5 Hz ideal — the 0.46% is the finite-GBW amplifier loading the bridge).
None of those three numbers is expressible.

The gap is structural: `regulator` wants a regulator component to stand up as a
soft-start ramp, and `large_signal` wants an op-amp and an input to drive.
Neither circuit has either, so nothing can ask *"run this and tell me what this
node settles to"*.

The shape it wants: an `analyzeTransient(nl, measureNet, spec)` that simulates
the design as authored — **no isolation**, following `runDcVoltage`'s precedent,
which avoids the "measures its own assumption" trap that terminating the
measured rail with an ideal source would create — plus two roles splitting the
two questions the way `opamp_stage`/`gain_stage` split theirs: `settled_rail`
claiming `settled_v`/`ripple_pp`, and `oscillator` claiming
`osc_freq`/`swing_pp`/`osc_thd_pct`. Names must be new: see §24. The open
question is start-up initial conditions — an oscillator does not start from an
operating point, and `run` currently refuses more than one card, which `.ic`
would need.

This also blocks the LT8640A's soft-start claim, which is measured (**4.086 ms**
10–90%, against the 4.08 ms the datasheet's 1.9 µA into 10 nF predicts) but
unclaimable: `analyzeStartup` replaces the regulator with its own ramp, and
honouring a `simReplace`d one instead needs four changes — `sr` read through
`findComponent`, the `build` path supported, the current probe not assuming a
`"+"` pin, and `uic` on the `.tran` so the part's own soft start is what runs.

## 24. Two evaluators producing one quantity silently overwrite — NOT FIXED

`registerEvaluator` maintains `quantityIndex[q] = it.name`, a flat map. A second
evaluator declaring an existing quantity replaces the first with no diagnostic,
and every claim on that quantity silently changes which analysis answers it.
Nothing does this today, which is why it has not bitten — but §23 cannot be
implemented without knowing it, and the registry is a documented extension
point, so a third-party evaluator can trigger it. It should raise.

---

## What is left, in order

§1–§22 and §25–§38 are done and recorded in `RESOLVED_FINDINGS.md`.
What is left:

1. **§23 — a `.tran` measurement that binds no driving part.** Two designs need
   it and a third (`lt8640a_buck`) needs the related `analyzeStartup` change.
   The shape is written out in §23; do not re-derive it.
2. **§24 — `registerEvaluator` should reject a duplicate quantity.** Small, and
   §23 introduces the first realistic chance of hitting it.
3. **`current_rating` / `isat` have no consumer** (§27). An inductor's peak
   current needs a `.tran` and a probe; it is the check a converter most wants.
4. **Capacitor tempco is not modelled** (§28). Half the argument for a Class 1
   timing capacitor is temperature drift, and nothing here represents it. The
   inputs such a model needs now exist and are the *only* part that does:
   `netlist/environment` carries a board's ambient range (`environment:`, with
   `t_ambient_min`/`t_ambient_max`) and a part's rise above it (`delta_t`,
   defaulting to 0), and `partTemperatureRange(c, env)` joins them. What is
   missing is the curve itself — capacitance against temperature per
   dielectric, alongside the DC-bias derating §26 added — plus the same
   question for an electrolytic's ESR at the cold end. A `delta_t` is authored
   today; deriving one from a dissipation and a thermal resistance is a
   separate step, and that key stays the override when it lands.
5. **The LT8640A switching model.** The averaged one is honest about what it
   cannot show — ripple, and anything to do with the internal compensation. A
   switching counterpart is what makes the 10 mV output-ripple figure and a
   phase margin measurable.
6. **Slew rate and output current limit.** The macromodel now saturates at its
   rails, so headroom is measurable; what it still cannot do is run out of
   *speed* or *current*. Both are ordinary macromodel additions.
