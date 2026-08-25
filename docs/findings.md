# Open findings

What checking real designs against this library turned up that is **still
open**. Everything already fixed — §1–§22 and §24–§41, each with what it was
and what the fix was — lives in `RESOLVED_FINDINGS.md`, and the designs
themselves are described there. The numbering is shared and continuous across
the two files, so a `§n` cross-reference means the same thing in either.

---

## 23. Every `.tran` quantity needs a bound driving part — PARTLY FIXED

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
operating point, and at the time this was written `run` refused more than one
card, which `.ic` was thought to need. (That diagnosis was wrong and is
corrected below.)

This also blocks the LT8640A's soft-start claim, which is measured (**4.086 ms**
10–90%, against the 4.08 ms the datasheet's 1.9 µA into 10 nF predicts) but
unclaimable: `analyzeStartup` replaces the regulator with its own ramp, and
honouring a `simReplace`d one instead needs four changes — `sr` read through
`findComponent`, the `build` path supported, the current probe not assuming a
`"+"` pin, and `uic` on the `.tran` so the part's own soft start is what runs.

**Half of this is now done** and is recorded as §41: `analysis/transient.nim`
and the `settled_rail` role exist, claim `settled_v` and `ripple_pp`, and
simulate the design as authored. That is what the LT8640A's ripple claim runs
through. What is left is the half the shape above says is hard:

* **`charge_pump`** could state a `settled_rail` claim today — the ripple and
  the settled voltage are exactly what it wants — and has not been converted.
  Doing so is the smallest remaining piece.
* **`wien_osc`** cannot yet state its claims, but **the mechanism it was
  waiting on now exists**, and the diagnosis recorded here was wrong. This
  said `run` had to accept more than one card. It did not: ngspice's default
  `write` keeps only the last *analysis*'s plot and a `SimResult` holds one
  plot, so that limit is real -- but `.ic` is not an analysis. It configures
  the analysis that follows and produces no plot, and the old guard counted
  cards rather than analyses, so one analysis plus one setup line was refused
  as "two cards". `spice/ngspice.run` now takes `run(nl, analysis, setup =
  @[...])`, refuses a known analysis card in the `setup` slot, and
  `analysis/transient.TransientSpec.initialConditions` emits the `.ic` and
  forces `uic`. Verified end to end on an LC tank, which sits at 0 V forever
  from its own operating point and rings at 5000 Hz measured (5033 Hz ideal)
  when kicked -- `tests/test_spice_ngspice.nim`.

  What is left for `wien_osc` is the measurement layer, not the simulator:
  `osc_freq`/`swing_pp`/`osc_thd_pct` need extracting from the settled window
  (`analysis/measure` already has `thd` and the zero-crossing arithmetic is
  ordinary), and the `oscillator` role needs writing. Names must be new: see
  §24. The one judgement to make is which node to kick and by how much, which
  is a condition on the claim in the sense §23 already describes for
  `tSettle` -- it says what was run, and the answer is a function of it.

  Note the honest cost of `uic`, which the role will have to state: it skips
  the operating-point solve, so every node not named in the `.ic` starts at
  zero rather than at its bias. `analyzeTransient` reports that as an
  assumption on every run that uses it.

---

## What is left, in order

§1–§22 and §24–§41 are done and recorded in `RESOLVED_FINDINGS.md`.
What is left:

1. **The rest of §23 — a transient that does not start from an operating
   point.** `analyzeTransient` and `settled_rail` shipped as §41 and cover the
   settling-and-ripple half. **The `.ic` half now exists too** —
   `run(nl, analysis, setup = @[...])` and `TransientSpec.initialConditions`,
   verified on an LC tank — so what `wien_osc` still needs is the *measurement*
   layer (`osc_freq`/`swing_pp`/`osc_thd_pct`) and an `oscillator` role, not a
   simulator change. `charge_pump` needs converting to the `settled_rail` role
   that now exists. `lt8640a_buck` still needs the `analyzeStartup` change to
   claim its soft start.
2. **`current_rating` / `isat` have no consumer** (§27). An inductor's peak
   current needs a `.tran` and a probe; it is the check a converter most wants.
   This is now much closer than it was: the LT8640A's switching model puts a
   real 0.94 A triangle on L1, so the number exists in the simulation and only
   the probe and the claim are missing.
3. **Capacitor tempco is not modelled** (§28). Half the argument for a Class 1
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
4. **A phase margin for the LT8640A.** §40 delivered the switching model and
   the ripple claim with it, and deliberately stopped short of stability: the
   compensation in that model is chosen for a sensible loop rather than fitted
   to the part's, which ADI does not publish. Measuring a margin through it
   would be a claim about `gmc` and `rzc`. What would make it real is either
   the internal network or a bench correlation, and neither is a code change.
5. **Slew rate and output current limit.** The macromodel now saturates at its
   rails, so headroom is measurable; what it still cannot do is run out of
   *speed* or *current*. Both are ordinary macromodel additions.
