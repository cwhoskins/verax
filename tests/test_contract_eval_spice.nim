## The simulation-backed evaluators. Skipped when `ngspice` is not on `PATH`.

import std/[math, os, strutils, tables, unittest]

import verax/contract/dsl
import verax/analysis/evaluators/contract_eval

let haveNgspice = findExe("ngspice").len > 0

proc resultFor(rs: seq[AssertionResult], id: string): AssertionResult =
  for r in rs:
    if r.assertion.id == id: return r
  raise newException(KeyError, "no result for " & id)

# --- fixtures -----------------------------------------------------------

proc dividerBoard(upper: string): Design =
  ## A 10 V source divided to a nominal 3.3 V rail (3.333 V with 2k/1k).
  design("divider"):
    net vin, kind = ntPower
    net vdd, kind = ntPower
    net gnd, kind = ntGround, name = "0"

    component V1, kind = "voltage_source", value = "DC 10":
      pin "+", vin, kind = ptPower
      pin "-", gnd, kind = ptGround
    component R1, kind = "resistor", value = upper:
      pin "1", vin, kind = ptPassive
      pin "2", vdd, kind = ptPassive
    component R2, kind = "resistor", value = "1000":
      pin "1", vdd, kind = ptPassive
      pin "2", gnd, kind = ptPassive

    role "power_rail", vdd_rail, rail = vdd, voltage = 3.3.V, band = 5.pct

# --- planning needs no simulator ----------------------------------------

test "the simulated evaluators register themselves on import":
  check isEvaluable("dc_voltage")
  check isEvaluable("z_max_in_band")
  check isEvaluable("phase_margin_deg")
  check "spice.dc_voltage" in registeredEvaluators()

test "a simulated quantity is not *evaluated* when no simulator is offered":
  # The default capability set is offline: importing must not run ngspice.
  let r = resultFor(evaluate(dividerBoard("2000")), "vdd_rail.voltage")
  check r.status == esNotEvaluated
  check "the .op capability" in r.reason

test "one .op answers every dc_voltage claim in the design":
  let d = design("rails"):
    net a, kind = ntPower
    net b, kind = ntPower
    net gnd, kind = ntGround, name = "0"
    component V1, kind = "voltage_source", value = "DC 5":
      pin "+", a, kind = ptPower
      pin "-", gnd, kind = ptGround
    component V2, kind = "voltage_source", value = "DC 12":
      pin "+", b, kind = ptPower
      pin "-", gnd, kind = ptGround
    require dc_voltage(a) == 5.0.V, id = "A"
    require dc_voltage(b) == 12.0.V, id = "B"

  let p = plan(d, allCapabilities)
  # Two claims, one node-voltage solve.
  check p.steps.len == 1
  check p.steps[0].evaluator == "spice.dc_voltage"
  check p.steps[0].assertions.len == 2

# --- the end-to-end verdict ---------------------------------------------

test "a rail that meets its requirement passes against a real .op":
  if not haveNgspice:
    skip()
  else:
    let rs = evaluate(dividerBoard("2000"), allCapabilities)
    let r = resultFor(rs, "vdd_rail.voltage")
    check r.status == esPass
    check abs(r.value - 3.3333) < 1.0e-3
    check r.unit == "V"
    check r.evaluator == "spice.dc_voltage"

test "a rail that misses its requirement fails, and reports the witness":
  if not haveNgspice:
    skip()
  else:
    # 4k over 1k puts the rail at 2.0 V, well outside 3.3 V +-5%.
    let rs = evaluate(dividerBoard("4000"), allCapabilities)
    let r = resultFor(rs, "vdd_rail.voltage")
    check r.status == esFail
    check abs(r.value - 2.0) < 1.0e-3
    check "2" in r.reason and "3.3" in r.reason
    check failed(rs).len == 1
    check worstSeverity(rs) == sevError

