import std/[math, os, strutils, tables, unittest, sequtils]

import verax/netlist/dsl
import verax/netlist/graph
import verax/analysis/analyses/opamp

let haveNgspice = findExe("ngspice").len > 0

proc nonInverting(rf = "9k", rg = "1k"): Netlist =
  ## Gain of 1 + Rf/Rg = 10 by default.
  netlist("amp"):
    net vcc, kind = ntPower, voltage = "5.0"
    net gnd, kind = ntGround, name = "0"
    net vin, kind = ntSignal
    net vout, kind = ntSignal
    net vfb, kind = ntSignal

    component U1, kind = "opamp":
      pin "IN+", vin, kind = ptInput
      pin "IN-", vfb, kind = ptInput
      pin "OUT", vout, kind = ptOutput
      pin "V+", vcc, kind = ptPower
      pin "V-", gnd, kind = ptGround

    component RF, kind = "resistor", value = rf:
      pin "1", vout, kind = ptPassive
      pin "2", vfb, kind = ptPassive
    component RG, kind = "resistor", value = rg:
      pin "1", vfb, kind = ptPassive
      pin "2", gnd, kind = ptPassive

test "the +/-/OUT pins are found from tolerant name variants":
  let nl = nonInverting()
  let p = findOpAmpPins(nl.components["U1"])
  check p.pos.name == "IN+"
  check p.neg.name == "IN-"
  check p.outp.name == "OUT"

test "unrecognizable pin names raise, naming what was actually there":
  let nl = netlist("odd"):
    net a, kind = ntSignal
    component U1, kind = "opamp":
      pin "PIN1", a, kind = ptInput
      pin "PIN2", a, kind = ptOutput
  try:
    discard findOpAmpPins(nl.components["U1"])
    check false
  except NetlistError as e:
    check "PIN1" in e.msg
    check "PIN2" in e.msg

test "checkFeedback passes a resistive feedback network":
  check checkFeedback(nonInverting(), "U1").len == 0

test "checkFeedback flags a missing feedback path":
  let nl = nonInverting()
  removeComponent(nl, "RF")
  let issues = checkFeedback(nl, "U1")
  check issues.len == 1
  check issues[0].kind == KindNoFeedback
  check issues[0].severity == sevError
  check "open-loop" in issues[0].message

test "a capacitive (integrator) feedback path counts as feedback":
  let nl = netlist("integrator"):
    net gnd, kind = ntGround, name = "0"
    net vin, kind = ntSignal
    net vout, kind = ntSignal
    net vfb, kind = ntSignal
    component U1, kind = "opamp":
      pin "IN+", gnd, kind = ptInput
      pin "IN-", vfb, kind = ptInput
      pin "OUT", vout, kind = ptOutput
    component C1, kind = "capacitor", value = "1n":
      pin "1", vout, kind = ptPassive
      pin "2", vfb, kind = ptPassive
    component R1, kind = "resistor", value = "10k":
      pin "1", vin, kind = ptPassive
      pin "2", vfb, kind = ptPassive
  # A DC-conductive-only walk would call this open-loop; it is not.
  check checkFeedback(nl, "U1").len == 0

test "a path back through another active device is not feedback":
  let nl = netlist("buffered"):
    net gnd, kind = ntGround, name = "0"
    net vin, kind = ntSignal
    net vout, kind = ntSignal
    net vbuf, kind = ntSignal
    net vfb, kind = ntSignal
    component U1, kind = "opamp":
      pin "IN+", vin, kind = ptInput
      pin "IN-", vfb, kind = ptInput
      pin "OUT", vout, kind = ptOutput
    component Q1, kind = "bjt":
      pin "C", vout, kind = ptPassive
      pin "B", vbuf, kind = ptPassive
      pin "E", vfb, kind = ptPassive
  check checkFeedback(nl, "U1").len == 1

test "analyzeOpAmpResponse returns the structural finding without simulating":
  let nl = nonInverting()
  removeComponent(nl, "RF")
  let r = analyzeOpAmpResponse(nl, "U1", "vin", "vout")
  check r.issues.len == 1
  check r.issues[0].kind == KindNoFeedback
  check r.measurements.len == 0

if not haveNgspice:
  echo "SKIP: ngspice not found on PATH, skipping real-simulation tests"
