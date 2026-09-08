## A user-defined interface: the control bundle between a radio's baseband
## MCU and its RF front-end module.
##
##   verax check designs/rf_frontend.nim
##
## Every other interface in the tree is a bus protocol from
## `verax/netlist/interfaces/std` -- I2C, SPI, UART.  This one is invented
## here, in the design file, the way `designs/lib/spi_memory.nim` invents
## `spi_memory_link`: three signals a front-end module needs from whatever
## drives it, bundled once and wired once per side with the role it plays.
##
## ## The interface
##
## `rf_ctrl` carries exactly what the prompt for this design asked for:
##
## * `rf_en`  -- one line that enables the front-end.  Low = the PA and LNA
##              are shut down and draw no bias.
## * `trx`    -- the transmit/receive antenna-switch select.  Low = receive,
##              so the antenna is routed to the LNA and the PA output is
##              terminated.
## * `gain`   -- a 4-bit parallel word setting the receive VGA, all-zero =
##              minimum gain.
##
## Two modports: `controller` (the MCU, every line an output) and `frontend`
## (the module, every line an input).  `validateInterfaces` then has enough
## to check the boundary -- one controller, no back-to-back outputs, nothing
## on the bundle left dangling.
##
## ## What it claims, and why the interface carries the claim
##
## `rf_ctrl` *implies* the `rf_keydown` role (defined below), the same way
## `i2cInterface()` implies `"i2c"`.  So the moment a design instantiates the
## interface it also inherits the claim that matters at power-up: `rf_en` and
## `trx` must sit low, held there by board pull-downs, before firmware has
## run -- otherwise the radio keys its PA into the antenna.  That is a
## `dc_voltage` claim against one `.op`; the 4-bit gain word gets the same
## treatment by an explicit `require` so the addressing of an interface bus
## member in a claim is on show too.
##
## What the `.op` proves and what it does not: the MCU is unmodelled, so its
## control outputs reach the deck as a stand-in impedance to 0 V rather than
## as a driver contending with the pull-down.  The claim therefore confirms
## the pull-down network is present and resolves the lines low; it is not the
## test of a driver fighting the pull-down, which needs a real buffer model
## on the MCU pin (the same gap `designs/xbar_switch.nim`'s cannot-check list
## records for its enables until `lib/adg904.nim` closed it).

import std/tables

import verax/contract/dsl
import verax/contract/roles/core
import verax/netlist/interfaces
import verax/verify

# --- the role the interface implies --------------------------------------

proc rfKeydownExpand(inst: RoleInstance): seq[Assertion] =
  ## Two claims: with nothing driving them, the enable and the T/R select
  ## both sit within `maxFraction` of the rail above ground -- i.e. low.
  ##
  ## `dc_voltage` and an absolute `<=` bound, exactly as `safe_default` does
  ## it in `designs/lib/xbar_parts.nim`: the quantity registry is entirely
  ## electrical and "this line reads as a logic low" has no quantity of its
  ## own.  The threshold is a fraction of the rail so one number covers a
  ## 3.3 V and a 1.8 V front-end; it defaults to 10%, well inside any logic
  ## family's V_IL and far above the millivolts a 100 k pull-down leaves.
  let rail = paramFloat(inst, "rail", 3.3)
  let maxFraction = paramFloat(inst, "maxFraction", 0.1)
  for (part, what) in {"rf_en": "the front-end enable",
                       "trx": "the transmit/receive antenna-switch select"}:
    result.add Assertion(
      id: assertionId(inst, part & "_low"),
      subjects: @[inst.subject(part)],
      quantity: "dc_voltage",
      expect: atMost(rail * maxFraction),
      unit: "V",
      severity: sevError,
      rationale:
        "at power-up the MCU has not configured its GPIOs, so " & what &
        " is driven by nothing but the board pull-down; a front-end that " &
        "comes up with rf_en or trx high would bias its PA and route it to " &
        "the antenna before firmware decides anything.  This checks the " &
        "pull-down is on the net and wins against the leakage on it.",
      origin: inst.name)