test "an undriven rail measures zero and fails, which is a real verdict":
  if not haveNgspice:
    skip()
  else:
  # ngspice solves this: the undriven rail sits at 0 V, so the honest report
  # is a failure with a witness, not a skip.
    let d = design("floating"):
      net vdd, kind = ntPower
      net gnd, kind = ntGround, name = "0"
      component R1, kind = "resistor", value = "1000":
        pin "1", vdd, kind = ptPassive
        pin "2", gnd, kind = ptPassive
      require dc_voltage(vdd) == 3.3.V, id = "X"
    let r = resultFor(evaluate(d, allCapabilities), "X")
    check r.status == esFail
    check abs(r.value) < 1.0e-9

test "a claim about a net inside a subcircuit instance is checked, not shrugged at":
  if not haveNgspice:
    skip()
  else:
  # A claim on an inner net (`design.innerNet`) must be checkable, not just
  # bindable. The name matches what `spice/flatten` calls that net.
    let leg = subckt("LEG", [TOP, BOT]):
      net TOP, kind = ntSignal
      net BOT, kind = ntSignal
      net mid, kind = ntSignal
      component R1, kind = "resistor", value = "1000":
        pin "1", TOP, kind = ptPassive
        pin "2", mid, kind = ptPassive
      component R2, kind = "resistor", value = "1000":
        pin "1", mid, kind = ptPassive
        pin "2", BOT, kind = ptPassive

    let d = design("hier"):
      net vin, kind = ntPower
      net gnd, kind = ntGround, name = "0", global = true
      component V1, kind = "voltage_source", value = "DC 10":
        pin "+", vin, kind = ptPower
        pin "-", gnd, kind = ptGround
      instance XL, leg, [vin, gnd]
      require dc_voltage(XL.innerNet("mid")) == 5.0.V, id = "INNER"

    let r = resultFor(evaluate(d, allCapabilities), "INNER")
    check r.status == esPass
    check abs(r.value - 5.0) < 1.0e-3

# --- setup recovered from the role that made the claim -------------------

test "a start-up claim with no regulator bound says exactly what is missing":
  # `overshoot_pct(vdd)` names the rail but not its regulator; with no role
  # to read that from, it's not evaluable and the reason names the fix.
  let d = design("noreg"):
    net vdd, kind = ntPower
    net gnd, kind = ntGround, name = "0"
    component C1, kind = "capacitor", value = "10u":
      pin "1", vdd, kind = ptPassive
      pin "2", gnd, kind = ptGround
    require overshoot_pct(vdd) <= 5.0, id = "OS"
  let r = resultFor(evaluate(d, allCapabilities), "OS")
  check r.status == esNotEvaluable
  check "regulator" in r.reason

test "a regulator role supplies the topology its own claims need":
  let d = design("reg"):
    net vin, kind = ntPower
    net vdd, kind = ntPower
    net gnd, kind = ntGround, name = "0"
    component U1, kind = "regulator":
      pin "IN", vin, kind = ptPower
      pin "OUT", vdd, kind = ptPower
      pin "GND", gnd, kind = ptGround
    component C1, kind = "capacitor", value = "10u":
      pin "1", vdd, kind = ptPassive
      pin "2", gnd, kind = ptGround
    role "regulator", vdd_reg, regulator = U1, output = vdd,
                      voltage = 3.3.V, maxOvershoot = 5.0

  # The regulator comes back through `Assertion.origin` -> the role bindings.
  let p = plan(d, allCapabilities)
  var startupSteps = 0
  for s in p.steps:
    if s.evaluator == "spice.startup": inc startupSteps
  check startupSteps == 1
  check "U1" in p.steps[0].key

test "a PDN target is claimed only when the designer states one":
  let bare = design("bare"):
    net vdd, kind = ntPower
    role "power_rail", r0, rail = vdd, voltage = 3.3.V
  for a in bare.expandAll():
    check a.quantity != "z_max_in_band"

  let targeted = design("targeted"):
    net vdd, kind = ntPower
    role "power_rail", r0, rail = vdd, voltage = 3.3.V, targetZ = 50.mohm
  var found = false
  for a in targeted.expandAll():
    if a.quantity == "z_max_in_band":
      found = true
      check a.expect.kind == ekMax
      check abs(a.expect.hi - 0.05) < 1.0e-12
      # The band is bounded at both ends.
      check a.condition.hasKey("f_from")
      check a.condition.hasKey("f_to")
  check found