else:
  test "closed-loop gain and bandwidth match GBW/gain":
    var spec = defaultOpAmpSpec()
    spec.idealAol = 1.0e5
    spec.idealGbw = 1.0e6
    let r = analyzeOpAmpResponse(nonInverting(), "U1", "vin", "vout", spec)

    # 1 + 9k/1k = 10 -> 20 dB, and bandwidth = GBW/gain = 100 kHz.
    check abs(r["gain_dc_db"] - 20.0) < 0.05
    check abs(r["bw_3db"] - 1.0e5) / 1.0e5 < 0.02
    check abs(r["gain_bw_product"] - spec.idealGbw) / spec.idealGbw < 0.03
    # A single-pole loop cannot peak.
    check r["peaking_db"] < 0.01

  test "changing the feedback ratio moves gain and bandwidth reciprocally":
    var spec = defaultOpAmpSpec()
    let r = analyzeOpAmpResponse(nonInverting("99k", "1k"), "U1", "vin", "vout", spec)
    check abs(r["gain_dc_db"] - 40.0) < 0.05          # gain of 100
    check abs(r["bw_3db"] - 1.0e4) / 1.0e4 < 0.02     # GBW/100

  test "the substituted ideal model is declared as an assumption":
    let r = analyzeOpAmpResponse(nonInverting(), "U1", "vin", "vout")
    var stated = false
    for a in r.assumptions:
      if "ideal single-pole" in $a and "second pole" in $a: stated = true
    check stated

  test "an insufficient-bandwidth requirement is reported":
    var spec = defaultOpAmpSpec()
    spec.minBandwidth = 1.0e6
    let r = analyzeOpAmpResponse(nonInverting(), "U1", "vin", "vout", spec)
    var found = false
    for i in r.issues:
      if i.kind == KindInsufficientBandwidth: found = true
    check found

  test "a single-pole loop has 90 degrees of phase margin":
    var spec = defaultOpAmpSpec()
    spec.idealAol = 1.0e5
    spec.idealGbw = 1.0e6
    let r = analyzeLoopGain(nonInverting(), "U1", "vin", "vout", spec)

    # Loop gain T = Aol*beta, beta = 1/10, so T(DC) = 1e4 = 80 dB and it
    # crosses 0 dB at GBW*beta = 100 kHz.
    check abs(r["loop_gain_dc_db"] - 80.0) < 0.1
    check abs(r["crossover_hz"] - 1.0e5) / 1.0e5 < 0.02
    # One pole can contribute at most 90 degrees of lag.
    check abs(r["phase_margin_deg"] - 90.0) < 1.0

  test "a second pole in the loop eats the phase margin and is flagged":
    # A capacitor from the feedback node to ground puts a second pole inside
    # the loop, at 1/(2*pi*(RF||RG)*C).
    proc withFeedbackCap(value: string): Netlist =
      result = nonInverting()
      let cf = addComponent(result, newComponent("CF", kind = "capacitor"))
      discard connect(cf, "1", result.nets["vfb"], ptPassive)
      discard connect(cf, "2", result.nets["0"], ptPassive)
      cf.attrs["value"] = value

    let r = analyzeLoopGain(withFeedbackCap("10n"), "U1", "vin", "vout")
    check r["phase_margin_deg"] < 45.0
    var flagged = false
    for i in r.issues:
      if i.kind == KindLowPhaseMargin:
        flagged = true
        check "ringing" in i.message
    check flagged

    # More capacitance moves the pole lower, so it must cost more margin and
    # pull crossover down -- a stronger claim than any single threshold.
    let mild = analyzeLoopGain(withFeedbackCap("2n"), "U1", "vin", "vout")
    let severe = analyzeLoopGain(withFeedbackCap("100n"), "U1", "vin", "vout")
    check mild["phase_margin_deg"] > r["phase_margin_deg"]
    check r["phase_margin_deg"] > severe["phase_margin_deg"]
    check mild["crossover_hz"] > severe["crossover_hz"]

    # Two poles approach -180 degrees asymptotically without ever reaching it,
    # so there is no finite frequency at which to read a gain margin. NaN is
    # the honest answer, not a large number.
    check r["gain_margin_db"].isNaN

  test "the same second pole shows up as closed-loop peaking":
    let nl = nonInverting()
    let cf = addComponent(nl, newComponent("CF", kind = "capacitor"))
    discard connect(cf, "1", nl.nets["vfb"], ptPassive)
    discard connect(cf, "2", nl.nets["0"], ptPassive)
    cf.attrs["value"] = "2n"
    let r = analyzeOpAmpResponse(nl, "U1", "vin", "vout")
    check r["peaking_db"] > 1.0
    var flagged = false
    for i in r.issues:
      if i.kind == KindGainPeaking: flagged = true
    check flagged

