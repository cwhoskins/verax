## Built-in roles for supplies, rails and the currents through them.
##
## `power_rail` is the single-subject rail claim `spice/isolate` reads.
## `regulator`/`linear_regulator`/`switching_regulator` are **one role
## specialised twice**: the specialisations call `regulatorExpand` whole and
## add topology-specific claims. `settled_rail`, `current_path`,
## `source_sweep` and `load_sweep` are the characterisation primitives.

import std/tables
import ../../netlist/types
import ../../netlist/annotations
import ../../units
import ./core

# --- built-in: power_rail --------------------------------------------------

proc powerRailApply*(inst: RoleInstance, nl: Netlist) =
  ## Writes the nominal voltage where consumers already look for it, so
  ## `spice/isolate` needs no knowledge of roles.
  let rail = inst.subject("rail")
  if not nl.nets.hasKey(rail.name):
    raise newException(NetlistError, "no such net: " & rail.name)
  if inst.hasParam("voltage"):
    setRailVoltage(nl.nets[rail.name],
                   Volts(paramFloat(inst, "voltage", 0.0)), annAuthored)

proc powerRailExpand*(inst: RoleInstance): seq[Assertion] =
  let rail = inst.subject("rail")
  let v = paramFloat(inst, "voltage", 0.0)
  let band = paramFloat(inst, "band", 0.05)
  result.add Assertion(
    id: assertionId(inst, "voltage"),
    subjects: @[rail],
    quantity: "dc_voltage",
    expect: nominal(v, fracTol = band),
    unit: "V",
    severity: sevError,
    rationale: "the rail must actually sit at its nominal voltage; every " &
               "analysis that terminates this rail with an ideal source " &
               "assumes it does",
    origin: inst.name)

  # Opt-in: a derating ceiling is a project rule. Without `voltage_rating`
  # on the parts the evaluator reports "not checked", not a pass.
  if inst.hasParam("maxDerating"):
    result.add Assertion(
      id: assertionId(inst, "derating"),
      subjects: @[rail],
      quantity: "worst_voltage_derating",
      expect: atMost(paramFloat(inst, "maxDerating", 0.8)),
      unit: "",
      severity: sevWarning,
      rationale: "every part on this rail must be working inside its " &
                 "voltage rating with margin; a tantalum over its rating " &
                 "fails short and takes the rail with it",
      origin: inst.name)

  # Only when a target is stated: it's a design decision, and a default
  # would manufacture a claim.
  if inst.hasParam("targetZ"):
    var a = Assertion(
      id: assertionId(inst, "impedance"),
      subjects: @[rail],
      quantity: "z_max_in_band",
      expect: atMost(paramFloat(inst, "targetZ", 0.0)),
      unit: "ohm",
      severity: sevWarning,
      rationale: "the decoupling network must hold the rail below its " &
                 "target impedance across the band where the capacitors, " &
                 "rather than the regulator or the planes, are what control it",
      origin: inst.name)
    # Bounded band: below the regulator's crossover the regulator holds the
    # rail (cut away); above ~100 MHz plane/package parasitics dominate.
    a.condition["f_from"] = $paramFloat(inst, "targetFrom", 1.0e5)
    a.condition["f_to"] = $paramFloat(inst, "targetTo", 1.0e8)
    result.add a

# --- the regulator family ------------------------------------------------
#
# One definition, specialised twice: a claim added to `regulatorExpand`
# reaches all three roles. Parts and params are shared `let`s because
# `Design.validate` checks stated params against `RoleDef.params`; a
# specialisation that forgot one would reject a valid design.

let regulatorParts* = @[
  RolePart(name: "regulator", kind: skComponent,
           doc: "the part driving the rail"),
  RolePart(name: "output", kind: skNet, doc: "the net it drives"),
  RolePart(name: "measure", kind: skNet, optional: true,
           doc: "where the rail is judged, when that is past a filter"),
  RolePart(name: "sense", kind: skComponent, optional: true,
           doc: "the part carrying the regulator's output current -- the " &
                "inductor after a converter, the pass element inside a " &
                "linear's loop model. Named because a part that reaches the " &
                "deck as a code model or a subcircuit has no terminal " &
                "current of its own to probe"),
]

