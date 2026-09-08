## Eight 74HC595 shift registers in an SPI daisy chain.
##
## This is a structural worked design for the **subsheet-array collapse**: one
## `SPI_DEV` sheet (`designs/lib/spi_dev.nim`) is instantiated eight times and
## chained `out(i) -> in(i+1)` on all three signals -- serial data through the
## registers, and the shift/latch clocks through pass-through straps on each
## sheet. Every port therefore classifies as a daisy chain, so the schematic
## collapses the eight boxes to one `SPI_DEV x8` badged block with three
## recirculation arcs; `vdd`/`gnd` read as common (a bus-bar tick).
##
## Two authoring choices are deliberate:
##
##  * **No `bus` statement for the chain links.** A `bus` stamps `bus.name` on
##    every member net, and `bundlePlan` would then claim all nine across nine
##    entities as grouped net-label tags -- which downgrades every chained
##    port to "bundled" and defeats the collapse. The links are plain `net`s.
##  * **The MCU carries no `partNumber`**, so `validatePinmux` finds no
##    alternate-function table and does not reject the bare pin names.
##
## The one simulated claim walks the SCLK strap end to end: `dc_path_exists`
## crosses each `SPI_DEV` through its internal strap net, so a missing strap
## port on any sheet breaks the path -- which is exactly the continuity the
## recirculation arc depicts.

import verax/contract/dsl
import verax/verify

import ./lib/spi_dev

let d = design("spi_daisy_chain"):
  net gnd, kind = ntGround, name = "0", global = true
  net vdd, kind = ntPower:
    spec:
      voltage = 3.3.V

  # The data chain: din -> X1 ... X8 -> dout (back to the MCU's MISO).
  net din, kind = ntSignal
  net d1, kind = ntSignal
  net d2, kind = ntSignal
  net d3, kind = ntSignal
  net d4, kind = ntSignal
  net d5, kind = ntSignal
  net d6, kind = ntSignal
  net d7, kind = ntSignal
  net dout, kind = ntSignal

  # The SCLK strap chain: sclk_head -> X1 ... X8 -> sclk_tail (terminated).
  net sclk_head, kind = ntSignal
  net sc1, kind = ntSignal
  net sc2, kind = ntSignal
  net sc3, kind = ntSignal
  net sc4, kind = ntSignal
  net sc5, kind = ntSignal
  net sc6, kind = ntSignal
  net sc7, kind = ntSignal
  net sclk_tail, kind = ntSignal

  # The latch (RCLK) strap chain: cs_head -> X1 ... X8 -> cs_tail (terminated).
  net cs_head, kind = ntSignal
  net cl1, kind = ntSignal
  net cl2, kind = ntSignal
  net cl3, kind = ntSignal
  net cl4, kind = ntSignal
  net cl5, kind = ntSignal
  net cl6, kind = ntSignal
  net cl7, kind = ntSignal
  net cs_tail, kind = ntSignal

  component U1, kind = "mcu":
    pin "VDD", vdd, kind = ptPower
    pin "VSS", gnd, kind = ptGround
    pin "MOSI", din, kind = ptOutput
    pin "SCK", sclk_head, kind = ptOutput
    pin "NSS", cs_head, kind = ptOutput
    pin "MISO", dout, kind = ptInput

  # Port order: vdd, gnd, sdi, sdo, sclk_in, sclk_out, cs_in, cs_out.
  instance X1, spiDev(), [vdd, gnd, din, d1, sclk_head, sc1, cs_head, cl1]
  instance X2, spiDev(), [vdd, gnd, d1, d2, sc1, sc2, cl1, cl2]
  instance X3, spiDev(), [vdd, gnd, d2, d3, sc2, sc3, cl2, cl3]
  instance X4, spiDev(), [vdd, gnd, d3, d4, sc3, sc4, cl3, cl4]
  instance X5, spiDev(), [vdd, gnd, d4, d5, sc4, sc5, cl4, cl5]
  instance X6, spiDev(), [vdd, gnd, d5, d6, sc5, sc6, cl5, cl6]
  instance X7, spiDev(), [vdd, gnd, d6, d7, sc6, sc7, cl6, cl7]
  instance X8, spiDev(), [vdd, gnd, d7, dout, sc7, sclk_tail, cl7, cs_tail]

  # Series terminations on the two strap tails, so every chain end is a real
  # wire rather than a dangling stub.
  component R1, kind = "resistor", value = "100":
    pin "1", sclk_tail, kind = ptPassive
    pin "2", gnd, kind = ptGround
  component R2, kind = "resistor", value = "100":
    pin "1", cs_tail, kind = ptPassive
    pin "2", gnd, kind = ptGround

  # The SCLK strap must be continuous through every sheet of the chain: a
  # missing strap port on any SPI_DEV breaks this path -- the continuity the
  # collapsed schematic's recirculation arc depicts.
  require dc_path_exists(sclk_head, sclk_tail) == 1

quit(verifyMain(d))
