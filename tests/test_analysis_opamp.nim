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

    # T = Aol*beta with beta = 1/10: 80 dB at DC, crossing at GBW*beta =
    # 100 kHz.
    check abs(r["loop_gain_dc_db"] - 80.0) < 0.1
    check abs(r["crossover_hz"] - 1.0e5) / 1.0e5 < 0.02
    # One pole contributes at most 90 degrees of lag.
    check abs(r["phase_margin_deg"] - 90.0) < 1.0

  test "a second pole in the loop eats the phase margin and is flagged":
    # A cap from the feedback node to ground adds a second loop pole at
    # 1/(2*pi*(RF||RG)*C).
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

    # More capacitance must cost more margin and pull crossover down.
    let mild = analyzeLoopGain(withFeedbackCap("2n"), "U1", "vin", "vout")
    let severe = analyzeLoopGain(withFeedbackCap("100n"), "U1", "vin", "vout")
    check mild["phase_margin_deg"] > r["phase_margin_deg"]
    check r["phase_margin_deg"] > severe["phase_margin_deg"]
    check mild["crossover_hz"] > severe["crossover_hz"]

    # Two poles never reach -180 degrees, so there's no gain margin: NaN.
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
    # The walk crosses it because its registration states direction and gain.
    check checkFeedback(stage("buffer"), "U1").len == 0

  test "a part whose behaviour is genuinely unknown still opens the loop":
    let issues = checkFeedback(stage("mcu"), "U1")
    check issues.len == 1
    check issues[0].kind == KindNoFeedback

  test "the loop actually closes in simulation, with the right numbers":
    # beta = 1/2: a 1 MHz GBW crosses at 500 kHz, 90 degrees margin, no gain
    # margin.
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
    ## A unity-gain Sallen-Key low-pass (f0 = 21.3 kHz, Q = 0.549). C1
    ## returns to the output -- a second feedback path, so the loop can't be
    ## opened at the inverting input alone.
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
    # `180 + phase at crossover` is a margin only if the break opened the
    # loop. Here it doesn't: the phase climbs through +180 above 0 dB and the
    # naive arithmetic gives 450.
    let r = analyzeLoopGain(sallenKey(), "U1", "vin", "vout")
    check r["phase_margin_deg"].isNaN
    check r["gain_margin_db"].isNaN
    check r.issues.anyIt(it.kind == KindLoopBreakInvalid)
    # The crossing itself is real and is still reported.
    check not r["crossover_hz"].isNaN

  test "a loop the break did open still measures its margin":
    # The guard must not fire on a single-pole stage (exactly 90 degrees).
    for nl in [nonInverting(), nonInverting("99k", "1k")]:
      let r = analyzeLoopGain(nl, "U1", "vin", "vout")
      check not r["phase_margin_deg"].isNaN
      check abs(r["phase_margin_deg"] - 90.0) < 1.0
      check not r.issues.anyIt(it.kind == KindLoopBreakInvalid)

  test "a second amplifier in the path is modelled, so a cascade is measured":
    # Two Sallen-Key sections, one damped and one peaky, flat only as a
    # product: the upstream amplifier must not be stood in for.
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
    # 4th-order near-Butterworth: flat, cornering just under 20 kHz.
    check r["peaking_db"] < 1.0
    check abs(r["bw_3db"] - 19.7e3) / 19.7e3 < 0.1

  proc acCoupledStage(): Netlist =
    ## A non-inverting stage with a capacitively coupled gain leg: 20 dB from
    ## ~100 Hz (1/(2*pi*RG*CG)) to 100 kHz, unity at DC -- so a DC-referenced
    ## figure is useless.
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
    # `gain_dc_db` is correct but useless: the stage has unity gain at DC.
    let r = analyzeOpAmpResponse(acCoupledStage(), "U1", "vin", "vout")
    check r["gain_dc_db"] < 1.5                   # essentially unity
    check abs(r["gain_max_db"] - 20.0) < 1.0      # 1 + 9k/1k
    # Low edge 1/(2*pi*1k*1.6u) = 99.5 Hz; high edge GBW/gain = 100 kHz.
    check abs(r["f_lo_3db"] - 99.5) / 99.5 < 0.15
    check abs(r["f_hi_3db"] - 100.0e3) / 100.0e3 < 0.2
    check r["f_gain_max"] > r["f_lo_3db"]

  test "a DC-coupled stage keeps both references, and they agree":
    # Where the first point is in the passband, both references agree.
    let r = analyzeOpAmpResponse(nonInverting(), "U1", "vin", "vout")
    check abs(r["gain_max_db"] - r["gain_dc_db"]) < 0.1
    check abs(r["f_hi_3db"] - r["bw_3db"]) / r["bw_3db"] < 0.05
    check r["f_lo_3db"].isNaN            # a DC-coupled stage has no low edge

  test "gain_at_f reports the gain at exactly the stated frequency":
    var spec = defaultOpAmpSpec()
    spec.gainAtFreq = 1000.0
    let r = analyzeOpAmpResponse(acCoupledStage(), "U1", "vin", "vout", spec)
    # Well inside the passband: the midband gain.
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
    ## A non-inverting stage with antiparallel diodes across the feedback --
    ## a soft clipper. The diodes carry a real model so they actually clip.
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
    ## Gain of 11 on +-5 V rails; 1 V peak in asks for 11 V out.
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
    # `.ac` linearises about the operating point, where the diodes are off.
    let r = analyzeLargeSignal(clippingStage(), "U1", "vin", "vout",
                               lsSpec(0.05))
    check r["thd_pct"] > 5.0
    check not r["output_swing"].isNaN

  test "the output is bounded by the clippers, not by the gain":
    # Linear gain of 101 on 50 mV would be 10 Vpp; the diodes hold it near a
    # diode drop.
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
    # The swing barely grows for 40x the drive.
    check hard["output_swing"] < soft["output_swing"] * 4.0

  test "a linear stage driven inside its range measures clean":
    # Nothing nonlinear means nothing to find. Split rails with a
    # ground-referenced input, so the stage is biased mid-range
    # (`nonInverting` sits on its negative rail; see the next test).
    let r = analyzeLargeSignal(railedStage(true), "U1", "vin", "vout",
                               lsSpec(0.1))
    check r["thd_pct"] < 1.0

  test "a stage biased on a rail cannot swing, and now says so":
    # The macromodel output is bounded, so it can't swing through a rail.
    let r = analyzeLargeSignal(nonInverting(), "U1", "vin", "vout",
                               lsSpec(0.001))
    check r["thd_pct"] > 20.0
    check r["clip_low"] > -0.1        # pinned at the 0 V rail

  test "a large-signal run needs a drive level":
    # The answer depends on it, so there's no default.
    var spec = defaultOpAmpSpec()
    expect NetlistError:
      discard analyzeLargeSignal(clippingStage(), "U1", "vin", "vout", spec)

  test "an amplifier with stated rails runs out of swing":
    # Unbounded, the output is an ideal VCVS that never saturates, so a
    # stage limited only by swing measures clean.
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
    # Invisible where the amplifier stays clear of its rails.
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
  ## A Wien-bridge oscillator: positive feedback returns straight to IN+, the
  ## node an `.ac` sweep would drive.
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
  ## A single-supply non-inverting stage whose gain leg returns to the bias
  ## rail the input is referenced to: a passive output-to-IN+ path through a
  ## rail, which is not feedback.
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
  # An ideal source on the input net holds that node, so if feedback returns
  # there the sweep measures a cut loop without failing.

  test "an oscillator's injection point is refused, with the reason":
    let issues = checkInjectionPoint(wienBridge(), "U1", "vp")
    check issues.len == 1
    check issues[0].kind == KindInputInFeedback
    check issues[0].severity == sevError
    check "U1.IN+" in issues[0].message

  test "and no numbers are produced for it":
    # notEvaluable, not a wrong answer.
    let r = analyzeOpAmpResponse(wienBridge(), "U1", "vp", "vout")
    check r.measurements.len == 0
    check r.issues.anyIt(it.kind == KindInputInFeedback)

  test "the loop-gain sweep refuses the same injection point":
    # It holds the input at DC 0 AC 0, clamping the node just as firmly.
    let r = analyzeLoopGain(wienBridge(), "U1", "vp", "vout")
    check r.issues.anyIt(it.kind == KindInputInFeedback)

  test "an ordinary non-inverting stage is not flagged":
    # Its input is IN+, but nothing feeds back to IN+.
    check checkInjectionPoint(nonInverting(), "U1", "vin").len == 0

  test "a path that returns through a bias rail is not feedback":
    # `vout` reaches `vin` through the 4.5 V rail, but a rail is an AC ground;
    # like `spice/isolate`, the walk doesn't cross rails.
    check checkInjectionPoint(biasedStage(), "U1", "vin").len == 0

  test "a stage with no feedback at all is still reported as open, not as this":
    # Missing loop vs. a measurement that would destroy it: distinct findings.
    let nl = nonInverting()
    removeComponent(nl, "RF")
    check checkInjectionPoint(nl, "U1", "vin").len == 0
    check checkFeedback(nl, "U1").anyIt(it.kind == KindNoFeedback)
