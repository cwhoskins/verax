## Chunk 5 of the crossbar switch: the MCU, the Ethernet PHY, and the I2C bus.
##
##   nimcir check designs/xbar_control.nim
##
## An STM32H563 (Ethernet MAC on-die) driving a DP83825I RMII PHY, with a
## 25 MHz crystal, an AT24MAC402 EEPROM carrying the board's EUI-48, and two
## PCA9555 I2C expanders that fan out to the eight ADG904 enable lines.
##
## **Both a board and a program.** Checked directly, `when isMainModule`
## feeds `v3v3` and states the bus and reset claims; imported, `xbarControl()`
## is a netlist for `designs/xbar_switch.nim`.
##
## ### What is checked
##
## * **the 3.3 V rail** at the MCU, and its decoupling.
## * **the I2C bus** via the `i2c` role: each line has a pull-up, the RC
##   corner clears the 100 kHz clock by ten times, the pull-up sink current
##   is inside the 3 mA a target must pull down, and there is one controller.
##   1.2 k pull-ups and 100 kHz rather than 400: five devices plus the
##   pull-ups is ~90 pF by `static.rc_corner`'s per-pin rule, and 400 kHz
##   would want a pull-up that sinks past the 3 mA a target must pull down --
##   the same arithmetic `designs/i2c_eeprom.nim` records.
## * **the reset line** sits high with nothing driving it -- the pull-up
##   holds the MCU out of reset.
## * **the expander enable outputs** default low (`safe_default`), the same
##   claim `designs/xbar_rf.nim` makes at the other end of these nets.
##
## ### What is NOT checked -- see the cannot-check list in xbar_switch.nim
##
## The Ethernet data path end to end: the MDI pairs, the MagJack's magnetics,
## RMII timing, link training, and anything the firmware does. There is no
## crystal model, no timing quantity and no digital-logic quantity. The
## **MAC readback conversation** -- the MCU reading the EUI-48 out of the
## AT24MAC402's 0xB0 page and checking it -- is not modelled either: it would
## need `designs/lib/m24c64.nim` reworked for one-byte addressing and a new
## controller script, which the plan for this design chose to list here
## rather than build.

import nimcir/contract/dsl

