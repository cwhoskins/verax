## Pin-capability tables: registration, parsing, and `validatePinmux`.

import std/[sequtils, strutils, tables, unittest]
import verax/netlist
import verax/netlist/pinmux
import verax/netlist/interfaces/std
import verax/netlist/annotations
import verax/units

proc mcuTable(name: string, complete = false): PartPinmux =
  ## A tiny STM32-shaped table: SPI1/SPI2/SPI3, one primary pin group plus an
  ## alternate SCK shared between SPI1 and SPI3, and a GPIO or two.
  newPartPinmux(name,
    partNumbers = ["PART-" & name],
    complete = complete,
    peripherals = [
      (name: "SPI1", iface: "spi"),
      (name: "SPI2", iface: "spi"),
      (name: "SPI3", iface: "spi"),
      (name: "I2C1", iface: "i2c"),
      (name: "ADC1", iface: "")],
    pins = [
      (pin: "PA5", function: "SPI1.sclk"),
      (pin: "PA6", function: "SPI1.miso"),
      (pin: "PA7", function: "SPI1.mosi"),
      (pin: "PA4", function: "SPI1.cs"),
      (pin: "PA4", function: "GPIO"),
      (pin: "PB3", function: "SPI1.sclk"),
      (pin: "PB3", function: "SPI3.sclk"),
      (pin: "PB13", function: "SPI2.sclk"),
      (pin: "PB14", function: "SPI2.miso"),
      (pin: "PB15", function: "SPI2.mosi"),
      (pin: "PB12", function: "SPI2.cs"),
      (pin: "PA3", function: "ADC1.in3"),
      (pin: "PE0", function: "GPIO"),
      (pin: "PE1", function: "GPIO")])

proc controllerOn(nl: Netlist, table: string, peripheral: string,
                  pins: openArray[(string, string)],
                  functions: openArray[(string, string)] = []): Component =
  let spi = addInterface(nl, "spi", spiInterface(1))
  let mcu = addComponent(nl, newComponent("U1", kind = "mcu"))
  mcu.attrs[keyPinmuxDef] = table
  connectPort(mcu, view(spi, "controller"), pins = pins, peripheral = peripheral,
              functions = functions)
  mcu

suite "pinmux: parsing and registration":
  test "parseFunction splits on the last dot":
    check parseFunction("SPI1.sclk") == PinCapability(peripheral: "SPI1", signal: "sclk")
    check parseFunction("GPIO") == PinCapability(peripheral: "", signal: "GPIO")
    check parseFunction("TIM2.ch1.n") == PinCapability(peripheral: "TIM2.ch1", signal: "n")

  test "$PinCapability round-trips the spelling":
    check $parseFunction("SPI1.sclk") == "SPI1.sclk"
    check $parseFunction("GPIO") == "GPIO"

  test "registerPartPinmux rejects a duplicate name":
    discard mcuTable("dupname")
    registerPartPinmux(mcuTable("dupname"))
    expect NetlistError:
      registerPartPinmux(mcuTable("dupname"))

  test "registerPartPinmux rejects a capability naming an undeclared peripheral":
    expect NetlistError:
      registerPartPinmux(newPartPinmux("badperiph",
        peripherals = [(name: "SPI1", iface: "spi")],
        pins = [(pin: "PA5", function: "SPI9.sclk")]))

  test "registerPartPinmux rejects a duplicate capability on one pin":
    expect NetlistError:
      registerPartPinmux(newPartPinmux("dupcap",
        peripherals = [(name: "SPI1", iface: "spi")],
        pins = [(pin: "PA5", function: "SPI1.sclk"),
                (pin: "PA5", function: "SPI1.sclk")]))

  test "registerPartPinmux rejects a part number two tables both claim":
    registerPartPinmux(newPartPinmux("owner-a", partNumbers = ["SHARED-PN"],
      peripherals = [(name: "SPI1", iface: "spi")],
      pins = [(pin: "PA5", function: "SPI1.sclk")]))
    expect NetlistError:
      registerPartPinmux(newPartPinmux("owner-b", partNumbers = ["SHARED-PN"],
        peripherals = [(name: "SPI1", iface: "spi")],
        pins = [(pin: "PA5", function: "SPI1.sclk")]))

registerPartPinmux(mcuTable("T"))

