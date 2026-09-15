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
## * **the power-on state.** Every ADG904's `EN` and `A0`/`A1` line carries a
##   100 k pulldown (`controlPulldowns`), and the I2C expanders that drive
##   them come out of reset as high-impedance inputs -- so `EN` is low and
##   the address lines read `00`, and an ADG904 with `EN` low has *every* RF
##   port internally terminated in 50 ohm regardless of address. `safe_default`
##   on the six enables not driven for the routing check is the claim that
##   the pulldown is there and wins against the leakage on the line -- a
##   `.op` measurement, not a statement about firmware.
## * **routing and isolation.** `kind = "rf_switch"` gives each ADG904 a real
##   model (`spice/models` builds four voltage-controlled switches decoded
##   from A1/A0, gated by EN, every open throw terminated in 50 ohm). With
##   EN1 and EN5 driven high and A1/A0 left on their pulldowns (`00`), a 1 V
##   tone on RIN1 reaches m1 and ROUT1 through the routed path, while m2 and
##   ROUT2 -- selected by nobody -- sit at ground in their terminations.
##   Four `.op` claims.
## * **the RF rail's decoupling**, behind eight parts.
## * **derating** on the rail's capacitors.
## * **the static DC-path walk no longer stops at the switches.** Every
##   ADG904 gets `traverse: "RFC" <-> ["RF1","RF2","RF3","RF4"]` stamped by
##   `equipAdg904` (`designs/lib/adg904.nim`), so `checkDCPaths` can follow
##   `EN`/`A0`/`A1`'s own reachability question past the switch's other pins
##   instead of calling the whole 8-pin part
##   `ambiguous_dc_path` -- 24 findings on this board (three per switch)
##   before this was stated, all of them harmless (the pulldowns below
##   answer the question a different way) but noise nonetheless. The same
##   statement is what lets `constrained.pathsFrom` draw RFC-to-RF1..4 as a
##   real signal path on the schematic rather than a topological dead end.
##

## ### What is NOT checked -- see the cannot-check list in xbar_switch.nim
##
## Every RF property *vs. frequency*: insertion loss, isolation, return loss,
## VSWR, the two-stage cascade's cumulative loss, port match. The ADG904
## model carries `Ron`/`Roff` and the decode, but no transmission lines and
## no frequency-dependent isolation (`Roff` is flat). The DC-blocking
## capacitors and the SMA connectors are in the netlist for the BoM and the
## layout; the routing check reads a DC path, not an RF one.

import std/tables
import verax/contract/dsl

