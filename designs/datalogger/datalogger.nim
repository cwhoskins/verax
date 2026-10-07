## A first non-trivial board, in five sheets: USB-C in, a buck-regulated
## 3.3 V system rail, an STM32H563 MCU (with its HSE crystal nested as its
## own sub-sheet) talking to an M24C64 EEPROM over I2C1, and a single-supply
## analog input channel -- plus a JTAG debug header (`J3`) broken straight
## off the MCU sheet, ARM's standard 20-pin pinout so a stock J-Link plugs in
## with no adapter.
##
##   verax check designs/datalogger/datalogger.nim
##
## Two of the five sheets (`mcu`, `analog`) are specific to this board and
## live alongside it in `designs/datalogger/lib/`; the other four (USB-C,
## buck, crystal, EEPROM) are generic building blocks -- built from pure
## physics or a specific part's own spec, nothing about *this* design -- and
## live in the shared `designs/lib/`. **The buck converter was the
## exception** until nesting an XSPICE-modelled part inside an `instance`
## was fixed: `designs/lib/lt8640a.nim`'s own `buckConfig` doc comment
## records the real, previously-unexercised limit this design found, and why
## the buck's components lived here, flat, at the same level
## `designs/lt8640a_buck.nim`'s always have. Now `lt8640a.buckSheet` is an
## ordinary `instance` like every other sheet below. The I2C pull-ups and bus
## capacitance stay flat for a related, separately-measured reason: see
## `designs/lib/m24c64_sheet.nim`'s header.
##
## | Sheet | Proc | Where | Parameterized by |
## | --- | --- | --- | --- |
## | USB-C | `usbc_sink.usbCSink` | `designs/lib/` (generic) | expected advertised current (sizes VBUS bulk) |
## | Buck converter | `lt8640a.buckSheet` | `designs/lib/` (generic) | output voltage, switching frequency, `ilim`/`dmax` |
## | MCU | `lib/mcu.mcuSheet` | `designs/datalogger/lib/` (board-specific) | crystal spec, board current budget |
## | ↳ crystal | `crystal.crystalNetwork` | `designs/lib/` (generic) | load capacitance, computed from the crystal's own `CL` |
## | EEPROM | `m24c64_sheet.eepromSheet` | `designs/lib/` (generic) | -- (one part; the bus is flat) |
## | Analog input | `lib/analog.analogInputChannel` | `designs/datalogger/lib/` (board-specific) | closed-loop gain, op-amp GBW/part |
##
## This is the same reuse discipline `designs/lib/filters.sallenKeyLP` and
## `designs/lib/opamp_stages.nonInvertingAmp` already establish elsewhere in
## this repo: a module states component *values* as a function of its
## arguments rather than as literals, so the claims below check the design
## equations rather than checking that somebody did the arithmetic twice.
## This is also the first design where that split runs *between directories*:
## `designs/datalogger/lib/` holds sheets shaped around this specific board's
## choices (which MCU, which analog topology), and `designs/lib/` holds
## sheets shaped around a specific part or a spec (a Type-C sink, an
## M24C64, a crystal's load-cap formula) that the next design gets for free
## by importing them -- datalogger just happens to be the first to ask.
##
## **Deliberately not claimed.** No inrush, load-step or PSRR claim on the
## buck -- all three want `switching_regulator`'s `source` binding pointed
## at a real `voltage_source`, and this board's input is a connector with a
## bench drive behind it (see `driveConnector` below), not one. No
## behavioural I2C transaction -- `designs/lib/m24c64_sheet.nim`'s own
## header explains why the real STM32H563 cannot carry the
## `dummy_mcu`/`DONE`/`PASS` pattern `designs/i2c_eeprom.nim` uses.
##
## **Deliberately not stated.** No `footprint` annotation on any part, so
## `verax layout` reports every placement as `footprint_unresolved` -- Stage 1
## of the board-to-PCB plan this design exists to start, and deliberately not
## this file's job.

import verax/contract/dsl
import verax/verify
import verax/spice/boundary
import verax/netlist/interfaces/std

import ../lib/lt8640a
import ../lib/usbc_sink
import ../lib/m24c64_sheet
import ./lib/mcu
import ./lib/analog

