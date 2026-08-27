## A linear regulator coming up at power-on.
##
##   nimcir check <this file>
##
## The `power_rail` template asks where a rail *sits*. This one asks how it
## *arrives*, which is a different question with a different analysis behind
## it: a `.tran` from zero rather than a `.op`. Four things only the way up
## can tell you --
##
##   * how long the rail takes to get there (`rise_time_10_90`),
##   * whether it goes past and comes back (`overshoot_pct`),
##   * how much current the output capacitors demand while charging
##     (`inrush_peak`), and
##   * when it stops moving (`settle_time`).
##
## **State plainly what this measures.** Unless the regulator carries a
## `simReplace` of its own, it is stood in for by an ideal source following
## an assumed soft-start ramp, and what is measured is what the *output
## network* does with that ramp -- the RC rise, the overshoot that network
## produces, the charging current. There is no control loop here, no current
## limit or foldback, no dropout and no load regulation. A rail that
## overshoots here would overshoot on a real board; a rail that looks clean
## here can still misbehave for loop-stability reasons this cannot see.
##
## **And it is why there is no ripple-rejection claim here**, though the role
## offers one and the parameters are two lines away. The stand-in is an ideal
## source at the output voltage with no path from its input to its output at
## all, so a PSRR measurement through it would report infinite rejection --
## a confident number about a stand-in rather than about a part. The analysis
## refuses it rather than answering: an output at the solver's noise floor
## while the input is not is reported as `not evaluated`, naming the missing
## feedthrough. That refusal is the point, and the misread it exists to catch
## is exactly the one this template would otherwise invite. Give U1 a
## `simReplace` carrying a real loop -- `designs/lib/adjreg.nim` is one --
## and the claim becomes measurable.
##
## The same goes for the **load step**, for a subtler reason: an ideal source
## has zero output impedance, so it holds the rail through any step and the
## droop measured is whatever the output network's ESR contributes and
## nothing the regulator did. That is a real number rather than a refused
## one, which makes it the more dangerous of the two.

import nimcir/contract/dsl
import nimcir/verify

let d = design("regulator"):
  # Where the board has to work. This block is what makes the `delta_t` on U1
  # below mean anything: a rise is a rise *above* something, and without a
  # stated ambient range the figure sits there unread and STRUCTURE says so.
  environment:
    t_ambient_min = 0.degC
    t_ambient_max = 70.degC

  net gnd,  kind = ntGround, name = "0"
  net vbus, kind = ntPower:            # what feeds the regulator
    spec:
      voltage = 5.0.V
  net vdd,  kind = ntPower:            # what it makes
    spec:
      voltage = 3.3.V

  component V1, kind = "voltage_source", value = "DC 5":
    pin "+", vbus, kind = ptPower
    pin "-", gnd,  kind = ptGround
    spec:
      voltage = 5.0.V

  component C1, kind = "capacitor", value = "10u":
    pin "1", vbus, kind = ptPassive
    pin "2", gnd,  kind = ptPassive
    spec:
      package = "0805"

  # The regulator states its output voltage on the **component**, and that is
  # load-bearing rather than bookkeeping. The *net*'s `voltage` is what the
  # rail is required to be; the *component*'s is what was chosen. Read the
  # rail's own annotation back and the check measures its own assumption and
  # passes every time -- state 3.3 on the net and fit a 5 V part, and this
  # reports `measured 5.00 V, expected 3.30 V`, which is the whole reason the
  # claim is worth making.
  component U1, kind = "regulator", partNumber = "AMS1117-3.3":
    pin "IN",  vbus, kind = ptPower
    pin "OUT", vdd,  kind = ptPower
    pin "GND", gnd,  kind = ptGround
    spec:
      voltage = 3.3.V
      # A linear regulator burns the difference. (5 - 3.3) V at 100 mA is
      # 0.17 W, and an SOT-223 on a small pour is about 62 degC/W, so this
      # part sits some 10 degC above whatever the air is. Everything else
      # defaults to a rise of 0 and sits at ambient; this one says so
      # because it does not.
      delta_t = 10.degC

  # The output bank. Its size is what sets both the rise time and the inrush:
  # the regulator has to charge all of it, so doubling the capacitance
  # roughly doubles both. That trade is the reason to measure rather than
  # assume -- more output capacitance is the reflexive fix for a noisy rail
  # and it is not free at power-on.
  component C2, kind = "capacitor", value = "22u":
    pin "1", vdd, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "1206"
      dielectric = "X5R"
      voltage_rating = 10.0.V

  component C3, kind = "capacitor", value = "100n":
    pin "1", vdd, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0402"

  # What the rail feeds. A load is not optional for this measurement: without
  # one the rail ramps into an open circuit, and both the settling and the
  # current mean something different.
  component R1, kind = "resistor", value = "33":
    pin "1", vdd, kind = ptPassive
    pin "2", gnd, kind = ptPassive

  # --- claims -------------------------------------------------------------

  role "power_rail", input, rail = vbus, voltage = 5.0.V, band = 5.pct

  role "power_rail", core, rail = vdd, voltage = 3.3.V, band = 5.pct

  # One `.tran` answers all five of these at once: the planner batches every
  # claim sharing a regulator and a judged net into a single run, so the cost
  # of the fifth claim is nothing.
  #
  # Read the rise and settle figures for what they are. With no model on the
  # part they are set by the **assumed** 1 ms soft-start ramp as much as by
  # the output network, so they bound the design rather than predict the
  # part -- the report says so in `assuming:`. Give U1 a `simReplace` of its
  # own and the same two claims start measuring the schedule that part
  # actually keeps to. The overshoot and the inrush are the network's own
  # answer either way, and those are the two worth watching here.
  #
  # `output` is the regulator's own pin. `measure` defaults to it and should
  # be given separately whenever there is post-regulator filtering -- an
  # inductance or a ferrite into a capacitor bank is a resonant circuit, and
  # the regulator pin would show a clean ramp while the load end rings.
  role "regulator", ramp, regulator = U1, output = vdd,
       voltage = 3.3.V, band = 5.pct,
       maxOvershoot = 5.0, maxInrush = 500.mA,
       maxRiseTime = 10.ms, maxSettleTime = 20.ms

quit(verifyMain(d))
