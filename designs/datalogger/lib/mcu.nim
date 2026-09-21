## The MCU sheet: an STM32H563ZIT6, its HSE crystal nested inside as its own
## sub-sheet (`designs/lib/crystal.nim` -- a generic building block, not
## specific to this board), NRST/BOOT0 strapping, I2C1 out to the EEPROM
## sheet, and USB FS D+/D- in from the USB-C sheet with series termination
## at this end of the run.
##
## Board-specific, unlike its neighbours in `designs/lib/`: this sheet's own
## choice of MCU, pin assignment and current budget belong to
## `designs/datalogger/`, so it lives at `designs/datalogger/lib/mcu.nim`
## rather than the shared library.
##
## Ports: `VDD`, `GND`, `SDA`, `SCL`, `DP`, `DM`.
##
## **I2C1 is checked by `validatePinmux` without needing an `iface`.**
## `port ..., peripheral = "I2C1"` is the usual way to bind a peripheral (see
## `designs/spi_memories.nim`), but that macro needs an `iface`-bound
## interface value in the same DSL block, and this sheet's I2C bus is a
## plain two-wire pair passed in from its caller rather than a declared
## interface. `pin "PB9", SDA, kind = ptInOut, function = "I2C1.sda"` is the
## documented alternative for exactly this case --
## `netlist/pinmux.nim`'s own doc comment: "`pin ..., function = "ADC1.in3"`
## stamps them for a non-interface pin" -- and it drives the identical
## `validatePinmux` check.
##
## **USB is not in `lib/stm32h563.nim`'s capability table at all** -- that
## table's own header says so ("The timer, ADC, SAI, FMC, OCTOSPI, SDMMC,
## DCMI and Ethernet functions are left out on purpose"), and USB is the
## same kind of gap. So `PA11`/`PA12` are wired with **no `function =`**,
## which the pinmux check never looks at (`validatePinmux` only inspects a
## pin carrying `pinmux.signal`) -- silent to the checker rather than
## incorrectly validated against a table that says nothing about USB.
## PA11 = D-, PA12 = D+ is the standard OTG_FS pin assignment across the
## whole STM32 family (F1 through H5); stated here rather than sourced from
## this specific part's own alternate-function table, which was not
## reachable to confirm bit-for-bit.

import verax/contract/dsl
import verax/netlist/formats/spice as spiceFormat

import ../../lib/stm32h563
import ../../lib/crystal

proc mcuSheet*(xtal = hse8MHz(), boardCurrentMa = 150.0): Netlist =
  ## `boardCurrentMa` sizes `VDD`'s `zin` stand-in the same way
  ## `designs/sensor_node.nim`'s own MCU pin does -- a rough current budget
  ## standing in for the part's real supply current, since no MCU model
  ## exists here to measure it.
  let vddZin = spiceValue(3.3 / (boardCurrentMa / 1000.0))

  result = subckt("MCU", [VDD, GND, SDA, SCL, DP, DM]):
    net GND, kind = ntGround, name = "0"
    net VDD, kind = ntPower
    net SDA, kind = ntSignal
    net SCL, kind = ntSignal
    net DP,  kind = ntSignal
    net DM,  kind = ntSignal
    net nrst, kind = ntSignal
    net xin,  kind = ntSignal
    net xout, kind = ntSignal
    net dpMcu, kind = ntSignal
    net dmMcu, kind = ntSignal

    component U1, kind = "mcu", partNumber = "STM32H563ZIT6":
      pin "VDD", VDD, kind = ptPower, zin = vddZin
      pin "VSS", GND, kind = ptGround
      pin "PB9", SDA, kind = ptInOut, function = "I2C1.sda"
      pin "PB8", SCL, kind = ptInOut, function = "I2C1.scl"
      pin "PA11", dmMcu, kind = ptInOut
      pin "PA12", dpMcu, kind = ptInOut
      pin "NRST",  nrst, kind = ptInput
      pin "BOOT0", GND,  kind = ptInput
      pin "PH0", xin,  kind = ptPassive
      pin "PH1", xout, kind = ptPassive

    component R_NRST, kind = "resistor", value = "10k":
      pin "1", VDD,  kind = ptPassive
      pin "2", nrst, kind = ptPassive
    component C_NRST, kind = "capacitor", value = "100n":
      pin "1", nrst, kind = ptPassive
      pin "2", GND,  kind = ptPassive
      spec:
        package = "0402"

    # Series termination at the MCU end of the USB FS pair -- the usual
    # placement in ST's own USB hardware/PCB guidelines application note.
    component R_DP, kind = "resistor", value = "27":
      pin "1", DP,    kind = ptPassive
      pin "2", dpMcu, kind = ptPassive
    component R_DM, kind = "resistor", value = "27":
      pin "1", DM,    kind = ptPassive
      pin "2", dmMcu, kind = ptPassive

    component C_VDD1, kind = "capacitor", value = "100n":
      pin "1", VDD, kind = ptPassive
      pin "2", GND, kind = ptPassive
      spec:
        package = "0402"
    component C_VDD2, kind = "capacitor", value = "1u":
      pin "1", VDD, kind = ptPassive
      pin "2", GND, kind = ptPassive
      spec:
        package = "0603"

    instance Xxtal, crystalNetwork(xtal), [xin, xout, GND]
