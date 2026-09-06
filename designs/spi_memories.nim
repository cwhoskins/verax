## Three SPI controllers, each sharing one bus between two 1-Mbit serial SRAMs.
##
## This is deliberately a structural worked design.  `STM32H563ZIT6` and
## `23LC1024-I/SN` are logical board parts, not simulator stand-ins: the check
## proves the sheet interfaces, pin naming, chip-select slices and tri-state
## MISO topology without claiming firmware timing or memory transactions.

import nimcir/contract/dsl
import nimcir/verify
import nimcir/netlist/interfaces/std

import ./lib/spi_memory

let d = design("spi_memories"):
  net gnd, kind = ntGround, name = "0"
  net vdd, kind = ntPower:
    spec:
      voltage = 3.3.V

  iface spi1, spiInterface(2)
  iface spi2, spiInterface(2)
  iface spi3, spiInterface(2)

  component U1, kind = "mcu", partNumber = "STM32H563ZIT6":
    pin "VDD", vdd, kind = ptPower
    pin "VSS", gnd, kind = ptGround
    port spi1, controller, pins = {"sclk": "SPI1_SCK", "mosi": "SPI1_MOSI",
                                   "miso": "SPI1_MISO", "cs_0": "SPI1_NSS0",
                                   "cs_1": "SPI1_NSS1"}
    port spi2, controller, pins = {"sclk": "SPI2_SCK", "mosi": "SPI2_MOSI",
                                   "miso": "SPI2_MISO", "cs_0": "SPI2_NSS0",
                                   "cs_1": "SPI2_NSS1"}
    port spi3, controller, pins = {"sclk": "SPI3_SCK", "mosi": "SPI3_MOSI",
                                   "miso": "SPI3_MISO", "cs_0": "SPI3_NSS0",
                                   "cs_1": "SPI3_NSS1"}

  # Every SRAM releases MISO unless selected.  These weak pulls give the MCU
  # a defined idle level and a DC path without changing the shared-bus model.
  component R1, kind = "resistor", value = "100k":
    pin "1", spi1["miso"], kind = ptPassive
    pin "2", gnd, kind = ptGround
  component R2, kind = "resistor", value = "100k":
    pin "1", spi2["miso"], kind = ptPassive
    pin "2", gnd, kind = ptGround
  component R3, kind = "resistor", value = "100k":
    pin "1", spi3["miso"], kind = ptPassive
    pin "2", gnd, kind = ptGround

  instance X1, SPI_MEMORY, {"vdd": vdd, "gnd": gnd,
                             "spi_sclk": spi1["sclk"], "spi_mosi": spi1["mosi"],
                             "spi_miso": spi1["miso"], "cs": spi1.bus("cs")[0]}
  instance X2, SPI_MEMORY, {"vdd": vdd, "gnd": gnd,
                             "spi_sclk": spi1["sclk"], "spi_mosi": spi1["mosi"],
                             "spi_miso": spi1["miso"], "cs": spi1.bus("cs")[1]}
  instance X3, SPI_MEMORY, {"vdd": vdd, "gnd": gnd,
                             "spi_sclk": spi2["sclk"], "spi_mosi": spi2["mosi"],
                             "spi_miso": spi2["miso"], "cs": spi2.bus("cs")[0]}
  instance X4, SPI_MEMORY, {"vdd": vdd, "gnd": gnd,
                             "spi_sclk": spi2["sclk"], "spi_mosi": spi2["mosi"],
                             "spi_miso": spi2["miso"], "cs": spi2.bus("cs")[1]}
  instance X5, SPI_MEMORY, {"vdd": vdd, "gnd": gnd,
                             "spi_sclk": spi3["sclk"], "spi_mosi": spi3["mosi"],
                             "spi_miso": spi3["miso"], "cs": spi3.bus("cs")[0]}
  instance X6, SPI_MEMORY, {"vdd": vdd, "gnd": gnd,
                             "spi_sclk": spi3["sclk"], "spi_mosi": spi3["mosi"],
                             "spi_miso": spi3["miso"], "cs": spi3.bus("cs")[1]}

quit(verifyMain(d))