proc xbarControl*(): Netlist =
  netlist("xbar_control"):
    net gnd, kind = ntGround, name = "0"
    net v3v3, kind = ntPower:
      spec:
        voltage = 3.297.V
    net sda, kind = ntSignal
    net scl, kind = ntSignal
    net nrst, kind = ntSignal
    net xin, kind = ntSignal
    net xout, kind = ntSignal
    # RMII between MCU and PHY -- carried as ports, not simulated
    net rmii_refclk, kind = ntSignal
    net rmii_crsdv, kind = ntSignal
    net rmii_rxd0, kind = ntSignal
    net rmii_rxd1, kind = ntSignal
    net rmii_txen, kind = ntSignal
    net rmii_txd0, kind = ntSignal
    net rmii_txd1, kind = ntSignal
    net mdio, kind = ntSignal
    net mdc, kind = ntSignal
    # MDI pairs to the MagJack -- external, carried as ports
    net mdi_tp, kind = ntSignal
    net mdi_tn, kind = ntSignal
    net mdi_rp, kind = ntSignal
    net mdi_rn, kind = ntSignal
    # the eight switch enables
    net en1, kind = ntSignal
    net en2, kind = ntSignal
    net en3, kind = ntSignal
    net en4, kind = ntSignal
    net en5, kind = ntSignal
    net en6, kind = ntSignal
    net en7, kind = ntSignal
    net en8, kind = ntSignal

    # --- power / control headers -------------------------------------
    component J0, kind = "connector", partNumber = "hdr-2":
      pin "V33", v3v3, kind = ptPower
      pin "GND", gnd, kind = ptGround
    component JI2C, kind = "connector", partNumber = "hdr-2":
      pin "SDA", sda, kind = ptInOut
      pin "SCL", scl, kind = ptInOut
    component JCTL, kind = "connector", partNumber = "hdr-8":
      pin "EN1", en1, kind = ptPassive
      pin "EN2", en2, kind = ptPassive
      pin "EN3", en3, kind = ptPassive
      pin "EN4", en4, kind = ptPassive
      pin "EN5", en5, kind = ptPassive
      pin "EN6", en6, kind = ptPassive
      pin "EN7", en7, kind = ptPassive
      pin "EN8", en8, kind = ptPassive
    component JMDI, kind = "connector", partNumber = "hdr-4":
      pin "TP", mdi_tp, kind = ptPassive
      pin "TN", mdi_tn, kind = ptPassive
      pin "RP", mdi_rp, kind = ptPassive
      pin "RN", mdi_rn, kind = ptPassive

    # --- the MCU -----------------------------------------------------
    component U401, kind = "mcu", partNumber = "STM32H563ZI":
      pin "VDD",  v3v3, kind = ptPower, zin = "40"     # ~80 mA at 3.3 V
      pin "VSS",  gnd,  kind = ptGround
      pin "NRST", nrst, kind = ptInput
      pin "OSC_IN",  xin,  kind = ptInput
      pin "OSC_OUT", xout, kind = ptOutput
      pin "SDA", sda, kind = ptInOut
      pin "SCL", scl, kind = ptInOut
      pin "RMII_REF_CLK", rmii_refclk, kind = ptInput
      pin "RMII_CRS_DV",  rmii_crsdv,  kind = ptInput
      pin "RMII_RXD0", rmii_rxd0, kind = ptInput
      pin "RMII_RXD1", rmii_rxd1, kind = ptInput
      pin "RMII_TX_EN", rmii_txen, kind = ptOutput
      pin "RMII_TXD0",  rmii_txd0, kind = ptOutput
      pin "RMII_TXD1",  rmii_txd1, kind = ptOutput
      pin "MDIO", mdio, kind = ptInOut
      pin "MDC",  mdc,  kind = ptOutput

    # 25 MHz crystal for the MCU / RMII reference.
    component Y1, kind = "crystal", partNumber = "25MHz-8pF":
      pin "1", xin,  kind = ptPassive
      pin "2", xout, kind = ptPassive
    component CX1, kind = "capacitor", value = "8p":
      pin "1", xin, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "0402"
        dielectric = "C0G"
        voltage_rating = 16.0.V
    component CX2, kind = "capacitor", value = "8p":
      pin "1", xout, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "0402"
        dielectric = "C0G"
        voltage_rating = 16.0.V

    # Reset pull-up: holds the MCU running when nothing drives NRST.
    component RRST, kind = "resistor", value = "10k":
      pin "1", v3v3, kind = ptPassive
      pin "2", nrst, kind = ptPassive
    component CRST, kind = "capacitor", value = "100n":
      pin "1", nrst, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "0402"
        dielectric = "X7R"
        voltage_rating = 16.0.V

    # --- the PHY ---------------------------------------------------
    component U402, kind = "ic", partNumber = "DP83825I":
      pin "VDD",  v3v3, kind = ptPower, zin = "66"     # ~50 mA at 3.3 V
      pin "GND",  gnd,  kind = ptGround
      pin "RMII_REF_CLK", rmii_refclk, kind = ptOutput
      pin "CRS_DV", rmii_crsdv, kind = ptOutput
      pin "RXD0", rmii_rxd0, kind = ptOutput
      pin "RXD1", rmii_rxd1, kind = ptOutput
      pin "TX_EN", rmii_txen, kind = ptInput
      pin "TXD0",  rmii_txd0, kind = ptInput
      pin "TXD1",  rmii_txd1, kind = ptInput
      pin "MDIO", mdio, kind = ptInOut
      pin "MDC",  mdc,  kind = ptInput
      pin "TDP", mdi_tp, kind = ptOutput
      pin "TDN", mdi_tn, kind = ptOutput
      pin "RDP", mdi_rp, kind = ptInput
      pin "RDN", mdi_rn, kind = ptInput
      pin "RESET_N", nrst, kind = ptInput

    # --- the EEPROM ----------------------------------------------
    component U403, kind = "eeprom", partNumber = "AT24MAC402":
      pin "VCC", v3v3, kind = ptPower
      pin "VSS", gnd,  kind = ptGround
      pin "SDA", sda, kind = ptInOut
      pin "SCL", scl, kind = ptInOut
      pin "A0", gnd, kind = ptInput
      pin "A1", gnd, kind = ptInput
      pin "A2", gnd, kind = ptInput
      pin "WP", gnd, kind = ptInput

    # --- the two expanders ------------------------------------
    component U404, kind = "ic", partNumber = "PCA9555":
      pin "VDD", v3v3, kind = ptPower
      pin "VSS", gnd,  kind = ptGround
      pin "SDA", sda, kind = ptInOut
      pin "SCL", scl, kind = ptInOut
      pin "A0", gnd, kind = ptInput
      pin "A1", gnd, kind = ptInput
      pin "A2", gnd, kind = ptInput
      pin "IO0_0", en1, kind = ptOutput
      pin "IO0_1", en2, kind = ptOutput
      pin "IO0_2", en3, kind = ptOutput
      pin "IO0_3", en4, kind = ptOutput
    component U405, kind = "ic", partNumber = "PCA9555":
      pin "VDD", v3v3, kind = ptPower
      pin "VSS", gnd,  kind = ptGround
      pin "SDA", sda, kind = ptInOut
      pin "SCL", scl, kind = ptInOut
      pin "A0", v3v3, kind = ptInput      # address strap 0x21
      pin "A1", gnd, kind = ptInput
      pin "A2", gnd, kind = ptInput
      pin "IO0_0", en5, kind = ptOutput
      pin "IO0_1", en6, kind = ptOutput
      pin "IO0_2", en7, kind = ptOutput
      pin "IO0_3", en8, kind = ptOutput

    # --- the bus pull-ups ------------------------------------
    # 1.5 k: see the header. Both values load-bearing, neither a default.
    component RP1, kind = "resistor", value = "1.2k":
      pin "1", v3v3, kind = ptPassive
      pin "2", sda, kind = ptPassive
      spec:
        tolerance = 1.pct
    component RP2, kind = "resistor", value = "1.2k":
      pin "1", v3v3, kind = ptPassive
      pin "2", scl, kind = ptPassive
      spec:
        tolerance = 1.pct
    component CBUS1, kind = "capacitor", value = "22p":
      pin "1", sda, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "0402"
        dielectric = "C0G"
        voltage_rating = 16.0.V
    component CBUS2, kind = "capacitor", value = "22p":
      pin "1", scl, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "0402"
        dielectric = "C0G"
        voltage_rating = 16.0.V

    # --- decoupling -----------------------------------------
    for (cn, _) in [("CD1", 1), ("CD2", 2), ("CD3", 3), ("CD4", 4),
                    ("CD5", 5), ("CD6", 6)]:
      component C, designator = cn, kind = "capacitor", value = "100n":
        pin "1", v3v3, kind = ptPassive
        pin "2", gnd, kind = ptPassive
        spec:
          package = "0402"
          dielectric = "X7R"
          voltage_rating = 16.0.V
    component CBULKC, kind = "capacitor", value = "10u":
      pin "1", v3v3, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "0805"
        dielectric = "X7R"
        voltage_rating = 16.0.V
    component CBULKC2, kind = "capacitor", value = "1u":
      pin "1", v3v3, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "0603"
        dielectric = "X7R"
        voltage_rating = 16.0.V

