import std/[math, os, sequtils, strutils, tables, unittest]

import verax/netlist/dsl
import verax/spice/transform
import verax/spice/ngspice
import verax/analysis/analyses/transient

let haveNgspice = findExe("ngspice").len > 0

proc rcRail(): Netlist =
  ## A square wave through an RC into a load, settling to a closed-form
  ## average and ripple: 50% duty at 100 kHz averages 5 V; with tau = 1 ms
  ## the ripple is V*d*(1-d)*T/(R*C) = 25 mV.
  result = newNetlist("rc")
  let vin = addNet(result, newNet("vin"))
  let vout = addNet(result, newNet("vout"))
  let gnd = addNet(result, newNet("0", ntGround))

  let v1 = addComponent(result, newComponent("V1", kind = "voltage_source"))
  discard connect(v1, "+", vin)
  discard connect(v1, "-", gnd)
  v1.attrs["value"] = "PULSE(0 10 0 1n 1n 5u 10u)"

  let r1 = addComponent(result, newComponent("R1", kind = "resistor"))
  discard connect(r1, "1", vin)
  discard connect(r1, "2", vout)
  r1.attrs["value"] = "100"

  let c1 = addComponent(result, newComponent("C1", kind = "capacitor"))
  discard connect(c1, "1", vout)
  discard connect(c1, "2", gnd)
  c1.attrs["value"] = "10u"
  # Class 1, so bias derating doesn't move the capacitance.
  c1.attrs["dielectric"] = "C0G"
  # Stated: the package-typical ESR would dominate the ripple here.
  c1.attrs["esr"] = "1e-3"
  c1.attrs["esl"] = "1e-12"

test "the window is what is measured, and the run before it is discarded":
  if not haveNgspice:
    skip()
  else:
    var spec = defaultTransientSpec()
    spec.tSettle = 5.0e-3   ## five time constants
    spec.tWindow = 5.0e-5   ## five periods of the drive
    let r = analyzeTransient(rcRail(), "vout", spec)

    # 5 V average from a 50% square wave far above the corner.
    check abs(r["settled_v"] - 5.0) < 0.05
    # V*d*(1-d)*T/(R*C) = 25 mV, and the measurement is peak-to-peak.
    check abs(r["ripple_pp"] - 0.025) / 0.025 < 0.15
    check r["settled_max"] > r["settled_min"]
    # Measuring from t = 0 would report the whole start-up rise as ripple.
    check r["ripple_pp"] < 0.1

test "a window that opens after the run ends says so rather than answering":
  if not haveNgspice:
    skip()
  else:
    var spec = defaultTransientSpec()
    spec.tSettle = 1.0e-3
    spec.tWindow = 1.0e-5
    spec.tStop = 1.0e-4        ## deliberately shorter than tSettle
    let r = analyzeTransient(rcRail(), "vout", spec)
    check r.measurements.len == 0
    check r.issues.len == 1
    check r.issues[0].kind == KindSimulationFailed

test "an unknown net raises rather than measuring something else":
  expect NetlistError:
    discard analyzeTransient(rcRail(), "nowhere", defaultTransientSpec())

test "the settle check fires only when it was asked for":
  if not haveNgspice:
    skip()
  else:
    var spec = defaultTransientSpec()
    spec.tSettle = 5.0e-3
    spec.tWindow = 5.0e-5
    check analyzeTransient(rcRail(), "vout", spec).issues.len == 0
    # 25 mV on 5 V is 0.5%, so a 0.1% band is violated and a 1% one is not.
    spec.settleTol = 0.001
    let tight = analyzeTransient(rcRail(), "vout", spec)
    check tight.issues.len == 1
    check tight.issues[0].kind == KindNotSettled
    spec.settleTol = 0.01
    check analyzeTransient(rcRail(), "vout", spec).issues.len == 0

