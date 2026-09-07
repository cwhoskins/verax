## A single-supply, AC-coupled amplifier, judged by its passband.
##
##   verax check <this file>
##
## The same op-amp as `opamp.nim`, on one supply instead of two, with the
## gain leg capacitively coupled. That one change makes `opamp_stage`'s
## headline claim meaningless and is the reason `gain_stage` exists.
##
## `bw_3db` and `gain_dc_db` are referenced to the **first swept point**,
## which is right for a DC-coupled stage and is the *stopband* of this one:
## Cg blocks DC, so the gain at DC is exactly 1 by construction. That is not
## a fault -- it is what makes a single supply work, since the stage has to
## sit at mid-rail and an amplifier with 20 dB of DC gain around a 2.5 V bias
## would try to put 25 V on a 5 V rail. Measure this circuit the DC-coupled
## way and you get a gain of 0.001 dB and a "bandwidth" measured 3 dB below
## unity, on the far side of a passband that has not started yet.
##
## So `gain_stage` references the response's own **maximum** instead:
## `gain_max_db` is the midband gain, and `f_lo_3db`/`f_hi_3db` are the two
## corners either side of it. Both edges are claimed below, because a
## coupling capacitor changed by one E12 step moves them and nothing else in
## this file would notice.
##
## Note what this role deliberately does *not* claim: stability. `peaking_db`
## cannot tell an intentional band-pass shape from resonance. State
## `opamp_stage` on the same parts as well when you want a phase margin too
## -- that is the supported way to have both, and `ts808_drive.nim` does it.

import verax/contract/dsl
import verax/verify

