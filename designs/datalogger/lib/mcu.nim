## The MCU sheet: an STM32H563ZIT6, its HSE crystal nested inside as its own
## sub-sheet (`designs/lib/crystal.nim` -- a generic building block, not
## specific to this board), NRST/BOOT0 strapping, I2C1 out to the EEPROM
## sheet, and USB FS D+/D- in from the USB-C sheet with series termination
## at this end of the run.
##
## Board-specific, unlike its neighbours in `designs/lib/`: this sheet's own
## choice of MCU, pin assignment and current budget belong to
## `designs/datalogger/`, so it lives at `designs/datalogger/lib/mcu.nim`
## rather than the shared library.
##
## Ports: `VDD`, `GND`, `DP`, `DM`, `AIN`, `NRST`, plus the `i2c`/`jtag`
## interface groups below, exposed as `i2c_sda`/`i2c_scl` and
## `jtag_tck`/`jtag_tms`/`jtag_tdi`/`jtag_tdo`/`jtag_ntrst`.
##
## **I2C1 and JTAG are both declared `iface`s, exposed straight as this
## sheet's own port groups** (`i2c.controller`/`jtag.target` in the `subckt`
## port bracket) rather than plain nets wired with a bare
## `pin ..., function = "..."` stamp, which is what this sheet (and
## `designs/spi_memories.nim`'s own `port ..., peripheral =`) used to need
## for exactly this case -- `port`'s macro wants an `iface`-bound value in
## the same DSL block, and these were plain pairs passed in from the caller.
## Declaring the interface *here*, and exposing it as the port group itself
## (`addPorts(nl, label, view(iface, modport))` names each resulting port
## `<label>_<signal>`), sidesteps that: U1 genuinely *is* the I2C1 controller
## and the JTAG target, so `i2c.controller`/`jtag.target` state a real fact,
## and both `PB9`/`PB8`, and `PA14`/`PA13`/`PA15`/`PB3`/`PB4`, still carry
## their own `function = "I2C1.sda"`/`"JTAG.tck"` etc. `pin` stamps for
## `validatePinmux` exactly as before -- that check reads pin attrs a bare
## `pin` statement sets regardless of what the bound net is. The payoff is
## schematic-only: U1's seven separate I2C/JTAG pins now draw as two merged
## pins on this sheet's own box (`schematic/bundles.nim` collapses a
## port-bound bundle with only one *other* entity, the same as a two-entity
## one), instead of seven pin/port pairs cluttering it.
##
## **`AIN` (`PA3`) and USB (`PA11`/`PA12`) are both checked now.**
## `lib/stm32h563.nim`'s table used to leave out ADC and USB entirely, which
## made both of these silent to `validatePinmux` -- no `function =` at all,
## the same as an unmodelled peripheral. The table now carries `ADC1`/`ADC2`
## (bare, non-interface channels) and `USB` (bound to `usb2Interface()`'s
## `p`/`n`), sourced from ST's own `STM32H563ZITx.xml` pin database, so
## these three pins are stamped like any other alternate function here:
## `pin "PA3", AIN, kind = ptInput, function = "ADC1.in15"` -- **channel 15,
## not 3**; `docs/authoring.md`'s `"ADC1.in3"` example is illustrative of the
## mechanism, not this part's real map, and PA3's actual channel (confirmed
## against the datasheet XML) is `ADC1_INP15`. `PA11`/`PA12` carry
## `function = "USB.n"`/`"USB.p"` -- D-/D+ respectively, the datasheet's own
## `USB_DM`/`USB_DP` naming, matching the standard OTG_FS assignment already
## used across the STM32 family.
##
## **JTAG's `NTRST` is `PB4`**, the TAP's own dedicated reset pin -- distinct
## from `NRST`, which resets the whole MCU, stays a plain port of its own,
## and was already wired internally to `R_NRST`/`C_NRST`; `datalogger.nim`'s
## J-Link header wires its `nRESET` line to that same net a plain reset
## button would.
##
## **U1 carries ST's own IBIS model** (`stm32Ibis`), for the USB pair's
## signal integrity (`datalogger.nim`'s `diff_pair` role, read by `verax
## constraints`). The file is ST's, licensed, and not committed: unzip
## `stm32h562_563_573_lqfp144.ibs` from ST's STM32H5 IBIS package into
## `designs/lib/stm32/`. Without it `verax constraints` says so and `verax
## check` is unaffected. Its `[Pin]` rows are package pin numbers (`103`);
## U1's pins bind by the rows' `signal_name` (`PA11`). `PA11`/`PA12` are a
## `[Model Selector]`; `ibis_model` picks the full-speed USB PHY at 3.3 V.

