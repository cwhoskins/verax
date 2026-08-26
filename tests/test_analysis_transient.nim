import std/[math, os, sequtils, strutils, tables, unittest]

import nimcir/netlist/dsl
import nimcir/spice/transform
import nimcir/spice/ngspice
import nimcir/analysis/transient

let haveNgspice = findExe("ngspice").len > 0

proc rcRail(): Netlist =
  ## A square wave through an RC into a load: something that settles to a
  ## known average with a known ripple on it, and whose answer is closed form.
  ##
  ## `PULSE(0 10 0 1n 1n 5u 10u)` is 50% duty at 100 kHz, so the average is
  ## 5 V. R = 100 ohm and C = 10 uF gives tau = 1 ms, and the ripple across
  ## the capacitor is V*d*(1-d)*T/(R*C) = 10*0.25*10u/1m = 25 mV.
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
  # Class 1, so the capacitance the arithmetic above assumes is the one the
  # simulation uses -- a Class 2 part would be bias-derated out from under it.
  c1.attrs["dielectric"] = "C0G"
  # Stated rather than left to the package-typical defaults, because those are
  # not small here: 100 mA of ripple current through a typical ESR puts more
  # on this node than the capacitance does, and the closed form above would be
  # measuring the stand-in instead of the filter.
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

    # 5 V average, from a 50% duty square wave through a filter whose corner
    # is far below the drive.
    check abs(r["settled_v"] - 5.0) < 0.05
    # V*d*(1-d)*T/(R*C) = 25 mV, and the measurement is peak-to-peak.
    check abs(r["ripple_pp"] - 0.025) / 0.025 < 0.15
    check r["settled_max"] > r["settled_min"]
    # The start-up ramp reached 0 V at t = 0 and 5 V here; measuring from the
    # beginning would have reported the whole rise as ripple.
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
    # A part carrying a steady-state model gets it here and gets its default
    # everywhere else. Proven by making the two disagree about the answer,
    # which is the only way to tell which one ran.
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
    # Ten times the resistance, so ten times the time constant and a tenth of
    # the ripple.
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
  ## A parallel LC that rings at a frequency closed form gives exactly:
  ## 1/(2*pi*sqrt(1m * 1u)) = 5032.92 Hz.
  ##
  ## Nothing drives it, which is the point -- it has no operating point to
  ## start from and sits at zero forever unless something puts energy in.
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
  # Class 1 and a stated ESR, for the same reason `rcRail` states them: the
  # package-typical defaults would put a damping term into a circuit whose
  # answer is being checked against closed form.
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

    # `NaN` rather than 0 Hz: an oscillator sitting at its operating point is
    # a flat line, and reporting a frequency of zero for it would be a
    # measurement where there was none.
    check r["osc_freq"].isNaN
    check r.issues.len == 1
    check r.issues[0].kind == KindDidNotOscillate
    check "initialConditions" in r.issues[0].message

test "a node driven periodically needs no kick at all":
  if not haveNgspice:
    skip()
  else:
    # The `kick` is optional on the role for this reason: plenty of circuits
    # are periodic without one, and `uic` is not free.
    var spec = defaultTransientSpec()
    spec.tSettle = 5.0e-3
    spec.tWindow = 5.0e-4      ## fifty periods of the 100 kHz drive
    let r = analyzeOscillation(rcRail(), "vout", spec)
    check abs(r["osc_freq"] - 1.0e5) / 1.0e5 < 0.01
    check not r.assumptions.anyIt("uic" in it.detail)

# --- device currents ----------------------------------------------------

