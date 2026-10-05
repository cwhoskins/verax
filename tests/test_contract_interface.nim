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

  test "a scalar spi interface attaches spi under its own name, unfanned":
    let d = design("d"):
      iface spi, spiInterface()
      component U1, kind = "mcu":
        port spi, controller
    check d.roles.hasKey("spi")
    check not d.roles.hasKey("spi_cs0")
    check d.roles["spi"].role == "spi"
    check d.roles["spi"].member == 0
    check d.roles["spi"].bindings["cs"].name == "spi_cs"
    check d.roles["spi"].bindings["controller"].name == "U1"

  test "a wide spi interface fans out to one instance per chip select":
    let d = design("d"):
      iface spi, spiInterface(3)
      component U1, kind = "mcu":
        port spi, controller
    check not d.roles.hasKey("spi")
    for k in 0 .. 2:
      let name = "spi_cs" & $k
      check d.roles.hasKey(name)
      check d.roles[name].role == "spi"
      check d.roles[name].member == k
      # sclk/mosi/miso are shared across every member of the fan-out; only
      # cs was narrowed.
      check d.roles[name].bindings["sclk"].name == "spi_sclk"
      check d.roles[name].bindings["mosi"].name == "spi_mosi"
      check d.roles[name].bindings["miso"].name == "spi_miso"
      check d.roles[name].bindings["cs"].name == "spi_cs_" & $k
      check d.roles[name].bindings["controller"].name == "U1"

  test "an explicitly declared role wins over the fan-out, per member name too":
    let d = design("d"):
      iface spi, spiInterface(2)
      component U1, kind = "mcu":
        port spi, controller
      role "spi", spi_cs0, sclk = spi["sclk"], mosi = spi["mosi"],
           miso = spi["miso"], cs = spi["cs", 0]
    # The explicit instance is untouched, and the fan-out still attaches the
    # member it did not shadow.
    check d.roles["spi_cs0"].bindings["cs"].name == "spi_cs_0"
    check d.roles.hasKey("spi_cs1")
    check d.roles["spi_cs1"].member == 1

  test "i2c and diff_pair attachment is unchanged by the fan-out logic":
    let d = design("d"):
      iface bus, i2cInterface()
      iface pair, diffPairInterface()
      component U1, kind = "mcu":
        port bus, controller
        pin "P", pair["p"], kind = ptOutput
        pin "N", pair["n"], kind = ptOutput
    check d.roles.hasKey("bus")
    check d.roles["bus"].role == "i2c"
    check d.roles["bus"].member == 0
    check d.roles.hasKey("pair")
    check d.roles["pair"].role == "diff_pair"
    check d.roles["pair"].member == 0