import std/[os, tables]
import verax/contract/dsl
import verax/netlist/formats/spice as spiceFormat
import verax/netlist/interfaces/std
import verax/netlist/graph

import ../../lib/stm32h563
import ../../lib/crystal

const stm32Ibis* = currentSourcePath().parentDir / ".." / ".." / "lib" / "stm32" /
                   "stm32h562_563_573_lqfp144.ibs"
  ## ST's IBIS file for the LQFP-144 STM32H562/563/573 (U1 is the
  ## `STM32H563ZIT6`, the non-SMPS part).

proc tagDiffPairMember(n: Net, ifaceName, signal: string) =
  ## Marks a *pre-existing* net as a `diff_pair` interface member, the exact
  ## `iface.*` attrs `netlist/interfaces.addInterface` stamps on a signal it
  ## creates fresh -- `iface` itself cannot do this, since every one of its
  ## signals is a brand-new net. `DP`/`DM` below have to stay the literal
  ## nets this sheet already exposes as its own `DP`/`DM` ports (`subckt`'s
  ## port bracket only accepts a bound identifier or an `iface` modport
  ## view, never an indexed expression like `dp["p"]`), so tagging them in
  ## place -- rather than replacing them with a fresh interface and renaming
  ## the port -- is the only way to give this pass-through pair the same
  ## purple `wkInterface` drawing `usbMcu` gets, instead of a `bus` tag's
  ## blue. No `iface.dir`: `DP`/`DM` are genuinely bidirectional here, and
  ## `diffPairInterface()`'s `driver`/`receiver` modports both claim a fixed
  ## direction neither pin actually has, so this deliberately sets only the
  ## three membership attrs `bundlePlan` reads, exactly as `addInterface`
  ## does, and leaves direction to each pin's own stated `kind` untouched
  ## (`schematic/bundles.nim`'s "net attrs only, never a pin attr" doc bullet
  ## is what makes this safe -- direction is per-pin, membership is per-net).
  n.attrs["iface.instance"] = ifaceName
  n.attrs["iface.def"] = "diff_pair"
  n.attrs["iface.signal"] = signal

