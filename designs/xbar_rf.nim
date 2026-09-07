## Chunk 4 of the crossbar switch: the 4x4 RF matrix.
##
##   verax check designs/xbar_rf.nim
##
## Eight ADG904 absorptive SP4T switches in a two-stage arrangement: four
## input-side switches fan the four SMA inputs onto a four-wire midplane, four
## output-side switches pick from the midplane onto the four SMA outputs. Any
## input reaches any output by setting one switch at each end to the same
## midplane rail.
##
## **Both a board and a program.** Checked directly, `when isMainModule`
## feeds `v3v3rf` and terminates the RF ports; imported, `xbarRf()` is a
## netlist for `designs/xbar_switch.nim`.
##
## ### What is checked here
##
## * **the power-on state.** Every ADG904's `EN` line carries a 100 k
##   pulldown (`controlPulldowns`), and the I2C expanders that drive `EN`
##   come out of reset as high-impedance inputs -- so `EN` is low, and an
##   ADG904 with `EN` low has *every* RF port internally terminated in
##   50 ohm. `safe_default` on the six enables not driven for the routing
##   check is the claim that the pulldown is there and wins against the
##   leakage on the line -- a `.op` measurement, not a statement about
##   firmware.
## * **routing and isolation.** `kind = "rf_switch"` gives each ADG904 a real
##   model (`spice/models` builds four voltage-controlled switches decoded
##   from A1/A0, gated by EN, every open throw terminated in 50 ohm). With
##   EN1 and EN5 driven and A1/A0 grounded, a 1 V tone on RIN1 reaches m1 and
##   ROUT1 through the routed path, while m2 and ROUT2 -- selected by nobody
##   -- sit at ground in their terminations. Four `.op` claims.
## * **the RF rail's decoupling**, behind eight parts.
## * **derating** on the rail's capacitors.
##
## ### What is NOT checked -- see the cannot-check list in xbar_switch.nim
##
## Every RF property *vs. frequency*: insertion loss, isolation, return loss,
## VSWR, the two-stage cascade's cumulative loss, port match. The ADG904
## model carries `Ron`/`Roff` and the decode, but no transmission lines and
## no frequency-dependent isolation (`Roff` is flat). The DC-blocking
## capacitors and the SMA connectors are in the netlist for the BoM and the
## layout; the routing check reads a DC path, not an RF one.

import verax/contract/dsl