let regulatorParams* = @[

  AnnDef(key: "voltage", kind: akFloat, unit: "V", scopes: {asNet},
         doc: "nominal regulated output"),
  AnnDef(key: "band", kind: akFloat, scopes: {asNet},
         doc: "acceptance band as a fraction of nominal; default 5%"),
  AnnDef(key: "maxOvershoot", kind: akFloat, unit: "%", scopes: {asNet},
         doc: "tolerated overshoot in percent; default 5"),
  AnnDef(key: "maxInrush", kind: akFloat, unit: "A", scopes: {asNet},
         doc: "peak charging current the supply must deliver; omitted " &
              "means unclaimed"),
  AnnDef(key: "maxRiseTime", kind: akFloat, unit: "s", scopes: {asNet},
         doc: "10-90% rise time of the rail; omitted means unclaimed"),
  AnnDef(key: "maxSettleTime", kind: akFloat, unit: "s", scopes: {asNet},
         doc: "time until the rail stays inside its band; omitted " &
              "means unclaimed"),
  AnnDef(key: "tRun", kind: akFloat, unit: "s", scopes: {asNet},
         doc: "how long to run; omitted derives it from the assumed " &
              "soft-start ramp, which is right for a regulator this " &
              "analysis stands up itself and says nothing about one " &
              "that brought its own model"),
  # --- a load step ---
  AnnDef(key: "iFrom", kind: akFloat, unit: "A", scopes: {asNet},
         doc: "load current before the step; default 0"),
  AnnDef(key: "iTo", kind: akFloat, unit: "A", scopes: {asNet},
         doc: "load current after it. Stating this is what asks for a load " &
              "step at all -- there is no default magnitude, because how " &
              "much current a part takes is a fact about the design"),
  AnnDef(key: "tEdge", kind: akFloat, unit: "s", scopes: {asNet},
         doc: "rise and fall time of the step; default 1 us. Not cosmetic: " &
              "a load's slew decides whether the droop is set by the output " &
              "capacitor's ESR or by the loop's bandwidth"),
  AnnDef(key: "tStepAt", kind: akFloat, unit: "s", scopes: {asNet},
         doc: "when the step lands. Everything before it is simulated and " &
              "discarded, so this is how long the rail is given to arrive"),
  AnnDef(key: "tHold", kind: akFloat, unit: "s", scopes: {asNet},
         doc: "how long the load stays on. 0 holds to the end of the run, " &
              "which means there is no release edge and no overshoot to " &
              "measure"),
  AnnDef(key: "tRecover", kind: akFloat, unit: "s", scopes: {asNet},
         doc: "how long to watch after each edge; default ten times tEdge"),
  AnnDef(key: "stepPoints", kind: akFloat, scopes: {asNet},
         doc: "samples across the recovery window; default 2000. The " &
              "derived print step is also ngspice's ceiling on its own " &
              "timestep, so this sets how well the edge is solved"),
  AnnDef(key: "maxDroop", kind: akFloat, unit: "V", scopes: {asNet},
         doc: "how far the rail may fall when the load arrives; omitted " &
              "means unclaimed"),
  AnnDef(key: "maxDroopPct", kind: akFloat, unit: "%", scopes: {asNet},
         doc: "the same, as a fraction of the rail"),
  AnnDef(key: "minStepV", kind: akFloat, unit: "V", scopes: {asNet},
         doc: "lowest the rail may ever be seen at during the step, as an " &
              "absolute -- an undervoltage lockout does not care what the " &
              "rail was before"),
  AnnDef(key: "maxStepOvershoot", kind: akFloat, unit: "V", scopes: {asNet},
         doc: "how far it may rise when the load is released again"),
  AnnDef(key: "maxRecover", kind: akFloat, unit: "s", scopes: {asNet},
         doc: "how long it may take to come back inside band and stay there"),
  AnnDef(key: "stepBand", kind: akFloat, scopes: {asNet},
         doc: "the band `maxRecover` is measured against, as a fraction of " &
              "where the rail settles under the new load; omitted takes " &
              "1%. State it whenever the droop is smaller than that, or " &
              "the rail never leaves the band and the recovery reads zero"),
  # --- supply rejection ---
  AnnDef(key: "minPsrrDb", kind: akFloat, unit: "dB", scopes: {asNet},
         doc: "least acceptable rejection of input ripple, measured with " &
              "one real tone through a `.tran`. Stating this is what asks " &
              "for the measurement; it needs a `source` to ripple and an " &
              "`input` net to quote against, which the specialised roles " &
              "bind. A tone reaches a switching converter and an XSPICE " &
              "code model, neither of which an `.ac` sweep can see"),
  AnnDef(key: "minPsrrBandDb", kind: akFloat, unit: "dB", scopes: {asNet},
         doc: "least acceptable rejection anywhere in a *swept* band, via " &
              "`.ac`. The cheaper way to ask and the one that finds the " &
              "worst point rather than answering at one frequency -- but an " &
              "`.ac` sees nothing through an XSPICE code model, so a " &
              "switching converter wants `minPsrrDb` instead. Stating both " &
              "is legal and is two runs"),
  AnnDef(key: "psrrAtF", kind: akFloat, unit: "Hz", scopes: {asNet},
         doc: "the frequency. For `minPsrrDb` it is the tone; for " &
              "`minPsrrBandDb` it moves the claim from the band's worst " &
              "point onto that one point. " &
              "Default 120 Hz, which is where a datasheet quotes ripple " &
              "rejection because it is twice the mains frequency"),
  AnnDef(key: "psrrRippleV", kind: akFloat, unit: "V", scopes: {asNet},
         doc: "tone amplitude, zero to peak; default 100 mV. Part of the " &
              "answer for 'tone' and irrelevant for 'ac': a `.tran` is not " &
              "linear, so a tone big enough to move a duty cycle gets a " &
              "different figure"),
  AnnDef(key: "psrrFrom", kind: akFloat, unit: "Hz", scopes: {asNet},
         doc: "low end of the swept band, for 'ac'; default 10 Hz"),
  AnnDef(key: "psrrTo", kind: akFloat, unit: "Hz", scopes: {asNet},
         doc: "high end of it; default 10 MHz"),
  AnnDef(key: "psrrPeriods", kind: akFloat, scopes: {asNet},
         doc: "whole periods of the tone in the window; default 8"),
  AnnDef(key: "psrrPoints", kind: akFloat, scopes: {asNet},
         doc: "samples per period; default 200"),
  # --- what it delivers ---
  AnnDef(key: "tSettle", kind: akFloat, unit: "s", scopes: {asNet},
         doc: "when a steady-state window opens, for the current and " &
              "ripple claims. Distinct from tRun, which is how long the " &
              "start-up run lasts"),
  AnnDef(key: "tWindow", kind: akFloat, unit: "s", scopes: {asNet},
         doc: "how long that window is"),
  AnnDef(key: "maxOutputCurrent", kind: akFloat, unit: "A", scopes: {asNet},
         doc: "peak the regulator may deliver, measured through `sense`"),
  AnnDef(key: "maxOutputAvg", kind: akFloat, unit: "A", scopes: {asNet},
         doc: "average it may deliver continuously"),
  AnnDef(key: "maxOutputDerating", kind: akFloat, scopes: {asNet},
         doc: "fraction of the regulator's *own* stated `current_rating` " &
              "the RMS through `sense` may reach. States no current: the " &
              "rating lives on the part somebody chose"),
]