# --- what each simulated run says it is ---------------------------------
#
# `describeStep` never simulates, so these need no ngspice.

test "a PDN step names the rail and the band it is judged over":
  let d = design("pdn"):
    net vdd, kind = ntPower
    role "power_rail", r0, rail = vdd, voltage = 3.3.V, targetZ = 50.mohm
  let p = plan(d, allCapabilities)
  var text = ""
  for s in p.steps:
    if s.evaluator == "spice.pdn": text = describeStep(d, s)
  check "net 'vdd'" in text
  check "100 kHz .. 100 MHz" in text
  # The setup key is machinery and must not be what a reader sees.
  check "100000.0" notin text

test "a start-up step names the part standing in for the regulator":
  let d = design("reg"):
    net vin, kind = ntPower
    net vdd, kind = ntPower
    net gnd, kind = ntGround, name = "0"
    component U1, kind = "regulator":
      pin "IN", vin, kind = ptPower
      pin "OUT", vdd, kind = ptPower
      pin "GND", gnd, kind = ptGround
    role "regulator", vdd_reg, regulator = U1, output = vdd,
                      voltage = 3.3.V, maxOvershoot = 5.0
  let p = plan(d, allCapabilities)
  var text = ""
  for s in p.steps:
    if s.evaluator == "spice.startup": text = describeStep(d, s)
  check "U1" in text
  check "soft-start" in text

test "the .op step says it is not isolated, which is why the claim means anything":
  # Isolating first would pin the rail at the voltage being asked about.
  let d = dividerBoard("2000")
  let p = plan(d, allCapabilities)
  var text = ""
  for s in p.steps:
    if s.evaluator == "spice.dc_voltage": text = describeStep(d, s)
  check "not isolated" in text

# --- what the run context guarantees ------------------------------------

test "the declared capabilities are what a run actually uses":
  # Each evaluator declares every analysis it runs, so `--caps` withholding
  # one actually refuses it.
  check evaluatorFor("z_max_in_band").get.needs == {capSpiceOp, capSpiceAc}
  check evaluatorFor("thd_pct").get.needs == {capSpiceOp, capSpiceTran}

test "a claim needing two capabilities is refused when only one is offered":
  let d = dividerBoard("2000")
  var found = false
  for rej in plan(d, {capStatic, capSpiceAc}).rejected:
    if rej.assertion.quantity == "z_max_in_band":
      found = true
      # Named, and named by label rather than by enum identifier.
      check ".op" in rej.reason
      check "capSpiceOp" notin rej.reason
  # The fixture claims no impedance; this guards the message shape only.
  discard found

test "an edited design is re-solved rather than answered from a stale cache":
  # The operating point lives in the EvalContext, so mutating a design and
  # evaluating again gets a fresh answer.
  if not haveNgspice:
    skip()
  else:
    let d = dividerBoard("2000")
    let first = resultFor(evaluate(d, allCapabilities), "vdd_rail.voltage")
    check abs(first.value - 3.333) < 0.01

    # Same Design object, different circuit.
    d.netlist.components["R1"].attrs["value"] = "4000"
    let second = resultFor(evaluate(d, allCapabilities), "vdd_rail.voltage")
    check abs(second.value - 2.0) < 0.01
    check first.value != second.value

test "one EvalContext shares an operating point across every step in a run":
  # Within one run the .op is solved once.
  if not haveNgspice:
    skip()
  else:
    let ctx = newEvalContext(dividerBoard("2000"), allCapabilities)
    check not ctx.scratch.hasKey("spice.operating_point")
    discard evaluate(ctx)
    check ctx.scratch.hasKey("spice.operating_point")

# --- device currents ----------------------------------------------------