test "the purpose reaches the model selection":
  if not haveNgspice:
    skip()
  else:
    # A steady-state model is used here and the default elsewhere; making the
    # two disagree shows which ran.
    let nl = rcRail()
    let r1 = nl.components["R1"]
    var slow = newSimReplacement("resistor", name = "averaged")
    slow.pinNets["1"] = "vin"
    slow.pinNets["2"] = "vout"
    slow.attrs["value"] = "100"
    var fast = newSimReplacement("resistor", name = "switching",
                                 suits = [spSteadyState])
    fast.pinNets["1"] = "vin"
    fast.pinNets["2"] = "vout"
    # Ten times the resistance: a tenth of the ripple.
    fast.attrs["value"] = "1000"
    addSimModel(r1, slow)
    addSimModel(r1, fast)

    var spec = defaultTransientSpec()
    spec.tSettle = 5.0e-2
    spec.tWindow = 5.0e-5
    let r = analyzeTransient(nl, "vout", spec)
    check abs(r["settled_v"] - 5.0) < 0.05
    check abs(r["ripple_pp"] - 0.0025) / 0.0025 < 0.2

# --- oscillation --------------------------------------------------------

proc tank(): Netlist =
  ## A parallel LC ringing at 1/(2*pi*sqrt(1m * 1u)) = 5032.92 Hz. Undriven,
  ## so it sits at zero unless given initial energy.
  result = newNetlist("tank")
  let a = addNet(result, newNet("a"))
  let gnd = addNet(result, newNet("0", ntGround))

  let l1 = addComponent(result, newComponent("L1", kind = "inductor"))
  discard connect(l1, "1", a)
  discard connect(l1, "2", gnd)
  l1.attrs["value"] = "1m"

  let c1 = addComponent(result, newComponent("C1", kind = "capacitor"))
  discard connect(c1, "1", a)
  discard connect(c1, "2", gnd)
  c1.attrs["value"] = "1u"
  # Class 1 and a stated ESR, so defaults add no damping.
  c1.attrs["dielectric"] = "C0G"
  c1.attrs["esr"] = "0.001"
  c1.attrs["esl"] = "1e-12"

test "an oscillator that will not start from its operating point is kicked into life":
  if not haveNgspice:
    skip()
  else:
    var spec = defaultTransientSpec()
    spec.tSettle = 1.0e-3
    spec.tWindow = 1.0e-2      ## about 50 periods
    spec.initialConditions["a"] = 2.0
    let r = analyzeOscillation(tank(), "a", spec)

    check abs(r["osc_freq"] - 5032.92) / 5032.92 < 0.01
    # 2 V of initial charge on the capacitor, swinging symmetrically.
    check abs(r["swing_pp"] - 4.0) / 4.0 < 0.05
    # A lossless tank is a pure sine.
    check r["osc_thd_pct"] < 1.0
    check r.issues.len == 0
    # The cost of `uic` is stated on every run that uses it.
    check r.assumptions.anyIt("uic" in it.detail)

test "no kick means no oscillation, and the issue says which of the two it is":
  if not haveNgspice:
    skip()
  else:
    var spec = defaultTransientSpec()
    spec.tSettle = 1.0e-3
    spec.tWindow = 1.0e-2
    let r = analyzeOscillation(tank(), "a", spec)

    # NaN, not 0 Hz: a flat line has no frequency to measure.
    check r["osc_freq"].isNaN
    check r.issues.len == 1
    check r.issues[0].kind == KindDidNotOscillate
    check "initialConditions" in r.issues[0].message

test "a node driven periodically needs no kick at all":
  if not haveNgspice:
    skip()
  else:
    # The `kick` is optional: many circuits are periodic without one.
    var spec = defaultTransientSpec()
    spec.tSettle = 5.0e-3
    spec.tWindow = 5.0e-4      ## fifty periods of the 100 kHz drive
    let r = analyzeOscillation(rcRail(), "vout", spec)
    check abs(r["osc_freq"] - 1.0e5) / 1.0e5 < 0.01
    check not r.assumptions.anyIt("uic" in it.detail)