let linearParams* = @[
  AnnDef(key: "vinFrom", kind: akFloat, unit: "V", scopes: {asNet},
         doc: "low end of the input sweep, for dropout and line regulation"),
  AnnDef(key: "vinTo", kind: akFloat, unit: "V", scopes: {asNet},
         doc: "high end of it"),
  AnnDef(key: "vinStep", kind: akFloat, unit: "V", scopes: {asNet},
         doc: "sweep step; omitted takes fifty-one points across the range"),
  AnnDef(key: "maxDropout", kind: akFloat, unit: "V", scopes: {asNet},
         doc: "input-to-output differential at the lowest input still " &
              "holding regulation; omitted means unclaimed"),
  AnnDef(key: "maxLineReg", kind: akFloat, unit: "%", scopes: {asNet},
         doc: "how far the output may move across the whole input sweep"),
  AnnDef(key: "iLoadFrom", kind: akFloat, unit: "A", scopes: {asNet},
         doc: "light-load end of the load sweep, for load regulation"),
  AnnDef(key: "iLoadTo", kind: akFloat, unit: "A", scopes: {asNet},
         doc: "heavy-load end of it"),
  AnnDef(key: "maxLoadReg", kind: akFloat, unit: "%", scopes: {asNet},
         doc: "how far the output may move across that load range"),
  AnnDef(key: "maxZOut", kind: akFloat, unit: "ohm", scopes: {asNet},
         doc: "DC output resistance, which is that movement per amp"),
]

let switchingParams* = @[
  AnnDef(key: "maxRipple", kind: akFloat, unit: "V", scopes: {asNet},
         doc: "peak-to-peak output ripple over the settled window; omitted " &
              "means unclaimed"),
  AnnDef(key: "fSw", kind: akFloat, unit: "Hz", scopes: {asNet},
         doc: "switching frequency, read off the bound `switch` node. What " &
              "sets it is a resistor or an internal oscillator, and a " &
              "converter running at the wrong rate has the wrong ripple, " &
              "the wrong inductor current and the wrong EMI signature"),
  AnnDef(key: "fSwBand", kind: akFloat, scopes: {asNet},
         doc: "acceptance band on it, as a fraction; default 10%"),
  AnnDef(key: "maxSwitchCurrent", kind: akFloat, unit: "A", scopes: {asNet},
         doc: "peak through the bound `inductor`, which in a synchronous " &
              "buck's on-time *is* the top switch's current"),
  AnnDef(key: "maxIsatDerating", kind: akFloat, scopes: {asNet},
         doc: "fraction of the inductor's own stated `isat` that peak may " &
              "reach; past the knee the inductance collapses and the ripple " &
              "measured here stops describing the part"),
  AnnDef(key: "iRipple", kind: akFloat, unit: "A", scopes: {asNet},
         doc: "the peak-to-peak the design equations fix -- for a converter " &
              "dI = Vout(1-D)/(L*f). What catches a wrong inductor value by " &
              "something other than the rail looking slightly worse"),
  AnnDef(key: "iRippleBand", kind: akFloat, scopes: {asNet},
         doc: "acceptance band on that, as a fraction; default 15%"),
]

# The three claim groups beyond start-up, separate so the specialisations
# share them.

proc loadStepClaims(inst: RoleInstance, judged: Subject): seq[Assertion] =
  ## What the rail does when the load jumps -- the time-domain question
  ## `power_rail.targetZ` is a proxy for.
  ##
  ## Each claim is gated on its own limit, never on the step (which is setup,
  ## in the conditions; the evaluator refuses a claim with no step). Gating
  ## on `iTo` would also hide the group from `claimingRoles`.
  let iFrom = paramFloat(inst, "iFrom", 0.0)
  let iTo = paramFloat(inst, "iTo", 0.0)

  template stepped(sfx, qty: string, e: Expectation, un, why: string;
                   sev = sevError) =
    var claim = Assertion(
      id: assertionId(inst, sfx),
      subjects: @[judged],
      quantity: qty,
      expect: e,
      unit: un,
      severity: sev,
      rationale: why,
      origin: inst.name)
    # Everything that changes the run joins the setup key; two step
    # magnitudes are two runs.
    claim.condition["step_from"] = $iFrom
    claim.condition["step_to"] = $iTo
    claim.condition["step_edge"] = $paramFloat(inst, "tEdge", 0.0)
    claim.condition["step_at"] = $paramFloat(inst, "tStepAt", 0.0)
    claim.condition["step_hold"] = $paramFloat(inst, "tHold", 0.0)
    claim.condition["step_recover"] = $paramFloat(inst, "tRecover", 0.0)
    claim.condition["step_points"] = $paramFloat(inst, "stepPoints", 0.0)
    claim.condition["step_band"] = $paramFloat(inst, "stepBand", 0.0)
    result.add claim

  if hasParam(inst, "maxDroop"):
    stepped("droop", "step_droop_v",
            atMost(paramFloat(inst, "maxDroop", 0.0)), "V",
            "how far the rail falls below where it was sitting when the " &
            "load arrives. Everything downstream has an undervoltage " &
            "threshold, and a rail that dips under it resets a part that " &
            "was working a microsecond earlier -- which looks like a " &
            "firmware fault and is not one")
  if hasParam(inst, "maxDroopPct"):
    stepped("droop_pct", "step_droop_pct",
            atMost(paramFloat(inst, "maxDroopPct", 0.0)), "%",
            "the same excursion as a fraction of the rail, which is how a " &
            "supply tolerance is written down and what a part's operating " &
            "range is quoted against")
  if hasParam(inst, "minStepV"):
    stepped("step_floor", "step_v_min",
            atLeast(paramFloat(inst, "minStepV", 0.0)), "V",
            "the lowest the rail is ever seen at during the step, stated " &
            "as an absolute rather than as an excursion: an undervoltage " &
            "lockout does not care what the rail was before")
  if hasParam(inst, "maxStepOvershoot"):
    stepped("step_overshoot", "step_overshoot_v",
            atMost(paramFloat(inst, "maxStepOvershoot", 0.0)), "V",
            "how far the rail rises above where it was when the load is " &
            "released again -- the half of a load step that is easy to " &
            "forget and that stresses the absolute-maximum rating of " &
            "everything on the rail rather than its undervoltage threshold",
            sevWarning)
  if hasParam(inst, "maxRecover"):
    stepped("recover", "step_recover_s",
            atMost(paramFloat(inst, "maxRecover", 0.0)), "s",
            "how long the rail takes to come back inside band and stay " &
            "there, measured against where it settles *under the new load* " &
            "rather than where it started -- load regulation moves that " &
            "point, and counting the shift as a failure to recover would " &
            "report a correct regulator as an unstable one",
            sevWarning)

