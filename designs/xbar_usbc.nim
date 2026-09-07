## Chunk 2 of the crossbar switch: the USB-C inlet (power only).
##
##   verax check designs/xbar_usbc.nim
##
## A power-only USB-C sink: VBUS in, the two 5.1 k CC pulldowns that
## advertise a sink to a source, a filtered CC-sense tap the MCU reads to
## learn the advertised current, VBUS bulk and a series ferrite to the board's
## `usb5v` node.
##
## **Both a board and a program.** Checked directly, `when isMainModule`
## plugs a 5 V source into VBUS and a 10 k Rp (a 3 A advertisement) into each
## CC line; imported, `xbarUsbC()` is a netlist for `designs/xbar_switch.nim`.
##
## ### What is and is not checked
##
## Checked: the CC divider. With the source's 10 k Rp against the board's
## 5.1 k Rd, each CC line sits at 5 * 5.1/15.1 = 1.69 V, which is the
## "3 A @ 5 V" advertisement the specification defines -- and both CC lines
## carry an Rd, so the board works in either plug orientation.
##
## Not checked: any PD negotiation (this board never requests more than 5 V),
## BC1.2, the SuperSpeed lanes (unpopulated), or VBUS sourcing. This is a
## sink that takes 5 V and nothing else.

import verax/contract/dsl

proc xbarUsbC*(): Netlist =
  netlist("xbar_usbc"):
    net gnd, kind = ntGround, name = "0"
    net usbvbus, kind = ntPower:
      spec:
        voltage = 5.0.V
    net cc1, kind = ntSignal
    net cc2, kind = ntSignal
    net ccsns, kind = ntSignal
    net usb5v, kind = ntPower:
      spec:
        voltage = 5.0.V

    # --- the receptacle ------------------------------------------------
    component J1, kind = "connector", partNumber = "USB-C 2.0 receptacle":
      pin "VBUS", usbvbus, kind = ptPower
      pin "GND",  gnd,     kind = ptGround
      pin "CC1",  cc1,     kind = ptPassive
      pin "CC2",  cc2,     kind = ptPassive

    # --- sink advertisement -----------------------------------------
    # 5.1 k on *both* CC lines. One Rd would make the board care which way
    # the cable is plugged in; two is what makes it orientation-independent.
    component RD1, kind = "resistor", value = "5.1k":
      pin "1", cc1, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        tolerance = 1.pct
    component RD2, kind = "resistor", value = "5.1k":
      pin "1", cc2, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        tolerance = 1.pct

    # The MCU reads this to learn what the source is advertising. A plain RC
    # anti-alias tap off CC1; CC voltage never exceeds ~3.3 V for a sink so
    # no divider is needed.
    component RCC, kind = "resistor", value = "10k":
      pin "1", cc1,   kind = ptPassive
      pin "2", ccsns, kind = ptPassive
    component CCC, kind = "capacitor", value = "1n":
      pin "1", ccsns, kind = ptPassive
      pin "2", gnd,   kind = ptPassive
      spec:
        package = "0402"
        dielectric = "C0G"
        voltage_rating = 16.0.V

    # --- VBUS conditioning ----------------------------------------
    component CB1, kind = "capacitor", value = "10u":
      pin "1", usbvbus, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "0805"
        dielectric = "X7R"
        voltage_rating = 16.0.V
    component CB2, kind = "capacitor", value = "100n":
      pin "1", usbvbus, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "0402"
        dielectric = "X7R"
        voltage_rating = 16.0.V

    # A ferrite between the connector and the board rail, to keep the
    # switcher's conducted noise off the cable.
    component FB1, kind = "ferrite_bead", value = "600":
      pin "1", usbvbus, kind = ptPassive
      pin "2", usb5v, kind = ptPassive
      spec:
        dcr = 50.mohm
        f_peak = 100.MHz

    component CO1, kind = "capacitor", value = "10u":
      pin "1", usb5v, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "0805"
        dielectric = "X7R"
        voltage_rating = 16.0.V
    component CO2, kind = "capacitor", value = "100n":
      pin "1", usb5v, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "0402"
        dielectric = "X7R"
        voltage_rating = 16.0.V

    component J2, kind = "connector", partNumber = "hdr-2":
      pin "VOUT", usb5v, kind = ptPower
      pin "GND", gnd, kind = ptGround

when isMainModule:
  import std/strutils
  import verax/verify
  import verax/spice/boundary

  let d = newDesign(xbarUsbC())

  # A source advertising 3 A: 5 V through a 10 k Rp on each CC line, and
  # 5 V on VBUS. The board's own 5.1 k Rd then puts each CC line at 1.69 V.
  driveConnector(findComponent(d.netlist, "J1"),
                 {"VBUS": driveSource(5.0.V, rout = 50.mohm),
                  "CC1": driveSource(5.0.V, rout = 10.kohm),
                  "CC2": driveSource(5.0.V, rout = 10.kohm)})
  driveConnector(findComponent(d.netlist, "J2"),
                 {"VOUT": driveSink(600.mA)})

  discard d.addRole("power_rail", "usb_rail",
                    {"rail": Subject(kind: skNet, name: "usb5v")},
                    {"voltage": "5.0", "band": "0.05",
                     "targetZ": "0.25", "targetFrom": "1e5", "targetTo": "1e8",
                     "maxDerating": "0.6"})

  for line in ["cc1", "cc2"]:
    d.assertThat(Assertion(
      id: "REQ-USBC-ADV-" & line.toUpperAscii,
      subjects: @[Subject(kind: skNet, name: line)],
      quantity: "dc_voltage",
      expect: nominal(1.69, fracTol = 0.10),
      unit: "V",
      severity: sevError,
      rationale: "the source's Rp against this board's 5.1 k Rd sets the CC " &
                 "voltage, and 1.68 V nominal is the '3 A at 5 V' band -- a " &
                 "missing or wrong Rd moves it out of every advertisement band",
      origin: "authored"))

  quit(verifyMain(d))
