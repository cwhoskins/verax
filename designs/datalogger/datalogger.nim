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
## **USB signal integrity, before layout.** The `usb` pair carries an
## explicit `diff_pair` role naming its IBIS ends: U1's `PA12`/`PA11` (ST's
## own model, the full-speed USB PHY at 3.3 V -- see `lib/mcu.nim`) driving,
## and the host behind `Xusbc.J1` receiving (`ibis/usb_fs_host.ibs`, a
## stand-in built from the USB 2.0 spec's limits, bound with
## `ibis_mate_file` below). ST's file has no `[Diff Pin]` -- full-speed USB
## is two single-ended buffers driven in opposition -- so the role names the
## N leg's driver outright (`driver_n`). `verax constraints` derives the
## pair's routing rules from them, simulating the 27 ohm `R_DP`/`R_DM`
## inside `Xmcu` as series termination:
##
##   verax constraints designs/datalogger/datalogger.nim --dru=datalogger.kicad_dru
##
## None of this adds a claim to `verax check`: the pair has no board yet
## (and board-level pair extraction does not exist), so its routing rules
## are derived, not measured. No `z_diff`: it would be a claim nothing can
## check (see `usb` below), so the template sizes the pair for its default
## 100 ohm, not USB's 90 -- a full-speed edge (4-20 ns) on a board this size
## does not tell the two apart. The cable is not modelled.
##
## **Deliberately not stated.** No `footprint` annotation on any part, so
## `verax layout` reports every placement as `footprint_unresolved` -- Stage 1
## of the board-to-PCB plan this design exists to start, and deliberately not
## this file's job.

