## Signal integrity on a routed board: an MCU's SPI clock and data into two
## flash parts, checked by the native SI engine (no ngspice).
##
##   verax check designs/si_spi.nim                  # against the shipped board
##   verax check designs/si_spi.nim --board=other.kicad_pcb
##   verax constraints designs/si_spi.nim --dru=si_spi.kicad_dru
##
## Each part names its IBIS model (`ibis_file`); `si_net` names the net, the
## driving pin and the receivers. The claims are the receivers' own IBIS
## thresholds (always) plus a flight-time budget and a UI to settle in.
## `designs/si_spi/si_spi.kicad_pcb` is a hand-written 4-layer board: both
## nets on F.Cu over a GND plane on In1.Cu, SCK point-to-point (60 mm),
## MOSI a Y to both flashes. The IBIS files are synthetic (linear tables)
## so the numbers are easy to reason about; real vendor files drop in the
## same way.
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

  role "si_net", sck_si, net = sck, driver = U1.pins["1"], rx = U2.pins["1"],
    max_flight_time = 1.5.ns, ui = 20.ns
  role "si_net", mosi_si, net = mosi, driver = U1.pins["2"], rx = U2.pins["2"],
    rx2 = U3.pins["2"], max_flight_time = 1.5.ns, ui = 20.ns

var args = commandLineParams()
var hasBoard = false
for a in args:
  if a.startsWith("--board="): hasBoard = true
if not hasBoard: args.add "--board=" & here / "si_spi" / "si_spi.kicad_pcb"
quit(verifyMain(d, args))