proc xbarRf*(): Netlist =
  netlist("xbar_rf"):
    net gnd, kind = ntGround, name = "0"
    net v3v3rf, kind = ntPower:
      spec:
        voltage = 3.297.V

    # midplane
    net m1, kind = ntSignal
    net m2, kind = ntSignal
    net m3, kind = ntSignal
    net m4, kind = ntSignal
    # SMA input / output nets
    net rin1, kind = ntSignal
    net rin2, kind = ntSignal
    net rin3, kind = ntSignal
    net rin4, kind = ntSignal
    net rout1, kind = ntSignal
    net rout2, kind = ntSignal
    net rout3, kind = ntSignal
    net rout4, kind = ntSignal
    # switch enables -- the lines the safety claim is about
    net en1, kind = ntSignal
    net en2, kind = ntSignal
    net en3, kind = ntSignal
    net en4, kind = ntSignal
    net en5, kind = ntSignal
    net en6, kind = ntSignal
    net en7, kind = ntSignal
    net en8, kind = ntSignal

    # --- power entry and the control header -----------------------------
    component J0, kind = "connector", partNumber = "hdr-2":
      pin "VRF", v3v3rf, kind = ptPower
      pin "GND", gnd, kind = ptGround
    component JCTL, kind = "connector", partNumber = "hdr-8":
      pin "EN1", en1, kind = ptInput
      pin "EN2", en2, kind = ptInput
      pin "EN3", en3, kind = ptInput
      pin "EN4", en4, kind = ptInput
      pin "EN5", en5, kind = ptInput
      pin "EN6", en6, kind = ptInput
      pin "EN7", en7, kind = ptInput
      pin "EN8", en8, kind = ptInput

    # --- the eight SMA edges -------------------------------------------
    for (nm, rn) in [("JIN1", rin1), ("JIN2", rin2), ("JIN3", rin3),
                     ("JIN4", rin4), ("JOUT1", rout1), ("JOUT2", rout2),
                     ("JOUT3", rout3), ("JOUT4", rout4)]:
      component J, designator = nm, kind = "connector", partNumber = "SMA-50":
        pin "RF", rn, kind = ptPassive
        pin "GND", gnd, kind = ptGround

    # --- DC blocks on every RF port ----------------------------------
    # C0G so the corner does not walk under bias. One at each SMA and one on
    # each midplane rail -- 12 in all, built in a loop.
    for (cn, a) in [("CBIN1", rin1), ("CBIN2", rin2), ("CBIN3", rin3),
                    ("CBIN4", rin4), ("CBOUT1", rout1), ("CBOUT2", rout2),
                    ("CBOUT3", rout3), ("CBOUT4", rout4),
                    ("CBM1", m1), ("CBM2", m2), ("CBM3", m3), ("CBM4", m4)]:
      component C, designator = cn, kind = "capacitor", value = "100n":
        pin "1", a, kind = ptPassive
        pin "2", gnd, kind = ptPassive
        spec:
          package = "0402"
          dielectric = "C0G"
          voltage_rating = 16.0.V

    # --- the eight switches -----------------------------------------
    # ADG904 absorptive SP4T. `kind = "rf_switch"`, so `spice/models`'
    # `muxModel` stands each one up as four voltage-controlled switches
    # decoded from A1/A0 and gated by EN, with every open throw terminated in
    # 50 ohm -- the datasheet numbers land via `equipAdg904` in the bench and
    # the system. A0/A1 to ground selects RF1 (`00`); firmware drives them
    # through the expanders in the real board.
    #
    # Input side: RFC on the SMA input, RF1..4 onto the midplane.
    for (nm, rfc, en) in [("XSW1", rin1, en1), ("XSW2", rin2, en2),
                          ("XSW3", rin3, en3), ("XSW4", rin4, en4)]:
      component U, designator = nm, kind = "rf_switch", partNumber = "ADG904":
        pin "RFC", rfc, kind = ptPassive
        pin "RF1", m1, kind = ptPassive
        pin "RF2", m2, kind = ptPassive
        pin "RF3", m3, kind = ptPassive
        pin "RF4", m4, kind = ptPassive
        pin "A0", gnd, kind = ptInput
        pin "A1", gnd, kind = ptInput
        pin "EN", en, kind = ptInput
        pin "VDD", v3v3rf, kind = ptPower, zin = "3300"
        pin "GND", gnd, kind = ptGround

    # Output side: RF1..4 from the midplane, RFC on the SMA output.
    for (nm, rfc, en) in [("XSW5", rout1, en5), ("XSW6", rout2, en6),
                          ("XSW7", rout3, en7), ("XSW8", rout4, en8)]:
      component U, designator = nm, kind = "rf_switch", partNumber = "ADG904":
        pin "RFC", rfc, kind = ptPassive
        pin "RF1", m1, kind = ptPassive
        pin "RF2", m2, kind = ptPassive
        pin "RF3", m3, kind = ptPassive
        pin "RF4", m4, kind = ptPassive
        pin "A0", gnd, kind = ptInput
        pin "A1", gnd, kind = ptInput
        pin "EN", en, kind = ptInput
        pin "VDD", v3v3rf, kind = ptPower, zin = "3300"
        pin "GND", gnd, kind = ptGround

    # --- per-switch bypass and the rail bank -----------------------
    for (cn, _) in [("CBY1", 1), ("CBY2", 2), ("CBY3", 3), ("CBY4", 4),
                    ("CBY5", 5), ("CBY6", 6), ("CBY7", 7), ("CBY8", 8)]:
      component C, designator = cn, kind = "capacitor", value = "100n":
        pin "1", v3v3rf, kind = ptPassive
        pin "2", gnd, kind = ptPassive
        spec:
          package = "0402"
          dielectric = "X7R"
          voltage_rating = 10.0.V
    component CRFBULK, kind = "capacitor", value = "10u":
      pin "1", v3v3rf, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "0805"
        dielectric = "X7R"
        voltage_rating = 10.0.V
    component CRFBULK2, kind = "capacitor", value = "1u":
      pin "1", v3v3rf, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "0603"
        dielectric = "X7R"
        voltage_rating = 10.0.V

proc rfEnableNets*(): seq[string] =
  ## The eight ADG904 enable nets, by name -- for `controlPulldowns` and the
  ## `safe_default` claims, in both this file's bench and the system.
  @["en1", "en2", "en3", "en4", "en5", "en6", "en7", "en8"]