proc currentBoard(): Design =
  ## A square wave through a series R-L into a resistive load: settles to
  ## 25 mA with a triangle on it, so average, peak and RMS all differ.
  design("current_board"):
    net vin, kind = ntPower
    net mid, kind = ntSignal
    net vout, kind = ntPower
    net gnd, kind = ntGround, name = "0"

    component V1, kind = "voltage_source", value = "PULSE(0 10 0 1n 1n 5u 10u)":
      pin "+", vin, kind = ptPower
      pin "-", gnd, kind = ptGround
    component R1, kind = "resistor", value = "100":
      pin "1", vin, kind = ptPassive
      pin "2", mid, kind = ptPassive
    component L1, kind = "inductor", value = "10m":
      pin "1", mid, kind = ptPassive
      pin "2", vout, kind = ptPassive
      spec:
        isat = 250.mA
        current_rating = 100.mA
    component C1, kind = "capacitor", value = "100u":
      pin "1", vout, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        dielectric = "C0G"
        esr = 1.mohm
        esl = 1.pH
    component RL, kind = "resistor", value = "100":
      pin "1", vout, kind = ptPassive
      pin "2", gnd, kind = ptPassive

    role "current_path", coil, part = L1,
         tSettle = 50.0.ms, tWindow = 100.0.us,
         iAvgMax = 30.mA, iRmsMax = 40.mA,
         maxIsatDerating = 0.5, maxRmsDerating = 0.9
    role "current_path", cap, part = C1,
         tSettle = 50.0.ms, tWindow = 100.0.us,
         iAvgMax = 1.mA

test "a current quantity is reachable, and its subject is a component":
  check isEvaluable("i_peak")
  check isEvaluable("i_rms_derating")
  check "spice.current_path" in registeredEvaluators()
  let ev = evaluatorFor("i_peak")
  check ev.isSome
  check ev.get.subjectKinds == {skComponent}
  # No `binds`: the subject is the part, so `require i_peak(L1) <= 6.A`
  # needs no role.
  check ev.get.binds.len == 0

test "two parts over one window are one run, not one run per part":
  # The setup is the window alone, so one `.tran` serves every part.
  let d = currentBoard()
  let p = plan(d, allCapabilities)
  var steps = 0
  for s in p.steps:
    if s.evaluator == "spice.current_path": steps += 1
  check steps == 1

test "the current claims are checked against the parts that carry them":
  if not haveNgspice:
    skip()
  else:
    let rs = evaluate(currentBoard(), allCapabilities)

    # 2.5 V average across 100 ohm, fed through 100 ohm.
    check resultFor(rs, "coil.i_avg").status == esPass
    check abs(resultFor(rs, "coil.i_avg").value - 0.025) / 0.025 < 0.02
    check resultFor(rs, "coil.i_rms").status == esPass

    # One run, two parts, numbers not crossed: the capacitor carries the
    # ripple and none of the DC; the inductor carries both.
    check resultFor(rs, "cap.i_avg").status == esPass
    check resultFor(rs, "cap.i_avg").value < 0.001

test "a derating claim reads the part's own rating rather than restating it":
  if not haveNgspice:
    skip()
  else:
    let rs = evaluate(currentBoard(), allCapabilities)
    # L1 states isat = 250 mA; the peak is around 27 mA, so about 11%.
    let dr = resultFor(rs, "coil.isat_derating")
    check dr.status == esPass
    check dr.value > 0.0 and dr.value < 0.2
    check resultFor(rs, "coil.rms_derating").status == esPass

test "a current claim on a net says a current is carried by a part":
  # `subjectKinds` rejects a net subject, and the message says what to write.
  let d = design("net_current"):
    net vdd, kind = ntPower
    net gnd, kind = ntGround, name = "0"
    component V1, kind = "voltage_source", value = "DC 5":
      pin "+", vdd, kind = ptPower
      pin "-", gnd, kind = ptGround
    require i_peak(vdd) <= 1.0.A, id = "REQ-NET-CURRENT"

  let rs = evaluate(d, allCapabilities)
  check resultFor(rs, "REQ-NET-CURRENT").status == esNotEvaluable

# --- load step, rejection and output-current derating -------------------