const
  buckCfg = buckConfig(voltage = 3.298.V, freq = 1.0.MHz, vin = 5.0.V)
    ## 3.298 V: `0.970 * (1 + 240k/100k)`, refit from
    ## `designs/lt8640a_buck.nim`'s own 4.962 V rail to what this board's
    ## logic actually runs at. `feedbackPair`/`rtForFsw` compute the exact
    ## resistors for whatever voltage/frequency is stated here -- this file
    ## names only the rail and the rate, never a resistor. `vin = 5.0.V`:
    ## this board's input is the USB-C `vbus` rail below, not `buckConfig`'s
    ## 12 V default -- stated so the input-side bypass caps size against
    ## what they actually see rather than a rail this board doesn't have.
  advertise = usb3000mA
    ## What this board expects the USB-C source to offer. Changing it moves
    ## `ccsns`'s claimed voltage below and `usbCSink`'s own VBUS bulk sizing
    ## with it -- see `../lib/usbc_sink.nim`'s header for why the
    ## board's own `Rd` never changes.

let ccTarget = ccSenseTarget(advertise)
  ## Bound to a `let` rather than inlined into the `require` below:
  ## `contract/dsl.require`'s "the unit comes from the literal" trick walks
  ## the comparison's right-hand expression looking for a binding, and a
  ## proc call there (`ccSenseTarget(advertise)`) makes it try `subjectOf`
  ## on the call's own argument -- a plain identifier is what the macro
  ## expects on that side.

