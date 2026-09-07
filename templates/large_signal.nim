## A soft-clipping stage, driven hard on purpose.
##
##   verax check <this file>
##
## Everything else in this library that measures an amplifier is
## **small-signal**: `.ac` linearises about the operating point, so a
## clipping diode is whatever conductance it happens to have at rest and
## never clips. That is the right model for gain and stability and the wrong
## one for a stage where the nonlinearity *is* the product.
##
## `large_signal` drives a real sine into the stage with a `.tran` and reports
## `thd_pct`, `output_swing`, `clip_high`/`clip_low` and
## `gain_compressed_db`. This circuit is an inverting amplifier of nominal
## gain 10 with antiparallel silicon across its feedback resistor: below a
## diode drop it is a linear amplifier, above one the diodes conduct and the
## gain folds over. Small-signal it measures 20 dB; driven, it compresses.
##
## One limit worth stating plainly: the substituted macromodel has no slew
## limit and no output current limit, and it only saturates when the design
## states its rails. So the distortion measured here is what the **network**
## produces. A stage whose only nonlinearity is the amplifier running out of
## swing reads as clean, which is a statement about the model rather than
## about the circuit.

import verax/contract/dsl
import verax/verify

const
  d1N4148 = "1N4148"
  d1N4148Card =
    "D(IS=2.52n RS=0.568 N=1.752 CJO=4p M=0.4 VJ=0.4 " &
    "BV=110 IBV=100u TT=20n)"

let d = design("large_signal"):
  net gnd, kind = ntGround, name = "0"
  net vcc, kind = ntPower:
    spec:
      voltage = 5.0.V
  net vee, kind = ntPower:
    spec:
      voltage = -5.0.V

  net vin,  kind = ntSignal
  net vn,   kind = ntSignal     # inverting input: the virtual ground
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

  # Split rails and an inverting topology, so IN+ sits at ground and the
  # summing node is a virtual ground at 0 V. There is no bias network to get
  # wrong here -- that is `gain_stage.nim`'s problem, and it is the reason
  # this template uses two supplies for a circuit that could use one.
  component U1, kind = "opamp", partNumber = "TL072":
    pin "IN+", gnd,  kind = ptInput
    pin "IN-", vn,   kind = ptInput
    pin "OUT", vout, kind = ptOutput
    pin "V+",  vcc,  kind = ptPower
    pin "V-",  vee,  kind = ptGround
    spec:
      gain = 200e3
      gbw = 3.MHz

  # Gain = -Rf/Rin = -10 while the diodes are off. Rin also sets the input
  # impedance, which for an inverting stage is just Rin -- the summing node
  # is held at ground by the loop, so the source sees one resistor.
  component Rin, kind = "resistor", value = "1k":
    pin "1", vin, kind = ptPassive
    pin "2", vn,  kind = ptPassive
  component Rf, kind = "resistor", value = "10k":
    pin "1", vn,   kind = ptPassive
    pin "2", vout, kind = ptPassive

  # The clippers. Antiparallel across Rf, so each half-cycle is clipped by
  # one of them: as |vout| approaches a diode drop the conducting diode's
  # dynamic resistance falls below Rf and the *gain* collapses, rather than
  # the output hitting a wall. That is what makes it a soft clipper -- the
  # transfer curve bends instead of breaking, which is why it sounds like
  # something and a comparator does not.
  #
  # The `model` statement is load-bearing. Without a card these are parts
  # SPICE cannot bind: each becomes two 1 Mohm resistors to ground, the
  # clipping silently stops existing, and the stage measures a clean 20 dB.
  model d1N4148, d1N4148Card

  component D1, kind = "diode", partNumber = d1N4148, value = d1N4148:
    pin "A", vn,   kind = ptPassive
    pin "K", vout, kind = ptPassive
  component D2, kind = "diode", partNumber = d1N4148, value = d1N4148:
    pin "A", vout, kind = ptPassive
    pin "K", vn,   kind = ptPassive

  # --- claims -------------------------------------------------------------

  role "power_rail", pos, rail = vcc, voltage = 5.0.V, band = 5.pct
  role "power_rail", neg, rail = vee, voltage = -5.0.V, band = 5.pct

  # 100 mV in at a nominal gain of 10 would be 2 V peak-to-peak if nothing
  # clipped. Measured, the stage puts out 905 mV peak-to-peak at 20.7% THD:
  # the diodes have taken more than half the swing away and bent what is
  # left, which is the compression this topology is built for. The gain that
  # survives is some 7 dB under the 20 dB the resistors alone would give.
  #
  # `minThd` is not a mistake. On a stage built to clip, too *little*
  # distortion is the defect: a circuit measuring clean here has lost its
  # clippers -- an unfitted diode, a wrong part number, or a missing model
  # card -- and every small-signal claim in this file would still pass.
  role "large_signal", clipper, opamp = U1, input = vin, output = vout,
       driveV = 100.mV, driveF = 1.kHz,
       minThd = 3.0, maxThd = 40.0,
       minSwing = 0.4.V, maxSwing = 1.6.V

quit(verifyMain(d))