suite "branch current vector names":
  test "the two shapes are told apart by whether the current is an unknown":
    # A voltage source, an inductor and the controlled sources that carry a
    # branch equation are solved *for* their current, so it is already in the
    # default saved set and no `.save` is needed.
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
    # `spice/flatten` makes `LXA.L1` an ordinary designator, and ngspice reads
    # it literally in both spellings.
    check branchCurrentVector("LXA.L1").vector == "i(LXA.L1)"
    check branchCurrentVector("RXA.R1").saveTerm == "@RXA.R1[i]"

  test "a three-terminal device is refused rather than guessed at":
    # Collector, emitter and base are three different currents and "the
    # current through Q1" does not say which. Picking one silently would
    # answer a question nobody asked.
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
    ## The same square-wave drive as `rcRail`, through a series inductor into
    ## a resistive load: a current with a known average and a known triangle
    ## on it, and two parts carrying exactly the same one.
    ##
    ## 10 V at 50% duty into R1 = 100 ohm and RL = 100 ohm is 5 V average
    ## across a 200 ohm chain, so the settled current is 25 mA and every part
    ## in the chain carries the same one.
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

      # 2.5 V average across a 100 ohm load, fed through 100 ohm.
      check abs(valueFor(r, "i_avg", "L1") - 0.025) / 0.025 < 0.02
      # R1 is in series with L1: same current, to the last digit.
      check abs(valueFor(r, "i_rms", "R1") - valueFor(r, "i_rms", "L1")) < 1e-9

      # **The sign of a branch current is a deck convention.** ngspice reports
      # a voltage source's current positive when it flows *into* the +
      # terminal, so V1 delivering 25 mA reads negative -- and the three
      # rating-facing magnitudes are identical to L1's regardless.
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
      # A triangle on a DC pedestal: the peak is above the RMS is above the
      # average, and the peak-to-peak is what separates them.
      check peak > rms
      check rms > avg
      check abs(pp - (valueFor(r, "i_max", "L1") -
                      valueFor(r, "i_min", "L1"))) < 1e-12
      check abs(peak - (avg + pp / 2.0)) / peak < 0.05

  test "one run answers every part, which is what makes a claim affordable":
    if not haveNgspice:
      skip()
    else:
      # Four parts, one `.tran`. The alternative -- one run per part -- would
      # simulate a switching model four times to read one set of waveforms
      # four ways.
      let r = analyzeCurrent(lcRail(), ["L1", "R1", "RL", "C1"], settledSpec())
      check r.raw.vectors.len > 0
      for part in ["L1", "R1", "RL", "C1"]:
        check not valueFor(r, "i_rms", part).isNaN
      # The capacitor carries the ripple and none of the DC; the load carries
      # the DC and almost none of the ripple.
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
      # **`NaN`, not 1.0 and not 0.** A part that states no rating is one
      # nobody has chosen yet, not one with infinite headroom -- and `NaN`
      # reads downstream as *not evaluated* rather than as a pass.
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
      # The parts that *can* be measured still are: one unmeasurable subject
      # must not sink the rest of the batch.
      check not valueFor(r, "i_rms", "L1").isNaN
      check valueFor(r, "i_rms", "Q1").isNaN
      check r.issues.anyIt(it.kind == KindNoCurrent and "Q1" in it.message)

  test "a part a model pass dissolved is reported, not raised":
    if not haveNgspice:
      skip()
    else:
      # The netlist reaching the deck is a materialized, flattened,
      # model-substituted copy, so a part the *design* has can be gone by the
      # time there is a current to read. A ferrite bead becomes a series DCR
      # into a parallel R-L-C and leaves no device carrying its designator.
      let nl = lcRail()
      let fb1 = addComponent(nl, newComponent("FB1", kind = "ferrite_bead"))
      discard connect(fb1, "1", nl.nets["vout"])
      discard connect(fb1, "2", nl.nets["0"])
      fb1.attrs["value"] = "600"

      let r = analyzeCurrent(nl, ["L1", "FB1"], settledSpec())
      check not valueFor(r, "i_rms", "L1").isNaN
      check valueFor(r, "i_rms", "FB1").isNaN
      check r.issues.anyIt(it.kind == KindNoCurrent and "FB1" in it.message)
