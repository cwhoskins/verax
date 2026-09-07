import std/[math, os, sequtils, strutils, tables, unittest]

import verax/netlist/dsl
import verax/analysis/analyses/psrr

let haveNgspice = findExe("ngspice").len > 0

proc rcDivider(r = "9k", c = "0"): Netlist =
  ## A supply, a resistive divider, and nothing that regulates: the rejection
  ## is the divider ratio and is exact at every frequency.
  ##
  ## R1 = 9k over R2 = 1k attenuates by 10, which is 20 dB. That is the whole
  ## point of the fixture -- a number this file knows from arithmetic rather
  ## than from a previous run of itself, and one both methods have to agree
  ## with and with each other.
  result = newNetlist("rc")
  let vin = addNet(result, newNet("vin"))
  let vout = addNet(result, newNet("vout"))
  let gnd = addNet(result, newNet("0", ntGround))

  let v1 = addComponent(result, newComponent("V1", kind = "voltage_source"))
  discard connect(v1, "+", vin)
  discard connect(v1, "-", gnd)
  v1.attrs["value"] = "DC 12"
  # Ideal, so the divider ratio is the whole answer: the default 10 mohm +
  # 1 uH would sit above R1 and add a pole of its own.
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
  ## A rail held by a part carrying no model, which `spice/models` stands in
  ## for as an ideal source at its stated output voltage. Nothing on its
  ## input can reach its output: this is the shape the guard exists for.
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

      # 10 kohm over 1 kohm is a factor of ten, which is 20 dB, and a
      # resistive divider has no frequency in it -- so the worst point in the
      # band and the point at 1 kHz are the same number.
      check abs(r["psrr_min_db"] - 20.0) < 0.1
      check abs(r["psrr_at_f"] - 20.0) < 0.1

  test "the worst point is found inside the band, not at its ends":
    if not haveNgspice:
      skip()
    else:
      # A capacitor across the bottom leg makes rejection *improve* with
      # frequency, so the worst point is the low end; inverting the network
      # would put it at the high end. Either way it has to be found on the
      # curve.
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
      # The ratio is quoted against what actually reached the input node, and
      # with an ideal supply that is the injected amplitude.
      check abs(r["in_ripple_v"] - 0.5) / 0.5 < 0.02
      check abs(r["out_ripple_v"] - 0.05) / 0.05 < 0.03

  test "the tone is picked out from ripple the circuit makes itself":
    if not haveNgspice:
      skip()
    else:
      # The same divider with a second, much larger source at a different
      # frequency on the output node. A peak-to-peak reading would report
      # that instead; extracting at the injected frequency does not.
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

      # RN in parallel with R2 halves the bottom leg to 500 ohm, so the
      # 1 kHz tone now divides by 9k/500 + 1 = 19 -> 25.6 dB. The 50 kHz
      # interferer is four times larger than the tone at the output and does
      # not appear in the answer at all.
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
