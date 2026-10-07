## Standard, opt-in interface definitions.
import std/tables
import ../interfaces
import ../types

proc modport(name: string, dirs: openArray[(string, PinType)], controller = false): Modport =
  result.name = name; result.controller = controller
  for pair in dirs: result.dirs[pair[0]] = pair[1]

proc i2cInterface*(): InterfaceDef =
  result.name = "i2c"
  result.signals = @[SignalDef(name: "scl", width: 1, shared: true),
                     SignalDef(name: "sda", width: 1, shared: true)]
  result.modports["controller"] = modport("controller", [("scl", ptOutput), ("sda", ptInOut)], true)
  result.modports["target"] = modport("target", [("scl", ptInput), ("sda", ptInOut)])
  result.modports["master"] = result.modports["controller"]
  result.modports["slave"] = result.modports["target"]
  result.implies = @[RoleClaim(role: "i2c")]

proc spiInterface*(nCs = 1): InterfaceDef =
  result.name = "spi"
  result.signals = @[SignalDef(name:"sclk", width:1), SignalDef(name:"mosi", width:1),
    # The selected peripheral drives MISO; the others release it (`shared`
    # tells ERC it's tri-state).
    SignalDef(name:"miso", width:1, shared:true), SignalDef(name:"cs", width:nCs)]
  result.modports["controller"] = modport("controller", [("sclk",ptOutput),("mosi",ptOutput),("miso",ptInput),("cs",ptOutput)], true)
  result.modports["peripheral"] = modport("peripheral", [("sclk",ptInput),("mosi",ptInput),("miso",ptInOut),("cs",ptInput)])
  # `cs` is often wide; `addImpliedRoles` fans it into one `spi` instance per
  # member.
  result.implies = @[RoleClaim(role: "spi")]

proc uartInterface*(): InterfaceDef =
  result.name = "uart"
  result.signals = @[SignalDef(name:"txd", width:1), SignalDef(name:"rxd", width:1)]
  result.modports["dte"] = modport("dte", [("txd",ptOutput),("rxd",ptInput)])
  result.modports["dce"] = modport("dce", [("txd",ptInput),("rxd",ptOutput)])

proc diffPairInterface*(): InterfaceDef =
  ## A bare differential pair (`p`/`n`), implying `diff_pair` with no params
  ## (so only `diff_pair_symmetry` is claimed); parts bind by name.
  # No `controller` modport: a receiver-only sheet isn't missing a driver.
  result.name = "diff_pair"
  result.signals = @[SignalDef(name: "p", width: 1), SignalDef(name: "n", width: 1)]
  result.modports["driver"] = modport("driver", [("p", ptOutput), ("n", ptOutput)])
  result.modports["receiver"] = modport("receiver", [("p", ptInput), ("n", ptInput)])
  result.implies = @[RoleClaim(role: "diff_pair")]

proc usb2Interface*(): InterfaceDef =
  ## USB 2.0 D+/D-: 90 ohm differential +/- 15% (USB 2.0 sec. 7.1.1.3). No
  ## `skew_intra_max`: the spec's 100 ps is a cable budget, not a board one.
  result.name = "usb2"
  result.signals = @[SignalDef(name: "p", width: 1), SignalDef(name: "n", width: 1)]
  result.modports["host"] = modport("host", [("p", ptInOut), ("n", ptInOut)])
  result.modports["device"] = modport("device", [("p", ptInOut), ("n", ptInOut)])
  result.implies = @[RoleClaim(role: "diff_pair",
    params: {"z_diff": "90", "z_diff_tol": "0.15"}.toOrderedTable)]

proc jtagInterface*(): InterfaceDef =
  ## Four-wire JTAG (`tck`/`tms`/`tdi`/`tdo`) plus optional `ntrst`; also
  ## covers SWD on the same port (`tms` = `swdio`, `tck` = `swclk`). **No
  ## `implies`**: nothing can check a scan chain yet.
  result.name = "jtag"
  result.signals = @[SignalDef(name: "tck", width: 1), SignalDef(name: "tms", width: 1),
                     SignalDef(name: "tdi", width: 1), SignalDef(name: "tdo", width: 1),
                     SignalDef(name: "ntrst", width: 1)]
  result.modports["controller"] = modport("controller",
    [("tck", ptOutput), ("tms", ptOutput), ("tdi", ptOutput), ("tdo", ptInput), ("ntrst", ptOutput)], true)
  result.modports["target"] = modport("target",
    [("tck", ptInput), ("tms", ptInput), ("tdi", ptInput), ("tdo", ptOutput), ("ntrst", ptInput)])

registerInterfaceDef(i2cInterface())
registerInterfaceDef(spiInterface())
registerInterfaceDef(uartInterface())
registerInterfaceDef(diffPairInterface())
registerInterfaceDef(usb2Interface())
registerInterfaceDef(jtagInterface())
