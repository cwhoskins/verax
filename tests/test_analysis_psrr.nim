import std/[math, os, sequtils, strutils, tables, unittest]

import verax/netlist/dsl
import verax/analysis/analyses/psrr

let haveNgspice = findExe("ngspice").len > 0

proc rcDivider(r = "9k", c = "0"): Netlist =
  ## A supply and a resistive divider, nothing regulating: R1 = 9k over
  ## R2 = 1k rejects exactly 20 dB at every frequency, by arithmetic.
  result = newNetlist("rc")
  let vin = addNet(result, newNet("vin"))
  let vout = addNet(result, newNet("vout"))
  let gnd = addNet(result, newNet("0", ntGround))

  let v1 = addComponent(result, newComponent("V1", kind = "voltage_source"))
  discard connect(v1, "+", vin)
  discard connect(v1, "-", gnd)
  v1.attrs["value"] = "DC 12"
  # Ideal: the default 10 mohm + 1 uH would add a pole above R1.
  v1.attrs["rout"] = "0"
  v1.attrs["lout"] = "0"

  let r1 = addComponent(result, newComponent("R1", kind = "resistor"))
  discard connect(r1, "1", vin)
  discard connect(r1, "2", vout)
  r1.attrs["value"] = r

  let r2 = addComponent(result, newComponent("R2", kind = "resistor"))
  discard connect(r2, "1", vout)
  discard connect(r2, "2", gnd)
  r2.attrs["value"] = "1k"

  if c != "0":
    let c1 = addComponent(result, newComponent("C1", kind = "capacitor"))
    discard connect(c1, "1", vout)
    discard connect(c1, "2", gnd)
    c1.attrs["value"] = c
    c1.attrs["dielectric"] = "C0G"
    c1.attrs["esr"] = "1e-6"
    c1.attrs["esl"] = "1e-15"

proc idealRail(): Netlist =
  ## A rail held by a model-less part, stood in for as an ideal source:
  ## nothing on its input reaches its output. The case the guard exists for.
  result = newNetlist("ideal")
  let vin = addNet(result, newNet("vin", ntPower))
  let vout = addNet(result, newNet("vout", ntPower))
  let gnd = addNet(result, newNet("0", ntGround))

  let v1 = addComponent(result, newComponent("V1", kind = "voltage_source"))
  discard connect(v1, "+", vin, ptPower)
  discard connect(v1, "-", gnd, ptGround)
  v1.attrs["value"] = "DC 12"

  let u1 = addComponent(result, newComponent("U1", kind = "regulator"))
  discard connect(u1, "IN", vin, ptPower)
  discard connect(u1, "OUT", vout, ptPower)
  discard connect(u1, "GND", gnd, ptGround)
  u1.attrs["voltage"] = "5"

  let rl = addComponent(result, newComponent("RL", kind = "resistor"))
  discard connect(rl, "1", vout)
  discard connect(rl, "2", gnd)
  rl.attrs["value"] = "50"

suite "psrr, swept":
  test "a resistive divider rejects by its own ratio, at every frequency":
    if not haveNgspice:
      skip()
    else:
      var spec = defaultPsrrSpec()
      spec.fStart = 10.0
      spec.fStop = 1.0e5
      spec.atF = 1.0e3
      spec.modelSources = false   ## the fixture states its own
      let r = analyzePsrrAc(rcDivider(), "V1", "vin", "vout", spec)

      # A factor of ten is 20 dB, and a divider has no frequency in it, so
      # the band minimum equals the 1 kHz point.
      check abs(r["psrr_min_db"] - 20.0) < 0.1
      check abs(r["psrr_at_f"] - 20.0) < 0.1

  test "the worst point is found inside the band, not at its ends":
    if not haveNgspice:
      skip()
    else:
      # A cap across the bottom leg makes rejection improve with frequency,
      # so the worst point is at the low end and must be found on the curve.
      var spec = defaultPsrrSpec()
      spec.fStart = 10.0
      spec.fStop = 1.0e6
      spec.modelSources = false
      let r = analyzePsrrAc(rcDivider(c = "1u"), "V1", "vin", "vout", spec)

      check abs(r["psrr_min_db"] - 20.0) < 0.5
      check r["f_psrr_min"] < 100.0

  test "psrr_at_f outside the swept band is NaN, not extrapolated":
    if not haveNgspice:
      skip()
    else:
      var spec = defaultPsrrSpec()
      spec.fStart = 100.0
      spec.fStop = 1.0e4
      spec.atF = 1.0e6
      spec.modelSources = false
      let r = analyzePsrrAc(rcDivider(), "V1", "vin", "vout", spec)
      check r["psrr_at_f"].isNaN

  test "a rail nothing can ripple is refused, not reported as infinite":
    if not haveNgspice:
      skip()
    else:
      var spec = defaultPsrrSpec()
      spec.fStart = 10.0
      spec.fStop = 1.0e4
      let r = analyzePsrrAc(idealRail(), "V1", "vin", "vout", spec)
      check r["psrr_min_db"].isNaN
      check r.issues.anyIt(it.kind == KindNoFeedthrough)

