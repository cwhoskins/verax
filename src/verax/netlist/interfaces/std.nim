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

proc diffPairInterface*(): InterfaceDef =
  ## A bare differential pair: two signals, no claimed numbers. `implies` the
  ## `diff_pair` role with no params, so instantiating one claims only
  ## `diff_pair_symmetry` -- the one thing `contract/evaluators/diff` can
  ## check without a board. Signals are named `p`/`n` so `diff_pair`'s parts
  ## bind by the ordinary same-name matching in `addRoleFromInterface`, with
  ## no need for `RoleClaim.binds`.
  # Neither modport is flagged `controller`: unlike a bus, a differential
  # pair has no invariant that a "driver" must be wired anywhere in a given
  # design -- a sheet describing only the receiver end (an ADC input pair, a
  # connector-side sheet) is not missing anything, so nothing here should
  # warn that it is.
  result.name = "diff_pair"
  result.signals = @[SignalDef(name: "p", width: 1), SignalDef(name: "n", width: 1)]
  result.modports["driver"] = modport("driver", [("p", ptOutput), ("n", ptOutput)])
  result.modports["receiver"] = modport("receiver", [("p", ptInput), ("n", ptInput)])
  result.implies = @[RoleClaim(role: "diff_pair")]

proc usb2Interface*(): InterfaceDef =
  ## USB 2.0's D+/D-, carrying the specification's own number: 90 ohm
  ## differential impedance +/- 15%, USB 2.0 sec. 7.1.1.3. Deliberately
  ## states no `skew_intra_max` -- the specification's 100 ps figure is a
  ## *cable* budget, not a board one, and inventing a board-level number on
  ## the author's behalf is not this catalogue's call to make.
  result.name = "usb2"
  result.signals = @[SignalDef(name: "p", width: 1), SignalDef(name: "n", width: 1)]
  result.modports["host"] = modport("host", [("p", ptInOut), ("n", ptInOut)])
  result.modports["device"] = modport("device", [("p", ptInOut), ("n", ptInOut)])
  result.implies = @[RoleClaim(role: "diff_pair",
    params: {"z_diff": "90", "z_diff_tol": "0.15"}.toOrderedTable)]

proc jtagInterface*(): InterfaceDef =
  ## The four-wire JTAG test-access port -- `tck`/`tms`/`tdi`/`tdo` -- plus
  ## the optional hardware TAP reset `ntrst`. ARM's SWJ-DP shares this same
  ## physical port with SWD (`tms` doubles as `swdio`, `tck` as `swclk`), so
  ## one interface covers either rather than a second whose signals would
  ## just be renamed copies. **No `implies`**: unlike `i2cInterface`, nothing
  ## in `contract/evaluators` can check a scan chain yet, and `implies`-ing a
  ## role that checks nothing would be worse than no role at all -- the same
  ## restraint `gainStageExpand`'s doc comment states for an uninvented gain
  ## default.
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
