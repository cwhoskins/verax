import std/[math, os, sequtils, strutils, tables, unittest]

import verax/netlist
import verax/analysis/analyses/startup

let haveNgspice = findExe("ngspice").len > 0

const
  RLoad = 100.0      # ohm
  CBulk = 10.0e-6    # F
  VOut = 3.3

proc supply(): Netlist =
  ## VIN -> U1 (regulator) -> 3V3, loaded by C1 and R1.
  result = newNetlist("supply")
  let vin = addNet(result, newNet("vin", ntPower))
  vin.attrs["voltage"] = "5.0"
  let v3 = addNet(result, newNet("v3v3", ntPower))
  v3.attrs["voltage"] = "3.3"
  let gnd = addNet(result, newNet("0", ntGround))

  let u1 = addComponent(result, newComponent("U1", kind = "regulator"))
  discard connect(u1, "IN", vin, ptPower)
  discard connect(u1, "OUT", v3, ptPower)
  discard connect(u1, "GND", gnd, ptGround)

  let c1 = addComponent(result, newComponent("C1", kind = "capacitor"))
  discard connect(c1, "1", v3, ptPassive)
  discard connect(c1, "2", gnd, ptPassive)
  c1.attrs["value"] = "10u"

  let r1 = addComponent(result, newComponent("R1", kind = "resistor"))
  discard connect(r1, "1", v3, ptPassive)
  discard connect(r1, "2", gnd, ptPassive)
  r1.attrs["value"] = "100"

test "an unknown regulator or output net is rejected by name":
  expect(NetlistError):
    discard analyzeStartup(supply(), "U9", "v3v3")
  expect(NetlistError):
    discard analyzeStartup(supply(), "U1", "nosuchnet")

test "an unstated regulated voltage raises rather than being guessed":
  let nl = supply()
  nl.nets["v3v3"].attrs.del("voltage")
  expect(NetlistError):
    discard analyzeStartup(nl, "U1", "v3v3")

if not haveNgspice:
  echo "SKIP: ngspice not found on PATH, skipping real-simulation tests"
