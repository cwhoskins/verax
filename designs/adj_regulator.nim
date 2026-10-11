## Two rails from one adjustable part, with the datasheet doing the sizing.
##
##   verax check designs/adj_regulator.nim
##
## No resistor value appears below. `designs/lib/adjreg.nim` carries the
## LM317 as a *value* -- its reference, its ADJ-pin current, its output
## range, its dropout, its minimum load and its thermal resistance -- and the
## equations that turn those into a programming network. This file says what
## it wants: 15 V in, 5 V at 100 mA and 12 V at 50 mA out.
##
## ## Why the claims are worth making
##
## The simulation does not read back what the equations computed. The
## regulator is replaced, for simulation only, by the loop it closes -- an
## error amplifier holding the reference between OUT and ADJ, and a current
## source for the ADJ pin -- so ngspice solves the divider that is actually
## in the netlist and reports what the rail actually comes to. The claim
## compares that to the voltage this file asked for.
##
## So the check fails if the design equation is wrong or incomplete, and it
## fails at the precision the claim states. Dropping the `iAdj * rAdj` term
## from `setResistor` -- the term everyone drops -- picks 720 R instead of
## 713 R for the 5 V rail and the simulator reports 5.036 V, which misses the
## 0.5% band below. Rounding to E96 costs the 12 V rail 0.25%, which does
## not.
##
## ## Two things this design states that the equations then use
##
## The **input current** is derived, not declared. The loop model's pass
## element sits in series with the input pin, so every milliamp the rail
## delivers -- the load's, and the programming divider's -- is drawn through
## it out of `vboard`; only the part's quiescent draw is stated. That is what
## puts a real drop across the 1 ohm of supply lead below, and the claim on
## `vboard` is what tests it: the figure this file predicts has to include
## the two programming dividers, which is exactly the term a hand calculation
## forgets.
##
## The **dissipation** is where the interesting answer is. The 5 V rail burns
## (14.8 - 5) V at the 100 mA of load plus the 5.2 mA the divider programs --
## a little over a watt -- and a TO-220 in free air is about 50 degC/W, so
## `delta_t` on that part comes out at 52 degC and the readiness report names
## it as the hottest thing on the board. At the 60 degC top of the stated
## ambient range that is a junction at 112 degC against a 125 degC limit: it
## works, and it works with no margin worth having. The fix is a heatsink, and
## `thetaJA` on the part is where that gets said. None of that is simulated --
## `netlist/environment` wires the figures together and models nothing -- but
## a premise carried silently is a premise nobody checks.
##
## ## What the rails are asked as *regulators*
##
## Four node voltages say what the divider settles at. They do not say what
## happens when the input moves, when the load jumps, or when there is hum on
## the supply -- and those are what a regulator is bought for. The two
## `linear_regulator` roles below ask them:
##
##   * a **load step** -- 50 mA arriving in a microsecond on top of the 5 V
##     rail's standing 100 mA. 11.3 mV of droop, back inside a 1 mV band in
##     8.7 us. It is the one measurement here that depends on the pass
##     element's own resistance rather than on the loop gain, because above
##     the loop's bandwidth the division by `1 + aol` has stopped.
##
##   * **ripple rejection**, claimed on the 5 V rail by **both** methods at
##     once: one real 100 mV sinusoid through a `.tran` with the amplitude
##     extracted at exactly 120 Hz, and the same frequency read off an `.ac`
##     sweep of the linearised circuit. Different runs, different solvers,
##     and they agree to 0.002 dB at 62.9 dB. On the 12 V rail the claim is
##     the *worst point across a band* instead, which is the shape that
##     matters: 62.9 dB at 120 Hz is 19.9 dB by 10 kHz and 4.19 dB by 1 MHz.
##
##   * **line regulation** over an 8 V to 20 V supply. 0.129% across 12 V is
##     0.0107 %/V against the datasheet's 0.01 %/V typical -- and that is
##     derived from the loop the model closes, not read back off the part.
##
## ## What this design deliberately does not claim
##
## No PDN sweep and no start-up ramp. The pass element is a controlled
## source, so the rail is stiff at every frequency the loop still holds and a
## `z_max_in_band` claim would pass any target that could be set; and the
## part has no soft start, so there is no ramp at t = 0 to measure -- which
## is what `without = "final_v,overshoot"` on both roles below is declining.
## No dropout claim either -- nothing clamps the pass element below the
## input, so this rail never leaves regulation and `dropout_v` comes back
## *not evaluated* rather than as a number. Nor `maxLoadReg` or `maxZOut`:
## the pass resistance divided by the loop gain is about 10 uohm at DC, and
## a claim that cannot fail is worse than no claim. All of them are stated in
## `lib/adjreg.nim` as limits of the model rather than left to be
## discovered.

