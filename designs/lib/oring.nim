## Standing a priority power mux up as an ideal-diode OR for simulation.
##
## `designs/xbar_power.nim` merges two 5 V inlets -- PoE and USB-C -- with a
## TPS2116 priority mux. The real part is a pair of back-to-back FETs with a
## comparator deciding which one is on; none of that has a model here. What a
## `.op` actually needs from it is far less: a device that conducts from
## whichever input is higher to the output, blocks the other way, and has a
## small series resistance. That is an OR of two diodes, and this module
## swaps one in through `Component.simReplace` -- so the design netlist still
## carries the TPS2116 for the BoM and only the simulation copy sees the
## diodes.
##
## What the swap buys: one netlist answers every combination of inlets
## present, which is what makes `designs/xbar_switch.nim`'s "both plugged in
## is safe" and "nothing on the USB pin when PoE powers the board" checkable
## as ordinary `dc_voltage` claims.
##
## What it does not model: the mux's priority logic, its break-before-make
## switchover, reverse-leakage current, or the body-diode path during a
## fast transient. The reverse-blocking claim measures the diode, not the
## TPS2116 -- but it still fails loudly if the OR is wired backwards, which
## is the mistake worth catching. See the cannot-check list in
## `designs/xbar_switch.nim`.

import std/tables

import verax/contract/dsl
import verax/netlist/graph
import verax/netlist/types

import ./xbar_parts

proc buildOringMux(nl: Netlist, old: Component): Component {.nimcall.} =
  ## Replace the mux with `IN1 -> OUT` and `IN2 -> OUT` ideal diodes.
  let in1 = old.pins.getOrDefault("IN1")
  let in2 = old.pins.getOrDefault("IN2")
  let outp = old.pins.getOrDefault("OUT")
  if in1 == nil or in2 == nil or outp == nil or
     in1.net == nil or in2.net == nil or outp.net == nil:
    raise newException(NetlistError,
      old.designator & " needs IN1, IN2 and OUT pins to be stood up as an " &
      "ideal-diode OR")
  let in1Net = in1.net
  let in2Net = in2.net
  let outNet = outp.net
  let des = old.designator

  removeComponent(nl, des)

  # The `.MODEL` card, added here rather than in the design file: a build
  # proc gets the materialized clone, and `Netlist.models` survives every
  # transform between here and the deck.
  setModel(nl, dOring, dOringCard)

  for (sfx, src) in [("A", in1Net), ("B", in2Net)]:
    let dd = addComponent(nl, newComponent("D" & des & "_" & sfx,
                                           kind = "diode"))
    dd.attrs["value"] = dOring
    discard connect(dd, "A", src, ptPassive)
    discard connect(dd, "K", outNet, ptPassive)

  nil

proc useIdealDiodeOr*(d: Design, designator: string) =
  ## Attach the ideal-diode-OR stand-in to the named priority mux. Call it
  ## after the `design(...)` block, by designator -- the DSL's `let` bindings
  ## do not leave the block.
  let c = findComponent(d.netlist, designator)
  if c == nil:
    raise newException(NetlistError,
      "no such component: " & designator & " (attaching the OR-ing model)")
  c.simReplace = newSimReplacement(buildOringMux)
