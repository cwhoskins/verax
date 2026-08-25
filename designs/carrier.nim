## The carrier board: USB in, 3.3 V out to a sensor head.
##
##   nimcir check designs/carrier.nim
##
## **This file is both a board and a program.** Checked directly it is the
## primary circuit: `when isMainModule` below states what is plugged into each
## connector and verifies the board against it. Imported by
## `designs/system_sensor_rig.nim` it is a module, `carrierBoard()` is just a
## netlist, and the system supplies the real other end instead.
##
## `when isMainModule` is the whole mechanism, and it is exactly right for the
## question: "is this board the thing under test, or a part of something
## bigger" is a property of how the file was compiled, which is what `when`
## answers. Nothing at runtime has to be told which world it is in.
##
## Its two connectors are what become its ports: `spice/boundary.asSubcircuit`
## promotes the net each connector pin sits on and **drops the connectors** --
## which takes the bench drives below with them, since a drive is recorded on
## a connector pin. So the standalone assumptions cannot leak into a system
## that has the real thing attached.
##
## **What a standalone check can and cannot tell you.** Every claim here is
## conditional on the assumed other end: a host supply of stated stiffness at
## one connector, and an assumed 100 mA draw at the other. That is worth
## checking -- it catches a divider, a dropout, a missing bypass -- and it is
## not a statement about the product. `designs/system_sensor_rig.nim` makes
## the same rail's claim against the board that is actually plugged in, and
## gets a different answer.

import nimcir/contract/dsl
import ./lib/parts

proc carrierBoard*(): Netlist =
  netlist("carrier"):
    net gnd,  kind = ntGround, name = "0"
    net vbus, kind = ntPower                 # from the host
    net vout, kind = ntPower                 # to the sensor head

    # --- the edges -----------------------------------------------------
    component J1, kind = "connector", partNumber = "USB-C receptacle":
      pin "VBUS", vbus, kind = ptPower
      pin "GND",  gnd,  kind = ptGround
    component J2, kind = "connector", partNumber = "JST-PH 4-way":
      pin "VOUT", vout, kind = ptPower
      pin "GND",  gnd,  kind = ptGround

    # --- input side ----------------------------------------------------
    component C1, kind = "capacitor", value = "10u":
      pin "1", vbus, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "0805"
        dielectric = "X7R"
        voltage_rating = 16.0.V
    component C2, kind = "capacitor", value = "100n":
      pin "1", vbus, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "0402"
        dielectric = "X7R"
        voltage_rating = 16.0.V

    # --- the regulator -------------------------------------------------
    # `voltage` on the *component* is what it makes, which is what keeps a
    # `dc_voltage` claim worth making: read off the net instead and the check
    # measures its own assumption back.
    component U1, kind = "ldo", partNumber = "AP2112K-3.3":
      pin "IN",  vbus, kind = ptPower
      pin "OUT", vout, kind = ptOutput
      pin "GND", gnd,  kind = ptGround
      spec:
        voltage = 3.3.V
        rout = 80.mohm

    # --- output side ---------------------------------------------------
    # The bulk lives here, on the carrier, which is the arrangement this
    # system exists to question: a cable away from the load, it is not the
    # decoupling it looks like.
    component C3, kind = "capacitor", value = "22u":
      pin "1", vout, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = packageTantalum
        dielectric = packageTantalum
        voltage_rating = 10.0.V
        esr = 200.mohm
        esl = 3.nH
    component C4, kind = "capacitor", value = "100n":
      pin "1", vout, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "0402"
        dielectric = "X7R"
        voltage_rating = 10.0.V

when isMainModule:
  import nimcir/verify
  import nimcir/spice/boundary

  # The board on the bench. Both edges have to be described: a supply at the
  # USB receptacle and a load at the output, because a regulator with nothing
  # attached tells you nothing you did not already know.
  let d = newDesign(carrierBoard())

  driveConnector(findComponent(d.netlist, "J1"),
                 {"VBUS": driveSource(5.0.V, rout = 100.mohm, lout = 2.uH)})
  # A *sink* rather than a resistor: the sensor head regulates its own
  # supply, so its current does not follow this rail, and a resistor would
  # damp the decoupling network in a way the real load does not.
  driveConnector(findComponent(d.netlist, "J2"),
                 {"VOUT": driveSink(100.mA)})

  discard d.addRole("power_rail", "host",
                    {"rail": Subject(kind: skNet, name: "vbus")},
                    {"voltage": "5.0", "band": "0.05"})
  # The board's own output, against its own decoupling and an assumed load.
  # 300 mohm is a reasonable bar for a 100 mA rail; what it cannot tell you is
  # what this rail looks like at the far end of a cable, which is the system's
  # question and has a very different answer.
  discard d.addRole("power_rail", "out",
                    {"rail": Subject(kind: skNet, name: "vout")},
                    {"voltage": "3.3", "band": "0.02",
                     "targetZ": "0.3", "targetFrom": "1e5", "targetTo": "1e7",
                     "maxDerating": "0.6"})

  quit(verifyMain(d))
