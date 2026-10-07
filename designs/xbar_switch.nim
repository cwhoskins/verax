## The Ethernet-controlled 4x4 RF crossbar switch: the whole system.
##
##   verax check designs/xbar_switch.nim
##
## Five boards wired together: the PoE inlet, the USB-C inlet, the power
## OR-ing and regulation, the RF switch matrix, and the MCU/PHY/I2C control.
## Each is checked on its own too (`designs/xbar_poe.nim` and friends); this
## file supplies the real other end to every chunk and makes the claims that
## no chunk can make alone.
##
## Both inlets are energised at once -- a PSE on the RJ45 *and* a 5 V source
## on the USB-C receptacle -- because "safe and operational with both plugged
## in" is the requirement, and the interesting question is whether the board
## is still fine in that state.
##
## ### What this file checks
##
## * **the 3.3 V rail holds** with both inlets live and the whole board
##   (PHY, MCU, expanders, switch bias) loading it.
## * **the RF rail's decoupling**, measured at the switch matrix -- a
##   different rail from the buck output once the ferrite and the board are
##   between them, the same way `designs/system_sensor_rig.nim` measures its
##   load's rail rather than its regulator's.
## * **the power-on terminated state**: all eight ADG904 `EN` lines sit low,
##   held by the pulldowns at both ends of the nets, with the expanders as
##   the real (high-impedance-at-boot) parts rather than a bench assumption.
## * **rail ordering**: the 5 V bus stays above the 3.3 V rail it feeds.
##
## ### What this design cannot check
##
## The library has no model for several things this board is built from, so
## the claims above are the checkable core and the rest is stated here.
##
## **Design limits -- true of this board, given the library:**
##
## * *Every RF property vs. frequency* -- insertion loss, isolation, return
##   loss, VSWR, crosstalk, the two-stage cascade's cumulative loss, port
##   match. There are still no transmission lines, no characteristic
##   impedance and no S-parameters here. The ADG904 *does* have a model now
##   (`kind = "rf_switch"` -> `spice/models` builds four voltage-controlled
##   switches decoded from A1/A0 and gated by EN, each open throw terminated
##   in 50 ohm), so a routed path and an off path's isolation are ordinary
##   `.op` claims -- `designs/xbar_rf.nim` makes them. What that model does
##   not carry is anything frequency-dependent: `Roff` is flat, so
##   off-isolation does not fall with frequency, and there is no delay line.
## * *The flyback doing its job.* The transformer T1 is a real `K`-coupled
##   part now, so the isolation *barrier* is a checked claim
##   (`dc_path_exists(vpoe, poe5v) == 0`, a graph walk) rather than a
##   sentence. But a switching primary has no model, so `equipXbarPoe`
##   strips the loop and stands the output up as an ideal isolated 5 V
##   source -- no dropout, current limit or soft start, and the leakage
##   spike and snubber dissipation are outside it.
## * *The Ethernet magnetics vs. frequency.* The PoE common-mode choke is
##   modelled (`kind = "common_mode_choke"`, 1:1, so at DC it is its winding
##   IR drop); the MagJack's MDI transformers are still declared-not-drawn,
##   because nothing on this board drives an MDI pair, so there is no
##   measurement for them to be part of.
## * *802.3af classification and the PD handshake.* The class current source
##   lives inside the PD controller, which is an ideal source here. Only the
##   detection *signature* is reachable, because it is a resistance
##   (`designs/xbar_poe.nim` sweeps it).
## * *The power mux's real behaviour.* The reverse-blocking claim in
##   `designs/xbar_power.nim` measures the ideal-diode stand-in, not the
##   TPS2116 -- priority logic, break-before-make timing and reverse-leakage
##   are outside it. The claim still fails loudly if the OR is wired
##   backwards, which is the mistake worth catching.
## * *The buck's switching-model steady-state claims* (output ripple,
##   switching rate, inductor ripple current, load step, PSRR). Fed through
##   the OR-ing diodes rather than a stiff bench source, the switcher's
##   input rings against the input-capacitor ESL and collapses the switching
##   model's timestep. `designs/lt8640a_buck.nim` exercises every one of
##   those claims against a stiff 12 V input. The averaged-model claims
##   (start-up, final value, overshoot, rise time) do run here.
## * *Rail sequencing.* "The switches are enabled only after 3v3 is up" is a
##   real requirement; the pulldowns make it true structurally and nothing
##   checks the dynamic ordering.
## * *The crystal, RMII timing, link training, firmware*, and the MAC
##   readback conversation -- no crystal model, no timing quantity, no
##   digital-logic quantity.
## * *TVS clamping.* The TVS parts are unmodelled; the derating claims check
##   the working voltage, not the clamp under a surge.
## * *Tolerance and temperature.* `tolerance` is written and read by nothing;
##   `environment:` is stated and consumed by nothing. Every number is
##   nominal, at one temperature.
##
## **Library gaps this design would still use** (candidates for
## `docs/findings.md`): transmission lines / characteristic impedance /
## S-parameters; a `sequencing` role; a logic-state quantity; an `esd_clamp`
## role; a `passive_filter` role for the ferrite-and-capacitor RF-rail
## filter, and a two-port AC transfer to claim the common-mode choke's
## rejection. Coupled inductors (`K` card) and a switch device model both
## shipped -- `spice/models/magnetics` and `spice/models/switch`.

