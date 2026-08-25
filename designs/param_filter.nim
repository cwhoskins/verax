## Two filters from one builder, at different corners.
##
##   nimcir check designs/param_filter.nim
##
## The point of this design is not the circuit -- it is that neither section's
## component values appear anywhere in this file. `designs/lib/filters.nim`
## computes them from a corner frequency and an impedance, and the *claims*
## below are written against the same two numbers the builder was given. So
## the check is a real one: if the design equations are wrong, or the builder
## rounds, or the amplifier's finite gain-bandwidth moves the corner, the
## claim fails. A hand-typed netlist claimed against hand-typed values checks
## only that somebody did the arithmetic twice.

import nimcir/contract/dsl
import nimcir/verify

import ./lib/filters

let d = design("param_filter"):
  net gnd, kind = ntGround, name = "0", global = true
  net vp, kind = ntPower:
    spec:
      voltage = 5.0.V
  net vn, kind = ntPower:
    spec:
      voltage = -5.0.V

  net inA,  kind = ntSignal
  net outA, kind = ntSignal
  net inB,  kind = ntSignal
  net outB, kind = ntSignal

  component V1, kind = "voltage_source", value = "DC 5":
    pin "+", vp, kind = ptPower
    pin "-", gnd, kind = ptGround
    spec:
      voltage = 5.0.V
  component V2, kind = "voltage_source", value = "DC -5":
    pin "+", vn, kind = ptPower
    pin "-", gnd, kind = ptGround
    spec:
      voltage = -5.0.V
  component C1, kind = "capacitor", value = "10u":
    pin "1", vp, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0805"
  component C2, kind = "capacitor", value = "10u":
    pin "1", vn, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0805"

  # The source impedance of whatever drives each filter. It is here because
  # without it the input string R1-R2 has no DC path anywhere and the .op is
  # singular -- which the tool now says out loud rather than reporting the
  # last iterate as an answer. A real filter is always fed from something with
  # a finite output impedance; 50 ohm is a signal generator.
  component RSA, kind = "resistor", value = "50":
    pin "1", inA, kind = ptPassive
    pin "2", gnd, kind = ptPassive
  component RSB, kind = "resistor", value = "50":
    pin "1", inB, kind = ptPassive
    pin "2", gnd, kind = ptPassive

  # Same builder, same impedance, one decade apart. Nothing below states a
  # resistor or a capacitor.
  instance XA, sallenKeyLP(fc = 1.kHz, r = 10.kohm), [inA, outA, vp, vn, gnd]
  instance XB, sallenKeyLP(fc = 10.kHz, r = 10.kohm), [inB, outB, vp, vn, gnd]

  role "power_rail", pos, rail = vp, voltage = 5.0.V, band = 5.pct
  role "power_rail", neg, rail = vn, voltage = -5.0.V, band = 5.pct

  # Claimed against the arguments the builder was given, not against anything
  # derived from what it produced. `without = "phase_margin"` because a
  # Sallen-Key's C1 returns to the output, so a second feedback path stays
  # closed across the loop break and no honest margin can be measured -- the
  # guards in `analyzeLoopGain` would return NaN and the claim would sit in
  # NOT CHECKED on every run.
  role "opamp_stage", secA, opamp = XA.innerComponent("U1"),
       input = inA, output = outA,
       minBandwidth = 950.Hz, maxPeaking = 0.3.dB,
       without = "phase_margin"
  role "opamp_stage", secB, opamp = XB.innerComponent("U1"),
       input = inB, output = outB,
       minBandwidth = 9.5.kHz, maxPeaking = 0.3.dB,
       without = "phase_margin"

quit(verifyMain(d))