import verax/contract/dsl
import verax/verify
import verax/netlist/formats/spice as spiceFormat
import verax/parts/series          # `e96`, the ladder the 12 V rail rounds to

import ./lib/adjreg

# What the design is asking for. Everything below is derived from these.
let
  vSupply = 15.0.V
  rLead = 1.ohm            ## supply lead, connector and polyfuse, together
  iQ = 5.mA                ## regulator quiescent draw, per part
  v5 = 5.0.V
  i5 = 100.mA
  v12 = 12.0.V
  i12 = 50.mA

  # The board's input node sits below the supply by the lead drop, which is
  # what both regulators are actually working from -- so it is what the
  # headroom check inside the builder has to be given. Getting this wrong is
  # how a 12 V rail out of a 15 V supply passes on paper and drops out on the
  # bench.
  #
  # The programming divider is part of the draw and not an afterthought: at
  # 240 R the loop pushes `Vref / rSet` through it whatever the load is
  # doing, and there is one on each rail. Leave it out and the predicted
  # board voltage is 10 mV high -- which the claim below now catches,
  # because the loop model draws its output current *through* the input pin
  # rather than declaring it.
  iProg = programmingCurrent(lm317, 240.ohm)
  iTotal = Amps(float(i5) + float(i12) + 2.0 * float(iQ) +
                2.0 * float(iProg))
  vBoardNominal = Volts(float(vSupply) - float(iTotal) * float(rLead))

