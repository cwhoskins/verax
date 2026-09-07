## Example: build a netlist with the `verax/netlist/dsl` macro DSL, then
## write it out as a SPICE deck.
##
## Run with:
##   nim c -r --path:./src examples/divider.nim

import std/[streams, tables]

import verax/netlist/dsl
import verax/netlist/formats/spice

let nl = netlist("divider"):
  net vin, kind = ntSignal
  net vout, kind = ntSignal
  net gnd, kind = ntGround, name = "0"

  component R1, kind = "resistor", partNumber = "RC0603", value = "1k":
    pin "1", vin, kind = ptPassive
    pin "2", vout, kind = ptPassive

  component R2, kind = "resistor", partNumber = "RC0603", value = "1k":
    pin "1", vout, kind = ptPassive
    pin "2", gnd, kind = ptPassive

echo "Built netlist '", nl.name, "' with ", nl.components.len, " components and ",
     nl.nets.len, " nets."
echo "R1 value attr: ", nl.components["R1"].attrs["value"]
echo ""
echo "--- as SPICE ---"
let outStream = newStringStream()
writeNetlist(nl, outStream)
echo outStream.data
