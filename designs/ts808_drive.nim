## Ibanez TS808 "Tube Screamer" -- the drive stage.
##
##   verax check designs/ts808_drive.nim
##
## The most-cloned overdrive circuit there is, and a good stress test: a
## single-supply op-amp stage running off a 9 V battery with a synthesised
## half-rail bias, soft clipping diodes inside the feedback loop, and a
## deliberately band-limited response -- the "mid hump" the pedal is known
## for is not an accident of the parts, it is what the gain leg's 0.047 uF
## and the 51 pF across the feedback resistor were chosen to produce.
##
## What is modelled and what is not:
##
##   * The input and output emitter followers are real 2SC1815 stages on the
##     board. They are declared `kind = "buffer"` here so the signal path
##     stays closed through them -- a discrete BJT stood in for by two
##     impedances to ground would open the loop and every gain figure below
##     would be about a different circuit.
##   * D1/D2 are the soft-clipping pair. They are what makes this an
##     overdrive rather than a clean preamp, and they are a *large-signal*
##     effect: the .ac sweep below is a small-signal measurement and sees
##     them as the off-state parts they are until the loop drives them.
##     The gain measured here is the undistorted gain, which is the correct
##     thing to check the bandwidth and stability of.

import verax/contract/dsl
import verax/verify

