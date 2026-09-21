## USB-C sink sheet: VBUS in, the two 5.1 k CC pulldowns that identify the
## board as a Type-C sink, a filtered CC-sense tap the MCU reads to learn
## the current a source is advertising, and D+/D- routed straight through to
## the MCU sheet.
##
## Ports: `VBUS`, `GND`, `CC1`, `CC2`, `CCSNS`, `DP`, `DM`.
##
## **What "current-setting" means for a sink, and what it does not.** A
## Type-C *source* advertises how much current it will supply by the value
## of the pull-up (`Rp`) it puts on CC -- 56 k for the 900 mA default, 22 k
## for 1.5 A, 10 k for 3 A. A *sink* does not choose that value: `Rd` is
## fixed at 5.1 k by the specification regardless of how much current the
## board actually wants, which is exactly `designs/xbar_usbc.nim`'s own
## worked example. So `usbCSink` itself takes no current parameter -- there
## is no resistor on this board whose value current would change. What *is*
## parameterized here is the other half of the question a sink genuinely
## answers: `advertisedCurrent` states what the design expects a source to
## offer, `rpFor` is the `Rp` a bench (or a real charger) would use to make
## that offer, and `ccSenseTarget` is the CC voltage that offer produces
## against this board's fixed 5.1 k -- the number a caller (e.g.
## `designs/datalogger/datalogger.nim`) drives its bench with and claims
## `ccsns` against, so a wrong assumption about what the wall supplies fails
## loudly rather than silently.
##
## **VBUS bulk scales with the current parameter.** That is a real board
## decision this sheet can make: more expected current wants more bulk
## capacitance to hold VBUS through the connector/cable's own inductance on
## a load transient. 1 uF/A is a reasonable rule of thumb, not a datasheet
## figure, and is stated as one.

import verax/contract/dsl
import verax/netlist/formats/spice as spiceFormat

type
  UsbCCurrent* = enum
    usbDefault    ## unadvertised / BC1.2-style default, <= 900 mA typical
    usb1500mA
    usb3000mA

proc rpFor*(c: UsbCCurrent): Ohms =
  ## The source-side CC pull-up that makes this advertisement, per the
  ## USB Type-C specification's Table 4-14 (Default/1.5A/3A source current
  ## advertisement via Rp).
  case c
  of usbDefault: 56.kohm
  of usb1500mA:  22.kohm
  of usb3000mA:  10.kohm

proc advertisedAmps*(c: UsbCCurrent): Amps =
  case c
  of usbDefault: 0.9.A
  of usb1500mA:  1.5.A
  of usb3000mA:  3.0.A

proc ccSenseTarget*(c: UsbCCurrent, vbus = 5.0.V, rd = 5.1.kohm): Volts =
  ## The steady-state CC voltage this board's fixed `Rd` divider produces
  ## against a source offering `c`: `vbus * Rd / (Rd + Rp)`.
  let rdF = float(rd)
  let rpF = float(rpFor(c))
  Volts(float(vbus) * rdF / (rdF + rpF))

proc usbCSink*(advertisedCurrent = usb3000mA): Netlist =
  let bulk = max(1.0e-6, float(advertisedAmps(advertisedCurrent)) * 1.0e-6)
    ## ~1 uF per amp of expected draw, floored at 1 uF so the default
    ## advertisement still gets a real bulk cap.

  result = subckt("USBC_SINK", [VBUS, GND, CC1, CC2, CCSNS, DP, DM]):
    net GND,  kind = ntGround, name = "0"
    net VBUS, kind = ntPower
    net CC1,  kind = ntSignal
    net CC2,  kind = ntSignal
    net CCSNS, kind = ntSignal
    net DP,   kind = ntSignal
    net DM,   kind = ntSignal

    component J1, kind = "connector", partNumber = "USB-C 2.0 receptacle":
      pin "VBUS", VBUS, kind = ptPower
      pin "GND",  GND,  kind = ptGround
      pin "CC1",  CC1,  kind = ptPassive
      pin "CC2",  CC2,  kind = ptPassive
      pin "DP",   DP,   kind = ptInOut
      pin "DM",   DM,   kind = ptInOut

    # 5.1 k on *both* CC lines -- orientation independence, the reason a
    # sink needs two rather than one.
    component RD1, kind = "resistor", value = "5.1k":
      pin "1", CC1, kind = ptPassive
      pin "2", GND, kind = ptPassive
      spec:
        tolerance = 1.pct
    component RD2, kind = "resistor", value = "5.1k":
      pin "1", CC2, kind = ptPassive
      pin "2", GND, kind = ptPassive
      spec:
        tolerance = 1.pct

    # The MCU's sense tap. A plain RC anti-alias off CC1 -- CC never exceeds
    # ~3.3 V for a sink, so no divider is needed to keep it inside the ADC's
    # range.
    component RCC, kind = "resistor", value = "10k":
      pin "1", CC1,   kind = ptPassive
      pin "2", CCSNS, kind = ptPassive
    component CCC, kind = "capacitor", value = "1n":
      pin "1", CCSNS, kind = ptPassive
      pin "2", GND,   kind = ptPassive
      spec:
        package = "0402"
        dielectric = "C0G"
        voltage_rating = 16.0.V

    component CB1, kind = "capacitor", value = spiceValue(bulk):
      pin "1", VBUS, kind = ptPassive
      pin "2", GND,  kind = ptPassive
      spec:
        package = "0805"
        dielectric = "X7R"
        voltage_rating = 16.0.V
    component CB2, kind = "capacitor", value = "100n":
      pin "1", VBUS, kind = ptPassive
      pin "2", GND,  kind = ptPassive
      spec:
        package = "0402"
        dielectric = "X7R"
        voltage_rating = 16.0.V
