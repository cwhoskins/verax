## Chunk 1 of the crossbar switch: the PoE inlet.
##
##   nimcir check designs/xbar_poe.nim
##
## An 802.3af powered-device front end: an RJ45's PoE conductors into a
## rectifier bridge, a TVS, the 25.5 k detection signature, a class-2
## classification resistor, and an isolated flyback to 5 V.
##
## **Both a board and a program.** Checked directly, `when isMainModule`
## drives the PoE feed at 48 V and a resistive load on the 5 V output;
## imported, `xbarPoe()` is a netlist and `designs/xbar_switch.nim` supplies
## the rest of the system.
##
## ### What is real here and what is a stand-in
##
## Real, and simulated: the bridge (four `SS1M`), the common-mode choke `LCM`
## (a real `K`-coupled part), the `SMAJ58A` TVS, the input bulk, and the
## detection network `RDET`/`RSNS`. `VPSE` is the power-sourcing equipment --
## a floating 37..57 V source between the two PoE conductors, which is what a
## PSE is.
##
## The flyback transformer `T1` is a real `kind = "transformer"` part now,
## so `spice/models` expands it to two windings and a SPICE `K` card and the
## isolation *barrier* is a checked claim -- `dc_path_exists(vpoe, poe5v)`,
## a graph walk, reads 0 because the two windings share no node.
##
## A stand-in: `U1`, the Si3402-B. `equipXbarPoe` strips the flyback loop
## (`buildSi3402`, the `buildIdealBuck` pattern) and stands the output up as
## an ideal isolated 5 V source: no dropout, no current limit, no soft
## start, and the transformer -- present in the netlist -- is inert because a
## switching primary has no model. The output rectifier and the opto/TL431
## feedback are on the BoM and absent from the electrical model. See the
## cannot-check list in `designs/xbar_switch.nim`.
##
## ### The detection signature
##
## `source_sweep` binds `VPSE` and sweeps it across the 2.8..10 V detection
## window while every other claim runs a `.op` at the stated 48 V. `RDET` is
## 24.9 k (inside the 23.75..26.25 k the standard allows) and `RSNS` is a
## 100 ohm current-sense in series with it, so `V(detsns)/V(feed)` is
## 100/25000 and a wrong signature resistor moves it. What this does **not**
## check is the classification current or the PD handshake: both live inside
## `U1`, which is an ideal source here.
##
## One trap worth stating: `U1`'s detection-sense pin, being unmodelled, would
## otherwise get a ~1 Mohm stand-in to ground in parallel with `RDET`. `zin`
## is stated large on that pin to keep the signature divider clean.

import std/tables

import nimcir/contract/dsl
import nimcir/netlist/graph
import nimcir/netlist/types as ntypes

import ./lib/xbar_parts

proc buildSi3402(nl: Netlist, old: Component): Component {.nimcall.} =
  ## Stand the Si3402-B up as an ideal isolated 5 V source.
  ##
  ## A switching flyback has no model here, so this strips the loop: an ideal
  ## 5 V source on `poe5v`, referenced to system ground -- which is where the
  ## downstream load returns and, past the barrier, what the secondary ground
  ## physically *is*. `gndiso` and the primary switch node then get only a
  ## high-impedance DC reference (1 Mohm), because with no primary drive
  ## nothing on the isolated side carries current: a low-impedance bond there
  ## would be a real short across a barrier the design does not have, and the
  ## solver does not need one once the source and the load share a ground.
  ## The transformer stays in the netlist -- expanded to two windings and a
  ## `K` card -- but inert. The barrier itself is checked statically by
  ## `dc_path_exists`, on the un-materialised netlist. `buildIdealBuck`'s
  ## pattern (`designs/xbar_power.nim`).
  let outNet = old.pins.getOrDefault("OUT").net
  let gnd = findNet(nl, "0")
  let gndiso = findNet(nl, "gndiso")
  let swp = findNet(nl, "swp")
  if outNet == nil or gnd == nil or gndiso == nil:
    raise newException(NetlistError, "buildSi3402: missing OUT/0/gndiso")
  removeComponent(nl, old.designator)

  let src = addComponent(nl, newComponent("V" & old.designator & "_OUT",
                                          kind = "voltage_source"))
  discard connect(src, "+", outNet, ptPower)
  discard connect(src, "-", gnd, ptGround)
  src.attrs["value"] = "DC 5"

  for (sfx, n) in [("REF", gndiso), ("SW", swp)]:
    if n == nil: continue
    let r = addComponent(nl, newComponent("R" & old.designator & "_" & sfx,
                                          kind = "resistor"))
    discard connect(r, "1", n, ptPassive)
    discard connect(r, "2", gnd, ptPassive)
    r.attrs["value"] = "1e6"
  nil