proc rejectionClaims(inst: RoleInstance, judged: Subject): seq[Assertion] =
  ## How much of the supply's ripple reaches the rail. **The method is chosen
  ## by which limit is stated, not by a mode string** (a string param needs
  ## its own validation and is invisible to `verify.claimingRoles`):
  ##
  ##   * `minPsrrDb` runs **one tone** through a `.tran`. Reaches everything,
  ##     including switching converters and XSPICE models without `AC_GAIN`
  ##     (which contribute nothing to an `.ac` matrix).
  ##   * `minPsrrBandDb` **sweeps a band** with `.ac`: cheaper, finds the
  ##     worst point, right for anything that linearises.
  ##
  ## Stating both is two runs.
  let atF = paramFloat(inst, "psrrAtF", 0.0)

  if hasParam(inst, "minPsrrDb"):
    var claim = Assertion(
      id: assertionId(inst, "psrr"),
      subjects: @[judged],
      quantity: "psrr_db",
      expect: atLeast(paramFloat(inst, "minPsrrDb", 0.0)),
      unit: "dB",
      severity: sevWarning,
      rationale: "ripple on the input has to be attenuated before it " &
                 "reaches anything that cares -- an ADC's reference, a " &
                 "PLL's supply, an amplifier's rail -- and a regulator that " &
                 "holds its DC value perfectly may pass a hundred " &
                 "millivolts of mains hum straight through. Measured with " &
                 "one real sinusoid rather than a small-signal sweep, so " &
                 "the amplitude is part of the question: a `.tran` is not " &
                 "linear, and a ripple big enough to move a duty cycle gets " &
                 "a different answer",
      origin: inst.name)
    claim.condition["ripple_f"] = $atF
    claim.condition["ripple_v"] = $paramFloat(inst, "psrrRippleV", 0.0)
    claim.condition["t_settle"] = $paramFloat(inst, "tSettle", 0.0)
    claim.condition["ripple_periods"] = $paramFloat(inst, "psrrPeriods", 0.0)
    claim.condition["ripple_points"] = $paramFloat(inst, "psrrPoints", 0.0)
    result.add claim

  if hasParam(inst, "minPsrrBandDb"):
    # `psrrAtF` redirects this claim to one point rather than adding a
    # second (the `gain_stage.atF` pattern).
    var claim = Assertion(
      id: assertionId(inst, "psrr_swept"),
      subjects: @[judged],
      quantity: (if atF > 0.0: "psrr_at_f" else: "psrr_min_db"),
      expect: atLeast(paramFloat(inst, "minPsrrBandDb", 0.0)),
      unit: "dB",
      severity: sevWarning,
      rationale: "the same rejection, swept: a regulator's is not flat, and " &
                 "its worst point sits where the loop gain has rolled off " &
                 "and the output capacitor has not yet taken over. Quoting " &
                 "either end of the band would miss it -- measured on an " &
                 "LM317 at 62.9 dB at 120 Hz and 7.8 dB at 63 kHz, on the " &
                 "same rail",
      origin: inst.name)
    claim.condition["f_from"] = $paramFloat(inst, "psrrFrom", 0.0)
    claim.condition["f_to"] = $paramFloat(inst, "psrrTo", 0.0)
    if atF > 0.0: claim.condition["at_f"] = $atF
    result.add claim

