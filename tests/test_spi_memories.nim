## Structural regression for the reusable SPI memory sheet.

import std/[tables, unittest]
import verax/netlist
import verax/netlist/interfaces/std
import verax/netlist/pinmux
import verax/analysis/io_check

import "../designs/lib/spi_memory"

suite "SPI memory sheet":
  test "two selected-by-slice memories share tri-state MISO":
    let nl = newNetlist("board")
    let gnd = addNet(nl, newNet("0", ntGround))
    let vdd = addNet(nl, newNet("vdd", ntPower))
    let spi = addInterface(nl, "spi", spiInterface(2))
    let wp = addBus(nl, "wp", 2)
    let mcu = addComponent(nl, newComponent("U1", kind = "mcu"))
    connectPort(mcu, view(spi, "controller"))
    discard connect(mcu, "WP0", wp[0], ptOutput)
    discard connect(mcu, "WP1", wp[1], ptOutput)

    var globals = initOrderedTable[string, Net]()
    let x1 = instantiate(nl, "X1", SPI_MEMORY,
      @[vdd, gnd, wp[0], spi["sclk"], spi["mosi"], spi["miso"], spi.bus("cs")[0]], globals)
    let x2 = instantiate(nl, "X2", SPI_MEMORY,
      @[vdd, gnd, wp[1], spi["sclk"], spi["mosi"], spi["miso"], spi.bus("cs")[1]], globals)
    promotePortDirections(x1)
    promotePortDirections(x2)

    check x1.subNetlist.components["U1"].partNumber == "23LC1024-I/SN"
    check x1.pins["spi_miso"].kind == ptInOut
    check x1.pins["spi_miso"].attrs["iface.instance"] == "spi"
    check x2.pins["spi_cs"].net == spi.bus("cs")[1]
    check x1.pins["wp"].net == wp[0]
    check x2.pins["wp"].net == wp[1]
    check checkOutputConflicts(nl).len == 0
    check validateInterfaces(nl).len == 0

  test "connectPort stamps peripheral and function onto the port pins":
    let nl = newNetlist("board")
    let spi = addInterface(nl, "spi", spiInterface(2))
    let mcu = addComponent(nl, newComponent("U1", kind = "mcu"))
    connectPort(mcu, view(spi, "controller"),
      pins = {"sclk": "PA5", "mosi": "PA7", "miso": "PA6",
              "cs_0": "PA4", "cs_1": "PD14"},
      peripheral = "SPI1", functions = {"cs_1": "GPIO"})
    check mcu.pins["PA5"].attrs[keyPinmuxPeripheral] == "SPI1"
    check mcu.pins["PA5"].attrs[keyPinmuxSignal] == "sclk"
    check mcu.pins["PA5"].attrs["iface.def"] == "spi"
    check mcu.pins["PA4"].attrs[keyPinmuxPeripheral] == "SPI1"
    check mcu.pins["PA4"].attrs[keyPinmuxSignal] == "cs"
    # The software chip select is a GPIO, not an SPI1 function.
    check not mcu.pins["PD14"].attrs.hasKey(keyPinmuxPeripheral)
    check mcu.pins["PD14"].attrs[keyPinmuxSignal] == "GPIO"