proc equipXbarPoe*(d: Design, prefix = "") =
  ## Attach the Si3402-B stand-in. Call it after building the design -- from
  ## the bench with no prefix, or from `designs/xbar_switch.nim` with the
  ## instance path, since `asSubcircuit` clones the netlist.
  let u1 = findComponent(d.netlist, prefix & "U1")
  if u1 != nil:
    u1.simReplace = newSimReplacement(buildSi3402)

proc xbarPoe*(): Netlist =
  netlist("xbar_poe"):
    environment:
      t_ambient_min = 0.degC
      t_ambient_max = 60.degC

    net gnd, kind = ntGround, name = "0"        # the PD's local 0 V (bridge -)
    net feedp, kind = ntSignal                  # PoE conductor 1
    net feedn, kind = ntSignal                  # PoE conductor 2
    net vpoe, kind = ntPower:                   # rectified PoE rail
      spec:
        voltage = 48.0.V
    net detsns, kind = ntSignal                 # detection-resistor sense tap
    net clsns, kind = ntSignal                  # classification pin
    net feedp2, kind = ntSignal                 # PoE conductor 1, past the CM choke
    net feedn2, kind = ntSignal                 # PoE conductor 2, past the CM choke
    net swp, kind = ntSignal                    # flyback primary switch node
    net secr, kind = ntSignal                   # flyback secondary, pre-rectifier
    net gndiso, kind = ntSignal                 # isolated secondary return
    net poe5v, kind = ntPower:                  # isolated 5 V output
      spec:
        voltage = 5.0.V

    model dBridge, dBridgeCard
    model tvsSmaj58a, tvsSmaj58aCard

    # --- the RJ45's PoE conductors, and the PSE behind them --------------
    # A MagJack, declared as one. Its magnetics carry the MDI pairs to the
    # PHY and are not on this chunk -- what is here is the PoE tap. `VPSE` is
    # a floating source: a PSE references neither conductor to anything, and
    # the PD makes its own 0 V at the bridge.
    component J1, kind = "connector", partNumber = "RJ45-MagJack":
      pin "POEP", feedp, kind = ptPassive
      pin "POEN", feedn, kind = ptPassive
    component VPSE, kind = "voltage_source", value = "DC 48":
      pin "+", feedp, kind = ptPassive
      pin "-", feedn, kind = ptPassive
      spec:
        voltage = 48.0.V
        rout = 20.0.ohm                         # PSE port + cabling

    # --- the common-mode choke --------------------------------------
    # A real coupled-inductor part on the PoE pair, between the MagJack and
    # the bridge -- the MagJack's data-pair choke has a sibling on the PoE
    # tap. 1:1, so at DC it is its winding resistance and nothing else; it is
    # here because it is a `K`-coupled part the library can now carry, and
    # its winding IR drop is on the 37 V budget.
    component LCM, kind = "common_mode_choke", partNumber = "744232900":
      pin "P1", feedp, kind = ptPassive
      pin "P2", feedp2, kind = ptPassive
      pin "S1", feedn, kind = ptPassive
      pin "S2", feedn2, kind = ptPassive
      spec:
        lpri = 1.mH
        k_coupling = 0.9
        dcr = 90.mohm

    # --- the rectifier bridge -----------------------------------------
    # Polarity-agnostic: a PSE may drive either conductor positive, and the
    # bridge makes `vpoe` positive whichever way round it is.
    component D1, kind = "diode", partNumber = dBridge, value = dBridge:
      pin "A", feedp2, kind = ptPassive
      pin "K", vpoe, kind = ptPassive
    component D2, kind = "diode", partNumber = dBridge, value = dBridge:
      pin "A", feedn2, kind = ptPassive
      pin "K", vpoe, kind = ptPassive
    component D3, kind = "diode", partNumber = dBridge, value = dBridge:
      pin "A", gnd, kind = ptPassive
      pin "K", feedp2, kind = ptPassive
    component D4, kind = "diode", partNumber = dBridge, value = dBridge:
      pin "A", gnd, kind = ptPassive
      pin "K", feedn2, kind = ptPassive

    # --- protection and bulk ----------------------------------------
    component DZ1, kind = "diode", partNumber = tvsSmaj58a, value = tvsSmaj58a:
      pin "A", gnd, kind = ptPassive
      pin "K", vpoe, kind = ptPassive
    component CIN1, kind = "capacitor", value = "100u":
      pin "1", vpoe, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "electrolytic"
        voltage_rating = 100.0.V
        esr = 300.mohm
    component CIN2, kind = "capacitor", value = "100n":
      pin "1", vpoe, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "0603"
        dielectric = "X7R"
        voltage_rating = 100.0.V

    # --- the detection signature -----------------------------------
    # 24.9 k 1% plus a 100 ohm sense. Both load-bearing: the sense resistor
    # is what gives the sweep a node to read, and 24.9 k is chosen to sit in
    # the middle of the allowed 23.75..26.25 k.
    component RDET, kind = "resistor", value = "24.9k":
      pin "1", vpoe, kind = ptPassive
      pin "2", detsns, kind = ptPassive
      spec:
        tolerance = 1.pct
    component RSNS, kind = "resistor", value = "100":
      pin "1", detsns, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        tolerance = 1.pct

    # --- classification -------------------------------------------
    # Class 2 (7 W). The resistor is real; the current through it is set by
    # U1's classification pin, which is not modelled, so this resistor is
    # here for the BoM and sees almost nothing in simulation.
    component RCLASS, kind = "resistor", value = "243":
      pin "1", clsns, kind = ptPassive
      pin "2", gnd, kind = ptPassive

    # --- the isolation barrier: the flyback transformer -------------
    # A real coupled-inductor part now (`kind = "transformer"` ->
    # `spice/models` two windings and a SPICE `K` card), so the barrier is a
    # graph property something can check -- `dc_path_exists(vpoe, poe5v)` in
    # the bench below -- rather than a sentence in this header. What is still
    # *not* simulated is the flyback *doing its job*: a switching primary has
    # no model here, so `equipXbarPoe` strips the loop and stands the output
    # up as an ideal isolated 5 V source, exactly as `buildIdealBuck` does
    # for the LT8640A in `designs/xbar_power.nim`.
    component T1, kind = "transformer", partNumber = "750317659":
      pin "P1", vpoe, kind = ptPassive         # primary, dotted end
      pin "P2", swp, kind = ptPassive          # to the Si3402-B switch
      pin "S1", secr, kind = ptPassive         # secondary, dotted end
      pin "S2", gndiso, kind = ptPassive
      spec:
        lpri = 470.uH
        turns = 0.22                           # ~48 V in -> ~5 V out at ~35% duty
        k_coupling = 0.985
        dcr = 0.35.ohm

    # Secondary rectifier: conducts on the primary's off-time.
    component DSEC, kind = "diode", partNumber = "PMEG6010":
      pin "A", secr, kind = ptPassive
      pin "K", poe5v, kind = ptPassive

    # The Y-capacitor and its bleed resistor bridge the barrier -- the only
    # things that do. The bleed gives the isolated section a DC reference
    # and discharges the Y-cap; neither is a power path, which is why
    # `dc_path_exists(vpoe, poe5v)` still reads 0.
    component CY1, kind = "capacitor", value = "2.2n":
      pin "1", gnd, kind = ptPassive
      pin "2", gndiso, kind = ptPassive
      spec:
        package = "Y2"
        dielectric = "C0G"
        voltage_rating = 250.0.V
    component RY1, kind = "resistor", value = "1meg":
      pin "1", gnd, kind = ptPassive
      pin "2", gndiso, kind = ptPassive

    # --- the PD interface / isolated converter ---------------------
    # Si3402-B: PD interface, hot-swap FET and flyback controller in one.
    # Stood up as an ideal 5 V source by `equipXbarPoe` -- see the header.
    # `zin` is stated large on the sense pins so the per-pin stand-in does
    # not shunt the detection divider or the class resistor.
    component U1, kind = "dcdc", partNumber = "Si3402-B":
      pin "VPP", vpoe, kind = ptPower
      pin "VNN", gnd, kind = ptGround
      pin "SW", swp, kind = ptOutput
      pin "DET", detsns, kind = ptInput, zin = "1e9"
      pin "CLASS", clsns, kind = ptInput, zin = "1e9"
      pin "OUT", poe5v, kind = ptOutput
      spec:
        voltage = 5.0.V
        delta_t = 12.degC

    # --- the 5 V output ---------------------------------------------
    # A tantalum bulk plus ceramics: the tantalum's ESR damps the
    # anti-resonance between the bulk and the ceramic bank, the same reason
    # `designs/sensor_head.nim` fits one.
    component COUT1, kind = "capacitor", value = "47u":
      pin "1", poe5v, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "tantalum"
        dielectric = "tantalum"
        voltage_rating = 16.0.V
        esr = 150.mohm
        esl = 3.nH
    component COUT2, kind = "capacitor", value = "10u":
      pin "1", poe5v, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "0805"
        dielectric = "X7R"
        voltage_rating = 16.0.V
    component COUT3, kind = "capacitor", value = "1u":
      pin "1", poe5v, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "0603"
        dielectric = "X7R"
        voltage_rating = 16.0.V
    component COUT4, kind = "capacitor", value = "100n":
      pin "1", poe5v, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "0402"
        dielectric = "X7R"
        voltage_rating = 16.0.V

    # The output edge: a header the power chunk plugs into. Made a connector
    # so `asSubcircuit` promotes `poe5v` to a port for the system.
    component J2, kind = "connector", partNumber = "hdr-2":
      pin "VOUT", poe5v, kind = ptPower
      pin "GND", gnd, kind = ptGround