import std/os
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

  # `part_use` says what each of these four is *for*, which a BOM reviewer
  # cannot read off a value: the pull-ups are general-purpose (any 1% 0402
  # will do), but the 47 pF parts set the bus's RC corner with the pull-ups
  # -- a timing use, which is why they are C0G and why substituting an X7R
  # "because it is cheaper" would be caught as a policy change rather than
  # passing as an equivalent. Parts a sheet sizes through `parts.*Request`
  # get this written for them by `applyChoice`; these four are hand-authored.
  component R_SDA, kind = "resistor", value = "1.2k":
    pin "1", vdd, kind = ptPassive
    pin "2", bus["sda"], kind = ptPassive
    spec:
      tolerance = 1.pct
      part_use = "general"
  component R_SCL, kind = "resistor", value = "1.2k":
    pin "1", vdd, kind = ptPassive
    pin "2", bus["scl"], kind = ptPassive
    spec:
      tolerance = 1.pct
      part_use = "general"
  component C_SDA, kind = "capacitor", value = "47p":
    pin "1", bus["sda"], kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0402"
      dielectric = "C0G"
      voltage_rating = 16.0.V
      part_use = "timing"
  component C_SCL, kind = "capacitor", value = "47p":
    pin "1", bus["scl"], kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0402"
      dielectric = "C0G"
      voltage_rating = 16.0.V
      part_use = "timing"

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
  # Fitted for bring-up, not for production: `dnp` keeps the header's line
  # on the BOM -- the footprint is on the board and the decision is visible
  # -- but marks it not populated at assembly. A debug board build flips it.
  component J3, kind = "connector", description = "ARM-JTAG-20":
    pin "VTREF",  vdd,          kind = ptPower
    pin "NTRST",  jtag["ntrst"], kind = ptInput
    pin "TDI",    jtag["tdi"],   kind = ptInput
    pin "TMS",    jtag["tms"],   kind = ptInput
    pin "TCK",    jtag["tck"],   kind = ptInput
    pin "TDO",    jtag["tdo"],   kind = ptPassive
    pin "NRESET", nrst,          kind = ptInOut
    pin "GND",    gnd,          kind = ptGround
    spec:
      dnp = true

  # Bring-up test points on the system rail and the ADC input: bare copper
  # pads, nothing to buy, so `bom_exclude` leaves them off the BOM entirely
  # (unlike `dnp`, which keeps a line). They stay in the netlist so layout
  # places them and the schematic shows where to probe.
  component TP1, kind = "test_point", description = "VDD test pad":
    pin "1", vdd, kind = ptPassive
    spec:
      bom_exclude = true
  component TP2, kind = "test_point", description = "AOUT test pad":
    pin "1", aout, kind = ptPassive
    spec:
      bom_exclude = true

  # --- claims ---------------------------------------------------------

  # The USB pair's IBIS ends, for `verax constraints` (see the header).
  # Named `usb`, like the `iface`, so this replaces the bare `diff_pair` the
  # interface would imply rather than adding a second one beside it -- the
  # same trick as `bus`/`"i2c"`. `ui`: full-speed, 12 Mb/s.
  role "diff_pair", usb, p = usb["p"], n = usb["n"],
       driver = Xmcu.innerPin("U1", "PA12"), driver_n = Xmcu.innerPin("U1", "PA11"),
       rx = Xusbc.innerPin("J1", "DP"),
       ui = 83.33.ns

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

  # What the ADC needs from the stage, which neither role above asks. A
  # user-defined role (`lib/analog.nim`) because none of these quantities has
  # a built-in role -- each needs the `opamp`/`input` binding a bare
  # `require` cannot carry.
  #
  # The large-signal half is the reason it exists. Driven at 0.75 V, a
  # full-scale input, the output has to swing 0.15 V .. 3.15 V around
  # mid-rail without touching either rail and without compressing. Those
  # claims found that this stage used to be biased *into* the top rail --
  # see `lib/analog.nim`'s header -- with every small-signal claim above
  # passing. `dc_voltage(aout)` below pins the fix directly.
  #
  # The numbers come from the ADC. 12 bits wants the loop to hold gain error
  # to half an LSB: 1/T < 2^-13, so T >= 78.3 dB at DC (measured 94.1). A
  # 640 ns acquisition window wants the stage settled to that same half LSB
  # in time: ln(2^13) = 9.0 time constants of 1/(2 pi fc), so fc >= 2.24 MHz
  # (measured 10.0 MHz -- the OPA320's 20 MHz GBW over a noise gain of 2).
  # The unity-gain frequency caps the bandwidth the stage hands its own
  # 7 nV/rtHz to the sampler over: integrated to 30 MHz that is 1/8 LSB.
  role "adc_driver", adc, opamp = Xanalog.innerComponent("Xamp", "U1"),
       input = ain, output = aout,
       bits = 12, tAcq = 640.ns, maxUnity = 30.MHz,
       bandLo = 10.Hz, bandHi = 5.MHz,
       driveV = 0.75.V, driveF = 1.kHz, gain = 6.02.dB,
       outMin = 0.1.V, outMax = 3.2.V

  require dc_voltage(aout) == 1.649.V, band = 2.pct,
          id = "REQ-DL-AOUT-BIAS-001",
          because = "the stage's output has to sit mid-rail to swing both " &
                    "ways into the ADC; RG's series capacitor is what gives " &
                    "the input bias unity gain, and without it this reads " &
                    "3.3 V -- the top rail"

  # The input connector has no DC path into the supply. `C_IN` is the only
  # thing between them: `vin` reaches VDD through the bias divider, so a
  # sensor with a DC offset at J2 (or a fault onto it) would otherwise drive
  # the rail through 100 k.
  require dc_path_exists(ain, vdd) == 0.0,
          id = "REQ-DL-AIN-ISO-001",
          because = "C_IN must block DC between the input connector and the " &
                    "rail; a short across it is a path into VDD"

  # --- the PDN beyond its worst point ---------------------------------------
  #
  # `power_rail` claims the impedance's maximum over the band. The shape
  # around it is the rest of the story, and every number here is the buck's
  # five 10 uF 0805s (derated to 7.86 uF each at 3.3 V, 15 mohm and 1 nH
  # apiece) doing what their datasheets say. One sweep answers all of them.
  #
  # The series resonance: 39 uF against 0.2 nH of parallel ESL is 1.8 MHz
  # (measured 1.78), where the bank bottoms out at its parallel ESR,
  # 3 mohm. It belongs just above the 1 MHz switching frequency, where the
  # ripple current lives -- and it must stay damped: ESR is the only thing
  # setting how deep the notch is and how high the peaks beside it are, and a
  # bank under a milliohm rings.
  require z_min(vdd) >= 1.mohm, f_from = 100.kHz, f_to = 10.MHz,
          id = "REQ-DL-PDN-ZMIN-001",
          because = "an undamped series resonance makes sharp antiresonances " &
                    "beside it; the bank's ESR is what keeps them low"
  require f_z_min(vdd) >= 1.MHz, f_from = 100.kHz, f_to = 10.MHz,
          id = "REQ-DL-PDN-FZMIN-LO-001",
          because = "the bank's lowest impedance belongs at or above the 1 MHz " &
                    "switching frequency, over the ripple current"
  require f_z_min(vdd) <= 3.MHz, f_from = 100.kHz, f_to = 10.MHz,
          id = "REQ-DL-PDN-FZMIN-HI-001",
          because = "past 3 MHz the notch has left the switching harmonics " &
                    "that matter -- fewer bulk caps, or smaller ones, than " &
                    "this board was sized with"

  # The worst point in band is its low edge (measured 112 kHz), where the
  # bank's capacitance is running out and the converter's loop takes over.
  # If it moves up the band, the bank has grown an in-band antiresonance.
  require f_z_max_in_band(vdd) <= 200.kHz, f_from = 100.kHz, f_to = 10.MHz,
          id = "REQ-DL-PDN-FZMAX-001",
          because = "the impedance maximum belongs at the low band edge, where " &
                    "the loop hands over to the bank; anywhere higher is a " &
                    "resonance inside the band"

  # The antiresonance is the buck's own output filter: L1 against the bank,
  # 1/(2 pi sqrt(L C)), measured at 17.8 kHz and 3.25 ohm with the loop cut
  # away (the PDN sweep isolates the rail). It must sit two decades below the
  # switching frequency for the filter to attenuate the ripple, and inside
  # the loop's bandwidth, which is what holds it down in the real circuit.
  require f_antiresonance(vdd) <= 50.kHz, f_from = 100.kHz, f_to = 10.MHz,
          id = "REQ-DL-PDN-FANTI-001",
          because = "the output LC pole must sit far below 1 MHz to filter the " &
                    "ripple, and inside the loop's bandwidth to be corrected"
  require z_antiresonance(vdd) <= 5.ohm, f_from = 100.kHz, f_to = 10.MHz,
          id = "REQ-DL-PDN-ZANTI-001",
          because = "with the loop open, only the bank's ESR damps the LC " &
                    "pole; a higher peak means less loss than this was " &
                    "budgeted against and more for the loop to correct"

  # A canary: the number of capacitors the sweep found on the rail. Inside
  # the band the five bulk caps dominate so completely that a sheet could
  # lose its local decoupling in a refactor and every impedance claim would
  # still pass. Adding decoupling is fine; losing it is not.
  require cap_count(vdd) >= 18.0, f_from = 100.kHz, f_to = 10.MHz,
          id = "REQ-DL-PDN-CAPS-001",
          because = "every sheet's local decoupling is still on the rail -- " &
                    "the band claims cannot see a missing 100 nF"

  # Parts past their own derating ceilings, counted across each rail. Every
  # capacitor that states a `voltage_rating` is checked against the family
  # ceiling (the X7Rs at 3.3 V on 10 V and 16 V parts are well inside it).
  require parts_over_derating(vdd) == 0.0,
          id = "REQ-DL-DERATE-VDD-001",
          because = "no part on the 3.3 V rail runs past its derating ceiling"
  require parts_over_derating(vbus) == 0.0,
          id = "REQ-DL-DERATE-VBUS-001",
          because = "no part on VBUS runs past its derating ceiling at 5 V"

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