suite "a part inside the loop that carries no model":
  proc stage(midKind: string): Netlist =
    ## An inverting-ish stage whose feedback runs through `midKind`.
    result = newNetlist("amp")
    let vin = addNet(result, newNet("vin"))
    let vout = addNet(result, newNet("vout"))
    let vbuf = addNet(result, newNet("vbuf"))
    let vfb = addNet(result, newNet("vfb"))
    let gnd = addNet(result, newNet("0", ntGround))
    let u = addComponent(result, newComponent("U1", kind = "opamp"))
    discard connect(u, "IN+", vin, ptInput)
    discard connect(u, "IN-", vfb, ptInput)
    discard connect(u, "OUT", vout, ptOutput)
    let b = addComponent(result, newComponent("U2", kind = midKind))
    discard connect(b, "IN", vout, ptInput)
    discard connect(b, "OUT", vbuf, ptOutput)
    let rf = addComponent(result, newComponent("R1", kind = "resistor"))
    discard connect(rf, "1", vbuf, ptPassive)
    discard connect(rf, "2", vfb, ptPassive)
    rf.attrs["value"] = "10k"
    let rg = addComponent(result, newComponent("R2", kind = "resistor"))
    discard connect(rg, "1", vfb, ptPassive)
    discard connect(rg, "2", gnd, ptPassive)
    rg.attrs["value"] = "10k"

  test "a buffer in the feedback path does not read as an open loop":
    # The static walk crosses it because its direction and gain are known
    # from its registration -- not because active parts are now waved through.
    check checkFeedback(stage("buffer"), "U1").len == 0

  test "a part whose behaviour is genuinely unknown still opens the loop":
    let issues = checkFeedback(stage("mcu"), "U1")
    check issues.len == 1
    check issues[0].kind == KindNoFeedback

  test "the loop actually closes in simulation, with the right numbers":
    # beta = 1/2 through the divider, so a 1 MHz GBW crosses at 500 kHz, and
    # a single-pole loop has 90 degrees of margin and no gain margin at all.
    let r = analyzeLoopGain(stage("buffer"), "U1", "vin", "vout")
    check abs(r["crossover_hz"] - 500.0e3) / 500.0e3 < 0.1
    check abs(r["phase_margin_deg"] - 90.0) < 5.0
    check r["gain_margin_db"].isNaN

  test "the substituted buffer says what it assumed":
    let r = analyzeLoopGain(stage("buffer"), "U1", "vin", "vout")
    var saidUnity = false
    for a in r.assumptions:
      if "U2" in $a and "gain" in $a and "unity" in $a: saidUnity = true
    check saidUnity

  test "a stated gain is used instead of unity":
    let nl = stage("buffer")
    nl.components["U2"].attrs["gain"] = "0.5"
    let r = analyzeLoopGain(nl, "U1", "vin", "vout")
    # Half the feedback returns, so the loop crosses an octave lower.
    check abs(r["crossover_hz"] - 250.0e3) / 250.0e3 < 0.1

  test "the amplifier itself is never replaced by the generic stand-in":
    let r = analyzeLoopGain(stage("buffer"), "U1", "vin", "vout")
    var macromodelled = false
    for a in r.assumptions:
      if "U1" in $a and "gbw" in $a: macromodelled = true
    check macromodelled

  proc sallenKey(): Netlist =
    ## A unity-gain Sallen-Key low-pass: f0 = 21.3 kHz at Q = 0.549. C1
    ## returns to the *output*, which is a second feedback path and the
    ## reason the loop cannot be opened at the inverting input alone.
    result = newNetlist("sk")
    let gnd = addNet(result, newNet("0", ntGround))
    let vin = addNet(result, newNet("vin"))
    let na = addNet(result, newNet("na"))
    let nb = addNet(result, newNet("nb"))
    let vout = addNet(result, newNet("vout"))
    for (desig, p1, p2, kind, value) in [("R1", vin, na, "resistor", "10k"),
                                         ("R2", na, nb, "resistor", "10k"),
                                         ("C1", na, vout, "capacitor", "820p"),
                                         ("C2", nb, gnd, "capacitor", "680p")]:
      let c = addComponent(result, newComponent(desig, kind = kind))
      discard connect(c, "1", p1, ptPassive)
      discard connect(c, "2", p2, ptPassive)
      c.attrs["value"] = value
    let u = addComponent(result, newComponent("U1", kind = "opamp"))
    discard connect(u, "IN+", nb, ptInput)
    discard connect(u, "IN-", vout, ptInput)
    discard connect(u, "OUT", vout, ptOutput)
    discard connect(u, "V-", gnd, ptGround)

  test "a loop the break did not open yields no phase margin, not 450 degrees":
    # `180 + phase at crossover` is only a phase margin if the break opened
    # the loop. Here it does not: the measured phase starts near +79 degrees
    # and climbs through +180 while |T| is still above 0 dB, and the naive
    # arithmetic reports 450 -- a number that is not a margin and that
    # satisfies every minimum a design could state.
    let r = analyzeLoopGain(sallenKey(), "U1", "vin", "vout")
    check r["phase_margin_deg"].isNaN
    check r["gain_margin_db"].isNaN
    check r.issues.anyIt(it.kind == KindLoopBreakInvalid)
    # The crossing itself is real and is still reported.
    check not r["crossover_hz"].isNaN

  test "a loop the break did open still measures its margin":
    # The guard must not fire on the ordinary case: a single-pole model in a
    # plain feedback network is exactly 90 degrees.
    for nl in [nonInverting(), nonInverting("99k", "1k")]:
      let r = analyzeLoopGain(nl, "U1", "vin", "vout")
      check not r["phase_margin_deg"].isNaN
      check abs(r["phase_margin_deg"] - 90.0) < 1.0
      check not r.issues.anyIt(it.kind == KindLoopBreakInvalid)

  test "a second amplifier in the path is modelled, so a cascade is measured":
    # Two Sallen-Key sections. Section 1 is damped and section 2 is peaky;
    # only their product is flat. With the upstream amplifier stood in for
    # by impedances to ground the path through it is gone, and this reported
    # 82 dB of peaking against a response that is flat to 20 kHz.
    let nl = sallenKey()
    let vout2 = addNet(nl, newNet("vout2"))
    let nc = addNet(nl, newNet("nc"))
    let nd = addNet(nl, newNet("nd"))
    for (desig, p1, p2, kind, value) in [("R3", nl.nets["vout"], nc, "resistor", "10k"),
                                         ("R4", nc, nd, "resistor", "10k"),
                                         ("C3", nc, vout2, "capacitor", "2.2n"),
                                         ("C4", nd, nl.nets["0"], "capacitor", "330p")]:
      let c = addComponent(nl, newComponent(desig, kind = kind))
      discard connect(c, "1", p1, ptPassive)
      discard connect(c, "2", p2, ptPassive)
      c.attrs["value"] = value
    let u2 = addComponent(nl, newComponent("U2", kind = "opamp"))
    discard connect(u2, "IN+", nd, ptInput)
    discard connect(u2, "IN-", vout2, ptInput)
    discard connect(u2, "OUT", vout2, ptOutput)
    discard connect(u2, "V-", nl.nets["0"], ptGround)

    var spec = defaultOpAmpSpec()
    spec.maxHops = 6
    let r = analyzeOpAmpResponse(nl, "U2", "vin", "vout2", spec)
    # 4th-order and near-Butterworth: flat, cornering just under 20 kHz.
    check r["peaking_db"] < 1.0
    check abs(r["bw_3db"] - 19.7e3) / 19.7e3 < 0.1

  proc acCoupledStage(): Netlist =
    ## A non-inverting stage whose gain leg is capacitively coupled -- the
    ## shape every single-supply amplifier takes. Midband gain is
    ## 1 + 9k/1k = 10 (20 dB) from about 100 Hz (the gain leg's zero, at
    ## 1/(2*pi*RG*CG)) up to the amplifier's own 100 kHz. Below that the
    ## stage falls back to unity, so its gain *at DC* is 0 dB by
    ## construction -- which is exactly what makes a DC-referenced figure
    ## useless here.
    result = newNetlist("ac")
    let gnd = addNet(result, newNet("0", ntGround))
    let vcc = addNet(result, newNet("vcc", ntPower))
    vcc.attrs["voltage"] = "5.0"
    let vin = addNet(result, newNet("vin"))
    let vfb = addNet(result, newNet("vfb"))
    let vg = addNet(result, newNet("vg"))
    let vout = addNet(result, newNet("vout"))
    let u = addComponent(result, newComponent("U1", kind = "opamp"))
    discard connect(u, "IN+", vin, ptInput)
    discard connect(u, "IN-", vfb, ptInput)
    discard connect(u, "OUT", vout, ptOutput)
    discard connect(u, "V+", vcc, ptPower)
    discard connect(u, "V-", gnd, ptGround)
    for (desig, p1, p2, kind, value) in [("RF", vout, vfb, "resistor", "9k"),
                                         ("RG", vg, gnd, "resistor", "1k"),
                                         ("CG", vfb, vg, "capacitor", "1.6u")]:
      let c = addComponent(result, newComponent(desig, kind = kind))
      discard connect(c, "1", p1, ptPassive)
      discard connect(c, "2", p2, ptPassive)
      c.attrs["value"] = value

  test "an AC-coupled stage reports its midband gain, not its DC gain":
    # This is the whole point of the band-referenced set. `gain_dc_db` is
    # correct and useless here: the gain-setting leg is capacitively coupled,
    # so the stage really does have unity gain at DC, by design.
    let r = analyzeOpAmpResponse(acCoupledStage(), "U1", "vin", "vout")
    check r["gain_dc_db"] < 1.5                   # essentially unity
    check abs(r["gain_max_db"] - 20.0) < 1.0      # 1 + 9k/1k
    # The low edge is the gain leg's zero, 1/(2*pi*1k*1.6u) = 99.5 Hz, and
    # the high edge is the amplifier's own GBW/gain = 100 kHz.
    check abs(r["f_lo_3db"] - 99.5) / 99.5 < 0.15
    check abs(r["f_hi_3db"] - 100.0e3) / 100.0e3 < 0.2
    check r["f_gain_max"] > r["f_lo_3db"]

  test "a DC-coupled stage keeps both references, and they agree":
    # Nothing was taken away: where the first swept point *is* the passband,
    # the DC-referenced and band-referenced answers are the same measurement.
    let r = analyzeOpAmpResponse(nonInverting(), "U1", "vin", "vout")
    check abs(r["gain_max_db"] - r["gain_dc_db"]) < 0.1
    check abs(r["f_hi_3db"] - r["bw_3db"]) / r["bw_3db"] < 0.05
    check r["f_lo_3db"].isNaN            # a DC-coupled stage has no low edge

  test "gain_at_f reports the gain at exactly the stated frequency":
    var spec = defaultOpAmpSpec()
    spec.gainAtFreq = 1000.0
    let r = analyzeOpAmpResponse(acCoupledStage(), "U1", "vin", "vout", spec)
    # Well inside the passband, so it is the midband gain.
    check abs(r["gain_at_f"] - 20.0) < 1.0

  test "gain_at_f outside the swept band is NaN, not an extrapolation":
    var spec = defaultOpAmpSpec()
    spec.fStart = 100.0
    spec.fStop = 10.0e3
    spec.gainAtFreq = 1.0e6
    let r = analyzeOpAmpResponse(acCoupledStage(), "U1", "vin", "vout", spec)
    check r["gain_at_f"].isNaN

  test "gain_at_f is not reported unless it was asked for":
    let r = analyzeOpAmpResponse(acCoupledStage(), "U1", "vin", "vout")
    var named: seq[string]
    for m in r.measurements: named.add m.name
    check "gain_at_f" notin named
    check "gain_max_db" in named

  proc clippingStage(): Netlist =
    ## A non-inverting stage with antiparallel diodes across the feedback
    ## network -- the shape of every soft-clipping overdrive. The diodes
    ## carry a real model, so they actually clip; without one they would be
    ## stood in for by resistors to ground and the stage would measure clean.
    result = newNetlist("clip")
    let gnd = addNet(result, newNet("0", ntGround))
    let vcc = addNet(result, newNet("vcc", ntPower))
    vcc.attrs["voltage"] = "9.0"
    let vin = addNet(result, newNet("vin"))
    let vfb = addNet(result, newNet("vfb"))
    let vout = addNet(result, newNet("vout"))
    setModel(result, "1N4148", "D(IS=2.52n RS=0.568 N=1.752)")
    let u = addComponent(result, newComponent("U1", kind = "opamp"))
    discard connect(u, "IN+", vin, ptInput)
    discard connect(u, "IN-", vfb, ptInput)
    discard connect(u, "OUT", vout, ptOutput)
    discard connect(u, "V-", gnd, ptGround)
    for (desig, p1, p2, kind, value) in [("RF", vout, vfb, "resistor", "100k"),
                                         ("RG", vfb, gnd, "resistor", "1k")]:
      let c = addComponent(result, newComponent(desig, kind = kind))
      discard connect(c, "1", p1, ptPassive)
      discard connect(c, "2", p2, ptPassive)
      c.attrs["value"] = value
    for (desig, a, k) in [("D1", vfb, vout), ("D2", vout, vfb)]:
      let d = addComponent(result, newComponent(desig, kind = "diode"))
      discard connect(d, "A", a, ptPassive)
      discard connect(d, "K", k, ptPassive)
      d.attrs["value"] = "1N4148"

  proc lsSpec(amp: float): OpAmpSpec =
    result = defaultOpAmpSpec()
    result.driveAmplitude = amp
    result.driveFreq = 1000.0

  proc railedStage(stated: bool): Netlist =
    ## Gain of 11 on +-5 V rails. Driven at 1 V peak it asks for 11 V of
    ## swing from an amplifier that has 5 to give.
    result = newNetlist("r")
    let gnd = addNet(result, newNet("0", ntGround))
    let vcc = addNet(result, newNet("vcc", ntPower))
    let vee = addNet(result, newNet("vee", ntPower))
    if stated:
      vcc.attrs["voltage"] = "5.0"
      vee.attrs["voltage"] = "-5.0"
    let vin = addNet(result, newNet("vin"))
    let vfb = addNet(result, newNet("vfb"))
    let vout = addNet(result, newNet("vout"))
    let u = addComponent(result, newComponent("U1", kind = "opamp"))
    discard connect(u, "IN+", vin, ptInput)
    discard connect(u, "IN-", vfb, ptInput)
    discard connect(u, "OUT", vout, ptOutput)
    discard connect(u, "V+", vcc, ptPower)
    discard connect(u, "V-", vee, ptPower)
    for (desig, p1, p2, value) in [("RF", vout, vfb, "100k"),
                                   ("RG", vfb, gnd, "10k")]:
      let c = addComponent(result, newComponent(desig, kind = "resistor"))
      discard connect(c, "1", p1, ptPassive)
      discard connect(c, "2", p2, ptPassive)
      c.attrs["value"] = value

  test "a clipping stage distorts, and the distortion is measured":
    # `.ac` cannot see this at all: it linearises about the operating point,
    # where the diodes are off and the stage is a clean gain of 101.
    let r = analyzeLargeSignal(clippingStage(), "U1", "vin", "vout",
                               lsSpec(0.05))
    check r["thd_pct"] > 5.0
    check not r["output_swing"].isNaN

  test "the output is bounded by the clippers, not by the gain":
    # A linear gain of 101 on 50 mV would swing 10 V peak-to-peak. Diodes
    # across the feedback network hold it near a diode drop either side.
    let r = analyzeLargeSignal(clippingStage(), "U1", "vin", "vout",
                               lsSpec(0.05))
    check r["output_swing"] < 3.0
    check r["clip_high"] > 0.0
    check r["clip_low"] < 0.0

  test "gain compresses as the drive rises, which is what an overdrive does":
    let soft = analyzeLargeSignal(clippingStage(), "U1", "vin", "vout",
                                  lsSpec(0.005))
    let hard = analyzeLargeSignal(clippingStage(), "U1", "vin", "vout",
                                  lsSpec(0.2))
    check hard["gain_compressed_db"] < soft["gain_compressed_db"] - 6.0
    # And the swing barely grows for a 40x increase in drive.
    check hard["output_swing"] < soft["output_swing"] * 4.0

  test "a linear stage driven inside its range measures clean":
    # The counterpart: without something nonlinear in it there is nothing to
    # find, and the number must say so rather than reporting noise.
    #
    # On split rails with a ground-referenced input, so the stage really is
    # biased in the middle of its range. `nonInverting` is deliberately not
    # used here: it runs on a single supply with V- on ground and its input
    # referenced to ground, so its output sits *on* the negative rail and
    # cannot swing down at all -- which the next test checks.
    let r = analyzeLargeSignal(railedStage(true), "U1", "vin", "vout",
                               lsSpec(0.1))
    check r["thd_pct"] < 1.0

  test "a stage biased on a rail cannot swing, and now says so":
    # Before the macromodel was bounded this measured perfectly clean: an
    # unbounded VCVS output swings straight through a rail the part does not
    # have. The circuit is real and so is the defect.
    let r = analyzeLargeSignal(nonInverting(), "U1", "vin", "vout",
                               lsSpec(0.001))
    check r["thd_pct"] > 20.0
    check r["clip_low"] > -0.1        # pinned at the 0 V rail

  test "a large-signal run needs a drive level":
    # The answer is a function of it, so there is no default to fall back on.
    var spec = defaultOpAmpSpec()
    expect NetlistError:
      discard analyzeLargeSignal(clippingStage(), "U1", "vin", "vout", spec)

  test "an amplifier with stated rails runs out of swing":
    # Unbounded, the macromodel's output is a VCVS -- an ideal source, which
    # cannot saturate however hard the loop drives it. A stage whose only
    # nonlinearity is the amplifier running out of swing then measures
    # perfectly clean, which is a statement about the model.
    let r = analyzeLargeSignal(railedStage(true), "U1", "vin", "vout",
                               lsSpec(1.0))
    check abs(r["clip_high"] - 5.0) < 0.05
    check abs(r["clip_low"] + 5.0) < 0.05
    check abs(r["output_swing"] - 10.0) < 0.1
    check r["thd_pct"] > 20.0        # a hard-clipped sine

  test "without stated rails it swings past them, and says so":
    let r = analyzeLargeSignal(railedStage(false), "U1", "vin", "vout",
                               lsSpec(1.0))
    check r["output_swing"] > 20.0   # gain of 11 on 1 V peak, unbounded
    check r["thd_pct"] < 1.0
    var warned = false
    for a in r.assumptions:
      if "unbounded" in $a and "measures clean" in $a: warned = true
    check warned

  test "the bound is declared as an assumption, not silently applied":
    let r = analyzeLargeSignal(railedStage(true), "U1", "vin", "vout",
                               lsSpec(1.0))
    var stated = false
    for a in r.assumptions:
      if "saturates at" in $a and "stops short of its rails" in $a:
        stated = true
    check stated

  test "bounding changes nothing small-signal":
    # It must be invisible where the amplifier never approaches its rails,
    # or every existing number moves for no reason.
    let free = analyzeOpAmpResponse(railedStage(false), "U1", "vin", "vout")
    let held = analyzeOpAmpResponse(railedStage(true), "U1", "vin", "vout")
    check abs(free["gain_dc_db"] - held["gain_dc_db"]) < 1e-6
    check abs(free["bw_3db"] - held["bw_3db"]) / free["bw_3db"] < 1e-6

  test "headroom keeps the model short of the rails":
    var spec = lsSpec(1.0)
    spec.vsatHeadroom = 1.5
    let r = analyzeLargeSignal(railedStage(true), "U1", "vin", "vout", spec)
    check abs(r["clip_high"] - 3.5) < 0.05
    check abs(r["clip_low"] + 3.5) < 0.05

  test "bounding can be turned off with the rails still stated":
    var spec = lsSpec(1.0)
    spec.boundToRails = false
    let r = analyzeLargeSignal(railedStage(true), "U1", "vin", "vout", spec)
    check r["output_swing"] > 20.0

