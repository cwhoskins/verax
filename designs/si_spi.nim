## Signal integrity on a routed board: an MCU's SPI clock and data into two
## flash parts, checked by the native SI engine (no ngspice).
##
##   verax check designs/si_spi.nim                  # against the shipped board
##   verax check designs/si_spi.nim --board=other.kicad_pcb
##   verax constraints designs/si_spi.nim --dru=si_spi.kicad_dru
##
## Each part names its IBIS model (`ibis_file`); `si_net` names the net, the
## driving pin and the receivers. The claims are the receivers' own IBIS
## thresholds (always) plus a flight-time budget, a UI to settle in, the
## receivers' overshoot/undershoot ratings, and a PRBS7 eye on MOSI.
## `designs/si_spi/si_spi.kicad_pcb` is a hand-written 4-layer board: both
## nets on F.Cu over a GND plane on In1.Cu, SCK point-to-point (60 mm),
## MOSI a Y to both flashes. The IBIS files are synthetic (linear tables)
## so the numbers are easy to reason about; real vendor files drop in the
## same way.
##
## The bus runs at 10 MHz (`ui = 100.ns`). At 50 MHz (`ui = 20.ns`) MOSI
## fails its settle claims on this board: the unterminated Y to the two
## flashes rings at ~690 MHz, +-0.2 V, and is within 2 % of its level only
## ~31 ns after the edge (the exact settle check of the plan's stage 7).
## A source resistor on MOSI, or one flash, would fix it; SCK
## (point-to-point) settles in ~4 ns either way.
##
## With no `--board=` given this design passes its own board, so `nimble
## verify` checks the routed result. `verax constraints` ignores the board
## and derives the routing rules (max length, vias, termination, stubs)
## from a template stack-up instead.

import std/[os, strutils, tables]
import verax/contract/dsl
import verax/verify

const here = currentSourcePath().parentDir

let d = design("si_spi"):
  net gnd, kind = ntGround, name = "GND"
  net vcc, kind = ntPower, name = "VCC":
    spec:
      voltage = 3.3.V
  net sck, kind = ntSignal, name = "SCK"
  net mosi, kind = ntSignal, name = "MOSI"

  component U1, kind = "ic", description = "MCU (SPI controller)":
    pin "1", sck, kind = ptOutput
    pin "2", mosi, kind = ptOutput
    pin "3", vcc, kind = ptPower
    pin "4", gnd, kind = ptGround
    spec:
      ibis_file = here / "si_spi" / "demo_mcu.ibs"

  component U2, kind = "ic", description = "SPI flash 0":
    pin "1", sck, kind = ptInput
    pin "2", mosi, kind = ptInput
    pin "3", vcc, kind = ptPower
    pin "4", gnd, kind = ptGround
    spec:
      ibis_file = here / "si_spi" / "demo_flash.ibs"
      ibis_component = "DEMO_FLASH"

  component U3, kind = "ic", description = "SPI flash 1":
    pin "2", mosi, kind = ptInput
    pin "3", vcc, kind = ptPower
    pin "4", gnd, kind = ptGround
    spec:
      ibis_file = here / "si_spi" / "demo_flash.ibs"
      ibis_component = "DEMO_FLASH_SO8B"

  component V1, kind = "voltage_source", value = "DC 3.3":
    pin "+", vcc, kind = ptPower
    pin "-", gnd, kind = ptGround

  # Overshoot and undershoot are the receivers' absolute-maximum ratings,
  # not signal quality: a flash input is typically rated to VSS - 0.5 V and
  # VCC + 0.5 V at DC and to 1.5 V past either rail for under 20 ns, which
  # is the regime a few nanoseconds of ringing is in. The unterminated SCK
  # is the one that tests it -- 60 mm point-to-point into a high-impedance
  # input rings 1.01 V below ground on its falling edge, 2/3 of the budget,
  # where MOSI's Y, loaded twice, only reaches 0.59 V.
  role "si_net", sck_si, net = sck, driver = U1.pins["1"], rx = U2.pins["1"],
    max_flight_time = 1.5.ns, ui = 100.ns,
    max_overshoot = 1.5.V, max_undershoot = 1.5.V

  # MOSI carries data, so it is also asked for an eye: 127 bits of PRBS7 at
  # the 100 ns UI folded on top of each other, which is what catches
  # intersymbol interference a single edge cannot -- a long run of ones
  # followed by a lone zero lands differently from an isolated edge when
  # the Y's ringing has not died by the next bit. The width wanted is 80% of
  # the UI, which leaves the flash's setup and hold windows (a few ns each
  # at this rate) plus the controller's own clock-to-out skew; the height
  # is 2 V of the 3.3 V swing, the CMOS thresholds' gap with room. At 10 MHz
  # the eye is open almost the whole rail and UI (3.30 V, 98.1 ns).
  role "si_net", mosi_si, net = mosi, driver = U1.pins["2"], rx = U2.pins["2"],
    rx2 = U3.pins["2"], max_flight_time = 1.5.ns, ui = 100.ns,
    max_overshoot = 1.5.V, max_undershoot = 1.5.V,
    min_eye_height = 2.0.V, min_eye_width = 80.ns

var args = commandLineParams()
var hasBoard = false
for a in args:
  if a.startsWith("--board="): hasBoard = true
if not hasBoard: args.add "--board=" & here / "si_spi" / "si_spi.kicad_pcb"
quit(verifyMain(d, args))
