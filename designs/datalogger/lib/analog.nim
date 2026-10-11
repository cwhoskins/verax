## The analog input sheet: a single-supply non-inverting gain stage built
## from `designs/lib/opamp_stages.nonInvertingAmp`, with the VDD/2 bias
## circuitry that makes it work on a single supply pulled out into its own
## subcircuit, `designs/lib/bias.biasNetwork` -- generic, like `opamp_stages`,
## and not specific to this board -- wired separately ahead of it, onto
## the non-inverting *input*. `biasNetwork` AC-couples `AIN` onto a node held
## at `VDD/2`, so the op-amp's non-inverting input sees a DC-biased,
## AC-coupled copy of the input signal.
##
## **The gain leg is AC-coupled too, and that is load-bearing.** A
## non-inverting stage amplifies whatever DC sits on its input by
## `1 + Rf/Rg`, the bias included. With a plain `RG` to ground the 1.65 V
## bias came out as 3.3 V and the output sat on the top rail with no room to
## swing -- which is what this sheet used to do, and nothing small-signal
## could see it: `.ac` linearises about the operating point and the
## macromodel's rail clamp is not in the linear model, so gain, corners and
## phase margin all read exactly right on a stage that could not pass a
## signal. The large-signal claims of `adc_driver` below found it -- driven
## at 0.5 V the output stuck at a 3.30 V ceiling with -6 dB of compressed
## gain. `RG` is now `opamp_stages.seriesRCNetwork` (via
## `acCoupledNonInvertingGain`), so the stage is gain 2 in band and unity at
## DC and the output sits mid-rail. Its corner is a tenth of the input
## coupling's, so the two high-pass poles do not stack inside the band.
## Returning `RG` to the bias instead (the other textbook fix) was tried and
## rejected: sharing `biasNetwork`'s reference between the gain leg and the
## input's bias resistor makes a second, positive feedback path that
## `opamp_stage`'s loop-gain break cannot open, and its phase margin stops
## being measurable.
##
## Ports: `AIN`, `AOUT`, `VDD`, `GND`.
##
## The op-amp `datalogger.nim`'s `opamp_stage`/`gain_stage` roles claim sits
## two levels deeper than it once did, at `<instance>.Xamp.U1` --
## `innerComponent` walks a multi-segment path exactly as readily as a
## single one (see `design.innerComponent`), so the nesting `nonInvertingAmp`
## brings along costs the role binding nothing but one more path segment.
## Real AC coupling ahead of the amplifier is also why `datalogger.nim`
## claims this stage with *both* roles rather than one: `opamp_stage` alone
## would claim `peaking_db`, referenced to the sweep's first point, and that
## point sits in `biasNetwork`'s own stopband -- see
## `contract/roles/analog.gainStageExpand`'s doc comment for why that pair
## exists.

import std/[math, tables]
import verax/contract/dsl
import verax/netlist/formats/spice as spiceFormat
import ../../lib/opamp_stages
import ../../lib/bias

proc analogInputChannel*(gain = 2.0, gbw = 20.0.MHz,
                         partNumber = "OPA320",
                         biasCornerHz = 1.6.Hz): Netlist =
  doAssert gain >= 1.0, "non-inverting gain is >= 1 (1.0 is a unity buffer)"

  result = subckt("ANALOG_IN", [AIN, AOUT, VDD, GND]):
    net GND,  kind = ntGround, name = "0"
    net VDD,  kind = ntPower
    net AIN,  kind = ntSignal
    net AOUT, kind = ntSignal
    net vin,  kind = ntSignal

    instance Xbias, biasNetwork(cornerHz = biasCornerHz),
      {"IN": AIN, "OUT": vin, "VDD": VDD, "GND": GND}

    # --- gain stage: the shared non-inverting amplifier, REF on true ground
    # and RG AC-coupled so the bias sees unity gain -- see the module doc.
    instance Xamp, nonInvertingAmp(defaultOpAmp(partNumber, gbw), gain,
                                   gainNetworks = acCoupledNonInvertingGain(
                                     corner = Hertz(float(biasCornerHz) / 10.0))),
      {"IN": vin, "OUT": AOUT, "VP": VDD, "VN": GND, "REF": GND, "GND": GND}

# --- a role for what the ADC needs from this stage --------------------------

