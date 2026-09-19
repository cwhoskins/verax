import std/[unittest, tables]
import verax/contract/dsl
import verax/netlist/interfaces/std

# A def naming its signals `dp`/`dn` rather than `diff_pair`'s own `p`/`n` --
# `implies`' `RoleClaim.binds` is what lets it still auto-attach the role,
# by naming which signal each part reads from, built by hand since the
# `interfaceDef` macro has no `implies "role", binds = {...}` spelling.
let dpPairDef = block:
  var def: InterfaceDef
  def.name = "dp_pair"
  def.signals = @[SignalDef(name: "dp", width: 1), SignalDef(name: "dn", width: 1)]
  def.implies = @[RoleClaim(role: "diff_pair",
    binds: {"p": "dp", "n": "dn"}.toOrderedTable)]
  registerInterfaceDef(def)
  def

suite "interface contracts":
  test "from interface binds matching nets and controller":
    let d = design("d"):
      iface bus, i2cInterface()
      component U1, kind = "mcu":
        port bus, controller
      role "i2c", manual, `from` = bus, frequency = 100.kHz
    check d.roles["manual"].bindings["sda"].name == "bus_sda"
    check d.roles["manual"].bindings["controller"].name == "U1"

  test "interface implies its role unless explicit role wins":
    let d = design("d"):
      iface bus, i2cInterface()
      component U1, kind = "mcu":
        port bus, controller
    check d.roles.hasKey("bus")
    check d.roles["bus"].bindings["scl"].name == "bus_scl"

  test "RoleClaim.binds maps a role part to a differently-named interface signal":
    let d = design("d"):
      iface link, dpPairDef
      component U1, kind = "mcu":
        pin "P", link["dp"], kind = ptInOut
        pin "N", link["dn"], kind = ptInOut
    check d.roles.hasKey("link")
    check d.roles["link"].role == "diff_pair"
    check d.roles["link"].bindings["p"].name == "link_dp"
    check d.roles["link"].bindings["n"].name == "link_dn"
