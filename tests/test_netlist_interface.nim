import std/[unittest, tables]
import verax/netlist
import verax/netlist/interfaces
import verax/netlist/dsl
import verax/netlist/interfaces/std

let macroDef = interfaceDef("macro_test"):
  signal tx
  signal data, width = 2
  modport source, controller = true:
    tx = ptOutput
    data = ptOutput
  implies "test_role"

proc simpleDef(): InterfaceDef =
  result.name = "test_interface"
  result.signals = @[SignalDef(name: "a", width: 1), SignalDef(name: "d", width: 2)]
  var m: Modport
  m.name = "host"; m.controller = true
  m.dirs["a"] = ptOutput; m.dirs["d"] = ptInput
  result.modports[m.name] = m

suite "interfaces":
  test "interfaceDef macro registers signals and modports":
    check interfaceDefOf("macro_test").signals.len == 2
    check macroDef.modports["source"].controller
  test "registration and recovery are metadata based":
    var d = simpleDef(); registerInterfaceDef(d)
    let nl = newNetlist("i"); let i = addInterface(nl, "io", d)
    check i["a"].name == "io_a"
    check i.bus("d")[1].name == "io_d_1"
    check findInterface(nl, "io")["a"] == i["a"]
    # Width is recovered from bus metadata so parameterized definitions keep
    # their authored width after a clone or registry default is reloaded.
    d.signals[0].width = 2; registerInterfaceDef(d)
    check findInterface(nl, "io").bus("a").len == 1
    registerInterfaceDef(simpleDef())
  test "modport stamps directions and pins":
    let d = simpleDef(); registerInterfaceDef(d)
    let nl = newNetlist("i"); let i = addInterface(nl, "io", d)
    let c = addComponent(nl, newComponent("U1"))
    connectPort(c, view(i, "host"))
    check c.pins["a"].kind == ptOutput
    check c.pins["d_0"].kind == ptInput

  test "SPI recovery preserves its parameterized chip-select width":
    let nl = newNetlist("i")
    discard addInterface(nl, "spi", spiInterface(2))
    var globals = initOrderedTable[string, Net]()
    let copy = clone(nl, globals)
    let recovered = findInterface(copy, "spi")
    check recovered.bus("cs").len == 2
    check recovered.def.signals[3].width == 2

  test "member index accessor and narrow present a value-space slice":
    let nl = newNetlist("i")
    let spi = addInterface(nl, "spi", spiInterface(2))
    check spi["cs", 0] == spi.bus("cs")[0]
    check spi["cs", 1] == spi.bus("cs")[1]
    # narrow copies -- the original interface is untouched.
    let n0 = spi.narrow("cs", 0)
    check n0.bus("cs").len == 1
    check n0.bus("cs")[0] == spi.bus("cs")[0]
    check n0.def.signals[3].width == 1
    check spi.bus("cs").len == 2          # original unchanged
    expect NetlistError: discard spi.narrow("cs", 5)
    # narrow of a slice re-indexes from zero.
    let sl = spi.narrow("cs", 1 .. 1)
    check sl.bus("cs").len == 1
    check sl.bus("cs")[0] == spi.bus("cs")[1]

  test "wiringOf on a whole interface member-suffixes wide signals":
    let nl = newNetlist("i")
    let spi = addInterface(nl, "spi", spiInterface(2))
    let w = wiringOf("spi", spi)
    var byLabel = initTable[string, Net]()
    for pair in w: byLabel[pair[0]] = pair[1]
    check byLabel["spi_sclk"] == spi["sclk"]
    check byLabel["spi_cs_0"] == spi.bus("cs")[0]
    check byLabel["spi_cs_1"] == spi.bus("cs")[1]
    # a narrowed interface wires straight onto a single-member child port.
    let nw = wiringOf("spi", spi.narrow("cs", 0))
    var narrowed: seq[string]
    for pair in nw: narrowed.add pair[0]
    check narrowed == @["spi_sclk", "spi_mosi", "spi_miso", "spi_cs"]
    # the whole-view overload keeps only the modport's signals, member-suffixed.
    let vw = wiringOf("spi", view(spi, "controller"))
    var vlabels: seq[string]
    for pair in vw: vlabels.add pair[0]
    check "spi_cs_0" in vlabels
    check "spi_cs_1" in vlabels
    check "spi_sclk" in vlabels

  test "wide interface members map to distinct package pins":
    let nl = newNetlist("i")
    let spi = addInterface(nl, "spi", spiInterface(2))
    let c = addComponent(nl, newComponent("U1"))
    connectPort(c, view(spi, "controller"),
      [("cs_0", "NSS1"), ("cs_1", "NSS2")])
    check c.pins["NSS1"].net == spi.bus("cs")[0]
    check c.pins["NSS2"].net == spi.bus("cs")[1]