when isMainModule:
  import nimcir/verify
  import nimcir/spice/boundary
  import ./lib/xbar_parts

  let d = newDesign(xbarControl())

  # Pulldowns on the expander outputs, at the driver end. `designs/xbar_rf.nim`
  # has its own at the switch end; in the system the two parallel.
  controlPulldowns(d.netlist,
    ["en1", "en2", "en3", "en4", "en5", "en6", "en7", "en8"])

  driveConnector(findComponent(d.netlist, "J0"),
                 {"V33": driveSource(3.297.V, rout = 40.mohm)})

  discard d.addRole("power_rail", "core",
                    {"rail": Subject(kind: skNet, name: "v3v3")},
                    {"voltage": "3.297", "band": "0.03",
                     "targetZ": "0.25", "targetFrom": "1e5", "targetTo": "1e8",
                     "maxDerating": "0.5"})

  discard d.addRole("i2c", "mgmt",
                    {"sda": Subject(kind: skNet, name: "sda"),
                     "scl": Subject(kind: skNet, name: "scl"),
                     "pullupRail": Subject(kind: skNet, name: "v3v3"),
                     "controller": Subject(kind: skComponent, name: "U401")},
                    {"frequency": "100e3"})

  for i, en in ["en1", "en2", "en3", "en4", "en5", "en6", "en7", "en8"]:
    discard d.addRole("safe_default", "en" & $(i + 1),
                      {"control": Subject(kind: skNet, name: en)},
                      {"rail": "3.297", "maxFraction": "0.1"})

  d.assertThat(Assertion(
    id: "REQ-CTL-RESET",
    subjects: @[Subject(kind: skNet, name: "nrst")],
    quantity: "dc_voltage",
    expect: atLeast(3.0),
    unit: "V",
    severity: sevError,
    rationale: "the 10 k pull-up must hold NRST high with nothing driving " &
               "it, or the board sits in reset after power-up",
    origin: "authored"))

  quit(verifyMain(d))
