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
    # A selected peripheral drives MISO; every other peripheral releases it.
    # `ptInOut` plus `shared` states that tri-state topology to ERC.
    SignalDef(name:"miso", width:1, shared:true), SignalDef(name:"cs", width:nCs)]
  result.modports["controller"] = modport("controller", [("sclk",ptOutput),("mosi",ptOutput),("miso",ptInput),("cs",ptOutput)], true)
  result.modports["peripheral"] = modport("peripheral", [("sclk",ptInput),("mosi",ptInput),("miso",ptInOut),("cs",ptInput)])

proc uartInterface*(): InterfaceDef =
  result.name = "uart"
  result.signals = @[SignalDef(name:"txd", width:1), SignalDef(name:"rxd", width:1)]
  result.modports["dte"] = modport("dte", [("txd",ptOutput),("rxd",ptInput)])
  result.modports["dce"] = modport("dce", [("txd",ptInput),("rxd",ptOutput)])

registerInterfaceDef(i2cInterface())
registerInterfaceDef(spiInterface())
registerInterfaceDef(uartInterface())