proc adcDriverExpand(inst: RoleInstance): seq[Assertion] =
  ## The claims an ADC makes of the stage that drives it. Each is opt-in on
  ## its parameter, like the built-in roles, and each carries
  ## `origin: inst.name` -- the only channel the op-amp evaluators have for
  ## the `opamp`/`input` bindings, and the reason none of these quantities
  ## can be claimed with a bare `require`.
  ##
  ## Small-signal: the loop gain at DC (gain error against the ADC's LSB),
  ## the loop's crossover (settling inside the acquisition window), the
  ## closed-loop unity-gain frequency (the noise bandwidth handed to the
  ## sampler) and where the response peaks. Large-signal, at one stated
  ## drive: the output's extremes and the gain the fundamental actually got.
  ## `gain_dc_db` and `gain_bw_product` are deliberately absent: both are
  ## referenced to the sweep's first point, which on an AC-coupled stage is
  ## the coupling network's stopband, not DC.
  let outNet = inst.subject("output")
  proc claim(sfx, qty: string, e: Expectation, u, why: string): Assertion =
    Assertion(id: assertionId(inst, sfx), subjects: @[outNet],
              quantity: qty, expect: e, unit: u, severity: sevError,
              rationale: why, origin: inst.name)

  if hasParam(inst, "bits"):
    # Gain error of a feedback stage is 1/T; half an LSB is 2^-(bits+1).
    let bits = paramFloat(inst, "bits", 12.0)
    let minT = 20.0 * log10(pow(2.0, bits + 1.0))
    result.add claim("loop_gain", "loop_gain_dc_db", atLeast(minT), "dB",
      "gain error is 1/T: holding it to half an LSB of a " & $int(bits) &
      "-bit converter takes this much loop gain at DC")
    if hasParam(inst, "tAcq"):
      # Settling to half an LSB is ln(2^(bits+1)) time constants of the
      # closed loop, whose bandwidth is the loop's crossover.
      let tAcq = paramFloat(inst, "tAcq", 0.0)
      let n = ln(pow(2.0, bits + 1.0))
      result.add claim("crossover", "crossover_hz",
        atLeast(n / (2.0 * PI * tAcq)), "Hz",
        "the stage has to settle to half an LSB inside the ADC's " &
        "acquisition window: that many time constants of 1/(2 pi fc)")

  if hasParam(inst, "maxUnity"):
    result.add claim("f_unity", "f_unity",
      atMost(paramFloat(inst, "maxUnity", 0.0)), "Hz",
      "the band over which the stage amplifies its own input noise into " &
      "the sampler; past it the noise is attenuated rather than gained")

  if hasParam(inst, "bandLo") and hasParam(inst, "bandHi"):
    result.add claim("f_peak", "f_gain_max",
      between(paramFloat(inst, "bandLo", 0.0), paramFloat(inst, "bandHi", 0.0)),
      "Hz",
      "a flat passband peaks somewhere inside itself; a maximum at either " &
      "edge is a resonance, not a passband")

  if hasParam(inst, "driveV"):
    let driveV = paramFloat(inst, "driveV", 0.0)
    let driveF = paramFloat(inst, "driveF", 1.0e3)
    template driven(a: Assertion): untyped =
      var x = a
      x.condition["drive_v"] = $driveV
      x.condition["drive_f"] = $driveF
      result.add x
    if hasParam(inst, "outMax"):
      driven claim("out_max", "clip_high",
        atMost(paramFloat(inst, "outMax", 0.0)), "V",
        "the output's highest excursion at full-scale drive stays clear " &
        "of the top rail, where the amplifier stops being linear")
    if hasParam(inst, "outMin"):
      driven claim("out_min", "clip_low",
        atLeast(paramFloat(inst, "outMin", 0.0)), "V",
        "the output's lowest excursion at full-scale drive stays clear of " &
        "ground, the bottom of the ADC's range")
    if hasParam(inst, "gain"):
      driven claim("compression", "gain_compressed_db",
        nominal(paramFloat(inst, "gain", 0.0), absTol = 0.1), "dB",
        "at full scale the fundamental still gets the stage's small-signal " &
        "gain: a clipped or rail-bound output loses it")

registerRole(RoleDef(
  name: "adc_driver",
  doc: "An op-amp stage driving an ADC input: loop gain and settling against " &
       "the converter's resolution and acquisition time, noise bandwidth, and " &
       "a full-scale drive that must neither clip nor compress.",
  parts: @[
    RolePart(name: "opamp", kind: skComponent, doc: "the amplifier"),
    RolePart(name: "input", kind: skNet, doc: "where the stage is driven"),
    RolePart(name: "output", kind: skNet, doc: "the net the ADC samples")],
  params: @[
    AnnDef(key: "bits", kind: akFloat, unit: "", scopes: {asNet},
           doc: "ADC resolution; claims loop gain for half-LSB gain error"),
    AnnDef(key: "tAcq", kind: akFloat, unit: "s", scopes: {asNet},
           doc: "ADC acquisition time; with `bits`, claims the crossover " &
                "that settles to half an LSB inside it"),
    AnnDef(key: "maxUnity", kind: akFloat, unit: "Hz", scopes: {asNet},
           doc: "highest closed-loop unity-gain frequency (noise bandwidth)"),
    AnnDef(key: "bandLo", kind: akFloat, unit: "Hz", scopes: {asNet},
           doc: "low edge of the passband the response must peak inside"),
    AnnDef(key: "bandHi", kind: akFloat, unit: "Hz", scopes: {asNet},
           doc: "high edge of it"),
    AnnDef(key: "driveV", kind: akFloat, unit: "V", scopes: {asNet},
           doc: "full-scale drive amplitude, zero to peak; a condition"),
    AnnDef(key: "driveF", kind: akFloat, unit: "Hz", scopes: {asNet},
           doc: "drive frequency; default 1 kHz"),
    AnnDef(key: "outMax", kind: akFloat, unit: "V", scopes: {asNet},
           doc: "highest the output may reach at that drive"),
    AnnDef(key: "outMin", kind: akFloat, unit: "V", scopes: {asNet},
           doc: "lowest the output may reach at that drive"),
    AnnDef(key: "gain", kind: akFloat, unit: "dB", scopes: {asNet},
           doc: "small-signal gain the fundamental must still get at that " &
                "drive, +-0.1 dB")],
  apply: nil,
  expand: adcDriverExpand))
