## Example: is this board's decoupling adequate?
##
## Sweeps the impedance of a 3V3 rail against a 100 mohm target, from a
## netlist that says nothing about impedance at all -- only which capacitors
## are on the rail, and their package.
##
## Run with:
##   nim c -r --path:./src examples/pdn_sweep.nim

import std/tables

import nimcir/netlist/dsl
import nimcir/analysis/pdn

# Three-tier decoupling: a tantalum bulk cap, a mid-value ceramic, and a
# small ceramic near the pin. Only `package` is annotated, so the analysis
# fills in ESR/ESL from its package table and says so in the report.
let board = netlist("mcu_board"):
  net vdd, kind = ntPower, voltage = "3.3"
  net gnd, kind = ntGround, name = "0"
  net io, kind = ntSignal

  component U1, kind = "mcu", partNumber = "STM32G0":
    pin "VDD", vdd, kind = ptPower
    pin "VSS", gnd, kind = ptGround
    pin "PA0", io, kind = ptOutput

  component C1, kind = "capacitor", value = "47u", package = "tantalum":
    pin "1", vdd, kind = ptPassive
    pin "2", gnd, kind = ptPassive
  component C2, kind = "capacitor", value = "1u", package = "0805":
    pin "1", vdd, kind = ptPassive
    pin "2", gnd, kind = ptPassive
  component C3, kind = "capacitor", value = "100n", package = "0402":
    pin "1", vdd, kind = ptPassive
    pin "2", gnd, kind = ptPassive

var spec = defaultPdnSpec()
spec.targetZ = 0.1          # 100 mohm
spec.ptsPerDecade = 50

let report = analyzePdn(board, "vdd", spec = spec)
echo report

echo ""
echo "--- impedance vs frequency ---"
let f = report.raw.freq()
let z = report.raw.mag("v(vdd)")
for i in 0 ..< f.len:
  if i mod 25 == 0:
    echo "  ", eng(f[i], "Hz"), "\t", eng(z[i], "ohm")

echo ""
echo "Try deleting C2 and re-running: with a 47uF tantalum and a 100nF"
echo "ceramic and nothing between them, the anti-resonant peak gets worse."