proc wienBridge(): Netlist =
  ## A Wien-bridge oscillator: the positive feedback returns straight to IN+,
  ## which is exactly the node an `.ac` sweep wants to drive.
  netlist("wien"):
    net vcc, kind = ntPower, voltage = "5.0"
    net gnd, kind = ntGround, name = "0"
    net vout, kind = ntSignal
    net w1, kind = ntSignal
    net vp, kind = ntSignal
    net vn, kind = ntSignal

    component U1, kind = "opamp":
      pin "IN+", vp, kind = ptInput
      pin "IN-", vn, kind = ptInput
      pin "OUT", vout, kind = ptOutput
      pin "V+", vcc, kind = ptPower
      pin "V-", gnd, kind = ptGround

    component R1, kind = "resistor", value = "10k":
      pin "1", vout, kind = ptPassive
      pin "2", w1, kind = ptPassive
    component C1, kind = "capacitor", value = "10n":
      pin "1", w1, kind = ptPassive
      pin "2", vp, kind = ptPassive
    component R2, kind = "resistor", value = "10k":
      pin "1", vp, kind = ptPassive
      pin "2", gnd, kind = ptPassive
    component C2, kind = "capacitor", value = "10n":
      pin "1", vp, kind = ptPassive
      pin "2", gnd, kind = ptPassive

    component RG, kind = "resistor", value = "10k":
      pin "1", vn, kind = ptPassive
      pin "2", gnd, kind = ptPassive
    component RF, kind = "resistor", value = "20k":
      pin "1", vn, kind = ptPassive
      pin "2", vout, kind = ptPassive

