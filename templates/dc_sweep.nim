## What a node does as something *moves*, rather than at one bias.
##
##   verax check <this file>
##
## A 5.1 V Zener shunt reference off a 12 V rail: one resistor, one diode,
## and a specification that is entirely made of slopes. How far the reference
## moves as the supply moves (line regulation), how little headroom it will
## still work on (dropout), and how stiff it is (output resistance). Not one
## of those is a number an operating point contains, because an operating
## point is one bias and every one of them is a difference between two.
##
## ## The two roles
##
## `source_sweep` sweeps a source the design already has and measures a node.
## `load_sweep` sweeps a constant-current sink the analysis **injects** at the
## node -- there is nothing here to bind it to, deliberately: a test load is
## not a part anybody solders, so putting one in the netlist would put it on
## the BoM and in the layout. It is a sink and not a resistor for the reason
## `spice/boundary` gives at length: a resistor's current follows the node it
## hangs on, so sweeping one sweeps the load and the drive together.
##
## ## Why there are two source sweeps below and not one
##
## Because they are two different questions and the answers are not
## comparable, which is exactly what an evaluator's setup key exists to keep
## apart. Line regulation is quoted over the range the part is *specified*
## over -- 6 V to 16 V here -- and comes to 1.67%, or 167 m%/V. Ask the same
## question over 3 V to 16 V and the answer is **41.6%**, which is not a
## worse reference but a different measurement: most of that range is below
## the Zener's knee, where the "reference" is just the supply arriving
## through a resistor.
##
## That lower range is where the dropout figure comes from, and it is the
## only place it can come from: `dropout_v` is the input-to-output
## differential at the lowest input still holding regulation, so a sweep that
## never leaves regulation cannot report one. It comes back **not evaluated**
## rather than zero when that happens, with an issue saying to sweep lower --
## because "no dropout was found" and "the dropout is small" are opposite
## conclusions and must not share a number.
##
## ## What a `.dc` costs
##
## One operating point per step. The default is fifty-one across the range,
## which is cheap and is plenty for anything read off the endpoints; the
## headroom sweep below states its own step, because `dropout_v` is read off
## a *threshold crossing* and is therefore the one quantity here whose
## precision is the step size.

import verax/contract/dsl
import verax/verify

let d = design("dc_sweep"):
  net gnd,  kind = ntGround, name = "0"
  net vin,  kind = ntPower:
    spec:
      voltage = 12.0.V
  net vref, kind = ntSignal:
    spec:
      voltage = 5.1.V

  # The `model` card is what makes this a Zener rather than a stand-in: a
  # part whose `value` names a registered model is no longer *unmodelled*, so
  # `spice/models` leaves it alone and `spice/isolate` will traverse it. `BV`
  # is the whole point of the part and there is no way to state it except in
  # the card, which is passed to the simulator verbatim.
  model "BZX84C5V1", "D(IS=1e-14 N=1.2 RS=1 BV=5.1 IBV=5m)"

  component V1, kind = "voltage_source", value = "DC 12":
    pin "+", vin, kind = ptPower
    pin "-", gnd, kind = ptGround
    spec:
      voltage = 12.0.V

  # The ballast. Everything below is a consequence of this resistor and the
  # diode's dynamic resistance: line regulation is `rz/(R1+rz)`, output
  # resistance is `R1 || rz`, and the current available to a load is what is
  # left of `(Vin - Vz)/R1` after the diode has taken its share.
  component R1, kind = "resistor", value = "1k":
    pin "1", vin,  kind = ptPassive
    pin "2", vref, kind = ptPassive

  component D1, kind = "diode", partNumber = "BZX84C5V1",
            value = "BZX84C5V1":
    pin "A", gnd,  kind = ptPassive
    pin "K", vref, kind = ptPassive

  # --- claims -------------------------------------------------------------

  # Where it sits at nominal input, which is the ordinary `.op` question and
  # is here to be read beside the swept ones rather than instead of them.
  require dc_voltage(vref) == 5.12.V, band = 2.pct,
          id = "REQ-REF-DC-001",
          because = "one bias, for comparison: this is the number a `.op` " &
                    "reports and the only one it can, and every claim below " &
                    "is a difference an operating point does not contain"

  # Line regulation, over the range the reference is specified over.
  #
  # `maxLineReg` and `maxLineRegPerV` are in **percent**, so they take a bare
  # number: `2.5.pct` is the fraction 0.025 and would be wrong by a hundred.
  # The two say the same thing and are both worth stating -- the total is
  # what a downstream error budget adds up, and the per-volt figure is the
  # one that does not change if somebody widens the sweep.
  role "source_sweep", line, source = V1, output = vref,
       vFrom = 6.0.V, vTo = 16.0.V,
       maxLineReg = 2.5, maxLineRegPerV = 0.25, minOut = 5.0.V

  # Headroom, over a range wide enough to find the knee. A separate role
  # instance because it is a separate run: every quantity a sweep produces is
  # a difference across the swept range, so a claim made over one range says
  # nothing about another and the planner keeps the two apart by the range in
  # the setup key.
  #
  # `vStep` is stated here and left to default above, because `dropout_v` is
  # the one quantity read off a threshold crossing rather than off the
  # endpoints: its precision *is* the step.
  role "source_sweep", headroom, source = V1, output = vref,
       vFrom = 3.0.V, vTo = 16.0.V, vStep = 25.0.mV,
       maxDropout = 800.0.mV

  # And how stiff the node is. `z_out_dc` here is `R1 || rz`, which is
  # dominated by the diode -- so a claim on it is a claim about the part
  # rather than about the resistor, and it is the number that says whether
  # this reference can drive anything at all.
  #
  # The range stops at 2 mA on purpose: `(12 - 5.1)/1k` is 6.9 mA total, and
  # a load that takes all of it starves the diode and the reference stops
  # being one. That limit is a design decision, which is why it is stated
  # rather than swept until something breaks.
  role "load_sweep", load, output = vref,
       iFrom = 0.0.A, iTo = 2.0.mA,
       maxZOut = 10.0.ohm, maxLoadReg = 0.5, minOut = 5.0.V

quit(verifyMain(d))