let d = design("datalogger"):
  environment:
    t_ambient_min = -10.degC
    t_ambient_max = 60.degC

  # Board-wide procurement defaults: a resistor that states no package is
  # bought as 0402. Every sheet inherits this unless it states its own.
  bom:
    resistor_package = "0402"

  net gnd, kind = ntGround, name = "0"
  net vbus, kind = ntPower:
    spec:
      voltage = 5.0.V
  net vdd, kind = ntPower:
    spec:
      voltage = buckCfg.voltage
  net cc1, kind = ntSignal
  net cc2, kind = ntSignal
  net ccsns, kind = ntSignal
  net ain,  kind = ntSignal
  net aout, kind = ntSignal
  net en,   kind = ntSignal
  net nrst,  kind = ntSignal
  # `nrst` is the system reset, not part of `jtag` below -- distinct from the
  # TAP's own `ntrst`, and driven by both `R_NRST`/`C_NRST` inside `Xmcu` and
  # `J3`'s `NRESET` pin, so it stays a plain net like any other.

  # SDA/SCL, USB D+/D-, and the four TAP signals are declared interfaces
  # rather than plain nets -- the only thing that changes is that
  # `schematic/bundles.nim` can now see them as one thing: each is wired flat
  # to at least two component entities at this level (the pull-ups/EEPROM for
  # `bus`, `Xusbc`/`Xmcu` for `usb`, `J3`/`Xmcu` for `jtag`), which is exactly
  # what `bundlePlan` needs to draw a merged bus tree or a grouped net-label
  # tag instead of N separate thin wires. `bus` is named to match the `role
  # "i2c", bus, ...` instance below on purpose: `addImpliedRoles` skips an
  # interface's implied role when a role of that name already exists, and
  # `i2cInterface()` implies plain `"i2c"` with no params -- reusing the name
  # is what keeps this from also registering a second, redundant i2c role
  # instance duplicating the explicit one's claims. `diffPairInterface()`,
  # not `usb2Interface()`, for the same reason `usb_hs_link.nim` picks it:
  # `usb2Interface()` additionally implies a 90-ohm `z_diff` claim that
  # `pcb/` cannot check yet, and a design meant to check clean should not
  # carry a claim nothing can measure. `jtagInterface()` implies nothing at
  # all, so it needs no such care.
  iface bus, i2cInterface()
  iface usb, diffPairInterface()
  iface jtag, jtagInterface()

  # --- USB-C sheet ---------------------------------------------------------

  instance Xusbc, usbCSink(advertise), [vbus, gnd, cc1, cc2, ccsns, usb["p"], usb["n"]]

  # --- buck converter sheet -------------------------------------------------

  instance Xbuck, buckSheet(buckCfg),
    {"VIN": vbus, "VOUT": vdd, "GND": gnd, "PG": open, "EN": en}

  # EN tied to vbus through a resistor rather than straight to VIN -- same
  # rail, but the resistor is a real strap a bench can break to force a
  # shutdown, where a direct wire would not be.
  component R_EN, kind = "resistor", value = "100k":
    pin "1", vbus, kind = ptPassive
    pin "2", en,   kind = ptPassive
    spec:
      tolerance = 5.pct

  # --- MCU sheet (crystal nested inside it) --------------------------------

  # `mcuSheet`'s I2C1/JTAG ports are its own declared `i2c`/`jtag` interface
  # groups now, named `i2c_sda`/`i2c_scl`/`jtag_tck`/`jtag_tms`/`jtag_tdi`/
  # `jtag_tdo`/`jtag_ntrst` by `addPorts` (see `lib/mcu.nim`'s header) --
  # `DP`/`DM` keep their bare names, since that pair stays a plain schematic
  # tag on the MCU sheet rather than an exposed interface (see `lib/mcu.nim`).
  instance Xmcu, mcuSheet(boardCurrentMa = 150.0),
    {"VDD": vdd, "GND": gnd, "i2c_sda": bus["sda"], "i2c_scl": bus["scl"],
     "DP": usb["p"], "DM": usb["n"], "AIN": aout, "NRST": nrst,
     "jtag_tck": jtag["tck"], "jtag_tms": jtag["tms"], "jtag_tdi": jtag["tdi"],
     "jtag_tdo": jtag["tdo"], "jtag_ntrst": jtag["ntrst"]}

  # --- I2C bus: flat -- see ../lib/m24c64_sheet.nim's header ---------------
  #
  # 1.2k, not the 1.5k this bus originally carried (`sensor_node.nim`'s own
  # value, for the same reason). `rc_corner`'s bus-capacitance estimate used
  # to count only pins declared at this flat level; fixed to also count
  # Xmcu.U1's and Xeeprom.U1's own SDA/SCL pins, reached through their
  # instance boundary the same way a nested pull-up now is -- see
  # ../lib/m24c64_sheet.nim's header for the fix. That is a more accurate
  # bus-loading estimate, not a new load on the real board, and it pushed
  # this bus's measured corner to 992 kHz against the 1.00 MHz
  # `i2cCornerMargin` wants at 100 kHz. 1.2k keeps `pullup_sink_current`
  # comfortably inside the 3 mA VOL floor (2.75 mA at 3.3 V, against
  # 2.2 mA at the old 1.5k) while pushing the corner back above 1 MHz.

  component R_SDA, kind = "resistor", value = "1.2k":
    pin "1", vdd, kind = ptPassive
    pin "2", bus["sda"], kind = ptPassive
    spec:
      tolerance = 1.pct
  component R_SCL, kind = "resistor", value = "1.2k":
    pin "1", vdd, kind = ptPassive
    pin "2", bus["scl"], kind = ptPassive
    spec:
      tolerance = 1.pct
  component C_SDA, kind = "capacitor", value = "47p":
    pin "1", bus["sda"], kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0402"
      dielectric = "C0G"
      voltage_rating = 16.0.V
  component C_SCL, kind = "capacitor", value = "47p":
    pin "1", bus["scl"], kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0402"
      dielectric = "C0G"
      voltage_rating = 16.0.V

  # --- EEPROM sheet ---------------------------------------------------------

  instance Xeeprom, eepromSheet(), [vdd, gnd, bus["sda"], bus["scl"]]

  # --- analog input sheet ---------------------------------------------------

  instance Xanalog, analogInputChannel(gain = 2.0), [ain, aout, vdd, gnd]

  # --- board-level parts ---------------------------------------------------

  component J2, kind = "connector", description = "3p-header":
    pin "AIN", ain, kind = ptInput
    pin "GND", gnd, kind = ptGround

  # ARM/MIPI 20-pin JTAG (2x10, 0.1"), the connector SEGGER documents as
  # J-Link's own standard pinout, so a stock 20-pin ribbon/adapter plugs in
  # with no translation. Only the pins this design actually drives are
  # declared, the same convention `J2`/`usbc_sink.J1` already follow for a
  # connector's unused physical pins -- `RTCK` (11, adaptive clocking, which
  # the STM32H563 does not drive back), `DBGRQ`/`DBGACK` (17/19, unused on
  # every ARM target) and the `VSupply` pin (2) are left undeclared rather
  # than wired to anything. `VTREF` (1) still has to connect, though: it is
  # how the probe reads the target's own I/O voltage rather than assuming
  # one, and a J-Link left floating there refuses to talk to the board at
  # all. Every physical GND pin (4/6/8/10/12/14/16/18/20) collapses onto one
  # logical `GND` pin, same as `usbc_sink.usbCSink`'s `J1`.
  component J3, kind = "connector", description = "ARM-JTAG-20":
    pin "VTREF",  vdd,          kind = ptPower
    pin "NTRST",  jtag["ntrst"], kind = ptInput
    pin "TDI",    jtag["tdi"],   kind = ptInput
    pin "TMS",    jtag["tms"],   kind = ptInput
    pin "TCK",    jtag["tck"],   kind = ptInput
    pin "TDO",    jtag["tdo"],   kind = ptPassive
    pin "NRESET", nrst,          kind = ptInOut
    pin "GND",    gnd,          kind = ptGround

  # --- claims ---------------------------------------------------------

  role "power_rail", input, rail = vbus, voltage = 5.0.V, band = 5.pct

  role "power_rail", sys, rail = vdd, voltage = buckCfg.voltage, band = 3.pct,
       targetZ = 300.mohm, targetFrom = 100.kHz, targetTo = 10.MHz

  role "i2c", bus, sda = bus["sda"], scl = bus["scl"], pullupRail = vdd,
       controller = Xmcu.innerComponent("U1"), frequency = 100.kHz

  # `opamp_stage`/`gain_stage` split the same way they do on `ts808_drive`:
  # this stage is single-supply and AC-coupled (`analog.analogInputChannel`
  # blocks DC into IN+ with `C_IN`), so `peaking_db` and `bw_3db` are both
  # referenced to the *first swept point* -- unity gain here by construction
  # -- and would flag the coupling network's own rolloff as instability.
  # `without = "peaking"` declines that claim; `gain_stage` below states what
  # the stage is actually specified by, referenced to the response's
  # maximum instead.
  role "opamp_stage", achan, opamp = Xanalog.innerComponent("Xamp", "U1"),
       input = ain, output = aout,
       minPhaseMargin = 45.0.deg, without = "peaking"

  role "gain_stage", achanGain, opamp = Xanalog.innerComponent("Xamp", "U1"),
       input = ain, output = aout,
       minGain = 5.0.dB, maxGain = 7.0.dB,
       fLoMax = 10.0.Hz, fHiMin = 5.0.MHz

  require dc_voltage(ccsns) == ccTarget, band = 3.pct,
          id = "REQ-DL-CCSNS-001",
          because = "the source's own Rp against this board's fixed 5.1k Rd " &
                    "is the only thing that tells the MCU what current the " &
                    "port actually offers"

# The buck's `switching_regulator` role. After the block, like `useLt8640a`
# used to be: the role names `Xbuck`'s own internal `U1`/`L1`/`sw`, which
# `switchingRegulatorRole` knows and this file does not have to.
switchingRegulatorRole(d, "Xbuck", "buck", buckCfg, findNet(d.netlist, "vdd"),
                        tSettle = 300.0.us, tWindow = 20.0.us)

# What is plugged into each connector. The source's own CC pull-up
# (`rpFor(advertise)`) is what actually makes the advertisement -- without
# it CC1/CC2 have nothing above `usbCSink`'s 5.1 k Rd and read 0 V, which is
# what `REQ-DL-CCSNS-001` measured before this was added.
driveConnector(findComponent(d.netlist, "Xusbc.J1"),
               {"VBUS": driveSource(5.0.V, rout = 100.mohm, lout = 2.uH),
                "CC1": driveSource(5.0.V, rout = rpFor(advertise)),
                "CC2": driveSource(5.0.V, rout = rpFor(advertise))})
driveConnector(findComponent(d.netlist, "J2"),
               {"AIN": driveSource(0.5.V, rout = 1.0.kohm)})

quit(verifyMain(d))
