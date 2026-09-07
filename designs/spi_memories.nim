## Three SPI controllers, each sharing one bus between two 1-Mbit serial SRAMs.
##
## This is deliberately a structural worked design.  `STM32H563ZIT6` and
## `23LC1024-I/SN` are logical board parts, not simulator stand-ins: the check
## proves the sheet interfaces, pin naming, chip-select slices and tri-state
## MISO topology without claiming firmware timing or memory transactions.
##
## Each controller port names the concrete peripheral it is wired as
## (`peripheral = "SPI1"`) and the real device pins it lands on, so
## `validatePinmux` checks those pins against `lib/stm32h563.nim`'s
## alternate-function table -- routing a clock to a pin the silicon cannot mux
## it onto is now a structural error.  The second chip select of each pair is a
## software GPIO (`functions = {"cs_1": "GPIO"}`), not a hardware NSS.

import nimcir/contract/dsl
import nimcir/verify
import nimcir/netlist/interfaces/std

import ./lib/spi_memory
import ./lib/stm32h563

let d = design("spi_memories"):
  net gnd, kind = ntGround, name = "0"
  net vdd, kind = ntPower:
    spec:
      voltage = 3.3.V

  # One SPI controller per memory pair, as an interface array: `spi[k]` is the
  # k-th controller's bus, each a 2-member chip-select interface.
  iface spi, spiInterface(2), count = 3

  # Write-protect: the controller owns every SRAM's WP line through one 6-bit
  # bus, so no memory is writable unless firmware has deliberately released it.
  bus wp, width = 6

  component U1, kind = "mcu", partNumber = "STM32H563ZIT6":
    pin "VDD", vdd, kind = ptPower
    pin "VSS", gnd, kind = ptGround
    port spi[0], controller, peripheral = "SPI1",
      pins = {"sclk": "PA5", "mosi": "PA7", "miso": "PA6",
              "cs_0": "PA4", "cs_1": "PD14"},
      functions = {"cs_1": "GPIO"}
    port spi[1], controller, peripheral = "SPI2",
      pins = {"sclk": "PB13", "mosi": "PB15", "miso": "PB14",
              "cs_0": "PB12", "cs_1": "PD15"},
      functions = {"cs_1": "GPIO"}
    port spi[2], controller, peripheral = "SPI3",
      pins = {"sclk": "PC10", "mosi": "PC12", "miso": "PC11",
              "cs_0": "PA15", "cs_1": "PF12"},
      functions = {"cs_1": "GPIO"}
    pin "PE0", wp[0], kind = ptOutput, function = "GPIO"
    pin "PE1", wp[1], kind = ptOutput, function = "GPIO"
    pin "PE2", wp[2], kind = ptOutput, function = "GPIO"
    pin "PE3", wp[3], kind = ptOutput, function = "GPIO"
    pin "PE4", wp[4], kind = ptOutput, function = "GPIO"
    pin "PE5", wp[5], kind = ptOutput, function = "GPIO"

  # Every SRAM releases MISO unless selected.  These weak pulls give the MCU
  # a defined idle level and a DC path without changing the shared-bus model.
  for i in 0 ..< 3:
    component "R", kind = "resistor", value = "100k", designator = "R" & $(i + 1):
      pin "1", spi[i]["miso"], kind = ptPassive
      pin "2", gnd, kind = ptGround

  # Each memory owns a single chip-select line: `narrow("cs", k)` presents its
  # controller's SPI with `cs` cut to one member, so the whole port is one
  # value wired by name -- no `spi1.bus("cs")[k]` per-signal boilerplate.
  for ci, ctrl in spi:
    for cs in 0 ..< 2:
      instance "X", SPI_MEMORY,
        {"vdd": vdd, "gnd": gnd, "wp": wp[ci * 2 + cs],
         "spi": ctrl.narrow("cs", cs)},
        designator = "X" & $(ci * 2 + cs + 1)

quit(verifyMain(d))
