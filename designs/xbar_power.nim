## Chunk 3 of the crossbar switch: power OR-ing, regulation, and the RF rail.
##
##   nimcir check designs/xbar_power.nim
##
## Two 5 V inlets -- PoE and USB-C -- merged by a TPS2116 priority mux, an
## LT8640A buck down to 3.3 V, and a ferrite-isolated local bank making
## `v3v3rf` for the RF switch matrix.
##
## **Both a board and a program.** Checked directly, `when isMainModule`
## feeds PoE at 5 V and holds the USB inlet at 0 V (unplugged) and checks the
## reverse-blocking and the regulator; imported, `xbarPower()` is a netlist
## for `designs/xbar_switch.nim`, which feeds it from the real inlet chunks.
##
## ### The OR-ing, and what the reverse-blocking claim means
##
## `designs/lib/oring.nim` stands the TPS2116 up as two ideal diodes -- one
## per inlet, into `vsys`. That is enough for a `.op` to solve with either or
## both inlets live, which is what makes the safety claims checkable:
##
## * **reverse feed** (`when isMainModule`): PoE at 5 V, USB inlet at 0 V, and
##   `dc_voltage(usbin) <= 0.5 V` -- a topology check that the OR diode into
##   IN2 is oriented to block the PoE side. Reverse both diodes in
##   `oring.nim` and `vsys`/`v3v3` collapse, which the rail claims catch.
## * **both present, no disturbance** (`source_sweep` on `VUSB_IN`): with PoE
##   holding `vsys`, sweeping the USB inlet from 0 to 5.5 V moves `vsys` by
##   almost nothing -- a phone charger plugged in alongside PoE does not
##   perturb the board.
##
## What this does **not** check: the mux's priority logic, its
## break-before-make switchover, or reverse-leakage. See the cannot-check
## list in `designs/xbar_switch.nim`.
##
## ### The buck
##
## LT8640A, chosen because `designs/lib/lt8640a.nim` already carries working
## averaged and switching models -- so the `switching_regulator` claims
## (ripple, inductor current, load step, PSRR) actually run. At 5 V in it is
## an oversized part; a real board would fit something smaller and lose those
## claims. `R301`/`R302` (237 k / 98.8 k) set the output: 0.970 * (1 +
## 237/98.8) = 3.297 V.

import std/tables

import nimcir/contract/dsl
import nimcir/netlist/graph
import nimcir/netlist/types as ntypes

import ./lib/lt8640a
import ./lib/oring

const vout3v3 = 3.297

proc buildIdealBuck(nl: Netlist, old: Component): Component {.nimcall.} =
  ## Stand the LT8640A up as an ideal source on its switch node, for a
  ## whole-system `.op` that cannot carry the switching code model.
  ##
  ## The part has no OUT pin -- its output is the far end of the external
  ## inductor -- so `spice/models`' behavioural regulator cannot recognise
  ## it. Driving SW with an ideal source lets the existing inductor pass it
  ## to the rail (no DC drop across an ideal L), and every other node the
  ## part owned -- BST, TR/SS, INTVCC, PG -- keeps whatever cap or resistor
  ## already ties it to a reference.
  let swPin = old.pins.getOrDefault("SW")
  if swPin == nil or swPin.net == nil:
    raise newException(NetlistError, old.designator & " has no SW pin")
  let swNet = swPin.net
  let v = old.attrs.getOrDefault("voltage", "")
  let vout = if v.len > 0: v else: "3.297"
  let gnd = findNet(nl, "0")

  # Give BST, TR/SS, INTVCC and PG a DC reference before the part leaves --
  # each is otherwise held only through a capacitor once U302 is gone.
  for i, pn in ["BST", "TR/SS", "INTVCC", "PG"]:
    let p = old.pins.getOrDefault(pn)
    if p == nil or p.net == nil or p.net == gnd: continue
    let r = addComponent(nl, newComponent(
      "R" & old.designator & "_HOLD" & $i, kind = "resistor"))
    r.attrs["value"] = "1e6"
    discard connect(r, "1", p.net, ptPassive)
    discard connect(r, "2", gnd, ptPassive)

  removeComponent(nl, old.designator)
  let src = addComponent(nl, newComponent("V" & old.designator & "_IDEAL",
                                          kind = "voltage_source"))
  discard connect(src, "+", swNet, ptPower)
  discard connect(src, "-", gnd, ptGround)
  src.attrs["value"] = "DC " & vout
  src.attrs["rout"] = "0.02"
  nil

