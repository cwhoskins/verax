## A second-order Sallen-Key low-pass, and the template where `without`
## earns its keep.
##
##   verax check <this file>
##
## Butterworth at 10 kHz: unity gain, Q = 0.707, 12 dB/octave beyond the
## corner. The filter itself is four passives and a follower. What makes it
## worth a template is the claim it has to **decline**.
##
## `opamp_stage` always claims a phase margin, and for a plain amplifier that
## is exact -- breaking the loop at the inverting input opens the only
## feedback path there is. A Sallen-Key has *two*: C1 returns to the
## **output**, and that positive path stays closed across the break. What
## comes back is then not a loop transmission at all, and the naive
## arithmetic on it reported **450 degrees** on the design this was found on
## -- which is not a phase margin, and which satisfies any `minPhaseMargin`
## a design could state. A stability claim that cannot fail is worse than no
## claim at all.
##
## Two things follow, and both are visible here. The measurement now checks
## whether the break actually opened the loop and returns `NaN` with a
## diagnosis when it did not, so the claim comes back *not checked* rather
## than passing. And `without = "phase_margin"` says so up front: this
## instance does not make that claim. The report prints `declines ...` rather
## than staying silent, and a suffix matching nothing raises rather than
## quietly leaving the claim in place.
##
## Declining is not the same as ignoring. Carrying an unmeasurable claim in
## every run is its own harm, because NOT CHECKED is precisely the section
## that must not become background noise.

import verax/contract/dsl
import verax/verify

let d = design("sallen_key"):
  net gnd, kind = ntGround, name = "0"
  net vcc, kind = ntPower:
    spec:
      voltage = 5.0.V
  net vee, kind = ntPower:
    spec:
      voltage = -5.0.V

  net vin,  kind = ntSignal
  net na,   kind = ntSignal     # R1/R2/C1 junction
  net vp,   kind = ntSignal     # non-inverting input
  net vout, kind = ntSignal

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

  # Split rails mean the signal is referenced to ground and the chain is DC
  # coupled throughout. This resistor is what gives the input a DC path when
  # nothing is plugged in; without it the whole R1-R2 string floats, since
  # C2 blocks and the amplifier's input draws nothing.
  component Rin, kind = "resistor", value = "100k":
    pin "1", vin, kind = ptPassive
    pin "2", gnd, kind = ptPassive

  # --- the filter ---------------------------------------------------------
  # Equal resistors, and the *ratio of the capacitors* is what sets Q:
  #
  #   f0 = 1 / (2*pi*R*sqrt(C1*C2))        Q = sqrt(C1/C2) / 2
  #
  # C1/C2 = 2 gives Q = 0.707, which is Butterworth -- maximally flat, no
  # peaking, the alignment you want unless you have a reason to want another.
  # With R = 10k and sqrt(2.2n * 1.1n) = 1.556 nF, f0 lands at 10.2 kHz.
  #
  # Note which capacitor is which. **C1 returns to the output**, and that is
  # the positive feedback that makes a two-pole response out of one
  # amplifier -- and it is exactly the path that survives a loop break at the
  # inverting input. Swap C1 and C2 and the circuit still filters, at the
  # same f0, with Q = 0.354 instead: over-damped, 6 dB down at the corner
  # rather than 3, and nothing but a bandwidth claim would notice.
  component R1, kind = "resistor", value = "10k":
    pin "1", vin, kind = ptPassive
    pin "2", na,  kind = ptPassive
  component R2, kind = "resistor", value = "10k":
    pin "1", na, kind = ptPassive
    pin "2", vp, kind = ptPassive
  component C1, kind = "capacitor", value = "2.2n":
    pin "1", na,   kind = ptPassive
    pin "2", vout, kind = ptPassive
    spec:
      package = "0603"
      dielectric = "C0G"
      voltage_rating = 50.0.V
  component C2, kind = "capacitor", value = "1.1n":
    pin "1", vp,  kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0603"
      dielectric = "C0G"
      voltage_rating = 50.0.V

  # C0G on both, and that is physics rather than preference. A Class 2
  # dielectric (X5R, X7R) loses capacitance to DC bias and to temperature,
  # and these two capacitors *are* the corner frequency -- a part at 70% of
  # its label moves f0 by 20%. Class 1 is paraelectric and does not depend
  # on applied voltage at all. Use Class 2 for decoupling, where the density
  # is; use Class 1 anywhere a value sets a frequency.

  component U1, kind = "opamp", partNumber = "OPA1642":
    pin "IN+", vp,   kind = ptInput
    pin "IN-", vout, kind = ptInput      # unity-gain follower: OUT tied to IN-
    pin "OUT", vout, kind = ptOutput
    pin "V+",  vcc,  kind = ptPower
    pin "V-",  vee,  kind = ptGround
    spec:
      gain = 120e3
      gbw = 11.MHz

  # --- claims -------------------------------------------------------------

  role "power_rail", pos, rail = vcc, voltage = 5.0.V, band = 5.pct
  role "power_rail", neg, rail = vee, voltage = -5.0.V, band = 5.pct

  # A Butterworth alignment does not peak at all -- that is what maximally
  # flat means -- so the peaking claim is tight and it is the one that
  # catches a mis-stuffed capacitor. Fit C2 the same value as C1 and Q rises
  # to 1.0, which peaks about 1.25 dB and rings on a step.
  #
  # The bandwidth is claimed as a floor at 9 kHz against a design corner of
  # 10.2 kHz, leaving room for the capacitors' own tolerance without leaving
  # room for the wrong part.
  role "opamp_stage", filt, opamp = U1, input = vin, output = vout,
       minBandwidth = 9.kHz, maxPeaking = 0.5.dB,
       without = "phase_margin"

quit(verifyMain(d))
