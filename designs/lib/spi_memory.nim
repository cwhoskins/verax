## One 23LC1024-I/SN serial SRAM sheet.
##
## The sheet owns the real part and its fixed straps; its SPI port is exposed
## as an interface so a parent may share SCLK/MOSI/MISO and select this memory
## with one member of a wider chip-select bus.

import std/tables
import nimcir/netlist/dsl
import nimcir/netlist/interfaces

let spiMemoryLink = interfaceDef("spi_memory_link"):
  signal sclk
  signal mosi
  signal miso, shared = true
  modport peripheral:
    sclk = ptInput
    mosi = ptInput
    miso = ptInOut

let SPI_MEMORY* = subckt("SPI_MEMORY", [vdd, gnd, spi.peripheral, cs]):
  net gnd, kind = ntGround, name = "0"
  net vdd, kind = ntPower
  iface spi, spiMemoryLink
  net cs, kind = ntSignal

  component U1, kind = "memory", partNumber = "23LC1024-I/SN":
    pin "VCC", vdd, kind = ptPower
    pin "VSS", gnd, kind = ptGround
    port spi, peripheral, pins = {"sclk": "SCK", "mosi": "SI",
                                  "miso": "SO"}
    pin "CS", cs, kind = ptInput
    # The board uses ordinary SPI rather than the part's SQI mode.
    pin "HOLD", vdd, kind = ptInput
    pin "WP", vdd, kind = ptInput