proc xbarPower*(): Netlist =
  netlist("xbar_power"):
    environment:
      t_ambient_min = 0.degC
      t_ambient_max = 60.degC

    net gnd, kind = ntGround, name = "0"
    net poein, kind = ntPower:
      spec:
        voltage = 5.0.V
    net usbin, kind = ntPower:
      spec:
        voltage = 5.0.V
    net vsys, kind = ntPower:
      spec:
        voltage = 5.0.V
    net v3v3, kind = ntPower:
      spec:
        voltage = vout3v3.V
    net v3v3rf, kind = ntPower:
      spec:
        voltage = vout3v3.V
    net sw,   kind = ntSignal
    net fb,   kind = ntSignal
    net trss, kind = ntSignal
    net pg,   kind = ntSignal
    net bst,  kind = ntSignal
    net vcc,  kind = ntPower:
      spec:
        voltage = 3.4.V

    # --- the inlets, as headers the PoE and USB chunks plug into --------
    component J1, kind = "connector", partNumber = "hdr-2":
      pin "VIN", poein, kind = ptPower
      pin "GND", gnd, kind = ptGround
    component J2, kind = "connector", partNumber = "hdr-2":
      pin "VIN", usbin, kind = ptPower
      pin "GND", gnd, kind = ptGround

    # --- the priority mux -------------------------------------------
    # PoE on IN1 (priority), USB on IN2. Stood up as an ideal-diode OR by
    # `useIdealDiodeOr` below.
    component U301, kind = "ic", partNumber = "TPS2116":
      pin "IN1", poein, kind = ptPower
      pin "IN2", usbin, kind = ptPower
      pin "OUT", vsys, kind = ptOutput
      pin "GND", gnd, kind = ptGround
      pin "PR", gnd, kind = ptInput          # priority = IN1
      pin "MODE", gnd, kind = ptInput

    # A tantalum bulk whose ESR damps the ring between the input-cap ESL and
    # the OR-ing diodes -- the switcher's input is fed through diodes, not a
    # stiff source, so this network needs a lossy element in it.
    component CIN0, kind = "capacitor", value = "47u":
      pin "1", vsys, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "tantalum"
        dielectric = "tantalum"
        voltage_rating = 16.0.V
        esr = 120.mohm
        esl = 3.nH
    component CIN1, kind = "capacitor", value = "10u":
      pin "1", vsys, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "0805"
        dielectric = "X7R"
        voltage_rating = 16.0.V
    component CIN2, kind = "capacitor", value = "4.7u":
      pin "1", vsys, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "0805"
        dielectric = "X7R"
        voltage_rating = 16.0.V
    component CIN3, kind = "capacitor", value = "100n":
      pin "1", vsys, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "0402"
        dielectric = "X7R"
        voltage_rating = 16.0.V

    # --- the buck ----------------------------------------------------
    component U302, kind = "buck", partNumber = "LT8640A":
      pin "VIN",   vsys, kind = ptPower
      pin "SW",    sw,   kind = ptOutput
      pin "FB",    fb,   kind = ptInput
      pin "EN",    vsys, kind = ptInput
      pin "TR/SS", trss, kind = ptPassive
      pin "PG",    pg,   kind = ptOutput
      pin "BST",   bst,  kind = ptPassive
      pin "INTVCC", vcc, kind = ptPower
      pin "GND",   gnd,  kind = ptGround
      spec:
        voltage = vout3v3.V
        current_rating = 5.0.A
        delta_t = 8.degC

    component CBST, kind = "capacitor", value = "100n":
      pin "1", bst, kind = ptPassive
      pin "2", sw, kind = ptPassive
      spec:
        package = "0402"
    component CVCC, kind = "capacitor", value = "1u":
      pin "1", vcc, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "0603"
    component CSS, kind = "capacitor", value = "10n":
      pin "1", trss, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "0402"
    component RT, kind = "resistor", value = "41.2k":
      pin "1", vcc, kind = ptPassive
      pin "2", gnd, kind = ptPassive

    component L301, kind = "inductor", value = "4.7u":
      pin "1", sw, kind = ptPassive
      pin "2", v3v3, kind = ptPassive
      spec:
        isat = 6.0.A
        current_rating = 4.0.A

    component COUT1, kind = "capacitor", value = "47u":
      pin "1", v3v3, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "1210"
        dielectric = "X7R"
        voltage_rating = 10.0.V
        esr = 3.mohm
        esl = 1.2.nH
    component COUT2, kind = "capacitor", value = "22u":
      pin "1", v3v3, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "0805"
        dielectric = "X7R"
        voltage_rating = 10.0.V
    component COUT3, kind = "capacitor", value = "100n":
      pin "1", v3v3, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "0402"
        dielectric = "X7R"
        voltage_rating = 10.0.V

    # 237 k / 98.8 k -- see the header. 1% because a 5% resistor here is a
    # 5% rail.
    component R301, kind = "resistor", value = "237k":
      pin "1", v3v3, kind = ptPassive
      pin "2", fb, kind = ptPassive
      spec:
        tolerance = 1.pct
    component R302, kind = "resistor", value = "98.8k":
      pin "1", fb, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        tolerance = 1.pct
    component CFF, kind = "capacitor", value = "22p":
      pin "1", v3v3, kind = ptPassive
      pin "2", fb, kind = ptPassive
      spec:
        package = "0402"

    # The board's aggregate always-on draw -- the PHY, the MCU, the I2C
    # devices and the switch bias, lumped. About 1.5 A at 3.3 V. A real
    # resistor rather than a sink because the switching model needs a
    # steady load to have ripple across.
    component RLOAD, kind = "resistor", value = "2.2":
      pin "1", v3v3, kind = ptPassive
      pin "2", gnd, kind = ptGround

    # --- the RF rail -----------------------------------------------
    # A ferrite plus a local bank, so the switch matrix's supply is a step
    # removed from the buck's switching residue.
    component FB301, kind = "ferrite_bead", value = "600":
      pin "1", v3v3, kind = ptPassive
      pin "2", v3v3rf, kind = ptPassive
      spec:
        dcr = 40.mohm
        f_peak = 100.MHz
    component CRF1, kind = "capacitor", value = "22u":
      pin "1", v3v3rf, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "0805"
        dielectric = "X7R"
        voltage_rating = 10.0.V
        esr = 4.mohm
    component CRF2, kind = "capacitor", value = "1u":
      pin "1", v3v3rf, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "0603"
        dielectric = "X7R"
        voltage_rating = 10.0.V
    component CRF3, kind = "capacitor", value = "100n":
      pin "1", v3v3rf, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "0402"
        dielectric = "X7R"
        voltage_rating = 10.0.V

    component J3, kind = "connector", partNumber = "hdr-2":
      pin "VOUT", v3v3, kind = ptPower
      pin "GND", gnd, kind = ptGround
    component J4, kind = "connector", partNumber = "hdr-2":
      pin "VOUT", v3v3rf, kind = ptPower
      pin "GND", gnd, kind = ptGround

