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
##          measured 4.9616 V -- the 0.01% left is the error amplifier's
##          finite DC gain, which is a property of the model and is stated
##          in it. The averaged model commands a *duty* rather than a switch
##          voltage, so the error it needs is `D / aol` rather than
##          `V_SW / aol` and the residual is an order smaller than it was
##
##   soft start: 1.9 uA into 10 nF is 190 V/s at the pin, and TR/SS is the
##          reference while it is below 0.970 V, so the output ramps
##          190 * (1 + 1M/243k) = 972 V/s -> 5.1 ms to regulation,
##          4.08 ms 10-90%.  Measured 4.08 ms, through the part's own model
##          rather than through the ramp `analyzeStartup` would otherwise
##          have assumed -- see the note above that claim.
##
##   output ripple: the inductor's current triangle across the output
##          capacitor. dI = V_OUT (1 - D) / (L f) = 0.94 A at D = 0.43, into
##          3 mohm of ESR and the capacitance left after DC-bias derating.
##          Measured 6.95 mV.
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
      # The datasheet's headline: a 42 V, **5 A** synchronous step-down.
      # Stated on the part rather than in a claim because that is what it
      # describes, and `maxOutputDerating` below reads it back -- so fitting
      # a different converter changes the limit in one place.
      current_rating = 5.0.A

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
  # The datasheet's 3.3 uH, and the two ratings a real part is bought by.
  # They are stated on the *part* rather than in the claim below because that
  # is where they belong -- they describe the component somebody chose, not
  # the circuit -- and `current_path`'s derating claims read them back, so
  # the numbers appear once. A Wurth 74438357033 is 11 A saturation, 6.5 A
  # continuous at 40 degC rise.
  component L1, kind = "inductor", value = "3.3u":
    pin "1", sw, kind = ptPassive
    pin "2", vout, kind = ptPassive
    spec:
      isat = 11.0.A
      current_rating = 6.5.A

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

  # --- one role for the converter ---------------------------------------
  #
  # `switching_regulator` bundles what `regulator`, `settled_rail` and
  # `current_path` were stating separately here, and the reason to bundle is
  # not brevity. Those three were describing one part, and the *window* they
  # share had to be written out three times with nothing keeping the copies
  # in step -- edit one and two claims quietly start describing a different
  # twenty microseconds from the third.
  #
  # Everything below is opt-in: the role claims nothing it was not given a
  # number for.
  #
  # **The window is 20 us from 300 us**, shared by every steady-state claim
  # below so the copies cannot drift. It is a judgement about the circuit --
  # a converter's output is settled a hundred microseconds after start-up and
  # 20 us is 20 switching cycles, enough for a peak-to-peak to be about the
  # ripple rather than about the sampling -- and no longer a constraint of
  # the model: `lt8640a_sw` now runs at any print step from ~1 ns up, so
  # `analyzeTransient`'s `tWindow / 1000` and `analyzeOscillation`'s
  # `tWindow / 10000` (a 2 ns step) both simulate cleanly. That is what lets
  # the `fSw` claim below exist -- see `docs/RESOLVED_FINDINGS.md` §66 for
  # what the switching edge used to do to a 2 ns step.
  role "switching_regulator", buck,
       regulator = U1, output = vout,
       switch = sw, inductor = L1, sense = L1,
       source = V1, input = vin,

       # The way up. The soft start is the one number on this board set by a
       # single capacitor and by nothing else: 1.9 uA out of TR/SS into CSS
       # is 190 V/s at the pin, and TR/SS is the reference while it is below
       # 0.970 V, so the output follows at 190 * (1 + 1M/243k) = 972 V/s,
       # reaching regulation in 5.1 ms and passing 10-90% in 4.08 ms.
       #
       # The rise time is claimed at 5 ms rather than at the measured 4.08:
       # CSS is a 10% part and the 1.9 uA is a typical with a min and a max
       # around it, so a claim at the measured figure would be a claim about
       # one corner of one part. `tRun` is a condition rather than a limit --
       # it says how long the run was, not how long the ramp may be -- and
       # 8 ms is comfortably past the 5.1 ms to regulation.
       #
       # Two consequences of the part carrying its own model are visible in
       # the report. The run starts from **zero with uic** rather than from a
       # solved operating point: it has to, because an operating point finds
       # the state a soft start settles *to*, so the run would begin at the
       # end of the ramp and report a rise time of zero. And **no inrush is
       # measured** -- the stand-in drives a switch node into L1, so the
       # current reaching VOUT is the inductor's and there is no single
       # branch to put a probe in series with. An honest gap rather than a
       # zero.
       voltage = 4.962.V, band = 2.pct, tRun = 8.0.ms,
       maxRiseTime = 5.0.ms, maxOvershoot = 2.0,

       # The settled window, shared by every steady-state claim below.
       tSettle = 300.0.us, tWindow = 20.0.us,

       # The switching frequency, set on the board by RT (41.2 k -> 1 MHz)
       # and passed to the model the same way. `analyzeOscillation` counts
       # switch-node edges over the settled window, so this checks that the
       # model is actually switching at the rate the board asks for -- and,
       # since RT and the model's `fsw` are two separate statements of one
       # number, that they agree. Measured 1.00 MHz; the default 10% band is
       # comfortable.
       fSw = 1.0e6,

       # What is left moving on the rail. 10 mV is the budget, and the
       # arithmetic behind it is worth writing down because the measurement
       # is otherwise unfalsifiable: 0.94 A of inductor ripple across 3 mohm
       # of ESR is 2.8 mV, and the same current into the derated 65 uF for
       # half a cycle is another 1.8 mV, with the two a quarter cycle apart.
       # The rest is COUT2 and the ESL.
       maxRipple = 10.0.mV,

       # The inductor's current, over that same window -- and the reason the
       # ripple figure above is believable at all. 6.95 mV of output ripple
       # is a current triangle across an ESR, so a claim on the *rail* rests
       # entirely on a current nothing was checking. dI = Vout(1-D)/(L f)
       # with D = Vout/Vin = 0.413 is 0.879 A at 12 V in.
       #
       # `maxIsatDerating` states no current at all: it reads L1's own `isat`
       # back off the part. 60% of saturation is the usual place to sit; past
       # the knee the inductance collapses and the ripple this run measured
       # stops describing the part that is fitted.
       iRipple = 0.879.A, iRippleBand = 15.pct,
       maxIsatDerating = 0.6,

       # What the part is delivering, against what the part is rated for.
       # `maxOutputDerating` names no current either -- it reads U1's own
       # `current_rating` -- and it is measured through L1 because a code
       # model has no terminal current of its own to probe. The average is
       # the 5 A load; the peak is the top of the same triangle.
       #
       # The derating limit is **1.0**, and that is not a limit chosen
       # loosely: this board is the front page's, which specifies the part
       # at exactly its rated 5 A, so there is no headroom to claim and the
       # only honest statement is that the part may not be run past what it
       # is rated for. It measures 994 m -- the last 0.6% is the ripple
       # triangle's contribution to the RMS, which the average does not see
       # and which is the reason this is worth measuring rather than
       # dividing on paper. A load a percent heavier fails it.
       #
       # These are the *standing* numbers, and only those: the setup key
       # they carry is the settled window, so they batch into the same
       # `.tran` as the ripple claims above -- a run with no load step in
       # it. What the part draws at the top of the step is the step's own
       # question, and the answer to it is the droop below rather than a
       # second current claim, because a rail that holds its band through a
       # step was by definition delivering the current the step asked for.
       maxOutputCurrent = 5.6.A, maxOutputAvg = 5.2.A,
       maxOutputDerating = 1.0,

       # Ripple rejection, by the **tone** method and necessarily so: an
       # `.ac` sweep sees exactly nothing through an XSPICE code model,
       # because a code model contributes to the AC matrix only if it sets
       # AC_GAIN and neither of this part's does. Measured here at 71.9 dB.
       #
       # 100 kHz is a tenth of the switching frequency, which is where input
       # ripple on a board like this actually lives -- it is what the input
       # capacitors leave behind. 1 V of it is large, and deliberately: at
       # 500 mV the tone at the output is not clearly above the converter's
       # own broadband content and the measurement is refused rather than
       # guessed at, which is the analysis working. The window is eight
       # periods at 500 points each, which works out to the same 20 ns step
       # the ripple runs use.
       minPsrrDb = 60.dB, psrrAtF = 100.kHz, psrrRippleV = 1.0.V,
       psrrPeriods = 8, psrrPoints = 500,

       # The step: 1 A arriving in a microsecond on top of RLOAD's standing
       # 5 A. An ordinary FPGA or radio waking up looks like this, and 1 A
       # is as much as this part can be asked for -- not because 6 A is
       # thermally fine for forty microseconds (it is; a continuous rating
       # is a thermal one) but because the switching model's cycle-by-cycle
       # limit is 7 A of *peak* inductor current, and 6 A of average plus
       # half of the 0.9 A triangle is already 6.45 A of it. Past that the
       # loop is in current limit and the droop measured is the limit's,
       # not the loop's. Stepping to 2 A measures 383 mV and never recovers,
       # which is that -- a true statement about a part being asked for more
       # than it has, and not the question this claim is asking.
       #
       # What holds the rail through it is COUT and the loop, in that order,
       # and the order is the whole point. The first microsecond is the
       # capacitor alone -- a loop crossing over at tens of kilohertz has
       # not noticed yet -- so the leading edge is 1 A across COUT's 3 mohm
       # of ESR, about 3 mV, and after that the charge comes out of the
       # derated 65 uF until the loop catches up. Measured 21.3 mV, so the
       # 150 mV limit is a real budget with room in it rather than a fit to
       # the number that came back.
       #
       # `stepBand` is the reason the recovery figure means anything. It
       # defaults to 1% of where the rail settles under the new load, which
       # is 50 mV here -- more than twice the droop, so the rail never
       # leaves the band and the recovery reads a confident zero. 0.1% is
       # 5 mV, a quarter of the excursion, and the answer is then the time
       # the loop actually takes.
       #
       # `stepPoints` is 2000 across a 40 us recovery window, which is again
       # the 20 ns step the other settled runs use. `tHold` is left
       # unstated, so the load stays on and there is no release edge to
       # measure an overshoot at; that halves the run.
       iFrom = 0.0.A, iTo = 1.0.A, tEdge = 1.0.us,
       tStepAt = 300.0.us, tRecover = 40.0.us, stepPoints = 2000,
       stepBand = 0.001,
       maxDroop = 150.mV, maxRecover = 30.us

# Attach the behavioural model. After the block, because it sets
# `simReplace` on the real part rather than replacing it -- everything above
# still describes the board.
useLt8640a(d, "U1")

quit(verifyMain(d))