registerRole(RoleDef(
  name: "rf_keydown",
  doc: "An RF front-end control bundle that must power up shut down and in " &
       "receive.",
  expects: "rf_ctrl",
  parts: @[
    RolePart(name: "rf_en", kind: skNet, doc: "the front-end enable line"),
    RolePart(name: "trx", kind: skNet,
             doc: "the transmit/receive antenna-switch select"),
  ],
  params: @[
    AnnDef(key: "rail", kind: akFloat, unit: "V", scopes: {asNet},
           doc: "the logic rail these lines swing to; default 3.3 V"),
    AnnDef(key: "maxFraction", kind: akFloat, unit: "", scopes: {asNet},
           doc: "highest fraction of the rail that still reads low; " &
                "default 0.1"),
  ],
  apply: nil,
  expand: rfKeydownExpand))

# --- the interface ------------------------------------------------------

let rfCtrl = interfaceDef("rf_ctrl"):
  signal rf_en, doc = "front-end enable; low = PA/LNA shut down"
  signal trx, doc = "antenna switch select; low = receive"
  signal gain, width = 4, doc = "receive VGA setting, all-zero = minimum"
  modport controller, controller = true:
    rf_en = ptOutput
    trx = ptOutput
    gain = ptOutput
  modport frontend:
    rf_en = ptInput
    trx = ptInput
    gain = ptInput
  implies "rf_keydown"

# The module's own end of the bundle is a separate, receive-only definition
# with no `controller` modport -- exactly the split `designs/lib/spi_memory.nim`
# draws between `spi_memory_link` and the parent's `spiInterface`. Same signal
# names, so the two wire together by name; a sheet that never drives the bus
# should not be judged for lacking a controller.
let rfCtrlSheet = interfaceDef("rf_ctrl_sheet"):
  signal rf_en
  signal trx
  signal gain, width = 4
  modport frontend:
    rf_en = ptInput
    trx = ptInput
    gain = ptInput

# --- the front-end module, as a sheet ----------------------------------

let RF_FRONTEND = subckt("RF_FRONTEND",
                         [vcc, gnd, ant, rf_tx, rf_rx, rfc.frontend]):
  net gnd, kind = ntGround, name = "0"
  net vcc, kind = ntPower
  net ant, kind = ntSignal        # to the antenna connector
  net rf_tx, kind = ntSignal      # transmit drive in
  net rf_rx, kind = ntSignal      # receive IF out
  net pa_out, kind = ntSignal
  net sw_rx, kind = ntSignal      # switch common -> LNA in
  net lna_out, kind = ntSignal

  iface rfc, rfCtrlSheet

  # The transmit/receive switch: antenna to the PA output or to the LNA,
  # picked by `trx`. The RF pins carry no DC direction -- `ptPassive`, the
  # same convention `designs/xbar_rf.nim` uses for a 50-ohm path.
  component U1, kind = "rf_switch", partNumber = "front-end T/R switch":
    pin "VCC", vcc, kind = ptPower
    pin "GND", gnd, kind = ptGround
    pin "RFC", ant, kind = ptPassive
    pin "RF1", pa_out, kind = ptPassive
    pin "RF2", sw_rx, kind = ptPassive
    pin "CTRL", rfc["trx"], kind = ptInput

  # The power amplifier: on only when `rf_en` is high.
  component U2, kind = "power_amplifier", partNumber = "Tx PA":
    pin "VCC", vcc, kind = ptPower
    pin "GND", gnd, kind = ptGround
    pin "RFIN", rf_tx, kind = ptPassive
    pin "RFOUT", pa_out, kind = ptPassive
    pin "EN", rfc["rf_en"], kind = ptInput

  # The low-noise amplifier, likewise gated by `rf_en`.
  component U3, kind = "lna", partNumber = "Rx LNA":
    pin "VCC", vcc, kind = ptPower
    pin "GND", gnd, kind = ptGround
    pin "RFIN", sw_rx, kind = ptPassive
    pin "RFOUT", lna_out, kind = ptPassive
    pin "EN", rfc["rf_en"], kind = ptInput

  # The variable-gain amplifier on the receive path, set by the 4-bit word.
  component U4, kind = "vga", partNumber = "Rx VGA":
    pin "VCC", vcc, kind = ptPower
    pin "GND", gnd, kind = ptGround
    pin "RFIN", lna_out, kind = ptPassive
    pin "RFOUT", rf_rx, kind = ptPassive
    pin "G0", rfc.bus("gain")[0], kind = ptInput
    pin "G1", rfc.bus("gain")[1], kind = ptInput
    pin "G2", rfc.bus("gain")[2], kind = ptInput
    pin "G3", rfc.bus("gain")[3], kind = ptInput