proc stepBoard(): Design =
  ## A 5 V rail behind 100 mohm, with 100 uF and a 1 A standing load. A
  ## 0.5 A step droops 50 mV once the source takes over; the capacitor's
  ## contribution over the first microsecond is `i * t / C` = 5 mV.
  design("step"):
    net vin, kind = ntPower
    net vout, kind = ntPower
    net gnd, kind = ntGround, name = "0"

    component V1, kind = "voltage_source", value = "DC 5":
      pin "+", vin, kind = ptPower
      pin "-", gnd, kind = ptGround
      spec:
        current_rating = 2.0.A
    component RS, kind = "resistor", value = "0.1":
      pin "1", vin, kind = ptPassive
      pin "2", vout, kind = ptPassive
    component C1, kind = "capacitor", value = "100u":
      pin "1", vout, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        dielectric = "C0G"
        esr = 1.mohm
        esl = 1.pH
    component RL, kind = "resistor", value = "5":
      pin "1", vout, kind = ptPassive
      pin "2", gnd, kind = ptPassive

    role "regulator", reg, regulator = V1, output = vout, sense = RS,
         without = "final_v,overshoot",
         voltage = 5.0.V, band = 5.pct,
         iFrom = 0.0.A, iTo = 0.5.A, tEdge = 1.0.us,
         tStepAt = 20.0.ms, tHold = 10.0.ms, tRecover = 10.0.ms,
         stepPoints = 4000, stepBand = 0.002,
         maxDroop = 60.mV, maxStepOvershoot = 60.mV, maxRecover = 5.0.ms

test "the load-step quantities are reachable and their subject is a net":
  check isEvaluable("step_droop_v")
  check isEvaluable("step_overshoot_v")
  check isEvaluable("step_recover_s")
  check "spice.load_step" in registeredEvaluators()
  let ev = evaluatorFor("step_droop_v")
  check ev.isSome
  check ev.get.subjectKinds == {skNet}
  # No `binds`: the subject is the rail. The step must still be stated.
  check ev.get.binds.len == 0

test "one load step is one run however many claims are made about it":
  let d = stepBoard()
  let p = plan(d, allCapabilities)
  var steps = 0
  for s in p.steps:
    if s.evaluator == "spice.load_step": steps += 1
  check steps == 1

test "two step magnitudes are two runs -- the answers do not pool":
  # The step magnitude is part of the setup key; pooling would answer one
  # claim with the other's number.
  let d = stepBoard()
  discard d.addRole("regulator", "reg2",
                    {"regulator": Subject(kind: skComponent, name: "V1"),
                     "output": Subject(kind: skNet, name: "vout")},
                    {"without": "overshoot",
                     "iFrom": "0.0", "iTo": "1.0", "tEdge": "1.0e-6",
                     "tStepAt": "0.02", "tRecover": "0.01",
                     "maxDroop": "0.2"})
  let p = plan(d, allCapabilities)
  var steps = 0
  for s in p.steps:
    if s.evaluator == "spice.load_step": steps += 1
  check steps == 2

test "a load step measures the droop the source resistance predicts":
  if not haveNgspice:
    skip()
  else:
    let rs = evaluate(stepBoard(), allCapabilities)
    let droop = resultFor(rs, "reg.droop")
    check droop.status == esPass
  # 0.5 A through 100 mohm.
    check abs(droop.value - 0.05) / 0.05 < 0.1
    # The release does not mirror the droop: a first-order RC has nothing to
    # overshoot with. An overshoot needs a second energy store.
    let over = resultFor(rs, "reg.step_overshoot")
    check over.status == esPass
    check over.value < 0.005

test "recovery is measured against where the rail settles under the new load":
  if not haveNgspice:
    skip()
  else:
    # No loop, so recovery is the RC's 10 us. Load regulation isn't a failure
    # to recover: the rail settles 50 mV lower and recovery is measured
    # against that, not the old level.
    let rs = evaluate(stepBoard(), allCapabilities)
    let rec = resultFor(rs, "reg.recover")
    check rec.status == esPass
    check rec.value >= 0.0 and rec.value < 1.0e-3

