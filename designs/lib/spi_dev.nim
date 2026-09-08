## One 74HC595 shift-register sheet in an SPI daisy chain.
##
## `sdi`/`sdo` are the real chain -- serial data in, cascade out. `sclk` and
## `cs` (the shift and latch clocks) are **straps**: the same internal net
## reaches the sheet boundary twice, once as `<name>_in` and once as
## `<name>_out`, which is what a module with an in-header and an out-header
## physically is. The parent then wires `out(i)` to `in(i+1)` for all three
## signals, so every one classifies as a daisy chain and the whole array
## collapses to one box with three recirculation arcs.
##
## A strap needs two port names bound to one `Net`, which the `subckt` macro
## cannot express (it derives one port name per identifier), so the straps
## are added with `graph.addPort` after the block -- legal because `nl.ports`
## is an `OrderedTable[string, Net]` and two keys may share one value.
##
## On the parent sheet the eight instances collapse to one `SPI_DEV x8` box and
## the strap ports read as a recirculation arc. On this sheet the strap is one
## node, so the schematic draws it as a single bidirectional `sclk` / `cs`
## pennant rather than an unconnected `_in` beside a wrong-way `_out`.

import std/tables
import verax/netlist/dsl
import verax/netlist/graph

proc spiDev*(): Netlist =
  result = block:
    let t = subckt("SPI_DEV", [vdd, gnd, sdi, sdo]):
      net gnd, kind = ntGround, name = "0", global = true
      net vdd, kind = ntPower
      net sclk, kind = ntSignal
      net cs, kind = ntSignal
      net sdi, kind = ntSignal
      net sdo, kind = ntSignal
      component U1, kind = "shift_register", partNumber = "74HC595":
        pin "VCC", vdd, kind = ptPower
        pin "GND", gnd, kind = ptGround
        pin "SRCLK", sclk, kind = ptInput
        pin "RCLK", cs, kind = ptInput
        pin "SER", sdi, kind = ptInput
        pin "QH_S", sdo, kind = ptOutput
    addPort(t, "sclk_in", t.nets["sclk"])
    addPort(t, "sclk_out", t.nets["sclk"])
    addPort(t, "cs_in", t.nets["cs"])
    addPort(t, "cs_out", t.nets["cs"])
    t
