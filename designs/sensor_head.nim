## The sensor head: a small board at the end of a cable.
##
##   verax check designs/sensor_head.nim
##
## **Both a board and a program**, like `designs/carrier.nim`: checked
## directly, `when isMainModule` below plugs a supply into its connector and
## verifies it; imported, `sensorHead()` is just a netlist and
## `designs/system_sensor_rig.nim` supplies the carrier board instead.
##
## Deliberately sparse, because that is the design under question. It has one
## 100 n bypass and one 1 u local bulk, on the assumption that the carrier's
## 22 u is "the" bulk capacitance -- which is true at DC and stops being true
## somewhere above a few hundred kilohertz, once the cable's inductance is
## worth more than the capacitor behind it.
##
## The load is a resistor rather than a sensor part with pin stand-ins,
## because the current it draws is one of the numbers the system claims and a
## stood-in impedance would make that a claim about the stand-in.

import verax/contract/dsl

proc sensorHead*(): Netlist =
  netlist("sensor_head"):
    net gnd, kind = ntGround, name = "0"
    net vin, kind = ntPower

    component J3, kind = "connector", partNumber = "JST-PH 4-way":
      pin "VIN", vin, kind = ptPower
      pin "GND", gnd, kind = ptGround

    component C5, kind = "capacitor", value = "1u":
      pin "1", vin, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "0603"
        dielectric = "X7R"
        voltage_rating = 10.0.V
    component C6, kind = "capacitor", value = "100n":
      pin "1", vin, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "0402"
        dielectric = "X7R"
        voltage_rating = 10.0.V

    # Local bulk, and it is here for damping as much as for charge.
    #
    # Without it this board passes its own check comfortably and is wrong in
    # the product, which is the reason both checks exist:
    #
    #     standalone, on a bench supply      10.00 mohm   passes by 30x
    #     in designs/system_sensor_rig.nim    8.71 ohm    fails by 10x
    #
    # The cable's 300 nH rings against the 886 nF of ceramic above it. The
    # anti-resonance lands near 1 MHz and peaks at L/(R*C) -- 300n/(0.04 *
    # 886n) is about 8.5 ohm, damped by nothing but the cable's own 40 mohm,
    # and the simulation agrees. A bench supply sitting next to the board has
    # no such inductance, so no board-level check can see it.
    #
    # A tantalum rather than another ceramic, and that is the point: its ESR
    # is what damps the peak. A third X7R would add charge and leave the
    # ringing exactly where it was.
    component C7, kind = "capacitor", value = "22u":
      pin "1", vin, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "tantalum"
        dielectric = "tantalum"
        voltage_rating = 10.0.V
        esr = 200.mohm
        esl = 3.nH

    # 33 ohm at 3.3 V is 100 mA, a plausible always-on sensor plus its MCU.
    component R1, kind = "resistor", value = "33":
      pin "1", vin, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        power_rating = 250.mW

when isMainModule:
  import verax/verify
  import verax/spice/boundary

  let d = newDesign(sensorHead())

  # On the bench this board is fed from a supply sitting right next to it.
  # That is the honest description of a bench test and it is also why a
  # standalone number here is optimistic: 10 mohm of source impedance is a
  # lab supply's short leads, not 300 mm of cable, and the difference is the
  # entire subject of `designs/system_sensor_rig.nim`.
  driveConnector(findComponent(d.netlist, "J3"),
                 {"VIN": driveSource(3.3.V, rout = 10.mohm)})

  discard d.addRole("power_rail", "supply",
                    {"rail": Subject(kind: skNet, name: "vin")},
                    {"voltage": "3.3", "band": "0.02",
                     "targetZ": "0.3", "targetFrom": "1e5", "targetTo": "1e7",
                     "maxDerating": "0.6"})

  quit(verifyMain(d))