let d = design("ts808_drive"):
  net gnd,  kind = ntGround, name = "0"
  net v9,   kind = ntPower                 # 9 V battery / DC jack
  # The bias rail must state its voltage. Without it this net is `ntPower`
  # with no nominal, and an isolation cuts it loose as a floating node --
  # which detaches the gain leg below and quietly turns this whole stage
  # into a unity-gain follower that passes every claim made about it.
  net vref, kind = ntPower:                # synthesised 4.5 V half-rail bias
    spec:
      voltage = 4.5.V
  net vin,  kind = ntSignal                # guitar in, after the input jack
  net vbuf, kind = ntSignal                # input emitter follower out
  net vamp, kind = ntSignal                # op-amp non-inverting input
  net vfb,  kind = ntSignal                # op-amp inverting node
  net vgain,kind = ntSignal                # gain-leg junction
  net vpot, kind = ntSignal                # drive pot / feedback junction
  net vout, kind = ntSignal                # op-amp output

  # --- supply -----------------------------------------------------------
  # A 9 V battery is not a stiff supply: an alkaline PP3 runs 1-2 ohm fresh
  # and far worse flat, which is why the pedal carries 100 uF of bulk.
  # `rout` is stated rather than defaulted, because here the supply really
  # is part of what is being studied.
  component BT1, kind = "voltage_source", value = "DC 9":
    pin "+", v9, kind = ptPower
    pin "-", gnd, kind = ptGround
    spec:
      voltage = 9.0.V
      rout = 1.5.ohm
      lout = 1.uH

  component C1, kind = "capacitor", value = "100u":
    pin "1", v9, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "electrolytic"
      esr = 250.mohm
      esl = 8.nH

  component C10, kind = "capacitor", value = "100n":
    pin "1", v9, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0805"

  # --- 4.5 V bias rail --------------------------------------------------
  # Two 10k resistors and a 47 uF reservoir. This is the whole reason the
  # circuit works on one supply, and it is also the weakest node on the
  # board: its source impedance is 5k in parallel with whatever C6 gives,
  # and every stage's input sits on it.
  component R9, kind = "resistor", value = "10k":
    pin "1", v9, kind = ptPassive
    pin "2", vref, kind = ptPassive
  component R10, kind = "resistor", value = "10k":
    pin "1", vref, kind = ptPassive
    pin "2", gnd, kind = ptPassive
  component C6, kind = "capacitor", value = "47u":
    pin "1", vref, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "electrolytic"
      esr = 500.mohm
      esl = 6.nH

  # --- input buffer -----------------------------------------------------
  component Q1, kind = "buffer", partNumber = "2SC1815":
    pin "IN",  vin,  kind = ptInput
    pin "OUT", vbuf, kind = ptOutput
    pin "V+",  v9,   kind = ptPower
    pin "V-",  gnd,  kind = ptGround
    spec:
      gain = 0.99

  component R1, kind = "resistor", value = "510k":
    pin "1", vin, kind = ptPassive
    pin "2", vref, kind = ptPassive

  # --- drive stage ------------------------------------------------------
  # Non-inverting, gain 1 + (R5 + drive)/R6 in the midband. With the pot at
  # half travel that is 1 + (51k + 250k)/4.7k, about 65x.
  component C2, kind = "capacitor", value = "47n":
    pin "1", vbuf, kind = ptPassive
    pin "2", vamp, kind = ptPassive
    spec:
      package = "film"
  component R4, kind = "resistor", value = "10k":
    pin "1", vamp, kind = ptPassive
    pin "2", vref, kind = ptPassive

  component U1A, kind = "opamp", partNumber = "JRC4558D":
    pin "IN+", vamp, kind = ptInput
    pin "IN-", vfb,  kind = ptInput
    pin "OUT", vout, kind = ptOutput
    pin "V+",  v9,   kind = ptPower
    pin "V-",  gnd,  kind = ptGround

  # Feedback: 51k in series with the 500k drive pot, set here to half.
  # `VR1` is what a schematic calls a pot, and it is also a designator whose
  # first letter is SPICE's voltage source. The deck writer takes the device
  # letter from `kind`, so this goes out as `RVR1`; spelled verbatim it
  # would have been a 250 kV source shorting the whole feedback network,
  # which is exactly what it was before that was fixed -- the stage measured
  # a gain of 12 instead of 65 and nothing said so.
  component R5, kind = "resistor", value = "51k":
    pin "1", vout, kind = ptPassive
    pin "2", vpot, kind = ptPassive
  component VR1, kind = "resistor", value = "250k":
    pin "1", vpot, kind = ptPassive
    pin "2", vfb, kind = ptPassive

  # 51 pF across the feedback. This is what stops the stage from having
  # gain at frequencies a guitar speaker will never reproduce, and it is
  # also what keeps the loop stable at high drive settings.
  component C3, kind = "capacitor", value = "51p":
    pin "1", vout, kind = ptPassive
    pin "2", vfb, kind = ptPassive
    spec:
      package = "0402"

  # The soft clippers. Antiparallel silicon across the feedback network.
  #
  # The `model` card is what makes these diodes rather than stand-ins. A
  # part whose `value` names a registered model is no longer *unmodelled*,
  # so `spice/models` leaves it alone and `spice/isolate` traverses it --
  # without one, each diode became two 1 Mohm resistors to ground, and the
  # pair of them shunted the inverting node with 500k. That is not a small
  # error: it acted as a second gain leg and lifted the stage's gain at the
  # bottom of the sweep from unity to 4.2 dB, which is where the old 31.6 dB
  # peaking figure came from against a real 35.3.
  #
  # The card body is passed through verbatim, so what ngspice reads is what
  # the datasheet said.
  model "1N4148", "D(IS=2.52n RS=0.568 N=1.752 CJO=4p M=0.4 VJ=0.4 " &
                  "BV=110 IBV=100u TT=20n)"

  component D1, kind = "diode", partNumber = "1N4148", value = "1N4148":
    pin "A", vfb, kind = ptPassive
    pin "K", vout, kind = ptPassive
  component D2, kind = "diode", partNumber = "1N4148", value = "1N4148":
    pin "A", vout, kind = ptPassive
    pin "K", vfb, kind = ptPassive

  # Gain leg to the bias rail. The 47 nF puts the low-frequency corner of
  # the *gain* at about 720 Hz with the pot at half -- below that the stage
  # falls back to unity, which is the mid hump.
  component C4, kind = "capacitor", value = "47n":
    pin "1", vfb, kind = ptPassive
    pin "2", vgain, kind = ptPassive
    spec:
      package = "film"
  component R6, kind = "resistor", value = "4.7k":
    pin "1", vgain, kind = ptPassive
    pin "2", vref, kind = ptPassive

  # --- claims -----------------------------------------------------------

  role "power_rail", batt, rail = v9,
       voltage = 9.0.V, band = 5.pct,
       targetZ = 2.ohm, targetFrom = 100.kHz, targetTo = 10.MHz

  # Stability, from `opamp_stage`. Phase margin is the one claim of that
  # role's three that fits an AC-coupled stage: loop gain is Aol*beta
  # measured at its own 0 dB crossing, and that is well defined whether or
  # not the signal path is capacitively coupled.
  #
  # `peaking` is declined rather than given a limit. It is measured against
  # the response's *first swept point*, and this stage's gain there is unity
  # by design -- C4 blocks DC, which is the whole point of a single-supply
  # stage -- so what it reports is the 35 dB mid hump, not resonance. A
  # limit set above that would be a claim that cannot fail, which is worse
  # than no claim; the gain claims below say the same thing and mean it.
  role "opamp_stage", drive, opamp = U1A, input = vamp, output = vout,
       minPhaseMargin = 50.deg, without = "peaking"

  # What this stage is actually specified by, from `gain_stage`, which
  # measures against the response's maximum rather than against DC.
  #
  # The mid hump is the TS808. It is not a side effect of the parts: C4 and
  # R6 put the bottom of the band around 700 Hz so the stage falls back to
  # unity below it rather than passing bass into the clippers, and the 51 pF
  # across the feedback brings the top down so there is no gain left where a
  # guitar speaker cannot reproduce it anyway. Both edges are claimed,
  # because a coupling capacitor changed by one E12 step moves them and
  # nothing else in this file would notice.
  #
  # 1 + (51k + 250k)/4.7k is 36 dB with the drive pot at half travel; the
  # amplifier's finite loop gain up there costs about a dB.
  role "gain_stage", voicing, opamp = U1A, input = vamp, output = vout,
       minGain = 33.dB, maxGain = 38.dB,
       fLoMax = 800.Hz, fHiMin = 5.kHz

  # And what it does when it is *driven*, which for an overdrive is the only
  # question that really matters. Everything above is small-signal: `.ac`
  # linearises about the operating point, so D1/D2 are whatever conductance
  # they have at rest and never clip. Here they do.
  #
  # 50 mV peak is a guitar pickup at a hard strum. The output swing is
  # bounded near a diode drop either side of the bias, because that is what
  # antiparallel silicon across the feedback network does, and the gain
  # collapses from 35 dB small-signal to about 20 dB at this level -- the
  # compression that is the whole point of the pedal.
  #
  # `minThd` is not a mistake. On an overdrive too *little* distortion is
  # the defect: a stage measuring clean here has lost its clippers.
  role "large_signal", overdrive, opamp = U1A, input = vamp, output = vout,
       driveV = 50.mV, driveF = 1.kHz,
       minThd = 10.0, maxThd = 45.0,
       minSwing = 0.6.V, maxSwing = 1.2.V

  require dc_voltage(vref) == 4.5.V, band = 5.pct,
          id = "REQ-TS-BIAS-001",
          because = "every stage swings around this node; off-centre bias " &
                    "clips one half of the waveform before the diodes do"

quit(verifyMain(d))
