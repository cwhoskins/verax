import std/[unittest, tables]
import nimcir/contract/dsl
import nimcir/netlist/interfaces/std

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