# --- the board --------------------------------------------------------

let d = design("rf_frontend"):
  net gnd, kind = ntGround, name = "0"
  net vdd, kind = ntPower:
    spec:
      voltage = 3.3.V
  net ant, kind = ntSignal
  net rf_tx, kind = ntSignal
  net rf_rx, kind = ntSignal

  iface rfc, rfCtrl

  # The baseband MCU drives the whole bundle as the controller side.
  component U10, kind = "mcu", partNumber = "baseband SoC":
    pin "VDD", vdd, kind = ptPower
    pin "VSS", gnd, kind = ptGround
    port rfc, controller

  # The pull-downs that make the power-up state a property of the board
  # rather than of firmware.  `rf_keydown` checks the first two; the gain
  # word is pulled low so the VGA comes up at minimum.
  for line in ["rf_en", "trx"]:
    component kind = "resistor", value = "100k", designator = "RPD_" & line:
      pin "1", rfc[line], kind = ptPassive
      pin "2", gnd, kind = ptPassive
  for k in 0 ..< 4:
    component kind = "resistor", value = "100k", designator = "RPD_gain" & $k:
      pin "1", rfc.bus("gain")[k], kind = ptPassive
      pin "2", gnd, kind = ptPassive

  # The RF edges of the board.
  component J1, kind = "connector", partNumber = "SMA antenna":
    pin "RF", ant, kind = ptPassive
    pin "GND", gnd, kind = ptGround
  component J2, kind = "connector", partNumber = "SMA Tx in":
    pin "RF", rf_tx, kind = ptPassive
    pin "GND", gnd, kind = ptGround
  component J3, kind = "connector", partNumber = "SMA Rx out":
    pin "RF", rf_rx, kind = ptPassive
    pin "GND", gnd, kind = ptGround

  instance X1, RF_FRONTEND,
    {"vcc": vdd, "gnd": gnd, "ant": ant, "rf_tx": rf_tx, "rf_rx": rf_rx,
     "rfc": rfc}

  # The 4-bit gain word must also sit low at power-up -- min gain, not a
  # random setting.  Each `require` addresses one member of the interface
  # bus directly.
  require dc_voltage(rfc.bus("gain")[0]) <= 0.33.V, id = "REQ-RF-GAIN-0",
          because = "the VGA control word is undriven until firmware writes " &
                    "it; the pull-down holds this bit low so the receiver " &
                    "comes up at minimum gain"
  require dc_voltage(rfc.bus("gain")[1]) <= 0.33.V, id = "REQ-RF-GAIN-1",
          because = "as REQ-RF-GAIN-0, for gain bit 1"
  require dc_voltage(rfc.bus("gain")[2]) <= 0.33.V, id = "REQ-RF-GAIN-2",
          because = "as REQ-RF-GAIN-0, for gain bit 2"
  require dc_voltage(rfc.bus("gain")[3]) <= 0.33.V, id = "REQ-RF-GAIN-3",
          because = "as REQ-RF-GAIN-0, for gain bit 3 (MSB)"

quit(verifyMain(d))
