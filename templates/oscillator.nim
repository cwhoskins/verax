## A Wien-bridge oscillator: a circuit whose intent is instability.
##
##   nimcir check <this file>
##
## Every other amplifier template here is judged by how far it is from
## oscillating. This one is specified the other way round: the loop gain must
## be *exactly* 1 at *exactly* 0 degrees, and everything a stability claim
## would call a defect is here the product.
##
## **Every `.ac`-backed claim in this library measures the wrong thing on
## this circuit**, which is why `oscillator` is a separate role rather than
## parameters on `opamp_stage`:
##
##   * `opamp_stage` and `gain_stage` sweep by hanging an ideal source on the
##     stage's input net. Here that net is IN+, and the Wien bridge *returns*
##     to IN+ -- so the source holds the node and the bridge is shorted out
##     of the circuit. Before that was detected the tool reported a 289 kHz
##     bandwidth for a circuit whose entire behaviour is at 1.59 kHz, and the
##     claim **passed**. It is now refused by name.
##   * There is no closed-loop transfer function to sweep anyway, because
##     there is nothing to sweep it *from*. An oscillator has to be run, not
##     swept.
##
## So `oscillator` runs it with a `.tran` and reports the three numbers an
## oscillator is actually specified by: `osc_freq`, `swing_pp`, `osc_thd_pct`.
##
## How it works. The Wien network is a bandpass: series R1+C1 into shunt
## R2||C2, whose transfer peaks at f0 = 1/(2*pi*R*C) where it is exactly 1/3
## with zero phase shift. Wrap it in an amplifier of gain exactly 3 and the
## Barkhausen condition holds at f0 and nowhere else.
##
## "Exactly 3" is the hard part, and it is why the diodes are there. Below 3
## it never starts; above 3 it grows until the amplifier clips, which is a
## square wave with a Wien filter on it. So Rf is split: 1 + 22k/10k = 3.2
## for reliable start-up, and once the output is big enough to forward-bias
## D1/D2 they shunt Rf2 and pull the gain back down. The circuit settles
## where the *cycle-averaged* gain is 3.

import nimcir/contract/dsl
import nimcir/verify

const
  d1N4148 = "1N4148"
  d1N4148Card =
    "D(IS=2.52n RS=0.568 N=1.752 CJO=4p M=0.4 VJ=0.4 " &
    "BV=110 IBV=100u TT=20n)"

