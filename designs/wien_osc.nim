## A Wien-bridge oscillator: 1.59 kHz, diode-stabilised, split rails.
##
##   verax check designs/wien_osc.nim
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
## Measured, through the `oscillator` role and the same single-pole
## macromodel this tool substitutes (ngspice-46, kicked with 10 mV, 150 ms
## to settle, then a 20 ms window -- 31 whole periods):
##
##   f0        1580.7 Hz   against 1591.55 Hz ideal, -0.68%
##   amplitude +-1.1888 V  (2.3775 V peak-to-peak)
##   THD       4.19%
##
## The 0.68% is not error, it is the circuit: a finite-gain, finite-GBW
## amplifier loads the Wien network and pulls its peak down slightly. A tool
## reporting exactly 1591.55 Hz would be reporting the formula, not the
## board. Two settings the number is sensitive to are worth knowing, because
## both look like circuit measurements and neither is: the amplifier's
## stated `gbw` below (leave it off and the macromodel's 1 MHz default reads
## 1573.3 Hz -- 0.5% low, a quarter of the claim's band), and the print step,
## which is also ngspice's own timestep ceiling (`analyzeOscillation` derives
## ten times the density `analyzeTransient` does for exactly this reason).

import verax/contract/dsl
import verax/verify

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

  # The datasheet's own two numbers, and they are not decoration here.
  # `spice/models.idealOpAmp` defaults to 100k of open-loop gain and 1 MHz
  # of gain-bandwidth when the part states none, and this circuit reads the
  # difference straight out as a frequency: the amplifier's finite gain
  # loads the Wien network and pulls its peak down, so a model three times
  # too slow reports an oscillator 0.7% lower than the part will run at.
  # That is a claim about the model wearing the clothes of a claim about
  # the board -- and it is nearly half the 2% band the frequency claim
  # below is worth stating at.
  component U1, kind = "opamp", partNumber = "TL072":
    pin "IN+", vp,   kind = ptInput
    pin "IN-", vn,   kind = ptInput
    pin "OUT", vout, kind = ptOutput
    pin "V+",  vcc,  kind = ptPower
    pin "V-",  vee,  kind = ptGround
    spec:
      gain = 200e3          # 200 V/mV typical
      gbw = 3.MHz

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

  # The three numbers an oscillator is specified by, and the role that binds
  # no driving part because there is none to bind.
  #
  # **Every .ac-backed claim in this library measures the wrong thing here,
  # and one of them measured it silently.**
  #
  #   * `opamp_stage` and `gain_stage` sweep by hanging an ideal source on
  #     the stage's input net. Here that net is IN+, and the Wien bridge
  #     returns to IN+ -- so the source holds the node and the bridge is
  #     shorted out of the circuit. Before that was detected, `gain_stage`
  #     reported `f_hi_3db` of 289 kHz (the forward path's GBW/3.2) for a
  #     circuit whose entire behaviour is at 1.59 kHz, and **the claim
  #     passed, exit 0**. It is now refused by name; see
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
  # So `oscillator` runs it, and `kick` is what makes the start-up a stated
  # thing rather than an accident. This circuit's operating point is every
  # node at zero with a loop gain of 3.2 around it, which is a balance it
  # would sit in forever -- and measured, it does not: ngspice's own solver
  # residual is enough to seed it, and unkicked it reaches full amplitude in
  # about 30 ms. That is not something to rely on. It is a property of the
  # solver's tolerance and not of the board, it puts the settling time
  # somewhere nobody chose, and a loop with less excess gain than 3.2 would
  # take arbitrarily longer or never arrive. Measured unkicked at
  # tSettle = 10 ms the amplitude claim reads **57.4 nV** -- oscillating,
  # correctly reported at 1.58 kHz, and four orders of magnitude short.
  #
  # 10 mV on the bridge tap makes it deterministic: an `.ic` with `uic`, and
  # the loop grows it until the diodes take the gain back to 3. Kicked, the
  # same 10 ms window is already at full amplitude.
  #
  # The cost of `uic` is real and is reported as an assumption on the run:
  # the operating-point solve is skipped, so every node not named starts at
  # zero rather than at its bias. Here that is exactly what is wanted, since
  # every node in this circuit *is* at zero before it starts.
  #
  # `tSettle` is 150 ms and it is set by the **stabiliser**, not by the
  # period. The loop starts with a gain of 3.2, so the envelope grows by
  # about 6% a cycle; getting from 10 mV to 1.19 V is a factor of 120, some
  # eighty cycles, and then the diodes have to find their level. 150 ms is
  # nearly 240 periods, which is comfortably past both, and leaves room for
  # a slower stabiliser without the claim needing to be re-timed. The window
  # is 20 ms -- about 32 whole periods, so the distortion integral has plenty
  # to work with.
  #
  # The frequency is claimed at what the **network** is designed for --
  # 1/(2*pi*10k*10n) = 1591.55 Hz -- and not at what the simulation happens
  # to report, which is 1580.7 Hz. That is deliberate and it is what the band
  # is for: the 0.68% gap is the amplifier loading the bridge, a real effect
  # of a real part, and a claim restated at the measured figure would be a
  # claim that can only ever pass. 2% is tight enough that a part
  # substitution in the Wien network breaks it -- swap C1/C2 for 12 nF and
  # the oscillator drops to 1.33 kHz -- which is the whole reason to state
  # it.
  #
  # Measured: 1580.7 Hz, 2.3775 V peak-to-peak, 4.19% THD.
  role "oscillator", tone, output = vout, kick = vp,
       tSettle = 150.0.ms, tWindow = 20.0.ms, kickV = 10.0.mV,
       freq = 1591.55.Hz, band = 2.pct,
       minSwing = 2.0.V, maxSwing = 2.8.V, maxThd = 6.0

quit(verifyMain(d))
