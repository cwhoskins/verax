## The analog input sheet: a single-supply non-inverting gain stage, biased
## at VDD/2 the way `designs/ts808_drive.nim` biases its whole signal chain.
##
## Ports: `AIN`, `AOUT`, `VDD`, `GND`.
##
## Built directly (component by component, `designs/aa_filter.nim`'s style)
## rather than through `designs/lib/opamp_stages.nonInvertingAmp`, so the
## op-amp this sheet's `opamp_stage` role claims sits at `<instance>.U1`
## with no extra nesting to walk through.

import verax/contract/dsl
import verax/netlist/formats/spice as spiceFormat

proc analogInputChannel*(gain = 2.0, gbw = 20.0.MHz,
                         partNumber = "OPA320"): Netlist =
  doAssert gain >= 1.0, "non-inverting gain is >= 1 (1.0 is a unity buffer)"
  # 100k, not 10k: `designs/lib/opamp_stages.defaultNonInvertingGain`'s own
  # default, matched deliberately -- measured a real, reproducible
  # difference between the two (13.5 MHz/1.5 dB of peaking at 10k against
  # this proc's own topology at gain 2, versus 10.4 MHz/0.192 dB at 100k,
  # both against the identical `OPA320`/20 MHz part), so this is not a
  # cosmetic choice.
  let rf = 100.0.kohm
  let rg = Ohms(float(rf) / (gain - 1.0))

  result = subckt("ANALOG_IN", [AIN, AOUT, VDD, GND]):
    net GND,  kind = ntGround, name = "0"
    net VDD,  kind = ntPower
    net AIN,  kind = ntSignal
    net AOUT, kind = ntSignal
    net vref, kind = ntSignal
    net fb,   kind = ntSignal

    # VDD/2 bias for a single-supply stage.
    component R_BIAS1, kind = "resistor", value = "10k":
      pin "1", VDD,  kind = ptPassive
      pin "2", vref, kind = ptPassive
    component R_BIAS2, kind = "resistor", value = "10k":
      pin "1", vref, kind = ptPassive
      pin "2", GND,  kind = ptPassive
    component C_BIAS, kind = "capacitor", value = "10u":
      pin "1", vref, kind = ptPassive
      pin "2", GND,  kind = ptPassive
      spec:
        package = "0805"

    component U1, kind = "opamp", partNumber = partNumber:
      pin "IN+", AIN,  kind = ptInput
      pin "IN-", fb,   kind = ptInput
      pin "OUT", AOUT, kind = ptOutput
      pin "V+",  VDD,  kind = ptPower
      pin "V-",  GND,  kind = ptGround
      spec:
        gbw = gbw

    if gain == 1.0:
      discard
    else:
      component RF, kind = "resistor", value = spiceValue(float(rf)):
        pin "1", AOUT, kind = ptPassive
        pin "2", fb,   kind = ptPassive
      component RG, kind = "resistor", value = spiceValue(float(rg)):
        pin "1", fb,   kind = ptPassive
        pin "2", vref, kind = ptPassive

    component CD1, kind = "capacitor", value = "100n":
      pin "1", VDD, kind = ptPassive
      pin "2", GND, kind = ptPassive
      spec:
        package = "0402"

  if gain == 1.0:
    mergeNets(findNet(result, "AOUT"), findNet(result, "fb"))