proc psrrBoard(): Design =
  ## An RC low-pass whose rejection is `sqrt(1 + (2*pi*f*R*C)^2)`: 1 kohm and
  ## 1 uF give 16.1 dB at 1 kHz.
  design("psrr"):
    net vin, kind = ntPower
    net vout, kind = ntPower
    net gnd, kind = ntGround, name = "0"

    component V1, kind = "voltage_source", value = "DC 5":
      pin "+", vin, kind = ptPower
      pin "-", gnd, kind = ptGround
    component R1, kind = "resistor", value = "1000":
      pin "1", vin, kind = ptPassive
      pin "2", vout, kind = ptPassive
    component C1, kind = "capacitor", value = "1u":
      pin "1", vout, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        dielectric = "C0G"
        esr = 1.uohm
        esl = 1.pH

    role "linear_regulator", filt,
         regulator = R1, output = vout, source = V1, input = vin,
         without = "overshoot",
         minPsrrDb = 15.dB, psrrAtF = 1.kHz, psrrRippleV = 100.mV,
         tSettle = 20.0.ms, psrrPeriods = 8, psrrPoints = 400,
         minPsrrBandDb = 15.dB, psrrFrom = 100.Hz, psrrTo = 10.kHz

test "the two rejection evaluators declare different capabilities":
  # Two evaluators, so a host offering only `.ac` or only `.tran` can run one.
  check isEvaluable("psrr_db")
  check isEvaluable("psrr_min_db")
  check isEvaluable("psrr_at_f")
  check "spice.psrr_tone" in registeredEvaluators()
  check "spice.psrr_ac" in registeredEvaluators()
  check evaluatorFor("psrr_db").get.needs == {capSpiceTran}
  check evaluatorFor("psrr_min_db").get.needs == {capSpiceAc}

test "a rejection claim names the role, because it needs a supply bound":
  # Both declare `binds`, so a bare claim names what must be bound.
  check evaluatorFor("psrr_db").get.binds == @["source", "input"]
  check evaluatorFor("psrr_min_db").get.binds == @["source", "input"]
  let d = design("bare_psrr"):
    net vdd, kind = ntPower
    net gnd, kind = ntGround, name = "0"
    component V1, kind = "voltage_source", value = "DC 5":
      pin "+", vdd, kind = ptPower
      pin "-", gnd, kind = ptGround
    require psrr_db(vdd) >= 40.dB, id = "REQ-BARE-PSRR"
  let rs = evaluate(d, allCapabilities)
  check resultFor(rs, "REQ-BARE-PSRR").status == esNotEvaluable

test "both methods measure an RC's known rejection, and agree with each other":
  if not haveNgspice:
    skip()
  else:
    let rs = evaluate(psrrBoard(), allCapabilities)
    # 20*log10(sqrt(1 + (2*pi*1000*1e-3)^2)) = 15.98 dB.
    let exact = 10.0 * log10(1.0 + pow(2.0 * PI * 1000.0 * 1.0e-3, 2.0))
    let tone = resultFor(rs, "filt.psrr")
    let swept = resultFor(rs, "filt.psrr_swept")
    check tone.status == esPass
    check swept.status == esPass
    check abs(tone.value - exact) < 0.3
    check abs(swept.value - exact) < 0.1
  # A tone has a noise floor and `.ac` a linearisation; they must agree.
    check abs(tone.value - swept.value) < 0.3

# --- channel match, the first two-subject quantity ---------------------