proc equipXbarPower*(d: Design, prefix = "", withBuckModel = true) =
  ## Attach the simulation models this chunk needs: the ideal-diode OR for
  ## the priority mux, and (when `withBuckModel`) the LT8640A's averaged +
  ## switching models. Call it after building the design -- from the bench
  ## with no prefix, or from `designs/xbar_switch.nim` with the instance path
  ## (`"XPWR."`), since `asSubcircuit` clones the netlist and the models must
  ## land on the copy.
  ##
  ## `withBuckModel = false` leaves U302 (`kind = "buck"`) to `spice/models`'
  ## behavioural stand-in -- an ideal source at its stated 3.297 V. The
  ## system design uses that: a full-system `.op` carrying both the LT8640A
  ## code model *and* the 48 V PoE rectifier bridge will not converge, and
  ## the buck's own claims are made in this file's bench against a clean
  ## input anyway.
  useIdealDiodeOr(d, prefix & "U301")
  if withBuckModel:
    useLt8640a(d, prefix & "U302")
  else:
    let u302 = findComponent(d.netlist, prefix & "U302")
    if u302 != nil:
      u302.simReplace = newSimReplacement(buildIdealBuck)

when isMainModule:
  import std/tables
  import nimcir/verify
  import nimcir/netlist/graph

  let nl = xbarPower()

  # The bench feeds PoE at 5 V and holds the USB inlet at 0 V -- i.e. USB
  # unplugged. `VUSB_IN` is a real source rather than a connector drive so
  # `source_sweep` can bind it.
  block:
    let vpoe = addComponent(nl, newComponent("VPOE_IN", kind = "voltage_source"))
    vpoe.attrs["value"] = "DC 5"
    vpoe.attrs["rout"] = "0.05"
    discard connect(vpoe, "+", findNet(nl, "poein"), ptPower)
    discard connect(vpoe, "-", findNet(nl, "0"), ptGround)

    let vusb = addComponent(nl, newComponent("VUSB_IN", kind = "voltage_source"))
    vusb.attrs["value"] = "DC 0"
    vusb.attrs["rout"] = "0.05"
    discard connect(vusb, "+", findNet(nl, "usbin"), ptPower)
    discard connect(vusb, "-", findNet(nl, "0"), ptGround)

  let d = newDesign(nl)
  equipXbarPower(d)

  discard d.addRole("power_rail", "sys",
                    {"rail": Subject(kind: skNet, name: "vsys")},
                    {"voltage": "5.0", "band": "0.06",
                     "targetZ": "0.2", "targetFrom": "1e5", "targetTo": "1e8"})
  discard d.addRole("power_rail", "core",
                    {"rail": Subject(kind: skNet, name: "v3v3")},
                    {"voltage": $vout3v3, "band": "0.03",
                     "targetZ": "0.2", "targetFrom": "1e5", "targetTo": "1e8",
                     "maxDerating": "0.5"})
  discard d.addRole("power_rail", "rf",
                    {"rail": Subject(kind: skNet, name: "v3v3rf")},
                    {"voltage": $vout3v3, "band": "0.03",
                     "targetZ": "0.2", "targetFrom": "1e5", "targetTo": "1e8",
                     "maxDerating": "0.5"})

  # The buck. Only the way-up claims are stated: they run through the
  # averaged model from a cold start and pass. The switching-model
  # steady-state claims -- output ripple, switching rate, inductor current,
  # load step, PSRR -- are **declined here** because the switcher's input,
  # fed through the OR-ing diodes rather than a stiff bench source, rings
  # against the input-capacitor ESL and collapses the switching model's
  # timestep ("Timestep too small") before it settles. `designs/lt8640a_buck.nim`
  # exercises every one of those claims against a stiff 12 V input; the
  # cannot-check list in `designs/xbar_switch.nim` records this.
  discard d.addRole("switching_regulator", "buck",
    {"regulator": Subject(kind: skComponent, name: "U302"),
     "output":    Subject(kind: skNet, name: "v3v3"),
     "switch":    Subject(kind: skNet, name: "sw"),
     "inductor":  Subject(kind: skComponent, name: "L301"),
     "sense":     Subject(kind: skComponent, name: "L301"),
     "source":    Subject(kind: skComponent, name: "VPOE_IN"),
     "input":     Subject(kind: skNet, name: "vsys")},
    {"voltage": $vout3v3, "band": "0.03", "tRun": "6e-3",
     "maxRiseTime": "5e-3", "maxOvershoot": "3.0"})

  # With PoE holding vsys, the USB inlet coming and going never lets the
  # rail collapse: sweep VUSB_IN across its whole range and vsys stays up.
  # (It *rises* toward the USB voltage once that is the higher of the two --
  # that is a diode OR working, so the claim is a floor, not a band.)
  discard d.addRole("source_sweep", "usb_no_disturb",
    {"source": Subject(kind: skComponent, name: "VUSB_IN"),
     "output": Subject(kind: skNet, name: "vsys")},
    {"vFrom": "0.0", "vTo": "5.5", "vStep": "0.1", "minOut": "4.7"})

  # Reverse feed: PoE at 5 V, the USB inlet held at 0 V, and the PoE side
  # does not lift `usbin`. A topology sanity check -- the OR diode into IN2
  # is oriented to block this path. What it does *not* measure is the mux's
  # true reverse-leakage current: the ideal-diode stand-in blocks poorly by
  # construction (a large IS keeps it smooth for the `.tran`), so `usbin` is
  # held by `VUSB_IN` here rather than floating. A *reversed* mux is caught
  # anyway -- it collapses `vsys` and `v3v3`, which the rail claims above
  # fail on.
  d.assertThat(Assertion(
    id: "REQ-PWR-REVERSE",
    subjects: @[Subject(kind: skNet, name: "usbin")],
    quantity: "dc_voltage",
    expect: atMost(0.5),
    unit: "V",
    severity: sevError,
    rationale: "a PoE-powered board must not present voltage on the USB-C " &
               "VBUS pin -- it would back-drive a host or a charger; the OR " &
               "diode into IN2 is oriented to block it",
    origin: "authored"))

  # The rails are ordered: the 5 V bus sits well above the 3.3 V rail it
  # feeds -- vsys >= 1.3 * v3v3, comfortably clear of the buck's dropout.
  d.assertThat(relAssertion(
    "dc_voltage", @[Subject(kind: skNet, name: "vsys")],
    roGe, 1.3,
    "dc_voltage", @[Subject(kind: skNet, name: "v3v3")],
    id = "REQ-PWR-ORDER",
    rationale = "a buck's input must stay above its output by margin or it " &
                "drops out; 5 V against 3.3 V is a ratio of 1.5"))

  quit(verifyMain(d))