suite "psrr, one tone":
  test "the tone method agrees with the sweep on a network with no dynamics":
    if not haveNgspice:
      skip()
    else:
      var spec = defaultPsrrSpec()
      spec.rippleF = 1.0e3
      spec.rippleV = 0.5
      spec.tSettle = 5.0e-3
      spec.modelSources = false
      let r = analyzePsrrTone(rcDivider(), "V1", "vin", "vout", spec)

      check abs(r["psrr_db"] - 20.0) < 0.2
      # Quoted against what reached the input; with an ideal supply, the
      # injected amplitude.
      check abs(r["in_ripple_v"] - 0.5) / 0.5 < 0.02
      check abs(r["out_ripple_v"] - 0.05) / 0.05 < 0.03

  test "the tone is picked out from ripple the circuit makes itself":
    if not haveNgspice:
      skip()
    else:
      # A larger interferer at another frequency on the output: peak-to-peak
      # would report it; extraction at the injected frequency doesn't.
      let nl = rcDivider()
      let vout = findNet(nl, "vout")
      let gnd = findNet(nl, "0")
      let noise = addComponent(nl, newComponent("VN",
                                                kind = "voltage_source"))
      let nNet = addNet(nl, newNet("nnode"))
      discard connect(noise, "+", nNet)
      discard connect(noise, "-", gnd)
      noise.attrs["value"] = "DC 0 SIN(0 2 50k)"
      noise.attrs["rout"] = "0"
      noise.attrs["lout"] = "0"
      let rn = addComponent(nl, newComponent("RN", kind = "resistor"))
      discard connect(rn, "1", nNet)
      discard connect(rn, "2", vout)
      rn.attrs["value"] = "1k"

      var spec = defaultPsrrSpec()
      spec.rippleF = 1.0e3
      spec.rippleV = 0.5
      spec.tSettle = 5.0e-3
      spec.periods = 20
      spec.modelSources = false
      let r = analyzePsrrTone(nl, "V1", "vin", "vout", spec)

      # RN || R2 = 500 ohm, so the tone divides by 19 -> 25.6 dB. The 50 kHz
      # interferer, four times larger at the output, doesn't appear.
      check abs(r["psrr_db"] - 20.0 * log10(19.0)) < 0.5

  test "a rail nothing can ripple is refused by the tone method too":
    if not haveNgspice:
      skip()
    else:
      var spec = defaultPsrrSpec()
      spec.rippleF = 1.0e3
      spec.tSettle = 1.0e-3
      let r = analyzePsrrTone(idealRail(), "V1", "vin", "vout", spec)
      check r["psrr_db"].isNaN
      check r["out_ripple_v"] < 1.0e-6
      check r.issues.anyIt(it.kind == KindNoFeedthrough)

  test "a source that is not a voltage source has nothing to ripple in series":
    let nl = rcDivider()
    expect NetlistError:
      discard analyzePsrrTone(nl, "R1", "vin", "vout", defaultPsrrSpec())