let d = design("adj_regulator"):
  environment:
    t_ambient_min = 0.degC
    t_ambient_max = 60.degC

  net gnd, kind = ntGround, name = "0", global = true
  net vsup, kind = ntPower:
    spec:
      voltage = 15.0.V
  net vboard, kind = ntPower:              # after the lead drop
    spec:
      voltage = vBoardNominal
  net v5rail, kind = ntPower:
    spec:
      voltage = 5.0.V
  net v12rail, kind = ntPower:
    spec:
      voltage = 12.0.V

  component V1, kind = "voltage_source", value = "DC 15":
    pin "+", vsup, kind = ptPower
    pin "-", gnd, kind = ptGround
    spec:
      voltage = 15.0.V

  component RLEAD, kind = "resistor", value = spiceValue(float(rLead)):
    pin "1", vsup,   kind = ptPassive
    pin "2", vboard, kind = ptPassive

  # Same part, same reference resistor, two outputs -- and two different
  # answers to "what can I buy". The 5 V rail takes the computed value; the
  # 12 V rail is rounded to E96, and what it then makes is recomputed from
  # the rounded part rather than reported back as the 12 V that was asked
  # for.
  instance XR5, adjustableRegulator(lm317, vin = vBoardNominal, vout = v5,
                                    iLoad = i5, rSet = 240.ohm,
                                    iQuiescent = iQ),
           [vboard, v5rail, gnd]
  instance XR12, adjustableRegulator(lm317, vin = vBoardNominal, vout = v12,
                                     iLoad = i12, rSet = 240.ohm,
                                     iQuiescent = iQ, series = e96),
           [vboard, v12rail, gnd]

  # The loads the currents above describe. Stated as resistors because that
  # is what the check needs them to be at DC; a real MCU or motor driver is
  # a regulated draw and would be a `driveSink` behind a connector.
  component RL5, kind = "resistor",
            value = spiceValue(float(v5) / float(i5)):
    pin "1", v5rail, kind = ptPassive
    pin "2", gnd,    kind = ptPassive
  component RL12, kind = "resistor",
            value = spiceValue(float(v12) / float(i12)):
    pin "1", v12rail, kind = ptPassive
    pin "2", gnd,     kind = ptPassive

  # --- claims ------------------------------------------------------------

  require dc_voltage(v5rail) == 5.0.V, band = 0.5.pct,
          id = "REQ-REG-5V-001",
          because = "the divider was sized by the full output equation, " &
                    "ADJ-pin term included, and the simulator solves that " &
                    "divider without reading anything this design computed " &
                    "-- so 0.5% is a check of the equation, not of the " &
                    "arithmetic being done twice"

  require dc_voltage(v12rail) == 12.0.V, band = 0.5.pct,
          id = "REQ-REG-12V-001",
          because = "the same equation with its bottom resistor rounded to " &
                    "a part that exists; what E96 granularity costs at " &
                    "12 V from a 1.25 V reference has to fit inside the " &
                    "same budget as everything else"

  # The loop's own promise, checked at the node it is made about: the part
  # holds its reference between OUT and ADJ, so the tap sits one reference
  # below the rail. If this reads 5 V the divider is open; if it reads 0 the
  # loop is not closing through it.
  require dc_voltage(XR5.innerNet("adj")) == 3.75.V, band = 1.pct,
          id = "REQ-REG-VREF-001",
          because = "Vout - Vref is what an LM317 actually regulates; the " &
                    "output voltage is a consequence of it and of two " &
                    "resistors, and this is the half that is the part's"

  # The 5 V rail as a *regulator* rather than as a node voltage. Everything
  # above reads what the divider settles at; none of it moves the input or
  # the load, and a part that holds its DC value perfectly can still pass a
  # hundred millivolts of mains hum straight through and sag 200 mV when the
  # MCU wakes.
  #
  # `without = "final_v,overshoot"` declines the two start-up claims the
  # base role makes by default. The part has no soft start and the loop
  # model has no ramp in it, so a run from power-on finds the rail already
  # where it belongs at t = 0 -- there is nothing there to measure and a
  # claim that cannot fail is worse than no claim.
  #
  # No `maxDropout`, no `maxLoadReg`, no `maxZOut`. All three are limits of
  # the loop model and all three are written down in `lib/adjreg.nim`:
  # nothing clamps the pass element below the input, so `dropout_v` comes
  # back not evaluated; and the pass resistance is divided by the loop gain,
  # so the DC output impedance is around 10 uohm and any `maxZOut` a person
  # would write passes without being a check. What the *load step* below
  # measures instead is that same resistance above the loop's bandwidth,
  # where the division has stopped -- which is the number a transient
  # actually depends on and the one a DC sweep cannot see.
  role "linear_regulator", reg5,
       regulator = XR5.innerComponent("U1"), output = v5rail,
       source = V1, input = vboard,
       voltage = 5.0.V, band = 0.5.pct,
       without = "final_v,overshoot",

       # 50 mA arriving in a microsecond on top of the standing 100 mA --
       # half again, which is an MCU coming out of stop mode. What holds the
       # rail through the first microsecond is COUT and nothing else: the
       # loop has not noticed. Measured 11.3 mV of droop and 8.7 us to come
       # back, against a 1 mV band rather than the 1% default -- at 1% the
       # band is 50 mV, four times the droop, the rail never leaves it and
       # the recovery reads a confident zero.
       iFrom = 0.0.A, iTo = 50.mA, tEdge = 1.0.us,
       tStepAt = 200.0.us, tRecover = 200.0.us, stepPoints = 2000,
       stepBand = 0.001,
       maxDroop = 50.mV, maxRecover = 100.us,

       # Ripple rejection at 120 Hz, which is where it matters on anything
       # fed from a bridge rectifier: 100 mV of hum on a 15 V supply is an
       # ordinary amount for a smoothing capacitor to leave behind.
       #
       # Claimed **twice, by both methods**, and that is the point of doing
       # it here. `minPsrrDb` puts one real 100 mV sinusoid through a
       # `.tran` and extracts the amplitude at exactly 120 Hz at each end;
       # `minPsrrBandDb` with `psrrAtF` set linearises the same circuit and
       # reads the same frequency off an `.ac` sweep. They are different
       # runs through different solvers and they agree to 0.002 dB -- 62.9
       # against 62.9 -- which is the cross-check the tone method needs,
       # because a tone measurement has a noise floor and an `.ac` sweep has
       # a linearisation, and neither one alone tells you which it hit.
       #
       # `tSettle` is 40 ms because the run has to start after the loop has
       # settled *and* on a whole period boundary of a 120 Hz tone, which is
       # 8.33 ms long.
       minPsrrDb = 55.dB, psrrAtF = 120.Hz, psrrRippleV = 100.mV,
       psrrPeriods = 6, psrrPoints = 400, tSettle = 40.0.ms,
       minPsrrBandDb = 55.dB, psrrFrom = 10.Hz, psrrTo = 1.kHz,

       # What the rail does when the supply moves, which is a slope and not
       # a bias: the operating point above is solved at one input voltage
       # and says nothing about it however precisely it lands. 8 V to 20 V
       # is the whole range this board could plausibly be fed over.
       #
       # 0.129% measured across 12 V of input is 0.0107 %/V, and the LM317
       # datasheet's typical line regulation is 0.01 %/V. That figure is not
       # read back from the part: it falls out of the loop gain the model
       # closes, which is the difference between a check and a tautology.
       vinFrom = 8.0.V, vinTo = 20.0.V, vinStep = 0.1.V,
       maxLineReg = 0.25

  # The same sweep, stated the way the datasheet states it: per volt of
  # input. `linear_regulator` claims the total movement across a range,
  # which is the board's question; `source_sweep` can also claim the slope,
  # which is the part's -- and the one a reader can hold against the LM317's
  # 0.01 %/V typical and 0.04 %/V maximum without knowing what range this
  # board was swept over. Twice the typical, comfortably inside the maximum
  # (measured 0.0107 %/V). Same source, range, step and nominal, so it shares
  # the role's `.dc` rather than running its own.
  role "source_sweep", reg5_line, source = V1, output = v5rail,
       input = vboard, vFrom = 8.0.V, vTo = 20.0.V, vStep = 0.1.V,
       nominal = 5.0.V, maxLineRegPerV = 0.02

  # The 12 V rail, and one claim only -- the **worst point across a band**
  # rather than a figure at one frequency. It is here because a rejection
  # number without a band is close to meaningless and this rail shows why:
  # the same part on the same board that rejects 62.9 dB at 120 Hz is down
  # to 19.9 dB by 10 kHz, and widening the band to 1 MHz finds 4.19 dB. The
  # loop gain has rolled off and COUT has not taken over, so there is a
  # decade or two in the middle where this rail is barely a filter at all.
  #
  # Which end of that a design cares about is a design question. 15 dB over
  # 10 Hz to 10 kHz is the claim that fits a board whose input ripple is
  # mains-derived; a board with a switcher upstream of it would have to
  # state the band up at the switching frequency and would not like the
  # answer.
  role "linear_regulator", reg12,
       regulator = XR12.innerComponent("U1"), output = v12rail,
       source = V1, input = vboard,
       voltage = 12.0.V, band = 0.5.pct,
       minPsrrBandDb = 15.dB, psrrFrom = 10.Hz, psrrTo = 10.kHz,
       without = "final_v,overshoot"

  require dc_voltage(vboard) == vBoardNominal, band = 0.5.pct,
          id = "REQ-REG-LEAD-001",
          because = "both regulators draw their load current through the " &
                    "supply lead, and the 12 V rail's headroom is measured " &
                    "from this node rather than from the supply"

quit(verifyMain(d))