else:
  test "the output network is collected, the upstream rail is cut":
    let r = analyzeStartup(supply(), "U1", "v3v3")
    # The load cap and resistor are on the (seeded) output rail, so they are
    # part of the fragment; nothing else in the design is.
    check abs(r["final_v"] - VOut) / VOut < 0.01

  test "rise time and inrush match the closed-form ramp response":
    # Driving R||C with a linear ramp of slope k = V/tss, the capacitor
    # current settles to a constant k*C once the initial transient decays
    # (tau = R*C = 1 ms here, comparable to the ramp, so the peak is reached
    # near the end of the ramp).
    var spec = defaultStartupSpec()
    spec.softStart = 10.0e-3        # >> tau, so the ramp dominates
    let r = analyzeStartup(supply(), "U1", "v3v3", spec = spec)

    # 10-90% of a linear ramp takes 80% of the ramp time.
    check abs(r["rise_time_10_90"] - 0.8 * spec.softStart) / (0.8 * spec.softStart) < 0.05

    # Peak current = ramp charging current + load current at the top:
    #   C*dV/dt + V/R
    let expectI = CBulk * (VOut / spec.softStart) + VOut / RLoad
    check abs(r["inrush_peak"] - expectI) / expectI < 0.05

    # A linear ramp into an RC does not overshoot.
    check r["overshoot_pct"] < 0.1

  test "inrush splits into a ramp-rate term and a constant load term":
    # Only the capacitor's share scales with dV/dt; the load's V/R does not.
    # Subtracting the load current recovers C*dV/dt for each ramp, which is
    # the quantity a designer actually trades against soft-start time.
    let iLoad = VOut / RLoad
    var slow = defaultStartupSpec()
    slow.softStart = 10.0e-3
    var fast = defaultStartupSpec()
    fast.softStart = 20.0e-3

    let iSlow = analyzeStartup(supply(), "U1", "v3v3", spec = slow)["inrush_peak"]
    let iFast = analyzeStartup(supply(), "U1", "v3v3", spec = fast)["inrush_peak"]
    check abs((iSlow - iLoad) - CBulk * VOut / slow.softStart) / (CBulk * VOut / slow.softStart) < 0.05
    check abs((iFast - iLoad) - CBulk * VOut / fast.softStart) / (CBulk * VOut / fast.softStart) < 0.05
    check iSlow > iFast

  test "an inrush limit is reported, and says the limit itself is not modelled":
    var spec = defaultStartupSpec()
    spec.softStart = 1.0e-3
    spec.currentLimit = 0.010
    let r = analyzeStartup(supply(), "U1", "v3v3", spec = spec)
    var found = false
    for i in r.issues:
      if i.kind == KindInrushExceedsLimit:
        found = true
        check "no current limit is modelled" in i.message
    check found

  test "the assumed ramp is stated as an assumption":
    let r = analyzeStartup(supply(), "U1", "v3v3")
    var stated = false
    for a in r.assumptions:
      if "soft-start" in $a and "no control loop" in $a: stated = true
    check stated

  test "an LC output filter overshoots, and the overshoot is flagged":
    # An inductor between the regulator and the bulk cap makes a series LC
    # with the 100 ohm load: zeta = (R_L/2)*sqrt(C/L) is well under 1 here, so
    # the rail rings past its target.
    let nl = supply()
    let v3 = nl.nets["v3v3"]
    let gnd = nl.nets["0"]
    let mid = addNet(nl, newNet("v3_pre", ntSignal))
    # Rewire the regulator output through the inductor.
    disconnect(nl.components["U1"].pins["OUT"])
    connect(nl.components["U1"].pins["OUT"], mid)
    let l1 = addComponent(nl, newComponent("L1", kind = "inductor"))
    discard connect(l1, "1", mid, ptPassive)
    discard connect(l1, "2", v3, ptPassive)
    l1.attrs["value"] = "100u"
    discard gnd

    var spec = defaultStartupSpec()
    spec.softStart = 100.0e-6      # fast enough to excite the LC
    spec.tStop = 5.0e-3
    # Driven at the regulator pin, judged at the load past the inductor.
    let r = analyzeStartup(nl, "U1", "v3_pre", "v3v3", spec)
    check r["overshoot_pct"] > 5.0
    var flagged = false
    for i in r.issues:
      if i.kind == KindOvershoot: flagged = true
    check flagged

  test "a rail that never reaches target is an error, not a quiet wrong number":
    var spec = defaultStartupSpec()
    spec.softStart = 1.0e-3
    spec.tStop = 50.0e-6           # ends 5% into the ramp
    spec.tStep = 1.0e-7
    let r = analyzeStartup(supply(), "U1", "v3v3", spec = spec)
    var found = false
    for i in r.issues:
      if i.kind == KindDidNotReachTarget:
        found = true
        check i.severity == sevError
    check found

