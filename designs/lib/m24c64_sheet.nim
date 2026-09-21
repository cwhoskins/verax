## A sheet wrapping ST's M24C64-U alone: the part plus its own decoupling
## cap, nothing board-specific. Generic (any design wiring up an M24C64
## wants exactly this), so it lives beside `designs/lib/m24c64.nim` -- that
## file is the part's XSPICE behavioural model (see its own header); this
## one is how to place it on a board.
##
## Ports: `VDD`, `GND`, `SDA`, `SCL`.
##
## **The I2C pull-ups and bus capacitance still belong at the caller's top
## level, not in this sheet -- though not for the reason originally written
## here.** `pullup_count` and the other `i2c` role quantities under it are
## `[static]` evaluators (`contract/evaluators/static.nim`) that used to
## walk only a net's *directly*-connected pins, and a bus net exposed as a
## *subckt port* has none of its own -- the resistors on the other side of
## a port live on the child netlist's own local net object, cross-linked
## only through `Pin.hierNet` at the boundary. Measured (in
## `designs/datalogger/datalogger.nim`): nesting the pull-ups here made
## `pullup_count(sda)` report 0. **That specific limitation is fixed**:
## `pullupsOn`/`capacitorsOn`/`runRcCorner`'s bus-capacitance estimate and
## `runControllerCount`'s interface fallback now walk `allPins(net)`, which
## closes over `netlist/graph.hierNetGroup` -- the same
## follow-`Pin.hierNet`-and-the-instance's-own-pin pattern `dcConnected`
## already used for `dc_path_exists`, generalized to the other evaluators.
## A pull-up nested inside this sheet would now be counted correctly. The
## sheet still keeps its resistors flat at the caller's level anyway,
## because that is simply where a board's bus decoupling belongs
## electrically (one bus, one set of pull-ups, regardless of how many
## sheets hang off it) -- not because nesting them would go uncounted.
## Every design in this repo that claims `i2c` (`designs/sensor_node.nim`,
## `designs/i2c_eeprom.nim`, `designs/spi_memories.nim`'s MISO pull-ups)
## keeps its bus resistors flat at the same level as the claim for that
## reason.
##
## **One consequence of the fix landed on the caller, not on this sheet**:
## `runRcCorner`'s bus-capacitance estimate now also counts this part's own
## `SDA`/`SCL` pins (reached through `allPins` the same way a nested
## pull-up now is), where before it counted only whatever sat directly at
## the top level. On `designs/datalogger/datalogger.nim` that is two more
## assumed 10 pF loads than the claim was written against, and it moved the
## bus's own `rc_corner` from just above 1.00 MHz to 992 kHz measured --
## `bus.sda.rc_corner`/`bus.scl.rc_corner` now fail there. Not a bug in the
## fix: an EEPROM genuinely does load the bus it is wired to, and the old
## number was silently under-counting every bus with a device reached
## through an `instance` -- but it does mean that design's pull-ups (or its
## claimed corner) need revisiting, which this sheet's own header is the
## place to say so rather than leaving a reader to rediscover it.
##
## Electrical only -- this sheet contributes only the part's own supply
## current stand-in, not a scripted transaction. `designs/i2c_eeprom.nim`'s
## `designs/lib/dummy_mcu.nim`/`useDummyMcu` pattern needs `DONE`/`PASS`
## pins that no real MCU has, so wiring a real conversation through a real
## MCU (rather than the dummy one `i2c_eeprom.nim` uses) would need a
## behavioural stand-in attached *beside* the real part the way
## `designs/lib/oring.nim` stands a diode pair in beside a real power mux --
## future work, not done here.

import verax/contract/dsl

proc eepromSheet*(): Netlist =
  result = subckt("EEPROM", [VDD, GND, SDA, SCL]):
    net GND, kind = ntGround, name = "0"
    net VDD, kind = ntPower
    net SDA, kind = ntSignal
    net SCL, kind = ntSignal

    component U1, kind = "eeprom", partNumber = "M24C64-U":
      pin "VCC", VDD, kind = ptPower, zin = "8250"
      pin "VSS", GND, kind = ptGround
      pin "SDA", SDA, kind = ptInOut
      pin "SCL", SCL, kind = ptInput
      pin "E0", GND, kind = ptInput
      pin "E1", GND, kind = ptInput
      pin "E2", GND, kind = ptInput
      pin "WC", GND, kind = ptInput

    component C_EE, kind = "capacitor", value = "100n":
      pin "1", VDD, kind = ptPassive
      pin "2", GND, kind = ptPassive
      spec:
        package = "0402"