suite "pinmux: validatePinmux":

  test "a correctly assigned port yields no issues":
    let nl = newNetlist("board")
    discard controllerOn(nl, "T", "SPI1",
      {"sclk": "PA5", "mosi": "PA7", "miso": "PA6", "cs": "PA4"})
    check validatePinmux(nl).len == 0

  test "an incapable pin is one sevError naming what it offers":
    let nl = newNetlist("board")
    discard controllerOn(nl, "T", "SPI2",
      {"sclk": "PB3", "mosi": "PB15", "miso": "PB14", "cs": "PB12"})
    let issues = validatePinmux(nl)
    let incap = issues.filterIt(it.kind == "pinmux_incapable")
    check incap.len == 1
    check incap[0].severity == sevError
    check "PB3" in incap[0].message
    check "SPI1.sclk" in incap[0].message
    check "SPI3.sclk" in incap[0].message

  test "an unlisted pin is a warning, promotable by complete":
    let nl = newNetlist("board")
    discard controllerOn(nl, "T", "SPI1",
      {"sclk": "PZ9", "mosi": "PA7", "miso": "PA6", "cs": "PA4"})
    let w = validatePinmux(nl).filterIt(it.kind == "pinmux_pin_unknown")
    check w.len == 1
    check w[0].severity == sevWarning

    registerPartPinmux(mcuTable("Tcomplete", complete = true))
    let nl2 = newNetlist("board")
    discard controllerOn(nl2, "Tcomplete", "SPI1",
      {"sclk": "PZ9", "mosi": "PA7", "miso": "PA6", "cs": "PA4"})
    let e = validatePinmux(nl2).filterIt(it.kind == "pinmux_pin_unknown")
    check e.len == 1
    check e[0].severity == sevError

  test "an unknown peripheral is reported and lists the ones the table has":
    let nl = newNetlist("board")
    let spi = addInterface(nl, "spi", spiInterface(1))
    let mcu = addComponent(nl, newComponent("U1", kind = "mcu"))
    mcu.attrs[keyPinmuxDef] = "T"
    connectPort(mcu, view(spi, "controller"),
      pins = {"sclk": "PA5", "mosi": "PA7", "miso": "PA6", "cs": "PA4"},
      peripheral = "SPI7")
    let i = validatePinmux(nl).filterIt(it.kind == "pinmux_peripheral_unknown")
    check i.len == 4                     # one per modport pin
    check "SPI1" in i[0].message

  test "a peripheral whose interface disagrees with the port is a kind mismatch":
    let nl = newNetlist("board")
    let spi = addInterface(nl, "spi", spiInterface(1))
    let mcu = addComponent(nl, newComponent("U1", kind = "mcu"))
    mcu.attrs[keyPinmuxDef] = "T"
    # I2C1 is an "i2c" peripheral; wiring it onto an "spi" port is the error.
    connectPort(mcu, view(spi, "controller"),
      pins = {"sclk": "PA5", "mosi": "PA7", "miso": "PA6", "cs": "PA4"},
      peripheral = "I2C1")
    check validatePinmux(nl).anyIt(it.kind == "pinmux_peripheral_kind_mismatch")

  test "two ports claiming one peripheral is double-booked":
    let nl = newNetlist("board")
    let a = addInterface(nl, "spia", spiInterface(1))
    let b = addInterface(nl, "spib", spiInterface(1))
    let mcu = addComponent(nl, newComponent("U1", kind = "mcu"))
    mcu.attrs[keyPinmuxDef] = "T"
    connectPort(mcu, view(a, "controller"),
      pins = {"sclk": "PA5", "mosi": "PA7", "miso": "PA6", "cs": "PA4"},
      peripheral = "SPI1")
    connectPort(mcu, view(b, "controller"),
      pins = {"sclk": "PB3", "mosi": "PA7", "miso": "PA6", "cs": "PA4"},
      peripheral = "SPI1", prefix = "b_")
    check validatePinmux(nl).anyIt(it.kind == "pinmux_peripheral_double_booked")

  test "one function on two pins of one part is duplicated":
    let nl = newNetlist("board")
    let spi = addInterface(nl, "spi", spiInterface(2))
    let mcu = addComponent(nl, newComponent("U1", kind = "mcu"))
    mcu.attrs[keyPinmuxDef] = "T"
    # Both chip selects left as SPI1.cs -- no `functions` override.
    connectPort(mcu, view(spi, "controller"),
      pins = {"sclk": "PA5", "mosi": "PA7", "miso": "PA6",
              "cs_0": "PA4", "cs_1": "PE0"},
      peripheral = "SPI1")
    check validatePinmux(nl).anyIt(it.kind == "pinmux_function_duplicated")

  test "functions override suppresses the incapable finding on a software CS":
    let nl = newNetlist("board")
    let spi = addInterface(nl, "spi", spiInterface(2))
    let mcu = addComponent(nl, newComponent("U1", kind = "mcu"))
    mcu.attrs[keyPinmuxDef] = "T"
    connectPort(mcu, view(spi, "controller"),
      pins = {"sclk": "PA5", "mosi": "PA7", "miso": "PA6",
              "cs_0": "PA4", "cs_1": "PE0"},
      peripheral = "SPI1", functions = {"cs_1": "GPIO"})
    check validatePinmux(nl).len == 0

  test "a standalone pin function is checked":
    let nl = newNetlist("board")
    let n = addNet(nl, newNet("vsense", ntSignal))
    let mcu = addComponent(nl, newComponent("U1", kind = "mcu"))
    mcu.attrs[keyPinmuxDef] = "T"
    let p = connect(mcu, "PA3", n, ptInput)
    setPinFunction(p, "ADC1.in3")
    check validatePinmux(nl).len == 0
    setPinFunction(p, "ADC1.in9")            # PA3 offers in3, not in9
    check validatePinmux(nl).anyIt(it.kind == "pinmux_incapable")

  test "a part with no registered table produces no issues":
    let nl = newNetlist("board")
    let spi = addInterface(nl, "spi", spiInterface(1))
    let mcu = addComponent(nl, newComponent("U1", kind = "mcu",
      partNumber = "NOTHING-KNOWS-THIS"))
    connectPort(mcu, view(spi, "controller"),
      pins = {"sclk": "PZ9", "mosi": "PZ8", "miso": "PZ7", "cs": "PZ6"},
      peripheral = "SPI1")
    check validatePinmux(nl).len == 0

  test "the check reaches a part inside a subckt instance":
    registerPartPinmux(mcuTable("Tsub"))
    let child = newNetlist("CHILD")
    let cn = addNet(child, newNet("clk", ntSignal))
    addPort(child, "clk", cn)
    let cu = addComponent(child, newComponent("U1", kind = "mcu"))
    cu.attrs[keyPinmuxDef] = "Tsub"
    let cp = connect(cu, "PB13", cn, ptOutput)   # PB13 is SPI2.sclk, not SPI1
    setPinFunction(cp, "SPI1.sclk")

    let top = newNetlist("TOP")
    let tn = addNet(top, newNet("topclk", ntSignal))
    var globals = initOrderedTable[string, Net]()
    discard instantiate(top, "X1", child, @[tn], globals)
    check top.children["X1"].components["U1"].pins["PB13"].attrs[keyPinmuxSignal] == "sclk"
    check validatePinmux(top).anyIt(it.kind == "pinmux_incapable")