import verax/contract/dsl
import verax/verify
import verax/spice/boundary

import ./lib/xbar_parts
import ./lib/adg904
import ./xbar_poe
import ./xbar_usbc
import ./xbar_power
import ./xbar_rf
import ./xbar_control

const vout3v3 = 3.297

let d = design("xbar_switch"):
  # One reference for the whole system, or each instance clones a private
  # "0" and every cross-board measurement is meaningless.
  net gnd, kind = ntGround, name = "0", global = true

  net poe5v, kind = ntPower:
    spec:
      voltage = 5.0.V
  net usb5v, kind = ntPower:
    spec:
      voltage = 5.0.V
  net usbvbus, kind = ntPower:
    spec:
      voltage = 5.0.V
  net cc1, kind = ntSignal
  net cc2, kind = ntSignal
  net sda, kind = ntSignal
  net scl, kind = ntSignal
  net v3v3, kind = ntPower:
    spec:
      voltage = vout3v3.V
  net v3v3rf, kind = ntPower:
    spec:
      voltage = vout3v3.V
  net enetA, kind = ntSignal      # PoE feed conductors -- driven inside XPOE
  net enetB, kind = ntSignal
  net mdiTp, kind = ntSignal
  net mdiTn, kind = ntSignal
  net mdiRp, kind = ntSignal
  net mdiRn, kind = ntSignal

  # `xbar_rf`'s enable/address/SMA nets are buses now (its own sheet ports
  # merge into one pennant each); declaring the parent side as the matching
  # buses lets `instance`'s `{"en": en, ...}` wiring expand through
  # `wiringOf` to the child's scalar ports in one entry per bus, instead of
  # eight/sixteen/four scalar `net`s and as many wiring-table entries.
  bus en, width = 8
  bus a, width = [8, 2]
  bus rin, width = 4
  bus rout, width = 4

  # --- the five boards, wired by name --------------------------------
  instance XPOE, asSubcircuit(xbarPoe(), "XBAR_POE"),
           {"feedp": enetA, "feedn": enetB, "poe5v": poe5v}
  instance XUSB, asSubcircuit(xbarUsbC(), "XBAR_USBC"),
           {"usbvbus": usbvbus, "cc1": cc1, "cc2": cc2, "usb5v": usb5v}
  instance XPWR, asSubcircuit(xbarPower(), "XBAR_POWER"),
           {"poein": poe5v, "usbin": usb5v, "v3v3": v3v3, "v3v3rf": v3v3rf}
  instance XRF, asSubcircuit(xbarRf(), "XBAR_RF"),
           {"v3v3rf": v3v3rf, "en": en, "a": a, "rin": rin, "rout": rout}
  # `xbarControl`'s own ports are unchanged (`en1".."en8"`, via its `JCTL`
  # header connector) -- only the parent-side nets they land on moved from
  # eight scalars to `en`'s eight members, so the child-side keys stay as
  # they were and only the values change.
  instance XCTL, asSubcircuit(xbarControl(), "XBAR_CTL"),
           {"v3v3": v3v3, "sda": sda, "scl": scl,
            "en1": en[0], "en2": en[1], "en3": en[2], "en4": en[3],
            "en5": en[4], "en6": en[5], "en7": en[6], "en8": en[7],
            "mdi_tp": mdiTp, "mdi_tn": mdiTn, "mdi_rp": mdiRp, "mdi_rn": mdiRn}

  # --- the RJ45, the SMA cable loads, and the MDI terminations -------
  # The MagJack is described inside XPOE (the PoE tap) and here (the MDI
  # pairs); it is one physical part. The PoE conductors are energised by the
  # PSE model inside XPOE, so `enetA`/`enetB` need no drive here.
  component J_ENET, kind = "connector", description = "RJ45-MagJack":
    pin "POEP", enetA, kind = ptPassive
    pin "POEN", enetB, kind = ptPassive
    pin "TP", mdiTp, kind = ptPassive
    pin "TN", mdiTn, kind = ptPassive
    pin "RP", mdiRp, kind = ptPassive
    pin "RN", mdiRn, kind = ptPassive

  # The USB-C receptacle. `asSubcircuit` dropped the one inside XUSB, so the
  # system carries its own on the promoted port nets -- the same pattern
  # `designs/system_sensor_rig.nim` uses for its host cable.
  component J_USB, kind = "connector", description = "USB-C 2.0 receptacle":
    pin "VBUS", usbvbus, kind = ptPower
    pin "GND",  gnd,     kind = ptGround
    pin "CC1",  cc1,     kind = ptPassive
    pin "CC2",  cc2,     kind = ptPassive

  # Each SMA carries a cable to a 50 ohm load. Built in a loop.
  for (rn, netv) in [("RT_IN1", rin[0]), ("RT_IN2", rin[1]), ("RT_IN3", rin[2]),
                     ("RT_IN4", rin[3]), ("RT_OUT1", rout[0]), ("RT_OUT2", rout[1]),
                     ("RT_OUT3", rout[2]), ("RT_OUT4", rout[3])]:
    component R, designator = rn, kind = "resistor", value = "50":
      pin "1", netv, kind = ptPassive
      pin "2", gnd, kind = ptPassive

  # Bob Smith termination on the unused MDI receive pair, so the PHY's
  # receive inputs have a DC reference.
  component R_MDIR, kind = "resistor", value = "100":
    pin "1", mdiRp, kind = ptPassive
    pin "2", mdiRn, kind = ptPassive

  # --- claims no chunk can make alone -------------------------------
  role "power_rail", core, rail = v3v3, voltage = vout3v3.V, band = 3.pct,
       targetZ = 250.mohm, targetFrom = 100.kHz, targetTo = 100.MHz,
       maxDerating = 0.5

  role "power_rail", rf_at_matrix, rail = v3v3rf, voltage = vout3v3.V,
       band = 3.pct,
       targetZ = 300.mohm, targetFrom = 100.kHz, targetTo = 100.MHz

  require dc_voltage(v3v3) == vout3v3.V, band = 3.pct,
          id = "REQ-SYS-CORE",
          because = "with a PSE on the RJ45 and a charger on the USB-C port " &
                    "at the same time, and the whole board -- PHY, MCU, " &
                    "expanders, switch bias -- drawing from the 3.3 V rail, " &
                    "the rail still has to sit where everything expects it"

  require dc_voltage(poe5v) >= 1.3 * dc_voltage(v3v3),
          id = "REQ-SYS-ORDER",
          because = "the 5 V inlet rail must stay well above the 3.3 V rail " &
                    "the buck makes from it, clear of the converter's dropout"

