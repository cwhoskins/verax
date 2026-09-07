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
  signal cs
  modport peripheral:
    sclk = ptInput
    mosi = ptInput
    miso = ptInOut
    cs = ptInput

# `cs` is a member of the link, not a fourth loose port: a parent shares
# `sclk`/`mosi`/`miso` and selects this memory with one member of a wider
# chip-select bus via `spi1.narrow("cs", k)`, which presents `spi1` with `cs`
# as a width-1 bus and wires straight onto `spi_cs`. Publishing `cs` in the
# interface (rather than a standalone `net cs` + `pin "CS"`) is also what lets
# the child sheet's SPI port collapse to one `spi[4]` pennant.
let SPI_MEMORY* = subckt("SPI_MEMORY", [vdd, gnd, spi.peripheral]):
  net gnd, kind = ntGround, name = "0"
  net vdd, kind = ntPower
  iface spi, spiMemoryLink

  component U1, kind = "memory", partNumber = "23LC1024-I/SN":
    pin "VCC", vdd, kind = ptPower
    pin "VSS", gnd, kind = ptGround
    port spi, peripheral, pins = {"sclk": "SCK", "mosi": "SI",
                                  "miso": "SO", "cs": "CS"}
    # The board uses ordinary SPI rather than the part's SQI mode.
    pin "HOLD", vdd, kind = ptInput
    pin "WP", vdd, kind = ptInput