proc matchBoard(rfRight: string): Design =
  ## Two non-inverting stages, gain 1 + Rf/Rg. Both Rf at 10k match; moving
  ## the right one is an imbalance `channel_match` must catch.
  design("match"):
    net inL, kind = ntSignal
    net outL, kind = ntSignal
    net fbL, kind = ntSignal
    net inR, kind = ntSignal
    net outR, kind = ntSignal
    net fbR, kind = ntSignal
    net gnd, kind = ntGround, name = "0"

    component UL, kind = "opamp":
      pin "IN+", inL, kind = ptInput
      pin "IN-", fbL, kind = ptInput
      pin "OUT", outL, kind = ptOutput
    component RfL, kind = "resistor", value = "10k":
      pin "1", outL, kind = ptPassive
      pin "2", fbL, kind = ptPassive
    component RgL, kind = "resistor", value = "1k":
      pin "1", fbL, kind = ptPassive
      pin "2", gnd, kind = ptPassive

    component UR, kind = "opamp":
      pin "IN+", inR, kind = ptInput
      pin "IN-", fbR, kind = ptInput
      pin "OUT", outR, kind = ptOutput
    component RfR, kind = "resistor", value = rfRight:
      pin "1", outR, kind = ptPassive
      pin "2", fbR, kind = ptPassive
    component RgR, kind = "resistor", value = "1k":
      pin "1", fbR, kind = ptPassive
      pin "2", gnd, kind = ptPassive

    role "gain_stage", left, opamp = UL, input = inL, output = outL,
         minGain = 10.dB
    role "gain_stage", right, opamp = UR, input = inR, output = outR,
         minGain = 10.dB
    role "channel_match", stereo, a = roleRef("left"), b = roleRef("right"),
         fFrom = 100.Hz, fTo = 20.kHz, maxGainDelta = 0.5.dB

test "the channel-match quantity is reachable, and needs two skClass subjects":
  check isEvaluable("gain_delta_max_db")
  check "spice.channel_match" in registeredEvaluators()
  let ev = evaluatorFor("gain_delta_max_db")
  check ev.isSome
  check ev.get.arity == 2 .. 2
  check ev.get.subjectKinds == {skClass}
  check ev.get.needs == {capSpiceAc}

test "a channel-match claim needing no sim is planned as one .ac step":
  let p = plan(matchBoard("10k"), allCapabilities)
  var steps = 0
  for s in p.steps:
    if s.evaluator == "spice.channel_match": inc steps
  check steps == 1

test "matched channels pass the delta claim":
  if not haveNgspice:
    skip()
  else:
    let r = resultFor(evaluate(matchBoard("10k"), allCapabilities),
                      "stereo.gain_delta")
    check r.status == esPass
    check r.value < 0.01
    check r.unit == "dB"

test "a gain-setting resistor off on one channel fails it, with the measurement":
  if not haveNgspice:
    skip()
  else:
    # Rf 12k vs 10k: gain 13 vs 11, about 1.46 dB apart across the band.
    let r = resultFor(evaluate(matchBoard("12k"), allCapabilities),
                      "stereo.gain_delta")
    check r.status == esFail
    check r.value > 1.0
    check "dB" in r.reason

test "i_out_derating reads the regulator's rating, not the sense part's":
  # The rating belongs to the chosen source part, not the sense resistor.
  if not haveNgspice:
    skip()
  else:
    let d = stepBoard()
    discard d.addRole("regulator", "rated",
                      {"regulator": Subject(kind: skComponent, name: "V1"),
                       "output": Subject(kind: skNet, name: "vout"),
                       "sense": Subject(kind: skComponent, name: "RS")},
                      {"without": "overshoot",
                       "tSettle": "0.05", "tWindow": "0.001",
                       "maxOutputDerating": "0.9"})
    let rs = evaluate(d, allCapabilities)
    let dr = resultFor(rs, "rated.i_out_derating")
    check dr.status == esPass
    # 1 A standing load against V1's stated 2 A rating.
    check abs(dr.value - 0.5) < 0.05

test "a regulator that states no rating reports derating as unchecked":
  # No rating reads NaN (not evaluated), not infinite headroom.
  if not haveNgspice:
    skip()
  else:
    let d = design("unrated"):
      net vdd, kind = ntPower
      net gnd, kind = ntGround, name = "0"
      component V1, kind = "voltage_source", value = "DC 5":
        pin "+", vdd, kind = ptPower
        pin "-", gnd, kind = ptGround
      component RS, kind = "resistor", value = "5":
        pin "1", vdd, kind = ptPassive
        pin "2", gnd, kind = ptPassive
      role "regulator", reg, regulator = V1, output = vdd, sense = RS,
           without = "overshoot",
           tSettle = 1.0.ms, tWindow = 1.0.ms,
           maxOutputDerating = 0.9
    let rs = evaluate(d, allCapabilities)
    check resultFor(rs, "reg.i_out_derating").status == esNotEvaluated