# --- device currents ----------------------------------------------------

suite "branch current vector names":
  test "the two shapes are told apart by whether the current is an unknown":
    # Sources, inductors and controlled sources are solved for their current,
    # so it's saved by default.
    for desig in ["V1", "L1", "E1", "H1"]:
      let (vec, save, why) = branchCurrentVector(desig)
      check vec == "i(" & desig & ")"
      check save.len == 0
      check why.len == 0

  test "everything else has to be asked for by name":
    check branchCurrentVector("R1") == ("i(@R1[i])", "@R1[i]", "")
    check branchCurrentVector("C4") == ("i(@C4[i])", "@C4[i]", "")
    check branchCurrentVector("D2") == ("i(@D2[id])", "@D2[id]", "")

  test "a flattened hierarchical designator keeps its dots":
    # A flattened designator `LXA.L1` is read literally.
    check branchCurrentVector("LXA.L1").vector == "i(LXA.L1)"
    check branchCurrentVector("RXA.R1").saveTerm == "@RXA.R1[i]"

  test "a three-terminal device is refused rather than guessed at":
    # Collector, emitter and base currents differ; "the current through Q1"
    # is ambiguous, so it's refused.
    let (vec, _, why) = branchCurrentVector("Q3")
    check vec.len == 0
    check "more than one current" in why
    check "ic" in why
    for desig in ["M1", "J2"]:
      check branchCurrentVector(desig).vector.len == 0

  test "an X instance and an A device have no terminal current of their own":
    check "hierarchy boundary" in branchCurrentVector("XA").reason
    check "code model" in branchCurrentVector("AU1").reason
    check branchCurrentVector("").reason.len > 0

