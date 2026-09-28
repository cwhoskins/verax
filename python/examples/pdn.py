"""Example: annotated components and the unit-safety/validation path.

The Python equivalent of the netlist half of `examples/design_contract.nim`
(the role/`require` half is Phase 2 of the study and is not built yet -- see
`docs/python_compatibility.md` §5/§8). This one shows what *is* built:
`spec()`-style annotations, the same registered-unit check the Nim DSL's
`spec:` block runs, and `verax check`'s own report over the plain netlist.

Run with:

    cd python && python3 examples/pdn.py
"""

import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from verax import Netlist
from verax.units import V, mohm, nH, nF

nl = Netlist("sensor_board")

vdd = nl.net("vdd", kind="power")
gnd = nl.net("0", kind="ground")
sda = nl.net("sda", kind="signal")
scl = nl.net("scl", kind="signal")

vdd.spec(voltage=V(3.3))

v1 = nl.component("V1", kind="voltage_source").spec(value="DC 3.3")
v1.connect("+", vdd, kind="power")
v1.connect("-", gnd, kind="ground")

# `spec()` here is the same registered-vocabulary check `spec:` runs in Nim,
# just raised at call time instead of at compile time -- see `esr = 20.mohm`
# in `examples/design_contract.nim` and its exact counterpart below.
c1 = nl.component("C1", kind="capacitor").spec(
    value="10u", package="tantalum", esr=mohm(100), esl=nH(3)
)
c1.connect("1", vdd, kind="passive")
c1.connect("2", gnd, kind="passive")

c2 = nl.component("C2", kind="capacitor").spec(value="100n", package="0402")
c2.connect("1", vdd, kind="passive")
c2.connect("2", gnd, kind="passive")

r1 = nl.component("R1", kind="resistor").spec(value="2.2k")
r1.connect("1", vdd, kind="passive")
r1.connect("2", sda, kind="passive")

r2 = nl.component("R2", kind="resistor").spec(value="2.2k")
r2.connect("1", vdd, kind="passive")
r2.connect("2", scl, kind="passive")

u1 = nl.component("U1", kind="mcu", part_number="STM32G0")
u1.connect("VDD", vdd, kind="power")
u1.connect("VSS", gnd, kind="ground")
u1.connect("SDA", sda, kind="inout")
u1.connect("SCL", scl, kind="inout")

print(f"Built netlist {nl.name!r} with {len(nl)} components.")
print("vdd voltage annotation:", vdd.annotation("voltage"), "V")
print("C1 ESR:", c1.annotation("esr"), "ohm")
print("C2 ESR:", c2.annotation("esr"), "(None -- not stated)")

print()
print("--- validation ---")
issues = nl.annotation_issues()
print("annotation issues:", len(issues))
for i in issues:
    print(" ", i)

print()
print("what a misspelling looks like -- the unvalidated `raw()` escape")
print("hatch, bypassing spec()'s check the way a hand-written attrs")
print("assignment or a file reader would:")
c1.raw("ESL", "3e-9")  # wrong case: 'ESL' shadows nothing, 'esl' is the key
for i in nl.annotation_issues():
    print(" ", i)

print()
print("what the unit check catches -- esr stated in farads instead of ohms:")
try:
    c2.spec(esr=nF(1))  # esr is registered in ohms; this is a Farads value
except Exception as e:
    print(" ", e)

print()
print("--- checking the claims ---")
# No role/require attached yet (Phase 2), so this reports the honest answer
# for a bare netlist: nothing was claimed, so nothing failed.
code = nl.check()
sys.exit(code)