# The orderable parts inside generic sheets. A sheet built around a part's
# *spec* (a Type-C sink, a non-inverting stage) does not choose who makes it
# or in which package -- that is this board's procurement decision, so it is
# stated here, against the instance path, rather than in `designs/lib/`.
setAnnotation(findComponent(d.netlist, "Xusbc.J1"), "mpn", "USB4105-GF-A")
setAnnotation(findComponent(d.netlist, "Xusbc.J1"), "manufacturer", "GCT")
setAnnotation(findComponent(d.netlist, "Xanalog.Xamp.U1"), "mpn", "OPA320AIDBVR")
setAnnotation(findComponent(d.netlist, "Xanalog.Xamp.U1"), "manufacturer",
              "Texas Instruments")

# What is plugged into each connector. The source's own CC pull-up
# (`rpFor(advertise)`) is what actually makes the advertisement -- without
# it CC1/CC2 have nothing above `usbCSink`'s 5.1 k Rd and read 0 V, which is
# what `REQ-DL-CCSNS-001` measured before this was added.
driveConnector(findComponent(d.netlist, "Xusbc.J1"),
               {"VBUS": driveSource(5.0.V, rout = 100.mohm, lout = 2.uH),
                "CC1": driveSource(5.0.V, rout = rpFor(advertise)),
                "CC2": driveSource(5.0.V, rout = rpFor(advertise))})
# And what the USB pins see on the far side, for SI: a full-speed host.
setAnnotation(findComponent(d.netlist, "Xusbc.J1"), "ibis_mate_file",
              currentSourcePath().parentDir / "ibis" / "usb_fs_host.ibs")
driveConnector(findComponent(d.netlist, "J2"),
               {"AIN": driveSource(0.5.V, rout = 1.0.kohm)})

quit(verifyMain(d))