proc outputCurrentClaims(inst: RoleInstance): seq[Assertion] =
  ## What the regulator delivers against its rating. **The subject is the
  ## `sense` part**: a regulator modelled as an XSPICE code model or
  ## subcircuit has no terminal current, so the design names what carries
  ## it (a buck's inductor, a linear's pass element). These are
  ## `current_path` quantities, so they share any existing `.tran`.
  if not inst.hasPart("sense"): return
  let sense = inst.subject("sense")

  template carried(sfx, qty: string, e: Expectation, un, why: string;
                   sev = sevError) =
    var claim = Assertion(
      id: assertionId(inst, sfx),
      subjects: @[sense],
      quantity: qty,
      expect: e,
      unit: un,
      severity: sev,
      rationale: why,
      origin: inst.name)
    claim.condition["t_settle"] = $paramFloat(inst, "tSettle", 0.0)
    claim.condition["t_window"] = $paramFloat(inst, "tWindow", 0.0)
    result.add claim

  if hasParam(inst, "maxOutputCurrent"):
    carried("i_out_peak", "i_peak",
            atMost(paramFloat(inst, "maxOutputCurrent", 0.0)), "A",
            "the peak the regulator has to deliver, which is where a " &
            "converter's cycle-by-cycle current limit trips and where its " &
            "inductor saturates -- both of them properties of the top of " &
            "the waveform rather than of its average")
  if hasParam(inst, "maxOutputAvg"):
    carried("i_out_avg", "i_avg",
            atMost(paramFloat(inst, "maxOutputAvg", 0.0)), "A",
            "the DC the part delivers continuously, which is what its " &
            "thermal rating was specified at")
  if hasParam(inst, "maxOutputDerating"):
    carried("i_out_derating", "i_out_derating",
            atMost(paramFloat(inst, "maxOutputDerating", 0.0)), "",
            "how much of the *regulator's own* stated `current_rating` the " &
            "RMS through the sense part uses up. It names no current: the " &
            "rating is a property of the part somebody chose, so a " &
            "substitution changes the limit in one place instead of two -- " &
            "and a regulator that states none reports this as unchecked " &
            "rather than as headroom nobody verified",
            sevWarning)

proc regulatorExpand*(inst: RoleInstance): seq[Assertion] =
  ## The rail's behaviour on the way up (`power_rail` claims only where it
  ## settles). The subject is the net the rail is *judged* at, which may be
  ## past a ferrite or LC from the regulator; `regulator`/`output` parts
  ## tell the evaluator what to simulate.
  ##
  ## `tRun` is a condition, not a limit. State it when the regulator brings
  ## its own model: the derived run length fits only the assumed ramp.
  let judged = if inst.hasPart("measure"): inst.subject("measure")
               else: inst.subject("output")
  let target = paramFloat(inst, "voltage", 0.0)
  let band = paramFloat(inst, "band", 0.05)
  let overshoot = paramFloat(inst, "maxOvershoot", 5.0)
  let tRun = paramFloat(inst, "tRun", 0.0)

  if target > 0.0:
    result.add Assertion(
      id: assertionId(inst, "final_v"),
      subjects: @[judged],
      quantity: "final_v",
      expect: nominal(target, fracTol = band),
      unit: "V",
      severity: sevError,
      rationale: "the rail must actually reach its nominal voltage once " &
                 "start-up has settled",
      origin: inst.name)

  result.add Assertion(
    id: assertionId(inst, "overshoot"),
    subjects: @[judged],
    quantity: "overshoot_pct",
    expect: atMost(overshoot),
    unit: "%",
    severity: sevWarning,
    rationale: "a rail that overshoots on the way up can exceed the " &
               "absolute-maximum rating of everything downstream of it, " &
               "even though it settles correctly afterwards",
    origin: inst.name)

  # Further opt-in start-up claims (inrush, reset timing): system specs, not
  # rail properties. Here because `spice.startup` answers them in the same
  # run.
  if hasParam(inst, "maxInrush"):
    result.add Assertion(
      id: assertionId(inst, "inrush"),
      subjects: @[judged],
      quantity: "inrush_peak",
      expect: atMost(paramFloat(inst, "maxInrush", 0.0)),
      unit: "A",
      severity: sevError,
      rationale: "the current the output capacitors demand while charging, " &
                 "which the upstream supply has to deliver before anything " &
                 "downstream has negotiated a budget",
      origin: inst.name)

  if hasParam(inst, "maxRiseTime"):
    result.add Assertion(
      id: assertionId(inst, "rise_time"),
      subjects: @[judged],
      quantity: "rise_time_10_90",
      expect: atMost(paramFloat(inst, "maxRiseTime", 0.0)),
      unit: "s",
      severity: sevError,
      rationale: "a rail slower than the part's power-on reset release " &
                 "leaves it running below its minimum operating voltage",
      origin: inst.name)

  if hasParam(inst, "maxSettleTime"):
    result.add Assertion(
      id: assertionId(inst, "settle"),
      subjects: @[judged],
      quantity: "settle_time",
      expect: atMost(paramFloat(inst, "maxSettleTime", 0.0)),
      unit: "s",
      severity: sevWarning,
      rationale: "how long the rail rings before it stays inside band, " &
                 "which is the earliest anything downstream may be released " &
                 "from reset",
      origin: inst.name)

  # `t_run` stamped once at the end, over the start-up claims only (the
  # other groups are separate runs it says nothing about).
  for a in result.mitems:
    a.condition["t_run"] = $tRun

  result.add loadStepClaims(inst, judged)
  result.add rejectionClaims(inst, judged)
  result.add outputCurrentClaims(inst)

