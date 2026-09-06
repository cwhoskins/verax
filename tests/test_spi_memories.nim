## Structural regression for the reusable SPI memory sheet used by
## designs/spi_memories.nim.

import std/[tables, unittest]
import nimcir/netlist
import nimcir/netlist/interfaces/std
import nimcir/analysis/io_check

import "../designs/lib/spi_memory"

suite "SPI memory sheet":
  test "two selected-by-slice memories share tri-state MISO":
    let nl = newNetlist("board")
    let gnd = addNet(nl, newNet("0", ntGround))
    let vdd = addNet(nl, newNet("vdd", ntPower))
    let spi = addInterface(nl, "spi", spiInterface(2))
    let mcu = addComponent(nl, newComponent("U1", kind = "mcu"))
    connectPort(mcu, view(spi, "controller"))

    var globals = initOrderedTable[string, Net]()
    let x1 = instantiate(nl, "X1", SPI_MEMORY,
      @[vdd, gnd, spi["sclk"], spi["mosi"], spi["miso"], spi.bus("cs")[0]], globals)
    let x2 = instantiate(nl, "X2", SPI_MEMORY,
      @[vdd, gnd, spi["sclk"], spi["mosi"], spi["miso"], spi.bus("cs")[1]], globals)
    promotePortDirections(x1)
    promotePortDirections(x2)

    check x1.subNetlist.components["U1"].partNumber == "23LC1024-I/SN"
    check x1.pins["spi_miso"].kind == ptInOut
    check x1.pins["spi_miso"].attrs["iface.instance"] == "spi"
    check x2.pins["cs"].net == spi.bus("cs")[1]
    check checkOutputConflicts(nl).len == 0
    check validateInterfaces(nl).len == 0