when isMainModule:
  import nimcir/verify
  import nimcir/spice/boundary

  let d = newDesign(xbarPoe())
  equipXbarPoe(d)

  # On the bench the 5 V output feeds the rest of the board -- about 3 W, so
  # 600 mA. A sink rather than a resistor because everything downstream
  # regulates its own supply.
  driveConnector(findComponent(d.netlist, "J2"),
                 {"VOUT": driveSink(600.mA)})

  discard d.addRole("power_rail", "poe_rail",
                    {"rail": Subject(kind: skNet, name: "vpoe")},
                    {"voltage": "48.0", "band": "0.21", "maxDerating": "0.85"})

  discard d.addRole("power_rail", "out5v",
                    {"rail": Subject(kind: skNet, name: "poe5v")},
                    {"voltage": "5.0", "band": "0.05",
                     "targetZ": "0.2", "targetFrom": "1e5", "targetTo": "1e8",
                     "maxDerating": "0.6"})

  # The detection signature, swept. `dc_transfer` is V(detsns)/V(feed) taken
  # as a slope across the window, which is what a PSE measures.
  discard d.addRole("source_sweep", "detect",
                    {"source": Subject(kind: skComponent, name: "VPSE"),
                     "output": Subject(kind: skNet, name: "detsns")},
                    {"vFrom": "2.8", "vTo": "10.0", "vStep": "0.1",
                     "nominal": "0.02", "ratio": "0.004", "band": "0.15"})

  # The isolation barrier: no DC-conductive path from the 48 V PoE rail to
  # the 5 V output. The flyback transformer is the only thing between them
  # and its two windings share no node -- a graph walk, no simulator.
  d.assertThat(Assertion(
    id: "REQ-POE-ISOLATION",
    subjects: @[Subject(kind: skNet, name: "vpoe"),
               Subject(kind: skNet, name: "poe5v")],
    quantity: "dc_path_exists",
    expect: nominal(0.0, absTol = 0.5),
    unit: "",
    severity: sevError,
    rationale: "an 802.3af PD isolates the PSE-side rail from its output; " &
               "the flyback transformer T1 is that barrier, and a DC path " &
               "across it would defeat the isolation the Y-cap and creepage " &
               "are designed around",
    origin: "authored"))

  # The rectified rail stays inside the PD's valid window at 48 V in.
  d.assertThat(Assertion(
    id: "REQ-POE-WINDOW",
    subjects: @[Subject(kind: skNet, name: "vpoe")],
    quantity: "dc_voltage",
    expect: atLeast(37.0),
    unit: "V",
    severity: sevError,
    rationale: "two bridge drops below the PSE's 48 V still has to clear the " &
               "37 V a PD is required to operate down to",
    origin: "authored"))

  quit(verifyMain(d))