proc linearRegulatorExpand*(inst: RoleInstance): seq[Assertion] =
  ## `regulator` plus what only a part that drops the difference is asked:
  ## `dropout_v` and line/load regulation, all via `.dc` sweeps. The sweep
  ## range joins the setup key, since figures over different ranges aren't
  ## comparable.
  result = regulatorExpand(inst)

  let outNet = if inst.hasPart("measure"): inst.subject("measure")
               else: inst.subject("output")

  template swept(sfx, qty, kind: string, e: Expectation, un, why: string;
                 sev = sevError) =
    var claim = Assertion(
      id: assertionId(inst, sfx),
      subjects: @[outNet],
      quantity: qty,
      expect: e,
      unit: un,
      severity: sev,
      rationale: why,
      origin: inst.name)
    claim.condition["sweep"] = kind
    if kind == "source":
      claim.condition["sweep_from"] = $paramFloat(inst, "vinFrom", 0.0)
      claim.condition["sweep_to"] = $paramFloat(inst, "vinTo", 0.0)
      claim.condition["sweep_step"] = $paramFloat(inst, "vinStep", 0.0)
    else:
      claim.condition["sweep_from"] = $paramFloat(inst, "iLoadFrom", 0.0)
      claim.condition["sweep_to"] = $paramFloat(inst, "iLoadTo", 0.0)
    if hasParam(inst, "voltage"):
      claim.condition["v_nominal"] = $paramFloat(inst, "voltage", 0.0)
    result.add claim

  if hasParam(inst, "maxDropout"):
    swept("dropout", "dropout_v", "source",
          atMost(paramFloat(inst, "maxDropout", 0.0)), "V",
          "how little headroom the part still regulates on, measured from " &
          "its own input pin rather than from the supply -- the difference " &
          "is whatever the input wiring and any series protection drop, and " &
          "that is exactly the margin a 12 V rail out of a 15 V supply " &
          "passes on paper and loses on the bench")
  if hasParam(inst, "maxLineReg"):
    swept("line_reg", "line_reg_pct", "source",
          atMost(paramFloat(inst, "maxLineReg", 0.0)), "%",
          "how far the output moves across the whole input range, which is " &
          "a slope and not a bias: an operating point at nominal line says " &
          "nothing about it however precisely it solves")
  if hasParam(inst, "maxLoadReg"):
    swept("load_reg", "load_reg_pct", "load",
          atMost(paramFloat(inst, "maxLoadReg", 0.0)), "%",
          "how far it moves across the load range, measured with a sink " &
          "the analysis injects rather than a resistor -- a resistor's " &
          "current follows the rail, so sweeping one sweeps the load and " &
          "the drive together")
  if hasParam(inst, "maxZOut"):
    swept("z_out", "z_out_dc", "load",
          atMost(paramFloat(inst, "maxZOut", 0.0)), "ohm",
          "that same movement per amp, which is the half of the part's " &
          "output behaviour no node voltage witnesses",
          sevWarning)

proc switchingRegulatorExpand*(inst: RoleInstance): seq[Assertion] =
  ## `regulator` plus what only a switcher is asked: output ripple (inductor
  ## current across ESR), switching frequency (fixes ripple, inductor current
  ## and EMI; recorded nowhere else), and inductor peak current (the
  ## measurable proxy for the top switch's limit). Existing evaluators only.
  result = regulatorExpand(inst)

  let outNet = if inst.hasPart("measure"): inst.subject("measure")
               else: inst.subject("output")
  let tSettle = paramFloat(inst, "tSettle", 0.0)
  let tWindow = paramFloat(inst, "tWindow", 0.0)

  template windowed(sfx, qty: string, subj: Subject, e: Expectation,
                    un, why: string; sev = sevError) =
    var claim = Assertion(
      id: assertionId(inst, sfx),
      subjects: @[subj],
      quantity: qty,
      expect: e,
      unit: un,
      severity: sev,
      rationale: why,
      origin: inst.name)
    claim.condition["t_settle"] = $tSettle
    claim.condition["t_window"] = $tWindow
    result.add claim

  if hasParam(inst, "maxRipple"):
    windowed("ripple", "ripple_pp", outNet,
             atMost(paramFloat(inst, "maxRipple", 0.0)), "V",
             "what is left moving on the rail once it has arrived. A `.op` " &
             "cannot see it -- an operating point has no ripple in it, so a " &
             "converter's rail reads as its own average by construction and " &
             "would pass any ripple claim ever made about it",
             sevWarning)

  if hasParam(inst, "fSw") and inst.hasPart("switch"):
    windowed("fsw", "osc_freq", inst.subject("switch"),
             nominal(paramFloat(inst, "fSw", 0.0),
                     fracTol = paramFloat(inst, "fSwBand", 0.1)), "Hz",
             "the rate the part actually runs at, read off the switch node " &
             "rather than assumed. It is set by a timing resistor or an " &
             "internal oscillator and appears nowhere else in a netlist, " &
             "and everything else here -- the ripple, the inductor's " &
             "triangle, the EMI -- is a function of it")

  if inst.hasPart("inductor"):
    let coil = inst.subject("inductor")
    if hasParam(inst, "maxSwitchCurrent"):
      windowed("i_switch", "i_peak", coil,
               atMost(paramFloat(inst, "maxSwitchCurrent", 0.0)), "A",
               "the peak the inductor carries, which during the on-time is " &
               "the top switch's own current -- so it is where a " &
               "cycle-by-cycle current limit trips, and the measurable " &
               "proxy for a limit that lives inside the part rather than " &
               "on the board")
    if hasParam(inst, "maxIsatDerating"):
      windowed("isat_derating", "i_peak_derating", coil,
               atMost(paramFloat(inst, "maxIsatDerating", 0.0)), "",
               "how much of the inductor's *own* stated saturation current " &
               "that peak reaches. Past the knee the inductance collapses, " &
               "the triangle grows and every other number measured here " &
               "stops describing the part that is fitted",
               sevWarning)
    if hasParam(inst, "iRipple"):
      windowed("i_ripple", "i_pp", coil,
               nominal(paramFloat(inst, "iRipple", 0.0),
                       fracTol = paramFloat(inst, "iRippleBand", 0.15)), "A",
               "the peak-to-peak the design equations fix -- for a buck " &
               "dI = Vout(1-D)/(L*f). Claiming it is what catches a wrong " &
               "inductor value by something other than the rail looking " &
               "slightly worse than it should")

