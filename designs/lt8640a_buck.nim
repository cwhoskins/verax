## The LT8640A front-page reference design: 12 V in, 5 V at 5 A.
##
##   nimcir check designs/lt8640a_buck.nim
##
## Analog Devices' own typical application for a 42 V, 5 A synchronous
## step-down Silent Switcher, built exactly as the datasheet draws it
## (LT8640A Rev. 0, front page): 3.3 uH, 100 uF out, 1 M / 243 k feedback,
## 10 nF on TR/SS, 41.2 k on RT for 1 MHz.
##
## **Why this design needed a code model written for it.** ADI publishes an
## LTspice model for this part and it is unusable here: LTC's
## switching-regulator models are encrypted and built on undocumented
## `A`-device primitives private to LTspice, which ngspice cannot read by
## design rather than by oversight. So the choice was between not simulating
## the part at all and writing a behavioural model. `designs/lib/lt8640a.nim`
## is that model -- the first design in this repository to carry one, and the
## first to need `spice/xspice` for something other than a demonstration.
##
## The model is attached through `simReplace`, so everything below still
## describes the **real part**: `kind = "buck"`, the datasheet's pin names,
## the designator a BoM would carry. Nothing here is a simulation artefact.
##
## What the numbers should be, from the datasheet and nothing else:
##
##   V_OUT = 0.970 * (1 + 1M/243k) = 4.962 V
##          measured 4.959 V -- the 0.05% is the error amplifier's finite
##          DC gain, which is a property of the model and is stated in it
##
##   soft start: 1.9 uA into 10 nF is 190 V/s at the pin, and TR/SS is the
##          reference while it is below 0.970 V, so the output ramps
##          190 * (1 + 1M/243k) = 972 V/s -> 5.1 ms to regulation,
##          4.08 ms 10-90%.  Measured 4.09 ms, through the part's own model
##          rather than through the ramp `analyzeStartup` would otherwise
##          have assumed -- see the note above that claim.
##
##   output ripple: the inductor's current triangle across the output
##          capacitor. dI = V_OUT (1 - D) / (L f) = 0.94 A at D = 0.43, into
##          3 mohm of ESR and the capacitance left after DC-bias derating.
##          Measured 7.12 mV.
##
## **Two models, and the ripple is why.** `useLt8640a` attaches both. The
## averaged model answers the rail voltage and the start-up ramp; it emits the
## switch node's cycle average rather than its waveform, so there is no ripple
## in it to measure at all. The switching model answers the ripple and costs
## about fifty timepoints per cycle for the privilege. Which one runs is not a
## choice this file makes: `spice/transform.selectSimModel` picks by what is
## being asked, so the `.op` behind `dc_voltage` gets the averaged one and the
## `.tran` behind `ripple_pp` gets the switching one, in the same check.
##
## **What this design still does not claim, and why.** No phase margin. The
## averaged model has no internal compensation in it, and the switching model
## carries a compensator chosen for a sensible loop rather than fitted to the
## part's -- which is not published. A margin measured through either would be
## a claim about the model.

import nimcir/contract/dsl
import nimcir/verify

import ./lib/lt8640a