suite "loads that carry no model":
  proc railWithLoad(loadKind: string): Netlist =
    result = newNetlist("b")
    let vin = addNet(result, newNet("vin", ntPower))
    let vdd = addNet(result, newNet("vdd", ntPower))
    let gnd = addNet(result, newNet("0", ntGround))
    vdd.attrs["voltage"] = "3.3"
    let u1 = addComponent(result, newComponent("U1", kind = "regulator"))
    discard connect(u1, "IN", vin, ptPower)
    discard connect(u1, "OUT", vdd, ptPower)
    discard connect(u1, "GND", gnd, ptGround)
    let c1 = addComponent(result, newComponent("C1", kind = "capacitor"))
    discard connect(c1, "1", vdd, ptPassive)
    discard connect(c1, "2", gnd, ptPassive)
    c1.attrs["value"] = "22u"
    let u2 = addComponent(result, newComponent("U2", kind = loadKind))
    discard connect(u2, "VDD", vdd, ptPower)
    discard connect(u2, "VSS", gnd, ptGround)

  test "a load with no model is stood in for rather than cut away":
    let r = analyzeStartup(railWithLoad("mcu"), "U1", "vdd")
    var stoodIn = false
    for a in r.assumptions:
      if "U2.VDD" in $a and "zin" in $a: stoodIn = true
    check stoodIn
    check abs(r["final_v"] - 3.3) < 0.05

  test "the regulator itself is never replaced by the generic stand-in":
    # It is excluded from the pass on purpose: `analyzeStartup` stands it up
    # as a soft-start ramp, and the behavioural regulator model would quietly
    # overwrite the one thing this analysis exists to measure.
    let r = analyzeStartup(railWithLoad("mcu"), "U1", "vdd")
    var ramped = false
    for a in r.assumptions:
      if "U1" in $a and "softStart" in $a: ramped = true
    check ramped
    check r["rise_time_10_90"] > 0.0

  test "the older cut-at-the-boundary behaviour is still reachable":
    var spec = defaultStartupSpec()
    spec.modelUnmodelledParts = false
    let r = analyzeStartup(railWithLoad("mcu"), "U1", "vdd", spec = spec)
    var cut = false
    for a in r.assumptions:
      if "U2" in $a and "cut at the boundary" in $a: cut = true
    check cut

  proc railWithFilteredRail(): Netlist =
    ## A regulated rail with a second, filtered rail one ferrite downstream --
    ## the shape any board with a separate analog supply takes.
    result = newNetlist("b")
    let vin = addNet(result, newNet("vin", ntPower))
    let vdd = addNet(result, newNet("vdd", ntPower))
    let vdda = addNet(result, newNet("vdda", ntPower))
    let gnd = addNet(result, newNet("0", ntGround))
    vdd.attrs["voltage"] = "3.3"
    vdda.attrs["voltage"] = "3.3"
    let u1 = addComponent(result, newComponent("U1", kind = "regulator"))
    discard connect(u1, "IN", vin, ptPower)
    discard connect(u1, "OUT", vdd, ptPower)
    discard connect(u1, "GND", gnd, ptGround)
    for (desig, kind, p1, p2, value) in [("C1", "capacitor", vdd, gnd, "22u"),
                                         ("FB1", "inductor", vdd, vdda, "600n"),
                                         ("C2", "capacitor", vdda, gnd, "1u")]:
      let c = addComponent(result, newComponent(desig, kind = kind))
      discard connect(c, "1", p1, ptPassive)
      discard connect(c, "2", p2, ptPassive)
      c.attrs["value"] = value
    let u2 = addComponent(result, newComponent("U2", kind = "mcu"))
    discard connect(u2, "VDD", vdd, ptPower)
    discard connect(u2, "VSS", gnd, ptGround)

  test "a rail downstream of the regulator is not stood up as an ideal source":
    # Nothing downstream is at its nominal voltage during start-up -- a rail
    # ramping from zero is the premise. Terminating `vdda` at 3.3 V while
    # `vdd` ramps from zero drives current backwards through FB1 into it: on
    # a real design that reported 2.8 kA against a true 163 mA.
    let r = analyzeStartup(railWithFilteredRail(), "U1", "vdd")
    check r["inrush_peak"] < 5.0
    check abs(r["final_v"] - 3.3) < 0.05

  test "the same inrush is measured wherever the rail is judged":
    # Judging past the filter changes the seed set, and used to change the
    # answer by four orders of magnitude.
    let atOutput = analyzeStartup(railWithFilteredRail(), "U1", "vdd")
    let atFiltered = analyzeStartup(railWithFilteredRail(), "U1", "vdd", "vdda")
    check abs(atOutput["inrush_peak"] - atFiltered["inrush_peak"]) /
          atFiltered["inrush_peak"] < 0.05

  test "the rail feeding the regulator's input keeps its ideal source":
    # The walk crosses passive parts only, so it stops at the regulator. The
    # input rail genuinely is up before start-up begins.
    let r = analyzeStartup(railWithFilteredRail(), "U1", "vdd")
    check abs(r["final_v"] - 3.3) < 0.05

  test "inrush says where it was probed, because that is not the subject":
    # An assertion's subject does two jobs: it says what the claim is about,
    # and it selects the analysis setup. Inrush is probed on the source
    # feeding the regulator's output whatever the subject says -- while the
    # subject still has to name the *judged* net, because that is what the
    # isolation seeds on. Both are right and they are not the same net.
    let r = analyzeStartup(railWithFilteredRail(), "U1", "vdd", "vdda")
    var stated = false
    for m in r.measurements:
      if m.name == "inrush_peak":
        check m.at == "net 'vdd'"
        stated = true
    check stated

  test "a measurement taken on the subject says nothing extra":
    let r = analyzeStartup(railWithFilteredRail(), "U1", "vdd", "vdda")
    for m in r.measurements:
      if m.name in ["final_v", "overshoot_pct", "rise_time_10_90"]:
        check m.at.len == 0