proc settledRailExpand*(inst: RoleInstance): seq[Assertion] =
  ## What a node does once it has stopped changing: where it sits, and what
  ## is still moving. Unlike `power_rail` (a `.op`, which has no ripple) and
  ## `regulator` (the way up, binds a driver), this binds nothing, so it
  ## reaches charge pumps, oscillator envelopes and cycle-by-cycle
  ## converters.
  ##
  ## `tSettle`/`tWindow` are conditions, not limits: two windows are two
  ## runs.
  let rail = inst.subject("rail")
  let tSettle = paramFloat(inst, "tSettle", 0.0)
  let tWindow = paramFloat(inst, "tWindow", 0.0)

  template settled(sfx, qty: string, e: Expectation, un, why: string;
                   sev = sevError) =
    var claim = Assertion(
      id: assertionId(inst, sfx),
      subjects: @[rail],
      quantity: qty,
      expect: e,
      unit: un,
      severity: sev,
      rationale: why,
      origin: inst.name)
    claim.condition["t_settle"] = $tSettle
    claim.condition["t_window"] = $tWindow
    result.add claim

  # Both claims opt-in; defaulting either would manufacture a claim.
  if hasParam(inst, "voltage"):
    settled("settled", "settled_v",
            nominal(paramFloat(inst, "voltage", 0.0),
                    fracTol = paramFloat(inst, "band", 0.05)), "V",
            "once it has settled, the rail has to sit where it was " &
            "specified to sit -- measured over a window rather than at an " &
            "operating point, so a rail that is still moving cannot pass by " &
            "being sampled at the right instant")
  if hasParam(inst, "maxRipple"):
    settled("ripple", "ripple_pp",
            atMost(paramFloat(inst, "maxRipple", 0.0)), "V",
            "what is left on the rail after it has settled is what every " &
            "load on it has to reject; a switching converter's ripple is " &
            "invisible to an operating point and to any averaged model of " &
            "the part", sevWarning)

proc currentPathExpand*(inst: RoleInstance): seq[Assertion] =
  ## The current **through a part** once settled -- the one built-in whose
  ## subject is a component (a net has no single current). Checks
  ## `current_rating` and `isat`.
  ##
  ## `tSettle`/`tWindow` are conditions, not limits.
  let part = inst.subject("part")
  let tSettle = paramFloat(inst, "tSettle", 0.0)
  let tWindow = paramFloat(inst, "tWindow", 0.0)

  template carried(sfx, qty: string, e: Expectation, un, why: string;
                   sev = sevError) =
    var claim = Assertion(
      id: assertionId(inst, sfx),
      subjects: @[part],
      quantity: qty,
      expect: e,
      unit: un,
      severity: sev,
      rationale: why,
      origin: inst.name)
    claim.condition["t_settle"] = $tSettle
    claim.condition["t_window"] = $tWindow
    result.add claim

  # Every claim opt-in; there's no default current budget for a part.
  if hasParam(inst, "isat"):
    carried("isat", "i_peak",
            atMost(paramFloat(inst, "isat", 0.0)), "A",
            "past saturation an inductor's inductance collapses, so every " &
            "figure that depends on it -- the ripple, the crossover, the " &
            "efficiency -- stops describing the part on the board. It is a " &
            "peak rather than an average because saturation happens at the " &
            "top of the triangle, not at its middle")
  if hasParam(inst, "iRmsMax"):
    carried("i_rms", "i_rms",
            atMost(paramFloat(inst, "iRmsMax", 0.0)), "A",
            "RMS is what heats the part, so this is the figure a continuous " &
            "rating and a temperature rise are both quoted against -- and " &
            "the one a peak-only claim misses on a waveform that spends most " &
            "of its time near zero")
  if hasParam(inst, "iAvgMax"):
    carried("i_avg", "i_avg",
            atMost(paramFloat(inst, "iAvgMax", 0.0)), "A",
            "the DC component the part carries, which is what a fuse, a " &
            "trace width and a connector contact are sized by")
  if hasParam(inst, "iRipple"):
    carried("ripple", "i_pp",
            nominal(paramFloat(inst, "iRipple", 0.0),
                    fracTol = paramFloat(inst, "band", 0.05)), "A",
            "the peak-to-peak the design equations fix -- for a converter " &
            "dI = Vout(1-D)/(Lf), which sets the output ripple, the current " &
            "limit headroom and whether the part saturates. Claiming it is " &
            "how a wrong inductor value is caught by something other than " &
            "the rail looking slightly worse")
  # These read the part's own rating rather than restating it in the design.
  if hasParam(inst, "maxIsatDerating"):
    carried("isat_derating", "i_peak_derating",
            atMost(paramFloat(inst, "maxIsatDerating", 0.0)), "",
            "how much of the part's *own* stated saturation current the peak " &
            "reaches -- nobody runs an inductor to its knee, and this is the " &
            "headroom stated once rather than copied out of the datasheet " &
            "into the design file", sevWarning)
  if hasParam(inst, "maxRmsDerating"):
    carried("rms_derating", "i_rms_derating",
            atMost(paramFloat(inst, "maxRmsDerating", 0.0)), "",
            "the same headroom against the part's stated continuous rating, " &
            "which is what its temperature rise was specified at", sevWarning)

