import std/[os, tables, unittest]

import nimcir/netlist/dsl
import nimcir/spice/transform
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