proc biasedStage(): Netlist =
  ## A single-supply non-inverting stage whose input arrives at IN+ and whose
  ## gain leg returns to the same *bias rail* the input is referenced to.
  ## There is a passive path from the output back to IN+ -- but it runs
  ## through the rail, so it is not feedback. This is the TS808's shape.
  netlist("biased"):
    net vcc, kind = ntPower, voltage = "9.0"
    net gnd, kind = ntGround, name = "0"
    net vref, kind = ntPower, voltage = "4.5"
    net vin, kind = ntSignal
    net vout, kind = ntSignal
    net vfb, kind = ntSignal

    component U1, kind = "opamp":
      pin "IN+", vin, kind = ptInput
      pin "IN-", vfb, kind = ptInput
      pin "OUT", vout, kind = ptOutput
      pin "V+", vcc, kind = ptPower
      pin "V-", gnd, kind = ptGround

    component R4, kind = "resistor", value = "10k":   # input bias to the rail
      pin "1", vin, kind = ptPassive
      pin "2", vref, kind = ptPassive
    component RF, kind = "resistor", value = "20k":
      pin "1", vout, kind = ptPassive
      pin "2", vfb, kind = ptPassive
    component RG, kind = "resistor", value = "1k":    # gain leg to the rail
      pin "1", vfb, kind = ptPassive
      pin "2", vref, kind = ptPassive