proc xbarRf*(): Netlist =
  result = netlist("xbar_rf"):
    net gnd, kind = ntGround, name = "0"
    net v3v3rf, kind = ntPower:
      spec:
        voltage = 3.297.V

    # midplane
    bus m, width = 4
    # SMA input / output nets
    bus rin, width = 4
    bus rout, width = 4
    # switch enables -- the lines the safety claim is about
    bus en, width = 8
    # switch address selects -- one two-dimensional bus, dimension 0 the
    # switch (0..7), dimension 1 the address bit (0 = A0, 1 = A1). Drawn
    # `a[7:0][1:0]` on the schematic.
    bus a, width = [8, 2]

    # --- power entry ----------------------------------------------------
    component J0, kind = "connector", partNumber = "hdr-2":
      pin "VRF", v3v3rf, kind = ptPower
      pin "GND", gnd, kind = ptGround

    # --- the eight SMA edges -------------------------------------------
    # Split into input/output loops (rather than one loop over both) so each
    # can carry its own `layout:` override: the inputs belong on the sheet's
    # left edge, the outputs on its right, matching the signal direction the
    # schematic already reads left to right.
    for (nm, rn) in [("JIN1", rin[0]), ("JIN2", rin[1]), ("JIN3", rin[2]),
                     ("JIN4", rin[3])]:
      component J, designator = nm, kind = "connector", partNumber = "SMA-50":
        layout:
          side = left
        pin "RF", rn, kind = ptPassive
        pin "GND", gnd, kind = ptGround
    for (nm, rn) in [("JOUT1", rout[0]), ("JOUT2", rout[1]),
                     ("JOUT3", rout[2]), ("JOUT4", rout[3])]:
      component J, designator = nm, kind = "connector", partNumber = "SMA-50":
        layout:
          side = right
        pin "RF", rn, kind = ptPassive
        pin "GND", gnd, kind = ptGround

    # --- the eight switches -----------------------------------------
    # ADG904 absorptive SP4T. `kind = "rf_switch"`, so `spice/models`'
    # `muxModel` stands each one up as four voltage-controlled switches
    # decoded from A1/A0 and gated by EN, with every open throw terminated in
    # 50 ohm -- the datasheet numbers land via `equipAdg904` in the bench and
    # the system. The address lines are real ports now: one two-dimensional
    # bus `a[switch, bit]`, drawn `a[7:0][1:0]`; firmware drives them through
    # the expanders in the real board.
    #
    # Input side: RFC on the SMA input, RF1..4 onto the midplane.
    #
    # `equipAdg904` (in `designs/lib/adg904.nim`, run in the bench and the
    # system below) is what actually says RFC reaches RF1..4, via
    # `addTraversalEdge` -- an 8-pin part is invisible to both the static DC
    # walk (`kinds.classifyConductivity` calls anything with more than two
    # connected pins ambiguous) and the schematic's own two-terminal-only
    # topology walk without it. Before this, `checkDCPaths` called every one
    # of these switches `ambiguous_dc_path` from each of A0/A1/EN (three
    # findings per switch, 24 total on this board) -- not because those
    # control pins are themselves unreachable (`controlPulldowns` in the
    # bench below ties each one to ground directly), but because *reaching*
    # them required asking the switch's other pins something nothing had
    # answered. It is a schematic-side fix as well as an electrical one:
    # `constrained.pathsFrom`'s semantic walk needs the same statement to
    # follow RFC through to RF1..4 rather than treating the switch as a
    # topological dead end. It lives with the rest of the ADG904's datasheet
    # numbers rather than at each instantiation site because it is the same
    # statement for all eight switches and every caller already runs every
    # designator through `equipAdg904` for `ron`/`roff`/`select_pins`.
    for (nm, rfc, en, sel) in [("XSW1", rin[0], en[0], 0), ("XSW2", rin[1], en[1], 1),
                               ("XSW3", rin[2], en[2], 2), ("XSW4", rin[3], en[3], 3)]:
      component U, designator = nm, kind = "rf_switch", partNumber = "ADG904":
        pin "RFC", rfc, kind = ptPassive
        pin "RF1", m[0], kind = ptPassive
        pin "RF2", m[1], kind = ptPassive
        pin "RF3", m[2], kind = ptPassive
        pin "RF4", m[3], kind = ptPassive
        pin "A0", a[sel, 0], kind = ptInput
        pin "A1", a[sel, 1], kind = ptInput
        pin "EN", en, kind = ptInput
        pin "VDD", v3v3rf, kind = ptPower, zin = "3300"
        pin "GND", gnd, kind = ptGround

    # Output side: RF1..4 from the midplane, RFC on the SMA output.
    for (nm, rfc, en, sel) in [("XSW5", rout[0], en[4], 4), ("XSW6", rout[1], en[5], 5),
                               ("XSW7", rout[2], en[6], 6), ("XSW8", rout[3], en[7], 7)]:
      component U, designator = nm, kind = "rf_switch", partNumber = "ADG904":
        pin "RFC", rfc, kind = ptPassive
        pin "RF1", m[0], kind = ptPassive
        pin "RF2", m[1], kind = ptPassive
        pin "RF3", m[2], kind = ptPassive
        pin "RF4", m[3], kind = ptPassive
        pin "A0", a[sel, 0], kind = ptInput
        pin "A1", a[sel, 1], kind = ptInput
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

  # Enable and address are exposed as ports directly rather than through a
  # header connector: nothing on this board plugs into them, they arrive
  # over the control-board wiring `designs/xbar_switch.nim` provides, so
  # there is no physical part standing between the ADG904 select pins and
  # the sheet boundary for a connector to model. `addPorts` takes a whole
  # `Bus` and ports every member in one call, named `<label>_<i>` (or
  # `<label>_<i0>_<i1>` for `a`'s two dimensions) -- the same expansion
  # `subckt`'s own port list does for a bus identifier. The `en`/`a` `let`s
  # the block above bound are scoped to that block, so `findBus` recovers
  # each one from the net attrs it left behind.
  addPorts(result, "en", findBus(result, "en"))
  addPorts(result, "a", findBus(result, "a"))