proc mcuSheet*(xtal = hse8MHz(), boardCurrentMa = 150.0): Netlist =
  ## `boardCurrentMa` sizes `VDD`'s `zin` stand-in the same way
  ## `designs/sensor_node.nim`'s own MCU pin does -- a rough current budget
  ## standing in for the part's real supply current, since no MCU model
  ## exists here to measure it.
  let vddZin = spiceValue(3.3 / (boardCurrentMa / 1000.0))

  result = subckt("MCU", [VDD, GND, i2c.controller, DP, DM, AIN, NRST, jtag.target]):
    net GND, kind = ntGround, name = "0"
    net VDD, kind = ntPower
    # `i2c`/`jtag` are declared interfaces exposed straight as this sheet's
    # own port groups (`i2c.controller`/`jtag.target` above), not plain nets
    # wrapped from outside -- U1 is genuinely the I2C1 controller and the
    # JTAG target, so those modports state a real fact rather than an
    # arbitrary pick, and `addPorts` names the resulting ports `i2c_sda`/
    # `i2c_scl`/`jtag_tck`/`jtag_tms`/`jtag_tdi`/`jtag_tdo`/`jtag_ntrst` --
    # `datalogger.nim`'s `instance Xmcu, ...` table keys on those. This also
    # gives U1's own SDA/SCL and TAP pins one merged pin on this sheet's own
    # box instead of seven separate ones (`bundlePlan` collapses a port-net
    # bundle with only one *other* entity, exactly like a two-entity one).
    iface i2c, i2cInterface()
    iface jtag, jtagInterface()
    net DP,  kind = ntSignal
    net DM,  kind = ntSignal
    net AIN, kind = ntSignal
    net NRST,  kind = ntSignal
    net xin,  kind = ntSignal
    net xout, kind = ntSignal
    # The series-termination-to-U1 half of the USB pair. Its own `iface`
    # (rather than plain nets, as this sheet used before) so this inner run
    # bundles on the MCU's own sub-sheet the same way the board sheet's `usb`
    # bundles `Xusbc`/`Xmcu` -- bare `diffPairInterface()`, not
    # `usb2Interface()`, for the reason stated where `datalogger.nim`
    # declares its own `usb`.
    iface usbMcu, diffPairInterface()

    component U1, kind = "mcu", partNumber = "STM32H563ZIT6":
      pin "VDD", VDD, kind = ptPower, zin = vddZin
      pin "VSS", GND, kind = ptGround
      pin "PB9", i2c["sda"], kind = ptInOut, function = "I2C1.sda"
      pin "PB8", i2c["scl"], kind = ptInOut, function = "I2C1.scl"
      pin "PA3", AIN, kind = ptInput, function = "ADC1.in15"
      pin "PA11", usbMcu["n"], kind = ptInOut, function = "USB.n"
      pin "PA12", usbMcu["p"], kind = ptInOut, function = "USB.p"
      pin "NRST",  NRST, kind = ptInput
      pin "BOOT0", GND,  kind = ptInput
      pin "PH0", xin,  kind = ptPassive
      pin "PH1", xout, kind = ptPassive
      pin "PA14", jtag["tck"],   kind = ptInput,  function = "JTAG.tck"
      pin "PA13", jtag["tms"],   kind = ptInput,  function = "JTAG.tms"
      pin "PA15", jtag["tdi"],   kind = ptInput,  function = "JTAG.tdi"
      pin "PB3",  jtag["tdo"],   kind = ptOutput, function = "JTAG.tdo"
      pin "PB4",  jtag["ntrst"], kind = ptInput,  function = "JTAG.ntrst"
      spec:
        ibis_file = stm32Ibis
        ibis_model = "io8usb_ft_phy_fs_3v3"

    component R_NRST, kind = "resistor", value = "10k":
      pin "1", VDD,  kind = ptPassive
      pin "2", NRST, kind = ptPassive
    component C_NRST, kind = "capacitor", value = "100n":
      pin "1", NRST, kind = ptPassive
      pin "2", GND,  kind = ptPassive
      spec:
        package = "0402"

    # Series termination at the MCU end of the USB FS pair -- the usual
    # placement in ST's own USB hardware/PCB guidelines application note.
    component R_DP, kind = "resistor", value = "27":
      pin "1", DP,          kind = ptPassive
      pin "2", usbMcu["p"], kind = ptPassive
    component R_DM, kind = "resistor", value = "27":
      pin "1", DM,          kind = ptPassive
      pin "2", usbMcu["n"], kind = ptPassive

    component C_VDD1, kind = "capacitor", value = "100n":
      pin "1", VDD, kind = ptPassive
      pin "2", GND, kind = ptPassive
      spec:
        package = "0402"
    component C_VDD2, kind = "capacitor", value = "1u":
      pin "1", VDD, kind = ptPassive
      pin "2", GND, kind = ptPassive
      spec:
        package = "0603"

    instance Xxtal, crystalNetwork(xtal), [xin, xout, GND]

  tagDiffPairMember(findNet(result, "DP"), "dp", "p")
  tagDiffPairMember(findNet(result, "DM"), "dp", "n")