suite "driving a node the loop returns to":
  # An `.ac` proc measures a stage by hanging an ideal source on its input
  # net. An ideal source holds that node, so if the feedback returns there,
  # the sweep measures the forward path of a circuit whose loop has been cut
  # -- and it does so without failing. Before this check, the Wien bridge
  # below reported `f_hi_3db` of 289 kHz for a circuit that does everything
  # it does at 1.59 kHz, and the claim passed.

  test "an oscillator's injection point is refused, with the reason":
    let issues = checkInjectionPoint(wienBridge(), "U1", "vp")
    check issues.len == 1
    check issues[0].kind == KindInputInFeedback
    check issues[0].severity == sevError
    check "U1.IN+" in issues[0].message

  test "and no numbers are produced for it":
    # notEvaluable, not a confident wrong answer.
    let r = analyzeOpAmpResponse(wienBridge(), "U1", "vp", "vout")
    check r.measurements.len == 0
    check r.issues.anyIt(it.kind == KindInputInFeedback)

  test "the loop-gain sweep refuses the same injection point":
    # It holds the input at DC 0 AC 0, which clamps the node just as firmly.
    let r = analyzeLoopGain(wienBridge(), "U1", "vp", "vout")
    check r.issues.anyIt(it.kind == KindInputInFeedback)

  test "an ordinary non-inverting stage is not flagged":
    # Its input is IN+, but nothing feeds back to IN+.
    check checkInjectionPoint(nonInverting(), "U1", "vin").len == 0

  test "a path that returns through a bias rail is not feedback":
    # The discriminator that matters in practice: `vout` really does reach
    # `vin` through passives here, via the 4.5 V rail. A rail is an AC ground
    # that every stage hangs off, so crossing one connects things that are
    # not connected in any signal sense -- the same rule `spice/isolate`
    # applies when it refuses to traverse through a rail.
    check checkInjectionPoint(biasedStage(), "U1", "vin").len == 0

  test "a stage with no feedback at all is still reported as open, not as this":
    # The two findings must not be confused: one says the loop is missing,
    # the other says the measurement would destroy it.
    let nl = nonInverting()
    removeComponent(nl, "RF")
    check checkInjectionPoint(nl, "U1", "vin").len == 0
    check checkFeedback(nl, "U1").anyIt(it.kind == KindNoFeedback)
