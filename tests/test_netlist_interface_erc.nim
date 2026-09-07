import std/[unittest, tables, sequtils]
import verax/netlist/interfaces
import verax/netlist/types
import verax/netlist/graph
import verax/netlist/interfaces/std
import verax/analysis/io_check

suite "interface ERC":
  test "reports no controller and dangling members":
    var d: InterfaceDef
    d.name = "erc"; d.signals = @[SignalDef(name: "x", width: 1)]
    var mp: Modport; mp.name = "controller"; mp.controller = true; mp.dirs["x"] = ptOutput
    d.modports[mp.name] = mp
    registerInterfaceDef(d)
    let nl = newNetlist("n"); discard addInterface(nl, "io", d)
    let kinds = validateInterfaces(nl).mapIt(it.kind)
    check "interface_no_controller" in kinds
    check "interface_signal_dangling" in kinds

  test "shared inouts do not create a generic conflict":
    var d: InterfaceDef
    d.name = "shared"; d.signals = @[SignalDef(name: "x", width: 1, shared: true)]
    var mp: Modport; mp.name = "side"; mp.dirs["x"] = ptInOut
    d.modports[mp.name] = mp; registerInterfaceDef(d)
    let nl = newNetlist("n"); let i = addInterface(nl, "io", d)
    let a = addComponent(nl, newComponent("A")); let b = addComponent(nl, newComponent("B"))
    connectPort(a, view(i, "side")); connectPort(b, view(i, "side"))
    check checkOutputConflicts(nl).len == 0

  test "shared tri-state SPI MISO is neither conflicted nor undriven":
    let nl = newNetlist("n"); let spi = addInterface(nl, "spi", spiInterface(2))
    let host = addComponent(nl, newComponent("HOST"))
    let a = addComponent(nl, newComponent("A")); let b = addComponent(nl, newComponent("B"))
    connectPort(host, view(spi, "controller"))
    connectPort(a, view(spi, "peripheral"))
    connectPort(b, view(spi, "peripheral"))
    check checkOutputConflicts(nl).len == 0
    check "interface_signal_undriven" notin validateInterfaces(nl).mapIt(it.kind)
