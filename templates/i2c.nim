## An I2C bus: two open-drain lines, their pull-ups, and the parts on them.
##
##   nimcir check <this file>
##
## What it claims comes from the `i2c` role: each line has at least one
## pull-up, each line's RC corner clears the clock by ten times, and there is
## exactly one controller. The RC answer rests on an assumed per-pin bus
## capacitance, which the report says out loud -- a netlist carries neither
## trace nor device pin capacitance, so state it if you know it.

import nimcir/contract/dsl
import nimcir/verify

let d = design("i2c_bus"):
  net gnd, kind = ntGround, name = "0"
  net vdd, kind = ntPower:
    spec:
      voltage = 3.3.V
  net sda, kind = ntSignal
  net scl, kind = ntSignal

  # 1.2k rather than the reflexive 2.2k: at 400 kHz, 2.2k against the ~30 pF
  # assumed for three pins puts the corner at 2.4 MHz, well under the
  # ten-times-clock the role asks for. Drop the clock to 100.kHz and 2.2k is
  # fine. Note the bus capacitance is assumed, not known -- adding a fourth
  # device moves this number whether or not you change the pull-ups.
  component R1, kind = "resistor", value = "1.2k":
    pin "1", vdd, kind = ptPassive
    pin "2", sda, kind = ptPassive
  component R2, kind = "resistor", value = "1.2k":
    pin "1", vdd, kind = ptPassive
    pin "2", scl, kind = ptPassive

  component U1, kind = "mcu", partNumber = "STM32G0":
    pin "VDD", vdd, kind = ptPower
    pin "VSS", gnd, kind = ptGround
    pin "SDA", sda, kind = ptInOut
    pin "SCL", scl, kind = ptInOut

  component U2, kind = "sensor", partNumber = "BME280":
    pin "VDD", vdd, kind = ptPower
    pin "GND", gnd, kind = ptGround
    pin "SDA", sda, kind = ptInOut
    pin "SCL", scl, kind = ptInOut

  # `controller` is what tells the check which part drives the bus: every
  # device on I2C has an inout data pin, and nothing in a netlist
  # distinguishes the controller from a target.
  role "i2c", i2c0, sda = sda, scl = scl, pullupRail = vdd,
       controller = U1, frequency = 400.kHz

quit(verifyMain(d))