# --- a regulator that brings its own model ------------------------------

proc buildRamp(nl: Netlist, old: Component): Component {.nimcall.} =
  ## Stands the regulator up as a source of its own, through the `build`
  ## route rather than through `kind`/`pinNets`.
  ##
  ## `build` exists because `kind`/`pinNets` cannot express an XSPICE code
  ## model -- there is a `.MODEL` card to register, an ordered port binding
  ## and port text to render. Nothing here needs any of that; what it does
  ## need is to be *the same route*, so that `analyzeStartup` taking it is
  ## covered without a configured ngspice source tree in the build.
  let outNet = old.pins["OUT"].net
  let gnd = nl.nets["0"]
  removeComponent(nl, old.designator)
  result = addComponent(nl, newComponent("VOWN", kind = "voltage_source"))
  discard connect(result, "+", outNet, ptPower)
  discard connect(result, "-", gnd, ptGround)
  # Twice as slow as `StartupSpec.softStart`'s default, which is how the run
  # below tells which of the two ramps actually ran.
  result.attrs["value"] = "PWL(0 0 2m 3.3)"

test "a regulator's own build-route model is what runs, not the assumed ramp":
  if not haveNgspice:
    skip()
  else:
    let nl = supply()
    addSimModel(nl.components["U1"], newSimReplacement(buildRamp, name = "own"))
    var spec = defaultStartupSpec()
    spec.tStop = 6.0e-3
    let r = analyzeStartup(nl, "U1", "v3v3", spec = spec)

    # 10-90% of a linear 2 ms ramp is 1.6 ms. The assumed ramp is 1 ms, so
    # the two answers cannot be confused for each other.
    check abs(r["rise_time_10_90"] - 1.6e-3) / 1.6e-3 < 0.1
    check r.assumptions.anyIt("builds its own stand-in" in it.detail)
    # And the assumed ramp is not reported as though it had been used.
    check not r.assumptions.anyIt(it.key == "softStart")

test "a part that starts itself is started from zero, not from a solved bias":
  if not haveNgspice:
    skip()
  else:
    # An operating point finds the state the soft start settles *to*, so the
    # `.tran` would begin at the end of the ramp and report a rise time of
    # zero for a part that takes milliseconds.
    let nl = supply()
    addSimModel(nl.components["U1"], newSimReplacement(buildRamp, name = "own"))
    var spec = defaultStartupSpec()
    spec.tStop = 6.0e-3
    check analyzeStartup(nl, "U1", "v3v3", spec = spec).assumptions
            .anyIt("uic" in it.detail)

    # ...and the assumed ramp, which has no state, keeps its operating point.
    check not analyzeStartup(supply(), "U1", "v3v3", spec = spec).assumptions
                .anyIt("uic" in it.detail)

test "the inrush probe goes on the pin that is actually on the output net":
  if not haveNgspice:
    skip()
  else:
    # It used to assume a pin named `"+"`, which is the pin of the PWL source
    # this analysis builds and is not one any other model has to have.
    let nl = supply()
    addSimModel(nl.components["U1"], newSimReplacement(buildRamp, name = "own"))
    var spec = defaultStartupSpec()
    spec.tStop = 6.0e-3
    let r = analyzeStartup(nl, "U1", "v3v3", spec = spec)
    # C = 10 uF charged at 3.3 V / 2 ms is 16.5 mA, plus the load's 33 mA.
    check abs(r["inrush_peak"] - 0.0495) / 0.0495 < 0.15

test "a stand-in with no pin on the output net reports no inrush rather than zero":
  if not haveNgspice:
    skip()
  else:
    # The ordinary case is a switching regulator: it drives a switch node
    # into an inductor, so the current reaching the rail is the inductor's
    # and there is no single branch to put a probe in series with.
    let nl = supply()
    var sr = newSimReplacement("voltage_source", name = "elsewhere")
    sr.pinNets["+"] = "vin"
    sr.pinNets["-"] = "0"
    sr.attrs["value"] = "DC 5"
    addSimModel(nl.components["U1"], sr)
    var spec = defaultStartupSpec()
    spec.tStop = 6.0e-3
    let r = analyzeStartup(nl, "U1", "v3v3", spec = spec)
    check not r.hasMeasurement("inrush_peak")
    check r.assumptions.anyIt("no inrush current was measured" in it.detail)