let d = design("oscillator"):
  net gnd, kind = ntGround, name = "0"
  net vcc, kind = ntPower:
    spec:
      voltage = 5.0.V
  net vee, kind = ntPower:
    spec:
      voltage = -5.0.V

  net vout, kind = ntSignal     # the sine
  net w1,   kind = ntSignal     # R1/C1 junction, series arm
  net vp,   kind = ntSignal     # non-inverting input, bridge tap
  net vn,   kind = ntSignal     # inverting input
  net nf,   kind = ntSignal     # Rf1/Rf2 junction, diode clamp

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

  # The datasheet's own two numbers, and this circuit reads the difference
  # straight out as a *frequency*: the amplifier's finite gain loads the Wien
  # network and pulls its peak down, so a model three times too slow reports
  # an oscillator 0.7% low -- a claim about the model wearing the clothes of
  # a claim about the board, and nearly half the band claimed below.
  component U1, kind = "opamp", partNumber = "TL072":
    pin "IN+", vp,   kind = ptInput
    pin "IN-", vn,   kind = ptInput
    pin "OUT", vout, kind = ptOutput
    pin "V+",  vcc,  kind = ptPower
    pin "V-",  vee,  kind = ptGround
    spec:
      gain = 200e3
      gbw = 3.MHz

  # --- the Wien network: positive feedback --------------------------------
  # Both legs use the same R and the same C, which is what puts the peak at
  # exactly 1/3 with zero phase. Unequal legs still peak, but not at a third
  # and not at zero phase, and the circuit then oscillates at whatever
  # frequency the phase does cross, if at all.
  component R1, kind = "resistor", value = "10k":
    pin "1", vout, kind = ptPassive
    pin "2", w1,   kind = ptPassive
  component C1, kind = "capacitor", value = "10n":
    pin "1", w1, kind = ptPassive
    pin "2", vp, kind = ptPassive
    spec:
      package = "film"
  component R2, kind = "resistor", value = "10k":
    pin "1", vp,  kind = ptPassive
    pin "2", gnd, kind = ptPassive
  component C2, kind = "capacitor", value = "10n":
    pin "1", vp,  kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "film"

  # --- gain leg: negative feedback, and the clamp -------------------------
  component Rg, kind = "resistor", value = "10k":
    pin "1", vn,  kind = ptPassive
    pin "2", gnd, kind = ptPassive
  component Rf1, kind = "resistor", value = "10k":
    pin "1", vn, kind = ptPassive
    pin "2", nf, kind = ptPassive
  component Rf2, kind = "resistor", value = "12k":
    pin "1", nf,   kind = ptPassive
    pin "2", vout, kind = ptPassive

  # The stabiliser: antiparallel silicon across **Rf2 only**. Across the
  # whole of Rf it would clamp the output itself, and the result is a clipped
  # wave -- which is the mistake this arrangement exists to avoid. Across Rf2
  # the diodes reduce the *gain* instead, so the amplifier never leaves its
  # linear region and the residual distortion is a few percent rather than a
  # few tens.
  #
  # The `model` statement is what makes them diodes at all. Without a card
  # each diode is a part SPICE cannot bind, gets stood in for as two 1 Mohm
  # resistors to ground, and the stabiliser silently stops existing.
  model d1N4148, d1N4148Card

  component D1, kind = "diode", partNumber = d1N4148, value = d1N4148:
    pin "A", nf,   kind = ptPassive
    pin "K", vout, kind = ptPassive
  component D2, kind = "diode", partNumber = d1N4148, value = d1N4148:
    pin "A", vout, kind = ptPassive
    pin "K", nf,   kind = ptPassive

  # --- claims -------------------------------------------------------------

  role "power_rail", pos, rail = vcc, voltage = 5.0.V, band = 5.pct
  role "power_rail", neg, rail = vee, voltage = -5.0.V, band = 5.pct

  # `kick` is what makes start-up a stated thing rather than an accident.
  # This circuit's operating point is every node at zero with a loop gain of
  # 3.2 around it -- a balance it would sit in forever. Measured, it does not
  # quite: ngspice's own solver residual is enough to seed it. That is a
  # property of the solver's tolerance and not of the board, it puts the
  # settling time somewhere nobody chose, and a loop with less excess gain
  # would take arbitrarily longer or never arrive. 10 mV on the bridge tap
  # makes it deterministic: an `.ic` with `uic`, and the loop grows it until
  # the diodes take the gain back to 3.
  #
  # `uic` is not free and the report says so as an assumption: the
  # operating-point solve is skipped, so every node not named starts at zero
  # rather than at its bias. Here that is exactly right, since every node in
  # this circuit *is* at zero before it starts.
  #
  # `tSettle` is set by the **stabiliser**, not by the period. The loop
  # starts at a gain of 3.2, so the envelope grows about 6% a cycle; getting
  # from 10 mV to 1.2 V is some eighty cycles, and then the diodes have to
  # find their level. 150 ms is nearly 240 periods, comfortably past both.
  # The 20 ms window is about 32 whole periods, so the distortion integral
  # has plenty to work with.
  #
  # The frequency is claimed at what the **network** is designed for --
  # 1/(2*pi*10k*10n) = 1591.55 Hz -- and not at what the simulation happens
  # to report, which is about 1581 Hz. The 0.7% gap is the amplifier loading
  # the bridge, a real effect of a real part; a claim restated at the
  # measured figure would be one that can only ever pass. 2% is tight enough
  # that a part substitution breaks it, which is the whole reason to state it.
  role "oscillator", tone, output = vout, kick = vp,
       tSettle = 150.0.ms, tWindow = 20.0.ms, kickV = 10.0.mV,
       freq = 1591.55.Hz, band = 2.pct,
       minSwing = 2.0.V, maxSwing = 2.8.V, maxThd = 6.0

quit(verifyMain(d))
