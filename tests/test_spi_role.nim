## The `spi` role: its per-chip-select fan-out (`design.addImpliedRoles`,
## exercised end to end here through `spiInterface`) and the evaluator its
## `miso_driver_count` claim rests on (`contract/evaluators/static`).

import std/[sequtils, strutils, tables, unittest]

import verax/netlist
import verax/contract
import verax/contract/dsl
import verax/netlist/interfaces/std
import verax/units

import "../designs/lib/spi_memory"

proc net(name: string): Subject = Subject(kind: skNet, name: name)
proc comp(name: string): Subject = Subject(kind: skComponent, name: name)

proc bus(): Design =
  ## A bare SPI bus with a controller and no peripherals -- enough to attach
  ## an `spi` role instance by hand and check what it claims, without going
  ## through an interface's fan-out.
  let nl = newNetlist("board")
  let vdd = addNet(nl, newNet("vdd", ntPower))
  let gnd = addNet(nl, newNet("0", ntGround))
  let sclk = addNet(nl, newNet("sclk", ntSignal))
  let mosi = addNet(nl, newNet("mosi", ntSignal))
  let miso = addNet(nl, newNet("miso", ntSignal))
  let cs = addNet(nl, newNet("cs", ntSignal))
  let u1 = addComponent(nl, newComponent("U1", kind = "mcu"))
  discard connect(u1, "VDD", vdd, ptPower)
  discard connect(u1, "GND", gnd, ptGround)
  discard connect(u1, "SCLK", sclk, ptOutput)
  discard connect(u1, "MOSI", mosi, ptOutput)
  discard connect(u1, "MISO", miso, ptInput)
  discard connect(u1, "CS", cs, ptOutput)
  newDesign(nl)

# --- the role's own claims ------------------------------------------------

suite "the spi role":
  test "always claims a controller and a miso-driver count":
    let d = bus()
    discard d.addRole("spi", "sp0",
      {"sclk": net("sclk"), "mosi": net("mosi"), "miso": net("miso"),
       "cs": net("cs"), "controller": comp("U1")})
    let quantities = d.expandAll().mapIt(it.quantity)
    check "controller_count" in quantities
    check "miso_driver_count" in quantities
    check "pullup_count" notin quantities

  test "cs.pullup is opt-in, claimed only when csPullup is stated":
    # `designs/spi_memories.nim` drives every select from a GPIO with no
    # pull-up, and an unconditional claim here would fail nine times on a
    # correct board -- the same `power_rail`/`targetZ` doctrine.
    let d = bus()
    discard d.addRole("spi", "sp0",
      {"sclk": net("sclk"), "mosi": net("mosi"), "miso": net("miso"),
       "cs": net("cs"), "controller": comp("U1")}, {"csPullup": "1"})
    check "pullup_count" in d.expandAll().mapIt(it.quantity)

  test "the frequency parameter rides in every claim's condition":
    let d = bus()
    discard d.addRole("spi", "sp0",
      {"sclk": net("sclk"), "mosi": net("mosi"), "miso": net("miso"),
       "cs": net("cs")}, {"frequency": "1000000"})
    for a in d.expandAll():
      check a.condition.getOrDefault("frequency") == "1000000"

# --- the per-chip-select fan-out ------------------------------------------

suite "the spi role's chip-select fan-out":
  test "controller_count is claimed once per bus, not once per chip select":
    let d = design("fanout"):
      net gnd, kind = ntGround, name = "0"
      net vdd, kind = ntPower:
        spec:
          voltage = 3.3.V
      iface spi, spiInterface(3)
      component U1, kind = "mcu":
        pin "VDD", vdd, kind = ptPower
        pin "VSS", gnd, kind = ptGround
        port spi, controller

    check d.roles.hasKey("spi_cs0")
    check d.roles.hasKey("spi_cs1")
    check d.roles.hasKey("spi_cs2")
    check d.roles["spi_cs0"].member == 0
    check d.roles["spi_cs1"].member == 1
    check d.roles["spi_cs2"].member == 2

    var controllerClaims = 0
    for a in d.expandAll():
      if a.quantity == "controller_count": inc controllerClaims
    check controllerClaims == 1

  test "a single-select interface fans out to nothing -- the historical, unfanned path":
    let d = design("noFanout"):
      net gnd, kind = ntGround, name = "0"
      net vdd, kind = ntPower:
        spec:
          voltage = 3.3.V
      iface spi, spiInterface(1)
      component U1, kind = "mcu":
        pin "VDD", vdd, kind = ptPower
        pin "VSS", gnd, kind = ptGround
        port spi, controller
    check d.roles.hasKey("spi")
    check not d.roles.hasKey("spi_cs0")
    check d.roles["spi"].member == 0

# --- miso_driver_count -----------------------------------------------------