let d = design("lt8640a_buck"):
  net gnd, kind = ntGround, name = "0"

  net vin, kind = ntPower:
    spec:
      voltage = 12.0.V
  net vout, kind = ntPower:
    spec:
      voltage = 4.962.V
  net sw,   kind = ntSignal                # switch node
  net fb,   kind = ntSignal                # feedback tap
  net trss, kind = ntSignal                # soft-start
  net pg,   kind = ntSignal                # power good
  net bst,  kind = ntSignal                # bootstrap
  # INTVCC is an output of the part, not an input to it, but it is still a
  # rail: RT hangs off it and an analysis that cuts a fragment out around
  # this area has to know what to drive it with. The datasheet says 3.4 V.
  net vcc,  kind = ntPower:                # INTVCC, internal 3.4 V regulator
    spec:
      voltage = 3.4.V

  # --- input ------------------------------------------------------------
  component V1, kind = "voltage_source", value = "DC 12":
    pin "+", vin, kind = ptPower
    pin "-", gnd, kind = ptGround
    spec:
      voltage = 12.0.V

  # The datasheet is specific about these and the reason is layout, not
  # filtering: two 1 uF parts, one per VIN pin, as close to the package as
  # the footprint allows, plus a 2.2 uF or larger bulk. At 1 MHz with 5 A of
  # switched current the loop area between these and the die is what sets
  # radiated emissions, which is the entire point of a "Silent Switcher".
  component C1, kind = "capacitor", value = "4.7u":
    pin "1", vin, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "1210"
  component C2, kind = "capacitor", value = "1u":
    pin "1", vin, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0603"
  component C3, kind = "capacitor", value = "1u":
    pin "1", vin, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0603"

  # --- the regulator ----------------------------------------------------
  component U1, kind = "buck", partNumber = "LT8640A":
    pin "VIN",   vin,  kind = ptPower
    pin "SW",    sw,   kind = ptOutput
    pin "FB",    fb,   kind = ptInput
    pin "EN",    vin,  kind = ptInput      # tied to VIN: shutdown unused
    pin "TR/SS", trss, kind = ptPassive
    pin "PG",    pg,   kind = ptOutput
    pin "BST",   bst,  kind = ptPassive
    pin "INTVCC", vcc, kind = ptPower
    pin "GND",   gnd,  kind = ptGround
    spec:
      voltage = 4.962.V

  component CBST, kind = "capacitor", value = "100n":
    pin "1", bst, kind = ptPassive
    pin "2", sw, kind = ptPassive
    spec:
      package = "0402"
  component CVCC, kind = "capacitor", value = "1u":
    pin "1", vcc, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0603"

  # 10 nF sets the ramp. This is the one component on the board whose value
  # is a *timing* choice rather than a filtering one: 1.9 uA into it is
  # 190 V/s at the pin, and the output follows at that times the feedback
  # ratio. Change it to 100 nF and start-up takes 51 ms.
  component CSS, kind = "capacitor", value = "10n":
    pin "1", trss, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0402"

  # --- output -----------------------------------------------------------
  component L1, kind = "inductor", value = "3.3u":
    pin "1", sw, kind = ptPassive
    pin "2", vout, kind = ptPassive

  component COUT, kind = "capacitor", value = "100u":
    pin "1", vout, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "1210"
      esr = 3.mohm
      esl = 1.2.nH
  component COUT2, kind = "capacitor", value = "100n":
    pin "1", vout, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0402"

  # The feedback divider, and the only two components that set the output
  # voltage. 1% parts, because a 5% resistor here is a 5% rail.
  component R1, kind = "resistor", value = "1meg":
    pin "1", vout, kind = ptPassive
    pin "2", fb, kind = ptPassive
    spec:
      tolerance = 1.pct
  component R2, kind = "resistor", value = "243k":
    pin "1", fb, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      tolerance = 1.pct

  # 10 pF across the top leg. The datasheet calls it a phase lead capacitor
  # and asks for 4.7 to 22 pF: it puts a zero in the feedback path to claw
  # back the phase the output pole costs. The averaged model cannot show what
  # it does -- that is a loop-compensation effect and the model has no
  # internal compensation -- but leaving it off the board would be wrong.
  component CFF, kind = "capacitor", value = "10p":
    pin "1", vout, kind = ptPassive
    pin "2", fb, kind = ptPassive
    spec:
      package = "0402"

  component RT, kind = "resistor", value = "41.2k":
    pin "1", vcc, kind = ptPassive
    pin "2", gnd, kind = ptPassive

  # A 1 ohm load: 5 V at 5 A is what the front page is specified at.
  component RLOAD, kind = "resistor", value = "1":
    pin "1", vout, kind = ptPassive
    pin "2", gnd, kind = ptPassive

  # --- claims -----------------------------------------------------------

  role "power_rail", input, rail = vin, voltage = 12.0.V, band = 5.pct

  # The claim the whole exercise is for: the rail this part makes is the one
  # the divider asks for. It is worth stating even though it looks like
  # arithmetic, because it is measured through the *model* -- so it is
  # simultaneously a check on the board's divider and on whether the part is
  # being simulated at all. Before the `.cm` reached the simulator this came
  # back as an ngspice error about an undefined model, three steps from the
  # cause.
  require dc_voltage(vout) == 4.962.V, band = 2.pct,
          id = "REQ-BUCK-VOUT-001",
          because = "R1/R2 and the 0.970 V reference are the only things " &
                    "that set this rail; there is no trim and no margin"

  # The claim the switching model exists for. `tSettle` is 300 us because the
  # model starts from the operating point rather than from zero -- there is no
  # soft start to wait out, only the compensation loop finding the load
  # current, which it does in about fifty microseconds at this crossover. The
  # window is twenty switching cycles.
  #
  # 10 mV is the budget, and the arithmetic behind it is worth writing down
  # because the measurement is otherwise unfalsifiable: 0.94 A of inductor
  # ripple across 3 mohm of ESR is 2.8 mV, and the same current into the
  # derated 65 uF for half a cycle is another 1.8 mV, with the two a quarter
  # cycle apart. The rest is COUT2 and the ESL.
  role "settled_rail", ripple, rail = vout,
       tSettle = 300.0.us, tWindow = 20.0.us,
       voltage = 4.962.V, band = 2.pct, maxRipple = 10.0.mV

  # The soft start, which is the one number on this board set by a single
  # capacitor and by nothing else. 1.9 uA out of TR/SS into CSS is 190 V/s at
  # the pin; TR/SS is the reference while it is below 0.970 V, so the output
  # follows at 190 * (1 + 1M/243k) = 972 V/s, reaching regulation in 5.1 ms
  # and passing 10-90% in 4.08 ms. Measured 4.09 ms.
  #
  # **This claim needed `analyzeStartup` to stop standing the regulator up
  # itself.** Its default is an assumed PWL ramp, which is the right model
  # for a part a netlist merely names -- and here it would have measured the
  # ramp this tool invented rather than the one CSS sets, reporting a number
  # that moves when you edit `StartupSpec.softStart` and not when you change
  # the capacitor. The part carries a model, so the model runs.
  #
  # Two consequences of that are worth knowing, because both are visible in
  # the report:
  #
  #   * the run starts from **zero with uic** rather than from a solved
  #     operating point. It has to: an operating point finds the state the
  #     soft start settles *to*, so the .tran would begin at the end of the
  #     ramp and report a rise time of zero.
  #   * **no inrush is measured.** The stand-in is a code model driving a
  #     switch node into L1, so the current reaching VOUT is the inductor's
  #     and there is no single branch to put a probe in series with. That is
  #     an honest gap rather than a zero: see docs/findings.md, where the
  #     inductor's peak current is the check a converter most wants and is
  #     still missing.
  #
  # `tRun` is 8 ms, comfortably past the 5.1 ms to regulation, and is a
  # condition rather than a limit -- it says what was run. The rise time is
  # claimed at 5 ms rather than at the measured 4.09: CSS is a 10% part and
  # the 1.9 uA is a typical with min and max around it, so a claim at the
  # measured figure would be a claim about one corner of a part.
  role "regulator", softstart, regulator = U1, output = vout,
       voltage = 4.962.V, band = 2.pct, tRun = 8.0.ms,
       maxRiseTime = 5.0.ms, maxOvershoot = 2.0

# Attach the behavioural model. After the block, because it sets
# `simReplace` on the real part rather than replacing it -- everything above
# still describes the board.
useLt8640a(d, "U1")

quit(verifyMain(d))