let d = design("gain_stage"):
  net gnd, kind = ntGround, name = "0"
  net vcc, kind = ntPower:
    spec:
      voltage = 5.0.V

  # The mid-rail bias. It is a `ntPower` net with a stated voltage rather
  # than a signal, and that is load-bearing in two places: an isolation
  # boundary terminates a rail at its stated voltage (an unstated one is cut
  # loose as a floating node, which changes the circuit rather than
  # substituting a number), and the feedback walk refuses to traverse a rail
  # -- which is right, because a bypassed bias node is an AC ground and not
  # a feedback path.
  net vref, kind = ntPower:
    spec:
      voltage = 2.5.V

  net vin,  kind = ntSignal     # what arrives at the connector
  net vamp, kind = ntSignal     # the amplifier's input, past the coupling cap
  net vn,   kind = ntSignal     # inverting input, the summing node
  net ng,   kind = ntSignal     # gain leg, below Rg
  net vout, kind = ntSignal

  component V1, kind = "voltage_source", value = "DC 5":
    pin "+", vcc, kind = ptPower
    pin "-", gnd, kind = ptGround
    spec:
      voltage = 5.0.V
  component C1, kind = "capacitor", value = "100n":
    pin "1", vcc, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0402"

  # --- the bias rail ------------------------------------------------------
  # Two equal resistors and a big bypass. The bypass is what makes it a rail
  # rather than a divider: without it the two 100k legs are in the signal
  # path and the stage's own output current modulates its bias.
  component Rb1, kind = "resistor", value = "100k":
    pin "1", vcc,  kind = ptPassive
    pin "2", vref, kind = ptPassive
  component Rb2, kind = "resistor", value = "100k":
    pin "1", vref, kind = ptPassive
    pin "2", gnd,  kind = ptPassive
  component Cb, kind = "capacitor", value = "10u":
    pin "1", vref, kind = ptPassive
    pin "2", gnd,  kind = ptPassive
    spec:
      package = "0805"
      dielectric = "X5R"
      voltage_rating = 16.0.V

  # --- the stage ----------------------------------------------------------
  # Cin blocks whatever DC the source carries and Rbias sets the input to
  # mid-rail. Together they are a high-pass at 1/(2*pi*100k*1u) = 1.6 Hz,
  # comfortably below the lower corner the gain leg sets.
  component Cin, kind = "capacitor", value = "1u":
    pin "1", vin,  kind = ptPassive
    pin "2", vamp, kind = ptPassive
    spec:
      package = "film"
  # The bleed, and it is not padding. Cin's outer plate touches nothing else
  # on this board, so with the connector empty that node has no DC path
  # anywhere -- its voltage is whatever charge happens to be on the cap. On
  # a bench that is the bang you hear when something is plugged in; here it
  # is a singular matrix, because a node with no DC reference is a row of
  # zeroes and ngspice says so by name ("check node vin"). A resistor to
  # ground defines it and costs nothing: 100k in parallel with the source is
  # invisible to anything that would drive this input.
  component Rsrc, kind = "resistor", value = "100k":
    pin "1", vin, kind = ptPassive
    pin "2", gnd, kind = ptPassive

  component Rbias, kind = "resistor", value = "100k":
    pin "1", vamp, kind = ptPassive
    pin "2", vref, kind = ptPassive

  component U1, kind = "opamp", partNumber = "TLV9061":
    pin "IN+", vamp, kind = ptInput
    pin "IN-", vn,   kind = ptInput
    pin "OUT", vout, kind = ptOutput
    pin "V+",  vcc,  kind = ptPower
    pin "V-",  gnd,  kind = ptGround
    spec:
      gain = 120e3
      gbw = 3.MHz

  # The gain leg, and Cg is the whole trick. At DC it is an open circuit, so
  # no current flows in Rf and the stage is a unity-gain follower sitting at
  # whatever Rbias put on its input. In the passband Cg is a short, so the
  # gain is 1 + Rf/Rg = 11, or 20.8 dB.
  #
  # Cg with Rg is also the lower corner: 1/(2*pi*1k*10u) = 15.9 Hz. Making
  # Cg bigger moves that corner down and nothing else -- it does not change
  # the midband gain, which is a ratio of resistors.
  component Rf, kind = "resistor", value = "10k":
    pin "1", vn,   kind = ptPassive
    pin "2", vout, kind = ptPassive
  component Rg, kind = "resistor", value = "1k":
    pin "1", vn, kind = ptPassive
    pin "2", ng, kind = ptPassive
  component Cg, kind = "capacitor", value = "10u":
    pin "1", ng,  kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0805"
      dielectric = "X5R"
      voltage_rating = 16.0.V

  # --- claims -------------------------------------------------------------

  role "power_rail", supply, rail = vcc, voltage = 5.0.V, band = 5.pct

  require dc_voltage(vref) == 2.5.V, band = 2.pct,
          id = "REQ-GS-BIAS-001",
          because = "the stage swings around this node, so an off-centre " &
                    "bias costs headroom on one side before anything else " &
                    "in the circuit is at fault"

  # The stage's own DC operating point, which on a single supply is a claim
  # worth making separately: the follower should sit exactly where the bias
  # put it, and a stage that does not is one where DC is leaking through the
  # gain leg -- a shorted or wrongly-fitted Cg, which changes nothing else
  # this file measures until the output hits a rail.
  require dc_voltage(vout) == 2.5.V, band = 2.pct,
          id = "REQ-GS-OPPT-001",
          because = "with Cg blocking DC the stage is a unity-gain follower " &
                    "at DC, so its output must sit at the bias it was given"

  # 1 + 10k/1k is 20.8 dB; the amplifier's finite loop gain costs a little.
  # The band is stated either side rather than as a floor because too much
  # gain is as much a defect as too little on a stage that has to fit
  # between two rails.
  #
  # The corners are claimed as *bounds*, not as values: `fLoMax` says the
  # passband has started by 100 Hz and `fHiMin` says it is still going at
  # 100 kHz. That is how a passband is specified -- a stage that reaches
  # further is not at fault.
  #
  # To claim the gain at one frequency instead of at the response's peak
  # ("20 dB at 1 kHz", the way an audio stage is actually specified), add
  # `atF = 1.kHz`: it moves the gain claim from `gain_max_db` onto
  # `gain_at_f` and stamps the frequency into the assertion's conditions.
  role "gain_stage", stage, opamp = U1, input = vamp, output = vout,
       minGain = 19.dB, maxGain = 21.dB,
       fLoMax = 100.Hz, fHiMin = 100.kHz

quit(verifyMain(d))
