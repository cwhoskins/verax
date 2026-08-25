## A Wien-bridge oscillator: 1.59 kHz, diode-stabilised, split rails.
##
##   nimcir check designs/wien_osc.nim
##
## The oldest op-amp circuit worth building -- it is what Hewlett sold to
## Disney in 1939 -- and it is here for one reason: **its intent is
## instability**, and every claim this library knows how to make assumes a
## stage should be stable.
##
## An amplifier is judged by how far it is from oscillating. `opamp_stage`
## claims a phase margin and bounds peaking; `gain_stage` claims a flat
## passband. An oscillator is specified the other way round: the loop gain
## must be *exactly* 1 at *exactly* 0 degrees, and everything a stability
## claim would call a defect is here the product.
##
## How it works. The Wien network is a bandpass: series R1+C1 into shunt
## R2||C2, whose transfer peaks at f0 = 1/(2*pi*R*C) where it is exactly 1/3
## with zero phase shift. Wrap it in an amplifier of gain exactly 3 and the
## Barkhausen condition holds at f0 and nowhere else.
##
## "Exactly 3" is the hard part, and it is why the diodes are there. Set the
## gain below 3 and it never starts; above 3 and it grows until the amplifier
## clips, which is a square wave with a Wien filter on it. So Rf is split:
## Rf1 + Rf2 gives 1 + 22k/10k = 3.2 for reliable start-up, and once the
## output is large enough to forward-bias D1/D2 they shunt Rf2 and pull the
## gain back down. The circuit settles where the *cycle-averaged* gain is 3.
##
## Measured (ngspice-46, 200 ms .tran, the same single-pole macromodel this
## tool substitutes):
##
##   f0        1584.3 Hz   against 1591.55 Hz ideal, -0.46%
##   amplitude +-1.189 V
##   THD       4.35%
##
## The 0.46% is not error, it is the circuit: a finite-gain, finite-GBW
## amplifier loads the Wien network and pulls its peak down slightly. A tool
## reporting exactly 1591.55 Hz would be reporting the formula, not the
## board.

import nimcir/contract/dsl
import nimcir/verify

import ./lib/parts

