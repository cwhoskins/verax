## A generic single-supply bias network, board-agnostic like this file's
## siblings (`opamp_stages`, `filters`) rather than specific to any one
## design: a VDD/2 divider (`R_BIAS1`/`R_BIAS2`, bypassed by `C_BIAS`)
## feeding an AC-coupling network (`R_BIASIN`/`C_IN`) that lands the bias on
## a signal *input*. `designs/datalogger/lib/analog.analogInputChannel` is
## its first caller: it wires this ahead of its gain stage's non-inverting
## input rather than onto the stage's `REF` -- see that file's own doc
## comment for why that split matters and why `REF` stays tied to true
## `GND` there.
##
## Pulled out as its own subcircuit so the corner it sets is a stated design
## parameter (`cornerHz`) rather than a capacitance baked into one board's
## sheet: `C_IN` is sized from `cornerHz` and `rIn` by the textbook
## single-pole formula `corner = 1 / (2*pi*rIn*C_IN)` -- the same formula
## `designs/lib/opamp_stages.parallelRCNetwork` sizes its own corner
## capacitor from -- so a caller states "still passing at 10 Hz" and checks
## it against a claim's `f_lo_3db`, rather than picking a capacitance and
## working the corner out afterwards by hand.
##
## Ports: `IN`, `OUT`, `VDD`, `GND`. `OUT` is the biased, AC-coupled node --
## wire it straight to the gain stage's non-inverting input.

import std/math
import verax/contract/dsl
import verax/netlist/formats/spice as spiceFormat

proc biasNetwork*(cornerHz = 1.6.Hz, rIn = 100.0.kohm,
                  rDiv = 10.0.kohm): Netlist =
  ## `rDiv` is each leg of the VDD/2 divider; `rIn` is the resistor that
  ## holds `OUT` at that bias without loading the divider or the source --
  ## kept large by default for exactly that reason. `cornerHz` is the only
  ## parameter that changes the AC behaviour; `rIn`/`rDiv` are there to
  ## retune impedance without touching it.
  doAssert float(cornerHz) > 0.0, "bias corner frequency must be positive"
  doAssert float(rIn) > 0.0 and float(rDiv) > 0.0,
    "bias network resistors must be positive"
  let cIn = Farads(1.0 / (2.0 * PI * float(rIn) * float(cornerHz)))

  result = subckt("BIAS_NET", [IN, OUT, VDD, GND]):
    net GND,  kind = ntGround, name = "0"
    net VDD,  kind = ntPower
    net IN,   kind = ntSignal
    net OUT,  kind = ntSignal
    net vref, kind = ntSignal

    # --- VDD/2 reference -----------------------------------------------------
    component R_BIAS1, kind = "resistor", value = spiceValue(float(rDiv)):
      pin "1", VDD,  kind = ptPassive
      pin "2", vref, kind = ptPassive
    component R_BIAS2, kind = "resistor", value = spiceValue(float(rDiv)):
      pin "1", vref, kind = ptPassive
      pin "2", GND,  kind = ptPassive
    component C_BIAS, kind = "capacitor", value = "10u":
      pin "1", vref, kind = ptPassive
      pin "2", GND,  kind = ptPassive
      spec:
        package = "0805"

    # --- AC coupling at `cornerHz` --------------------------------------------
    component R_BIASIN, kind = "resistor", value = spiceValue(float(rIn)):
      pin "1", vref, kind = ptPassive
      pin "2", OUT,  kind = ptPassive
    component C_IN, kind = "capacitor", value = spiceValue(float(cIn)):
      pin "1", IN,  kind = ptPassive
      pin "2", OUT, kind = ptPassive
      spec:
        package = "0805"
