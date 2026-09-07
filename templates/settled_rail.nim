## What a rail is still doing once it has stopped arriving.
##
##   verax check <this file>
##
## A 5 V supply feeding a load that switches on and off at 100 kHz -- an MCU
## waking to sample, a converter's input, anything that draws in bursts. The
## question is not where the rail sits (`power_rail` answers that) nor how it
## got there (`regulator` answers that), but what is left moving on it in
## steady state.
##
## **Do not reach for `dc_voltage` here.** It is backed by a `.op`, and a
## `.op` takes a PULSE source at its DC value -- which for this load is 0 A.
## So nothing switches, and the tool reports a perfectly correct 5.000 V: a
## right answer to a question nobody asked, with the entire ripple missing.
##
## `settled_rail` asks the other question. Run the circuit, wait `tSettle`,
## then over a window of `tWindow` report what the node settled to
## (`settled_v`), what it swings by (`ripple_pp`), and the extremes
## (`settled_min`/`settled_max`). It binds no driving part, which is exactly
## why it reaches a circuit that has none.
##
## Both timings are **conditions, not limits**: the answer is a function of
## them, so they ride in the assertion's conditions and join the evaluator's
## setup key. State `tSettle` too early and a start-up transient is reported
## as ripple. It is stated rather than detected because what counts as
## settled is a judgement about the circuit, and a detector that guessed
## wrong would be confidently wrong.

import verax/contract/dsl
import verax/verify

let d = design("settled_rail"):
  net gnd,   kind = ntGround, name = "0"
  net vin,   kind = ntPower:          # upstream of the feed resistance
    spec:
      voltage = 5.0.V
  net vrail, kind = ntPower:          # what the load actually sees
    spec:
      voltage = 4.95.V

  component V1, kind = "voltage_source", value = "DC 5":
    pin "+", vin, kind = ptPower
    pin "-", gnd, kind = ptGround
    spec:
      voltage = 5.0.V

  # Bulk on the source side, so the supply's own impedance is not what this
  # template is measuring. The default stand-in for a source is 10 mohm in
  # series with 1 uH -- at 100 kHz that inductance is 0.6 ohm, which would
  # otherwise dominate everything below.
  component C1, kind = "capacitor", value = "100u":
    pin "1", vin, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "tantalum"
      dielectric = "tantalum"
      voltage_rating = 16.0.V
      esr = 100.mohm

  # The feed: trace resistance, a ferrite's DCR, a connector -- whatever sits
  # between the bulk and the load. It is what turns a switching load into a
  # *drop*, because the average current across it is a DC error and the
  # switching part of it is what the local capacitor has to supply.
  component R1, kind = "resistor", value = "1":
    pin "1", vin,   kind = ptPassive
    pin "2", vrail, kind = ptPassive

  # The local decoupling, and its **ESR is stated rather than defaulted**
  # because ESR is what sets the answer here. The ripple on this node is two
  # separate things added together: the charge droop `I*t/C` while the load
  # is on, and a step of `I*ESR` at each edge as the current commutes into
  # the capacitor. An ideal capacitor has no ESR and reports only the first,
  # which is how a rail that measures fine in a hand calculation misbehaves
  # on the bench.
  component C2, kind = "capacitor", value = "100u":
    pin "1", vrail, kind = ptPassive
    pin "2", gnd,   kind = ptPassive
    spec:
      package = "1210"
      dielectric = "X5R"
      voltage_rating = 16.0.V
      esr = 20.mohm
      esl = 1.5.nH

  # The load: 100 mA at a 50% duty cycle, 100 kHz, with 100 ns edges. Note
  # this is a **current** source, not a resistor, and the difference is not
  # only accuracy -- a resistor's current follows the rail, so it damps the
  # network, while a constant-current sink is an open circuit at AC and damps
  # nothing. A regulated load (an MCU, a module with its own converter)
  # behaves like the sink, not like the resistor.
  #
  # `value` reaches the deck verbatim; the annotation registry documents that
  # key as never parsed as a number for exactly this reason, since a whole
  # source spec is not a magnitude.
  component I1, kind = "current_source", value = "PULSE(0 0.1 0 100n 100n 4.9u 10u)":
    pin "+", vrail, kind = ptPassive
    pin "-", gnd,   kind = ptPassive

  # --- claims -------------------------------------------------------------

  role "power_rail", supply, rail = vin, voltage = 5.0.V, band = 5.pct

  # 100 mA at 50% duty is 50 mA average, and 50 mA across the 1 ohm feed is
  # a 50 mV drop -- so the rail settles at 4.95 V, not 5 V. That drop is a
  # design consequence rather than a fault, which is why it is claimed at
  # 4.95 and not at 5: a claim at 5 V with a band wide enough to pass would
  # be a claim that no longer notices the feed resistance doubling.
  #
  # `tSettle` is 2 ms against an RC of 100 us -- twenty time constants, so
  # nothing of the initial charge-up is inside the window. `tWindow` is
  # 100 us, which is ten whole load cycles, so the peak-to-peak is taken
  # over whole periods of the thing that makes the ripple.
  #
  # Measured, the rail ripples by 4.89 mV against a 10 mV budget. **That
  # figure is a function of the load's edge rate, not only of the
  # decoupling**, and it is worth knowing by how much: drive the same
  # circuit with 10 ns edges instead of 100 ns and it reads 27.8 mV -- more
  # than five times as much, from parts that did not change. The extra is
  # C2's 1.5 nH of ESL against a di/dt ten times higher, and it swamps both
  # the charge droop and the ESR step. So a ripple budget is a claim about
  # the load as much as about the capacitor, and the edge rate stated in
  # that PULSE spec is an assumption this design is making about a part
  # somebody else chose.
  role "settled_rail", loaded, rail = vrail,
       tSettle = 2.0.ms, tWindow = 100.0.us,
       voltage = 4.95.V, band = 2.pct, maxRipple = 10.0.mV

quit(verifyMain(d))
