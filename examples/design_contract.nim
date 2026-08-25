## Example: stating what a design *is* and what it must *do*.
##
## The same board written twice -- once as a bare netlist with ad-hoc string
## attributes, and once with roles, typed annotations and requirements -- so
## the difference the contract layer makes is visible side by side.
##
## Run with:
##   nim c -r --path:./src examples/design_contract.nim

import std/tables

import nimcir/contract/dsl
import nimcir/netlist/annotations
import nimcir/verify

# --- the design ---------------------------------------------------------

let d = design("sensor_board"):
  net vdd, kind = ntPower
  net gnd, kind = ntGround, name = "0"
  net sda, kind = ntSignal
  net scl, kind = ntSignal

  # `spec:` is checked at compile time: misspell `esr`, or write it on a net
  # instead of a component, and the build fails rather than the value being
  # silently ignored by everything that looks for it.
  # The supply. It is not modelled as ideal: `spice/models` puts a finite
  # `rout`/`lout` in series with it, because an ideal source is a dead short
  # at AC and would report this rail's impedance as 0 ohm at every frequency.
  # Annotate `rout`/`lout` from a datasheet to replace the stand-in.
  component V1, kind = "voltage_source", value = "DC 3.3":
    pin "+", vdd, kind = ptPower
    pin "-", gnd, kind = ptGround

  component C1, kind = "capacitor", value = "10u":
    pin "1", vdd, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "tantalum"
      esr = 100.mohm
      esl = 3.nH

  component C2, kind = "capacitor", value = "100n":
    pin "1", vdd, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0402"

  component R1, kind = "resistor", value = "2.2k":
    pin "1", vdd, kind = ptPassive
    pin "2", sda, kind = ptPassive
  component R2, kind = "resistor", value = "2.2k":
    pin "1", vdd, kind = ptPassive
    pin "2", scl, kind = ptPassive

  component U1, kind = "mcu", partNumber = "STM32G0":
    pin "VDD", vdd, kind = ptPower
    pin "VSS", gnd, kind = ptGround
    pin "SDA", sda, kind = ptInOut
    pin "SCL", scl, kind = ptInOut

  # A role is a parameterized bundle of assertions. `power_rail` also *writes*
  # its voltage onto the net, which is how spice/isolate later terminates the
  # rail without knowing that roles exist.
  role "power_rail", vdd_rail, rail = vdd, voltage = 3.3.V, band = 5.pct
  role "i2c", i2c0, sda = sda, scl = scl, pullupRail = vdd,
              controller = U1, frequency = 400.kHz

  # A requirement of your own, alongside the ones the roles imply.
  require z_max_in_band(vdd) <= 100.mohm,
          f_from = 100.kHz, f_to = 100.MHz,
          id = "REQ-PDN-001",
          because = "keeps rail droop under 10 mV at the MCU's 100 mA di/dt"

echo d.explain()

echo ""
echo "--- what the roles wrote onto the netlist ---"
echo "vdd voltage annotation: ", railVoltage(d.netlist.nets["vdd"]).value, " V ",
     "(source: ", railVoltage(d.netlist.nets["vdd"]).source, ")"
echo "sda belongs to: ", rolesOf(d.netlist.nets["sda"])
echo "C1 ESR: ", esr(d.netlist.components["C1"]).value, " ohm ",
     "(source: ", esr(d.netlist.components["C1"]).source, ")"
echo "C2 ESR: ", (if esr(d.netlist.components["C2"]).has: "stated"
                  else: "not stated -- a PDN run will default it from the " &
                        "package and say so"),
     ""

echo ""
echo "--- validation ---"
let issues = validateAnnotations(d.netlist)
echo "annotation issues: ", issues.len
for i in issues: echo "  ", i

# What a misspelling looks like when it bypasses the DSL -- as a file reader
# or a hand-written `attrs` assignment would.
d.netlist.components["C1"].attrs["ESL"] = "3e-9"
echo ""
echo "after writing a stray `ESL` key directly into attrs:"
for i in validateAnnotations(d.netlist):
  echo "  ", i

echo ""
echo "--- checking the claims ---"
# Four answers, not two: pass, fail, could-not-check and nothing-can-check.
#
# `nimcir/verify` registers the simulation-backed evaluators itself, so a
# quantity that reports as unevaluable here really is one nothing produces --
# rather than one whose evaluator module simply was not imported. What is
# *offered* is still the caller's choice: pass `offlineCapabilities` and the
# simulated claims come back "not evaluated, requires capSpiceAc", which is a
# withheld capability rather than an unknown quantity. Neither is a pass.
#
# The two i2c failures below are real: 2.2k against an assumed 20 pF of bus
# capacitance puts the RC corner at 3.6 MHz, under the ten-times-clock a
# 400 kHz bus wants. Note the assumption is reported rather than buried --
# the answer rests on a number the netlist does not contain.
quit(verifyMain(d))