suite "analyzeCurrent":
  proc lcRail(): Netlist =
    ## `rcRail`'s drive through a series inductor into a load: 25 mA average
    ## through a 200 ohm chain, the same current in every series part.
    result = newNetlist("lc")
    let vin = addNet(result, newNet("vin"))
    let mid = addNet(result, newNet("mid"))
    let vout = addNet(result, newNet("vout"))
    let gnd = addNet(result, newNet("0", ntGround))

    let v1 = addComponent(result, newComponent("V1", kind = "voltage_source"))
    discard connect(v1, "+", vin)
    discard connect(v1, "-", gnd)
    v1.attrs["value"] = "PULSE(0 10 0 1n 1n 5u 10u)"

    let r1 = addComponent(result, newComponent("R1", kind = "resistor"))
    discard connect(r1, "1", vin)
    discard connect(r1, "2", mid)
    r1.attrs["value"] = "100"

    let l1 = addComponent(result, newComponent("L1", kind = "inductor"))
    discard connect(l1, "1", mid)
    discard connect(l1, "2", vout)
    l1.attrs["value"] = "10m"

    let c1 = addComponent(result, newComponent("C1", kind = "capacitor"))
    discard connect(c1, "1", vout)
    discard connect(c1, "2", gnd)
    c1.attrs["value"] = "100u"
    c1.attrs["dielectric"] = "C0G"
    c1.attrs["esr"] = "1e-3"
    c1.attrs["esl"] = "1e-12"

    let rl = addComponent(result, newComponent("RL", kind = "resistor"))
    discard connect(rl, "1", vout)
    discard connect(rl, "2", gnd)
    rl.attrs["value"] = "100"

  proc settledSpec(): TransientSpec =
    result = defaultTransientSpec()
    result.tSettle = 50.0e-3      ## many time constants past the LC's settling
    result.tWindow = 100.0e-6     ## ten switching periods

  proc valueFor(r: AnalysisReport, name, at: string): float =
    for m in r.measurements:
      if m.name == name and m.at == at: return m.value
    NaN

  test "parts in series carry one current, and the sign is not part of it":
    if not haveNgspice:
      skip()
    else:
      let r = analyzeCurrent(lcRail(), ["L1", "R1", "V1"], settledSpec())

      # 2.5 V across 100 ohm.
      check abs(valueFor(r, "i_avg", "L1") - 0.025) / 0.025 < 0.02
      # R1 is in series with L1: same current, to the last digit.
      check abs(valueFor(r, "i_rms", "R1") - valueFor(r, "i_rms", "L1")) < 1e-9

      # A source's branch current is positive flowing into +, so V1
      # delivering 25 mA reads negative; the magnitudes match L1's.
      check valueFor(r, "i_max", "V1") < 0.0
      check abs(valueFor(r, "i_peak", "V1") - valueFor(r, "i_peak", "L1")) < 1e-9
      check valueFor(r, "i_avg", "V1") > 0.0

  test "peak, RMS and average are three different numbers about one waveform":
    if not haveNgspice:
      skip()
    else:
      let r = analyzeCurrent(lcRail(), ["L1"], settledSpec())
      let peak = valueFor(r, "i_peak", "L1")
      let rms = valueFor(r, "i_rms", "L1")
      let avg = valueFor(r, "i_avg", "L1")
      let pp = valueFor(r, "i_pp", "L1")
      # A triangle on DC: peak > RMS > average.
      check peak > rms
      check rms > avg
      check abs(pp - (valueFor(r, "i_max", "L1") -
                      valueFor(r, "i_min", "L1"))) < 1e-12
      check abs(peak - (avg + pp / 2.0)) / peak < 0.05

  test "one run answers every part, which is what makes a claim affordable":
    if not haveNgspice:
      skip()
    else:
      # Four parts, one `.tran`.
      let r = analyzeCurrent(lcRail(), ["L1", "R1", "RL", "C1"], settledSpec())
      check r.raw.vectors.len > 0
      for part in ["L1", "R1", "RL", "C1"]:
        check not valueFor(r, "i_rms", part).isNaN
      # The capacitor carries the ripple, the load the DC.
      check valueFor(r, "i_avg", "C1") < 0.001
      check abs(valueFor(r, "i_avg", "RL") - 0.025) / 0.025 < 0.02

  test "a rating the part states is read back; one it does not is NaN":
    if not haveNgspice:
      skip()
    else:
      let nl = lcRail()
      let l1 = findComponent(nl, "L1")
      l1.attrs["isat"] = "0.5"
      l1.attrs["current_rating"] = "0.1"
      let r = analyzeCurrent(nl, ["L1", "R1"], settledSpec())

      # 25 mA against a 500 mA knee.
      check abs(valueFor(r, "i_peak_derating", "L1") -
                valueFor(r, "i_peak", "L1") / 0.5) < 1e-12
      check abs(valueFor(r, "i_rms_derating", "L1") -
                valueFor(r, "i_rms", "L1") / 0.1) < 1e-12
      # NaN, not 1.0 or 0: no rating means not evaluated, not a pass.
      check valueFor(r, "i_peak_derating", "R1").isNaN
      check valueFor(r, "i_rms_derating", "R1").isNaN

  test "a part run past its stated rating says so as an issue":
    if not haveNgspice:
      skip()
    else:
      let nl = lcRail()
      findComponent(nl, "L1").attrs["isat"] = "0.02"   ## 20 mA, against 50
      let r = analyzeCurrent(nl, ["L1"], settledSpec())
      check r.issues.anyIt(it.kind == KindOverCurrent)
      check r.issues.anyIt("inductance collapses" in it.message)

  test "a part with no single current is refused by name, not left blank":
    if not haveNgspice:
      skip()
    else:
      let nl = lcRail()
      let q1 = addComponent(nl, newComponent("Q1", kind = "bjt"))
      discard connect(q1, "C", nl.nets["vout"])
      discard connect(q1, "B", nl.nets["mid"])
      discard connect(q1, "E", nl.nets["0"])
      q1.attrs["value"] = "QMOD"
      setModel(nl, "QMOD", "NPN")

      let r = analyzeCurrent(nl, ["L1", "Q1"], settledSpec())
      # One unmeasurable subject doesn't sink the batch.
      check not valueFor(r, "i_rms", "L1").isNaN
      check valueFor(r, "i_rms", "Q1").isNaN
      check r.issues.anyIt(it.kind == KindNoCurrent and "Q1" in it.message)

  test "a part a model pass dissolved is reported, not raised":
    if not haveNgspice:
      skip()
    else:
      # The deck is a flattened, model-substituted copy, so a design part may
      # be gone: a ferrite bead becomes an R-L-C with no device named for it.
      let nl = lcRail()
      let fb1 = addComponent(nl, newComponent("FB1", kind = "ferrite_bead"))
      discard connect(fb1, "1", nl.nets["vout"])
      discard connect(fb1, "2", nl.nets["0"])
      fb1.attrs["value"] = "600"

      let r = analyzeCurrent(nl, ["L1", "FB1"], settledSpec())
      check not valueFor(r, "i_rms", "L1").isNaN
      check valueFor(r, "i_rms", "FB1").isNaN
      check r.issues.anyIt(it.kind == KindNoCurrent and "FB1" in it.message)