let ens = rfEnableNets()
for i, en in ens:
  d.assertThat(Assertion(
    id: "REQ-SYS-SAFE-" & $(i + 1),
    subjects: @[Subject(kind: skNet, name: en)],
    quantity: "dc_voltage",
    expect: atMost(vout3v3 * 0.1),
    unit: "V",
    severity: sevError,
    rationale: "switch " & $(i + 1) & "'s enable must sit low at power-up " &
               "with the expanders released, so the RF port stays 50 ohm " &
               "terminated until firmware chooses a route -- measured here " &
               "with the real expanders on the nets, not a bench assumption",
    origin: "authored"))

# Both inlets energised: a PSE on the RJ45 (modelled inside XPOE) and a 5 V
# source on the USB-C receptacle.
equipXbarPower(d, "XPWR.", withBuckModel = false)

# The PoE front end's Si3402-B, stood up as an ideal isolated 5 V source --
# the flyback transformer (a real `K`-coupled part now) stays in the netlist
# but a switching primary has no model. See `designs/xbar_poe.nim`.
equipXbarPoe(d, "XPOE.")

# The eight ADG904s, with their datasheet numbers, so each is an absorptive
# SP4T rather than eight pins to ground -- which is what makes every RF port
# sit in 50 ohm with the enables low.
equipAdg904(d.netlist,
  ["XRF.XSW1", "XRF.XSW2", "XRF.XSW3", "XRF.XSW4",
   "XRF.XSW5", "XRF.XSW6", "XRF.XSW7", "XRF.XSW8"])

# The pulldowns that hold every ADG904 enable low at power-up, at both ends
# of the nets. The chunks add their own in their benches; imported, those
# `when isMainModule` blocks do not run, so the system adds them here.
controlPulldowns(d.netlist, rfEnableNets())

# The address lines need the same treatment, for a different reason: unlike
# EN, an undriven select net has nothing else touching it at all --
# `muxModel`'s decoder reads it without loading it, so with no pulldown the
# whole-system `.op` solve is singular (`xbar_rf.nim` documents this for its
# own bench; the system is the only place these sixteen nets get it, since
# `xbar_rf`'s `when isMainModule` block does not run when imported).
controlPulldowns(d.netlist, rfAddressNets())

driveConnector(findComponent(d.netlist, "J_USB"),
               {"VBUS": driveSource(5.0.V, rout = 50.mohm),
                "CC1": driveSource(5.0.V, rout = 10.kohm),
                "CC2": driveSource(5.0.V, rout = 10.kohm)})

quit(verifyMain(d))
