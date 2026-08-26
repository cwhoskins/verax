## One amplifier stage, judged the way an amplifier is judged: bandwidth,
## peaking, and how far it is from oscillating.
##
##   nimcir check <this file>
##
## A non-inverting amplifier of gain 2. `opamp_stage` claims three things
## about it, and they come from **two** different simulations:
##
##   * `bw_3db` and `peaking_db` from a closed-loop `.ac` sweep, and
##   * `phase_margin_deg` from a *separate* run that breaks the loop at the
##     inverting input, injects there, and measures the loop transmission.
##
## That second run is not a refinement of the first. Phase margin is a
## property of the loop gain `Aol*beta` at its 0 dB crossing, and the
## closed-loop response `Aol/(1+Aol*beta)` is a different function with a
## different phase -- "180 + phase at unity gain" read off the closed-loop
## curve gives a number that looks like a phase margin, moves in roughly the
## right direction, and is not one. So the closed-loop pass reports peaking,
## which is an honest indicator (a closed-loop peak is what low margin looks
## like from outside), and the margin comes from the loop measurement.
##
## Use `gain_stage` instead of this role for a stage that is AC coupled --
## see `gain_stage.nim`. Use both together when you want a margin *and* a
## passband; they are separate roles rather than one because `peaking_db`
## cannot tell an intentional band-pass shape from resonance.

import nimcir/contract/dsl
import nimcir/verify

let d = design("opamp"):
  net gnd, kind = ntGround, name = "0"
  net vcc, kind = ntPower:
    spec:
      voltage = 5.0.V
  net vee, kind = ntPower:
    spec:
      voltage = -5.0.V

  net vin,  kind = ntSignal     # the stage's input
  net vn,   kind = ntSignal     # inverting input, the feedback summing node
  net vout, kind = ntSignal     # the stage's output

  # --- supplies -----------------------------------------------------------
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

  component C1, kind = "capacitor", value = "100n":
    pin "1", vcc, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0402"
  component C2, kind = "capacitor", value = "100n":
    pin "1", vee, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0402"

  # --- the stage ----------------------------------------------------------
  # `gain` and `gbw` are the datasheet's own two numbers, and stating them is
  # not bookkeeping: the substituted macromodel defaults to 100k and 1 MHz
  # when a part says nothing, and every bandwidth this file claims is that
  # figure divided by the closed-loop gain. Leave `gbw` off and the report
  # is describing the default rather than the part -- which reads exactly
  # like a claim about your circuit.
  component U1, kind = "opamp", partNumber = "TL072":
    pin "IN+", vin,  kind = ptInput
    pin "IN-", vn,   kind = ptInput
    pin "OUT", vout, kind = ptOutput
    pin "V+",  vcc,  kind = ptPower
    pin "V-",  vee,  kind = ptGround
    spec:
      gain = 200e3          # 200 V/mV typical
      gbw = 3.MHz

  # The input's DC return, and it is not optional. A non-inverting input is
  # the gate or base of the amplifier's front end: it draws a bias current,
  # and with nothing to draw it *through* the node has no DC path anywhere.
  # That is a real defect on a real board -- the input drifts to a rail -- and
  # it is also why leaving it out makes ngspice give up here rather than
  # report a number: the operating point genuinely does not exist. On a
  # board fed from a previous stage, that stage's output is the return and
  # this resistor is not fitted.
  component Rin, kind = "resistor", value = "10k":
    pin "1", vin, kind = ptPassive
    pin "2", gnd, kind = ptPassive

  # Gain = 1 + Rf/Rg = 2. The *ratio* sets the gain; the absolute values set
  # how much current the output wastes driving its own feedback and how much
  # Johnson noise the network contributes, which is why 10k/10k rather than
  # 10R/10R or 10M/10M.
  component Rg, kind = "resistor", value = "10k":
    pin "1", vn,  kind = ptPassive
    pin "2", gnd, kind = ptPassive
  component Rf, kind = "resistor", value = "10k":
    pin "1", vn,   kind = ptPassive
    pin "2", vout, kind = ptPassive

  # --- claims -------------------------------------------------------------

  role "power_rail", pos, rail = vcc, voltage = 5.0.V, band = 5.pct
  role "power_rail", neg, rail = vee, voltage = -5.0.V, band = 5.pct

  # 3 MHz of gain-bandwidth at a closed-loop gain of 2 is a corner at about
  # 1.5 MHz. The claim is stated at 1 MHz rather than at the measured figure
  # deliberately: a limit restated at whatever came back is a limit that can
  # only ever pass, and this one has a job -- swap in a part with a tenth the
  # gain-bandwidth and it fails, which is exactly the substitution nothing
  # else in this file would notice.
  #
  # 90 degrees of phase margin is what a single-pole loop gives, and it is
  # what this circuit should measure: a plain resistive feedback network adds
  # no phase of its own. A margin materially below that means something in
  # the feedback path has a pole in it -- stray capacitance at the summing
  # node is the usual culprit -- and 50 degrees is the conventional floor.
  role "opamp_stage", stage, opamp = U1, input = vin, output = vout,
       minBandwidth = 1.MHz, minPhaseMargin = 50.deg, maxPeaking = 0.5.dB

quit(verifyMain(d))