proc rfEnableNets*(): seq[string] =
  ## The eight ADG904 enable nets, by name -- for `controlPulldowns` and the
  ## `safe_default` claims, in both this file's bench and the system.
  @["en_0", "en_1", "en_2", "en_3", "en_4", "en_5", "en_6", "en_7"]

proc rfAddressNets*(): seq[string] =
  ## The sixteen ADG904 address-select nets (A0 then A1, one pair per
  ## switch), by name -- for `controlPulldowns` in both this file's bench
  ## and the system. Needed for simulation, not just safety: `muxModel`'s
  ## decoder reads each select net without loading it, so an address net
  ## with nothing else on it is a floating node and the `.op` solve is
  ## singular. Row-major over `bus a, width = [8, 2]`: `a_<switch>_<bit>`.
  @["a_0_0", "a_0_1", "a_1_0", "a_1_1", "a_2_0", "a_2_1", "a_3_0", "a_3_1",
    "a_4_0", "a_4_1", "a_5_0", "a_5_1", "a_6_0", "a_6_1", "a_7_0", "a_7_1"]

when isMainModule:
  import verax/verify
  import verax/netlist/graph
  import verax/spice/boundary
  import ./lib/xbar_parts
  import ./lib/adg904

  let d = newDesign(xbarRf())

  # Every EN line pulled to ground, as the board is.
  controlPulldowns(d.netlist, rfEnableNets())

  # Every address line pulled to ground too: the expanders that drive A0/A1
  # come out of reset the same way EN does, and unlike EN an undriven select
  # net has nothing else touching it at all -- `muxModel`'s decoder reads it
  # without loading it, so with no pulldown the `.op` solve is singular.
  # Pulled low, every switch defaults to A1,A0 = 00 -> RF1, same as the old
  # hard-wire to ground.
  controlPulldowns(d.netlist, rfAddressNets())

  # The eight ADG904s, with their datasheet numbers.
  equipAdg904(d.netlist,
    ["XSW1", "XSW2", "XSW3", "XSW4", "XSW5", "XSW6", "XSW7", "XSW8"])

  # The RF rail on the bench.
  driveConnector(findComponent(d.netlist, "J0"),
                 {"VRF": driveSource(3.297.V, rout = 30.mohm)})


  discard d.addRole("power_rail", "rfrail",
                    {"rail": Subject(kind: skNet, name: "v3v3rf")},
                    {"voltage": "3.297", "band": "0.03",
                     "targetZ": "0.3", "targetFrom": "1e5", "targetTo": "1e8",
                     "maxDerating": "0.5"})

  # The power-on safe default, on the six enables still held only by their
  # pulldowns. en1 and en5 are driven for the routing check above.
  for en in ["en_1", "en_2", "en_3", "en_5", "en_6", "en_7"]:
    discard d.addRole("safe_default", en,
                      {"control": Subject(kind: skNet, name: en)},
                      {"rail": "3.297", "maxFraction": "0.1"})


  quit(verifyMain(d))