# --- load step --------------------------------------------------------------

proc lcRail(l = "10u", c = "100u", esr = "1e-3"): Netlist =
  ## An ideal 5 V source through an inductor into a capacitor bank. A step
  ## `dI` rings at amplitude `dI * sqrt(L/C)` and `1 / (2*pi*sqrt(L*C))`:
  ## with 10 uH and 100 uF, 316 mV per amp at 5033 Hz (199 us period).
  result = newNetlist("lc")
  let vin = addNet(result, newNet("vin"))
  let vout = addNet(result, newNet("vout"))
  let gnd = addNet(result, newNet("0", ntGround))

  let v1 = addComponent(result, newComponent("V1", kind = "voltage_source"))
  discard connect(v1, "+", vin)
  discard connect(v1, "-", gnd)
  v1.attrs["value"] = "DC 5"
  # Ideal: the default source impedance would add to the inductor.
  v1.attrs["rout"] = "0"
  v1.attrs["lout"] = "0"

  let l1 = addComponent(result, newComponent("L1", kind = "inductor"))
  discard connect(l1, "1", vin)
  discard connect(l1, "2", vout)
  l1.attrs["value"] = l

  let c1 = addComponent(result, newComponent("C1", kind = "capacitor"))
  discard connect(c1, "1", vout)
  discard connect(c1, "2", gnd)
  c1.attrs["value"] = c
  c1.attrs["dielectric"] = "C0G"   ## no bias derating under the arithmetic
  c1.attrs["esr"] = esr
  c1.attrs["esl"] = "1e-12"

test "a load step droops the rail by dI * sqrt(L/C)":
  if not haveNgspice:
    skip()
  else:
    var spec = defaultLoadStepSpec()
    spec.iFrom = 0.0
    spec.iTo = 1.0
    spec.tSettle = 1.0e-3       ## well past any start-up
    spec.tEdge = 1.0e-7         ## fast against a 199 us ring
    spec.tHold = 1.0e-3
    spec.tRecover = 6.0e-4      ## three ring periods
    let r = analyzeLoadStep(lcRail(), "vout", spec)

    # dI * sqrt(L/C) = 1 * sqrt(10u/100u) = 316 mV.
    let z0 = sqrt(10.0e-6 / 100.0e-6)
    check abs(r["step_droop_v"] - z0) / z0 < 0.12
    # The ring is about the new operating point (still 5 V when lossless), so
    # the rail comes back above where it started.
    check r["step_v_min"] < 5.0 - 0.5 * z0
    check r["step_v_max"] > 5.0

