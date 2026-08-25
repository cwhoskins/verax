# Open findings

What checking real designs against this library turned up that is **still
open**. Everything already fixed — §1–§42, each with what it was and what the
fix was — lives in `RESOLVED_FINDINGS.md`, and the designs themselves are
described there. The numbering is shared and continuous across the two files,
so a `§n` cross-reference means the same thing in either.

§23 was the last structural gap and is closed: `analyzeOscillation` and the
`oscillator` role reach a circuit whose intent is instability, `charge_pump`
and `wien_osc` state their central claims, and `analyzeStartup` honours a
regulator's own model so the LT8640A can claim its soft start. What is below
is what is left.

---

## What is left, in order

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
   separate step, and that key stays the override when it lands.

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

5. **A start-up transient is not sampled the way a settled one is.**
   `analyzeStartup` derives its print step from the run length
   (`tStop / 2000`), where §23 established that the derived step is *also*
   ngspice's ceiling on its own timestep. That is defensible for a rise time,
   which is a slow measurement, and it is not obviously defensible for the
   `overshoot_pct` of a rail ringing on an LC — the statistic undersampling
   shortens is exactly a peak. `analyzeTransient` sizes from the *window*
   instead and `analyzeOscillation` takes ten times that density; nobody has
   checked what the third one costs.