when isMainModule:
  import std/tables
  import verax/verify
  import verax/netlist/graph
  import verax/spice/boundary
  import ./lib/xbar_parts
  import ./lib/adg904

  let d = newDesign(xbarRf())

  # Every EN line pulled to ground, as the board is.
  controlPulldowns(d.netlist, rfEnableNets())

  # The eight ADG904s, with their datasheet numbers.
  equipAdg904(d.netlist,
    ["XSW1", "XSW2", "XSW3", "XSW4", "XSW5", "XSW6", "XSW7", "XSW8"])

  # The RF rail on the bench.
  driveConnector(findComponent(d.netlist, "J0"),
                 {"VRF": driveSource(3.297.V, rout = 30.mohm)})

  # A 50 ohm cable-and-load on every SMA port, the same terminations
  # `designs/xbar_switch.nim` puts on the system's ports.
  for (rn, netv) in [("RT_IN1", "rin1"), ("RT_IN2", "rin2"), ("RT_IN3", "rin3"),
                     ("RT_IN4", "rin4"), ("RT_OUT1", "rout1"),
                     ("RT_OUT2", "rout2"), ("RT_OUT3", "rout3"),
                     ("RT_OUT4", "rout4")]:
    let r = addComponent(d.netlist, Component(designator: rn, kind: "resistor"))
    r.attrs["value"] = "50"
    discard connect(r, "1", findNet(d.netlist, netv), ptPassive)
    discard connect(r, "2", findNet(d.netlist, "0"), ptPassive)

  # Route input 1 to output 1: EN1 and EN5 driven high, A1/A0 grounded, so
  # RIN1 -> m1 -> ROUT1. A 1 V DC tone on RIN1 stands in for an RF carrier
  # (this bench has no transmission lines -- it measures the routed path's
  # DC continuity, not its S-parameters). The other six enables stay on
  # their pulldowns.
  for (nm, netn) in [("VEN1", "en1"), ("VEN5", "en5")]:
    let v = addComponent(d.netlist, Component(designator: nm,
                                              kind: "voltage_source"))
    v.attrs["value"] = "DC 3.297"
    discard connect(v, "+", findNet(d.netlist, netn), ptPower)
    discard connect(v, "-", findNet(d.netlist, "0"), ptGround)
  block:
    let v = addComponent(d.netlist, Component(designator: "VRIN1",
                                              kind: "voltage_source"))
    v.attrs["value"] = "DC 1"
    v.attrs["rout"] = "0.05"
    discard connect(v, "+", findNet(d.netlist, "rin1"), ptPassive)
    discard connect(v, "-", findNet(d.netlist, "0"), ptGround)

  discard d.addRole("power_rail", "rfrail",
                    {"rail": Subject(kind: skNet, name: "v3v3rf")},
                    {"voltage": "3.297", "band": "0.03",
                     "targetZ": "0.3", "targetFrom": "1e5", "targetTo": "1e8",
                     "maxDerating": "0.5"})

  # The power-on safe default, on the six enables still held only by their
  # pulldowns. en1 and en5 are driven for the routing check above.
  for en in ["en2", "en3", "en4", "en6", "en7", "en8"]:
    discard d.addRole("safe_default", en,
                      {"control": Subject(kind: skNet, name: en)},
                      {"rail": "3.297", "maxFraction": "0.1"})

  # Routing: the selected path carries the tone.
  d.assertThat(Assertion(
    id: "REQ-RF-ROUTE-MID",
    subjects: @[Subject(kind: skNet, name: "m1")],
    quantity: "dc_voltage", expect: atLeast(0.3), unit: "V",
    severity: sevError,
    rationale: "with EN1 high and A1/A0 = 00 the ADG904 connects RFC to RF1, " &
               "so the 1 V tone on RIN1 reaches the m1 midplane rail through " &
               "two 4 ohm on-resistances and the 50 ohm loads -- a wrong " &
               "on-resistance or a stuck decoder drops it",
    origin: "authored"))
  d.assertThat(Assertion(
    id: "REQ-RF-ROUTE-OUT",
    subjects: @[Subject(kind: skNet, name: "rout1")],
    quantity: "dc_voltage", expect: atLeast(0.3), unit: "V",
    severity: sevError,
    rationale: "and the output switch XSW5 carries it on from m1 to ROUT1 -- " &
               "the end-to-end path through both switch stages",
    origin: "authored"))

  # Isolation: an unselected path stays terminated near ground.
  d.assertThat(Assertion(
    id: "REQ-RF-ISO-MID",
    subjects: @[Subject(kind: skNet, name: "m2")],
    quantity: "dc_voltage", expect: atMost(0.05), unit: "V",
    severity: sevError,
    rationale: "the m2 midplane rail is selected by nobody, and every ADG904 " &
               "throw onto it is open and internally terminated in 50 ohm, so " &
               "it sits at ground -- this is the absorptive behaviour the " &
               "part is chosen for",
    origin: "authored"))
  d.assertThat(Assertion(
    id: "REQ-RF-ISO-OUT",
    subjects: @[Subject(kind: skNet, name: "rout2")],
    quantity: "dc_voltage", expect: atMost(0.05), unit: "V",
    severity: sevError,
    rationale: "output 2 is not routed to anything, so its SMA port sees only " &
               "its own 50 ohm load and the ADG904's terminated RFC",
    origin: "authored"))

  quit(verifyMain(d))