test "a load step reports the release as an overshoot":
  if not haveNgspice:
    skip()
  else:
    # Damped: on a lossless rail a release timed a whole number of periods
    # after the step cancels the ring, making the overshoot depend on the
    # hold time. 200 mohm ESR gives Q ~1.6, so each edge is its own transient
    # and the two mirror each other.
    var spec = defaultLoadStepSpec()
    spec.iFrom = 0.0
    spec.iTo = 1.0
    spec.tSettle = 1.0e-3
    spec.tEdge = 1.0e-7
    spec.tHold = 1.0e-3         ## five ring periods; long since decayed
    spec.tRecover = 6.0e-4
    let r = analyzeLoadStep(lcRail(esr = "0.2"), "vout", spec)

    check r.hasMeasurement("step_overshoot_v")
    check r["step_overshoot_v"] > 0.0
    # Mirror images, to within the load-regulation shift.
    check abs(r["step_overshoot_v"] - r["step_droop_v"]) /
          r["step_droop_v"] < 0.25

test "a load step that holds to the end of the run reports no release":
  if not haveNgspice:
    skip()
  else:
    var spec = defaultLoadStepSpec()
    spec.iFrom = 0.0
    spec.iTo = 0.5
    spec.tSettle = 1.0e-3
    spec.tEdge = 1.0e-7
    spec.tRecover = 3.0e-4
    let r = analyzeLoadStep(lcRail(), "vout", spec)
    # `tHold` is zero, so there's no falling edge and no overshoot.
    check not r.hasMeasurement("step_overshoot_v")
    check r.hasMeasurement("step_droop_v")

test "a resistive rail droops by dI * R and recovers at once":
  if not haveNgspice:
    skip()
  else:
    # 1 ohm behind a big bank: droop is dI * R with tau = R*C, no ring.
    let nl = newNetlist("r")
    let vin = addNet(nl, newNet("vin"))
    let vout = addNet(nl, newNet("vout"))
    let gnd = addNet(nl, newNet("0", ntGround))
    let v1 = addComponent(nl, newComponent("V1", kind = "voltage_source"))
    discard connect(v1, "+", vin)
    discard connect(v1, "-", gnd)
    v1.attrs["value"] = "DC 5"
    v1.attrs["rout"] = "0"
    v1.attrs["lout"] = "0"
    let r1 = addComponent(nl, newComponent("R1", kind = "resistor"))
    discard connect(r1, "1", vin)
    discard connect(r1, "2", vout)
    r1.attrs["value"] = "1"
    let c1 = addComponent(nl, newComponent("C1", kind = "capacitor"))
    discard connect(c1, "1", vout)
    discard connect(c1, "2", gnd)
    c1.attrs["value"] = "100u"
    c1.attrs["dielectric"] = "C0G"
    c1.attrs["esr"] = "1e-3"
    c1.attrs["esl"] = "1e-12"

    var spec = defaultLoadStepSpec()
    spec.iFrom = 0.0
    spec.iTo = 0.1
    spec.tSettle = 1.0e-3
    spec.tEdge = 1.0e-7
    spec.tRecover = 1.0e-3      ## ten time constants
    let r = analyzeLoadStep(nl, "vout", spec)

    # dI * R = 100 mV; monotone, so the worst excursion is the new level.
    check abs(r["step_droop_v"] - 0.1) / 0.1 < 0.05
    check abs(r["step_v_min"] - 4.9) < 0.01
    # Measured against the level under the new load, so an offset isn't a
    # failure to recover.
    check r["step_recover_s"] < 5.0e-4

test "a load step of zero magnitude is refused rather than measured":
  var spec = defaultLoadStepSpec()
  spec.iFrom = 0.5
  spec.iTo = 0.5
  spec.tSettle = 1.0e-3
  let r = analyzeLoadStep(lcRail(), "vout", spec)
  check not r.hasMeasurement("step_droop_v")
  check r.issues.anyIt(it.kind == KindStepNotSeen)