proc sourceSweepExpand*(inst: RoleInstance): seq[Assertion] =
  ## What a node does as a source is swept. `vFrom`/`vTo`/`vStep` are
  ## conditions (the answers are differences across the range).
  ##
  ## `ratio` and `maxLineReg` are the same measurement for opposite circuits:
  ## a divider should follow by a stated slope, a regulator shouldn't follow
  ## (quoted as a percentage).
  let outNet = inst.subject("output")
  let vFrom = paramFloat(inst, "vFrom", 0.0)
  let vTo = paramFloat(inst, "vTo", 0.0)
  let vStep = paramFloat(inst, "vStep", 0.0)

  template swept(sfx, qty: string, e: Expectation, un, why: string;
                 sev = sevError) =
    var claim = Assertion(
      id: assertionId(inst, sfx),
      subjects: @[outNet],
      quantity: qty,
      expect: e,
      unit: un,
      severity: sev,
      rationale: why,
      origin: inst.name)
    claim.condition["sweep"] = "source"
    claim.condition["sweep_from"] = $vFrom
    claim.condition["sweep_to"] = $vTo
    claim.condition["sweep_step"] = $vStep
    if hasParam(inst, "nominal"):
      claim.condition["v_nominal"] = $paramFloat(inst, "nominal", 0.0)
    result.add claim

  # Every claim opt-in; there's no default for how a node should respond.
  if hasParam(inst, "ratio"):
    swept("transfer", "dc_transfer",
          nominal(paramFloat(inst, "ratio", 0.0),
                  fracTol = paramFloat(inst, "band", 0.05)), "",
          "the output has to follow the input by the ratio the design " &
          "equations computed -- measured as a slope across the whole swept " &
          "range rather than as one node voltage at one bias, which a wrong " &
          "network can still get right")
  if hasParam(inst, "maxLineReg"):
    swept("line_reg", "line_reg_pct",
          atMost(paramFloat(inst, "maxLineReg", 0.0)), "%",
          "how far the output moves across the whole input range, as a " &
          "percentage of the output -- which is what a supply's own " &
          "tolerance has to be budgeted against")
  if hasParam(inst, "maxLineRegPerV"):
    swept("line_reg_per_v", "line_reg_pct_per_v",
          atMost(paramFloat(inst, "maxLineRegPerV", 0.0)), "%/V",
          "the datasheet form of the same figure, which unlike the total " &
          "does not change with how wide the sweep was")
  if hasParam(inst, "maxDropout"):
    swept("dropout", "dropout_v",
          atMost(paramFloat(inst, "maxDropout", 0.0)), "V",
          "the input-to-output differential the part still regulates at; " &
          "below it the rail follows the supply down and every claim made " &
          "about the rail stops holding")
  if hasParam(inst, "minOut"):
    swept("out_min", "dc_out_min",
          atLeast(paramFloat(inst, "minOut", 0.0)), "V",
          "the lowest the output reaches anywhere in the swept range, which " &
          "is what anything downstream has to tolerate")
  if hasParam(inst, "maxOut"):
    swept("out_max", "dc_out_max",
          atMost(paramFloat(inst, "maxOut", 0.0)), "V",
          "the highest the output reaches anywhere in the swept range, " &
          "which is what anything downstream has to survive")
  if hasParam(inst, "maxDelta"):
    swept("delta", "dc_out_delta",
          atMost(paramFloat(inst, "maxDelta", 0.0)), "V",
          "how far the output moves across the whole range, in volts -- the " &
          "same figure `maxLineReg` states as a percentage, for a node that " &
          "has a budget rather than a nominal to be a fraction of")

proc loadSweepExpand*(inst: RoleInstance): seq[Assertion] =
  ## What a node does as current is drawn from it. Binds no part: the
  ## analysis injects a constant-current sink (a test load isn't a board
  ## part), so it also reaches networks with no load port, where `z_out_dc`
  ## is the Thevenin resistance.
  let outNet = inst.subject("output")
  let iFrom = paramFloat(inst, "iFrom", 0.0)
  let iTo = paramFloat(inst, "iTo", 0.0)
  let iStep = paramFloat(inst, "iStep", 0.0)

  template swept(sfx, qty: string, e: Expectation, un, why: string;
                 sev = sevError) =
    var claim = Assertion(
      id: assertionId(inst, sfx),
      subjects: @[outNet],
      quantity: qty,
      expect: e,
      unit: un,
      severity: sev,
      rationale: why,
      origin: inst.name)
    claim.condition["sweep"] = "load"
    claim.condition["sweep_from"] = $iFrom
    claim.condition["sweep_to"] = $iTo
    claim.condition["sweep_step"] = $iStep
    if hasParam(inst, "nominal"):
      claim.condition["v_nominal"] = $paramFloat(inst, "nominal", 0.0)
    result.add claim

  if hasParam(inst, "maxLoadReg"):
    swept("load_reg", "load_reg_pct",
          atMost(paramFloat(inst, "maxLoadReg", 0.0)), "%",
          "how far the output sags across the whole load range, as a " &
          "percentage of the output at light load")
  if hasParam(inst, "zOut"):
    swept("z_out", "z_out_dc",
          nominal(paramFloat(inst, "zOut", 0.0),
                  fracTol = paramFloat(inst, "band", 0.05)), "ohm",
          "the resistance looking back into the node, which for anything " &
          "built from a stated total and a stated ratio is a number the " &
          "design equations fix and no component value in the file says")
  if hasParam(inst, "maxZOut"):
    swept("z_out_max", "z_out_dc",
          atMost(paramFloat(inst, "maxZOut", 0.0)), "ohm",
          "how stiff the node has to be: everything hung on it sees this " &
          "resistance in series with whatever it draws")
  # The node's level at the heaviest load in the range.
  if hasParam(inst, "minOut"):
    swept("out_min", "dc_out_min",
          atLeast(paramFloat(inst, "minOut", 0.0)), "V",
          "the lowest the node reaches at the heaviest load in the range, " &
          "which is the voltage everything on it has to keep working at")
  if hasParam(inst, "maxOut"):
    swept("out_max", "dc_out_max",
          atMost(paramFloat(inst, "maxOut", 0.0)), "V",
          "the highest the node reaches anywhere in the load range")
  if hasParam(inst, "maxDelta"):
    swept("delta", "dc_out_delta",
          atMost(paramFloat(inst, "maxDelta", 0.0)), "V",
          "how far the node sags across the whole load range, in volts -- " &
          "the same figure `maxLoadReg` states as a percentage")