let d = design("wien_osc"):
  net gnd, kind = ntGround, name = "0"
  net vcc, kind = ntPower:
    spec:
      voltage = 5.0.V
  net vee, kind = ntPower:
    spec:
      voltage = -5.0.V

  net vout, kind = ntSignal                # the sine
  net w1,   kind = ntSignal                # R1 / C1 junction, series arm
  net vp,   kind = ntSignal                # non-inverting input, bridge tap
  net vn,   kind = ntSignal                # inverting input
  net nf,   kind = ntSignal                # Rf1 / Rf2 junction, diode clamp

  # --- supplies ---------------------------------------------------------
  component V1, kind = "voltage_source", value = "DC 5":
    pin "+", vcc, kind = ptPower
    pin "-", gnd, kind = ptGround
    spec:
      voltage = 5.0.V
  component V2, kind = "voltage_source", value = "DC -5":
    pin "+", vee, kind = ptPower
    pin "-", gnd, kind = ptGround
    spec:
      voltage = -5.0.V

  component C10, kind = "capacitor", value = "100n":
    pin "1", vcc, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0402"
  component C11, kind = "capacitor", value = "100n":
    pin "1", vee, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0402"

  component U1, kind = "opamp", partNumber = "TL072":
    pin "IN+", vp,   kind = ptInput
    pin "IN-", vn,   kind = ptInput
    pin "OUT", vout, kind = ptOutput
    pin "V+",  vcc,  kind = ptPower
    pin "V-",  vee,  kind = ptGround

  # --- the Wien network: positive feedback ------------------------------
  # Series arm R1 + C1 from the output, shunt arm R2 || C2 to ground. Both
  # legs use the same R and the same C, which is what makes the peak land at
  # exactly 1/3 with zero phase -- unequal legs still peak, but not at a
  # third and not at zero phase, and the circuit then oscillates at whatever
  # frequency the phase does cross, if at all.
  component R1, kind = "resistor", value = "10k":
    pin "1", vout, kind = ptPassive
    pin "2", w1, kind = ptPassive
  component C1, kind = "capacitor", value = "10n":
    pin "1", w1, kind = ptPassive
    pin "2", vp, kind = ptPassive
    spec:
      package = "film"

  component R2, kind = "resistor", value = "10k":
    pin "1", vp, kind = ptPassive
    pin "2", gnd, kind = ptPassive
  component C2, kind = "capacitor", value = "10n":
    pin "1", vp, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "film"

  # --- gain leg: negative feedback, and the clamp -----------------------
  component Rg, kind = "resistor", value = "10k":
    pin "1", vn, kind = ptPassive
    pin "2", gnd, kind = ptPassive
  component Rf1, kind = "resistor", value = "10k":
    pin "1", vn, kind = ptPassive
    pin "2", nf, kind = ptPassive
  component Rf2, kind = "resistor", value = "12k":
    pin "1", nf, kind = ptPassive
    pin "2", vout, kind = ptPassive

  # The stabiliser. Antiparallel silicon across Rf2 only -- across the whole
  # of Rf it would clamp the output itself and the result is a clipped wave,
  # which is the mistake this arrangement exists to avoid. Across Rf2 the
  # diodes reduce the *gain* instead, so the amplifier never leaves its
  # linear region and the residual distortion is a few percent rather than
  # a few tens.
  model d1N4148, d1N4148Card

  component D1, kind = "diode", partNumber = d1N4148, value = d1N4148:
    pin "A", nf, kind = ptPassive
    pin "K", vout, kind = ptPassive
  component D2, kind = "diode", partNumber = d1N4148, value = d1N4148:
    pin "A", vout, kind = ptPassive
    pin "K", nf, kind = ptPassive

  # --- claims -----------------------------------------------------------

  role "power_rail", pos, rail = vcc, voltage = 5.0.V, band = 5.pct
  role "power_rail", neg, rail = vee, voltage = -5.0.V, band = 5.pct

  # And that is all this design can claim, which is the finding.
  #
  # An oscillator is specified by three numbers -- 1584 Hz, +-1.19 V, 4.35%
  # THD -- and **none of them is expressible here**. There is no quantity
  # named for an oscillation frequency, an output amplitude, or whether the
  # circuit starts. Everything that could be pointed at this stage measures
  # the wrong thing:
  #
  #   * `opamp_stage` and `gain_stage` are backed by an .ac sweep, which
  #     drives an ideal source onto the stage's input net. Here that net is
  #     IN+, and the Wien bridge returns to IN+ -- so the source holds the
  #     node and the bridge is shorted out of the circuit. Before that was
  #     detected, `gain_stage` reported `f_hi_3db` of 289 kHz (the forward
  #     path's GBW/3.2) for a circuit whose entire behaviour is at 1.59 kHz,
  #     and **the claim passed, exit 0**. It is now refused by name; see
  #     `analysis/opamp.checkInjectionPoint`.
  #
  #   * `large_signal` would measure THD, which is the one figure that does
  #     transfer -- but it drives the input too, and an oscillator has no
  #     input to drive.
  #
  #   * The .ac family is the wrong family regardless. There is no
  #     closed-loop transfer function to sweep, because there is nothing to
  #     sweep it *from*. An oscillator has to be run, not swept.
  #
  # What is missing is a .tran measurement of a net that binds no driving
  # part -- which is the same thing `designs/charge_pump.nim` cannot reach
  # from the other direction. Two circuits, one gap. See docs/findings.md.
  #
  # Deliberately no claim is made rather than a claim that reports NOT
  # CHECKED on every run: that section is the one that must not become
  # background noise, which is the same reasoning `without` exists for.

quit(verifyMain(d))