proc twoSelectBus(sharedCs: bool): Design =
  ## A controller and two peripherals, each with its own chip select unless
  ## `sharedCs`, in which case both sit on chip select 0 -- the defect
  ## `miso_driver_count` exists to catch: two peripherals that will both
  ## drive MISO the instant that one select is asserted.
  let nl = newNetlist("board")
  let sclk = addNet(nl, newNet("sclk", ntSignal))
  let mosi = addNet(nl, newNet("mosi", ntSignal))
  let miso = addNet(nl, newNet("miso", ntSignal))
  let cs0 = addNet(nl, newNet("cs0", ntSignal))
  let cs1 = addNet(nl, newNet("cs1", ntSignal))
  let u1 = addComponent(nl, newComponent("U1", kind = "mcu"))
  discard connect(u1, "SCLK", sclk, ptOutput)
  discard connect(u1, "MOSI", mosi, ptOutput)
  discard connect(u1, "MISO", miso, ptInput)
  discard connect(u1, "CS0", cs0, ptOutput)
  discard connect(u1, "CS1", cs1, ptOutput)
  let u2 = addComponent(nl, newComponent("U2", kind = "memory"))
  discard connect(u2, "SCLK", sclk, ptInput)
  discard connect(u2, "MOSI", mosi, ptInput)
  discard connect(u2, "MISO", miso, ptInOut)
  discard connect(u2, "CS", cs0, ptInput)
  let u3 = addComponent(nl, newComponent("U3", kind = "memory"))
  discard connect(u3, "SCLK", sclk, ptInput)
  discard connect(u3, "MOSI", mosi, ptInput)
  discard connect(u3, "MISO", miso, ptInOut)
  discard connect(u3, "CS", (if sharedCs: cs0 else: cs1), ptInput)
  newDesign(nl)

proc misoDriverAssertion(cs: string): Assertion =
  Assertion(id: "REQ", subjects: @[net("miso"), net(cs)],
           quantity: "miso_driver_count", expect: atMost(1.0))

suite "miso_driver_count":
  test "one memory per select returns 1, and never counts the controller":
    let d = twoSelectBus(sharedCs = false)
    d.assertThat misoDriverAssertion("cs0")
    let r0 = evaluate(d, offlineCapabilities)
    check r0.len == 1
    check r0[0].status == esPass
    check r0[0].value == 1.0    # not 2 -- U1's MISO pin is ptInput, excluded

  test "two memories sharing one select returns 2 and fails the claim":
    let d = twoSelectBus(sharedCs = true)
    d.assertThat misoDriverAssertion("cs0")
    let r = evaluate(d, offlineCapabilities)
    check r.len == 1
    check r[0].status == esFail
    check r[0].value == 2.0

  test "declines when no pin on MISO states a direction":
    let nl = newNetlist("board")
    let miso = addNet(nl, newNet("miso", ntSignal))
    let cs = addNet(nl, newNet("cs", ntSignal))
    let u2 = addComponent(nl, newComponent("U2", kind = "memory"))
    discard connect(u2, "MISO", miso)                  # default ptUnknown
    discard connect(u2, "CS", cs, ptInput)
    let d = newDesign(nl)
    d.assertThat misoDriverAssertion("cs")
    let r = evaluate(d, offlineCapabilities)
    check r.len == 1
    check r[0].status == esNotEvaluable
    check "states a direction" in r[0].reason

  test "a hierarchical instance is not double-counted; only its leaf driver is":
    # `designs/lib/spi_memory.SPI_MEMORY` is a real subckt: the boundary pin
    # `X1` presents on the shared MISO bus sits on the identical conductor as
    # the leaf 23LC1024's own driving pin, joined only through `Pin.hierNet`
    # at the instance boundary (`allPins`'s reason for existing). Counting
    # both would report 2 drivers behind one memory.
    let nl = newNetlist("board")
    let gnd = addNet(nl, newNet("0", ntGround))
    let vdd = addNet(nl, newNet("vdd", ntPower))
    let spi = addInterface(nl, "spi", spiInterface(1))
    let wp = addNet(nl, newNet("wp", ntSignal))
    let mcu = addComponent(nl, newComponent("U1", kind = "mcu"))
    connectPort(mcu, view(spi, "controller"))
    discard connect(mcu, "WP", wp, ptOutput)
    var globals = initOrderedTable[string, Net]()
    let x1 = instantiate(nl, "X1", SPI_MEMORY,
      @[vdd, gnd, wp, spi["sclk"], spi["mosi"], spi["miso"], spi["cs"]], globals)
    promotePortDirections(x1)
    let d = newDesign(nl)
    d.assertThat Assertion(id: "REQ", subjects: @[net("spi_miso"), net("spi_cs")],
                           quantity: "miso_driver_count", expect: atMost(1.0))
    let r = evaluate(d, offlineCapabilities)
    check r.len == 1
    check r[0].status == esPass
    check r[0].value == 1.0