suite "pinmux: reset-state pulls":
  proc pulledTable(name: string): PartPinmux =
    newPartPinmux(name, partNumbers = ["PART-" & name],
      peripherals = [(name: "JTAG", iface: "jtag")],
      pins = [(pin: "PA13", function: "JTAG.tms"),
              (pin: "PA14", function: "JTAG.tck"),
              (pin: "PA15", function: "GPIO")],
      resetPulls = [(pin: "PA13", kind: pkUp, ohms: 40.kohm),
                    (pin: "PA14", kind: pkDown, ohms: 40.kohm)])

  proc partOn(nl: Netlist, table: string): Component =
    let vdd = addNet(nl, newNet("vdd", ntPower))
    result = addComponent(nl, newComponent("U1", kind = "mcu",
                                           partNumber = "PART-" & table))
    discard connect(result, "VDD", vdd, ptPower)
    for pin in ["PA13", "PA14", "PA15"]:
      discard connect(result, pin, addNet(nl, newNet(pin.toLowerAscii)), ptInput)

  test "a part inherits its table's reset pulls, by pin":
    registerPartPinmux(pulledTable("pulls-a"))
    let u = partOn(newNetlist("t"), "pulls-a")
    let tms = pinPull(u.pins["PA13"])
    check tms.has and tms.value.kind == pkUp
    check abs(float(tms.value.ohms) - 40.0e3) < 1e-9
    check "pulls-a" in tms.value.origin
    check pinPull(u.pins["PA14"]).value.kind == pkDown
    check not hasPull(u.pins["PA15"])
    check pullRail(u.pins["PA13"]).net.name == "vdd"

  test "a pull stated on the pin overrides the table's":
    registerPartPinmux(pulledTable("pulls-b"))
    let u = partOn(newNetlist("t"), "pulls-b")
    setAnnotation(u.pins["PA13"], "pull_down", 10.kohm)
    let p = pinPull(u.pins["PA13"])
    check p.value.kind == pkDown
    check abs(float(p.value.ohms) - 10.0e3) < 1e-9
    check p.value.origin == "stated on the pin"

  test "a part with no table has only the pulls stated on its pins":
    let nl = newNetlist("t")
    let u = addComponent(nl, newComponent("U1", kind = "mcu"))
    let p = connect(u, "BOOT", addNet(nl, newNet("boot")), ptInput)
    check not hasPull(p)
    setAnnotation(p, "pull_up", 47.kohm)
    check hasPull(p)

  test "a reset pull on a pin the table does not name is refused":
    expect NetlistError:
      registerPartPinmux(newPartPinmux("pulls-bad",
        peripherals = [], pins = [(pin: "PA1", function: "GPIO")],
        resetPulls = [(pin: "PA9", kind: pkUp, ohms: 40.kohm)]))
