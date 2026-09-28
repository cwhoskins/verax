"""Example: stating what a design *is* and what it must *do*, from Python.

The Python sibling of `examples/design_contract.nim` -- same board, same two
roles, same requirement, same two intentional i2c failures -- built with
`verax.contract.Design` instead of the `design(...)` macro. Phase 2 of
`docs/python_compatibility.md`'s §8 ordering: built-in role instantiation and
`require` against a built-in evaluator, with no callback boundary.

Run with:

    cd python && python3 examples/design_contract.py
"""

import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from verax.contract import Design
from verax.units import V, Hz, kHz, MHz, mohm, nH, pct

d = Design("sensor_board")

vdd = d.net("vdd", kind="power")
gnd = d.net("0", kind="ground")
sda = d.net("sda", kind="signal")
scl = d.net("scl", kind="signal")

v1 = d.component("V1", kind="voltage_source").spec(value="DC 3.3")
v1.connect("+", vdd, kind="power")
v1.connect("-", gnd, kind="ground")

c1 = d.component("C1", kind="capacitor").spec(
    value="10u", package="tantalum", esr=mohm(100), esl=nH(3)
)
c1.connect("1", vdd, kind="passive")
c1.connect("2", gnd, kind="passive")

c2 = d.component("C2", kind="capacitor").spec(value="100n", package="0402")
c2.connect("1", vdd, kind="passive")
c2.connect("2", gnd, kind="passive")

r1 = d.component("R1", kind="resistor").spec(value="2.2k")
r1.connect("1", vdd, kind="passive")
r1.connect("2", sda, kind="passive")
r2 = d.component("R2", kind="resistor").spec(value="2.2k")
r2.connect("1", vdd, kind="passive")
r2.connect("2", scl, kind="passive")

u1 = d.component("U1", kind="mcu", part_number="STM32G0")
u1.connect("VDD", vdd, kind="power")
u1.connect("VSS", gnd, kind="ground")
u1.connect("SDA", sda, kind="inout")
u1.connect("SCL", scl, kind="inout")

# A role is a parameterized bundle of assertions. `power_rail` also *writes*
# its voltage onto the net, which is how `spice/isolate` later terminates the
# rail without knowing that roles exist.
d.role("power_rail", "vdd_rail", rail=vdd, voltage=V(3.3), band=pct(5))
d.role("i2c", "i2c0", sda=sda, scl=scl, pullupRail=vdd, controller=u1,
       frequency=kHz(400))

# A requirement of your own, alongside the ones the roles imply.
d.require_max("z_max_in_band", vdd, hi=mohm(100), f_from=Hz(1e5), f_to=Hz(1e8),
              id="REQ-PDN-001",
              because="keeps rail droop under 10 mV at the MCU's 100 mA di/dt")

print(d.explain())

print()
print("--- what the roles wrote onto the netlist ---")
print("vdd voltage annotation:", vdd.annotation("voltage"), "V")
print("sda belongs to:", sda.roles())
print("C1 ESR:", c1.annotation("esr"), "ohm")
print("C2 ESR:", c2.annotation("esr"), "(None -- not stated)")

print()
print("--- validation ---")
issues = d.netlist.annotation_issues()
print("annotation issues:", len(issues))
for i in issues:
    print(" ", i)

print()
print("what a misspelling looks like when it bypasses spec()'s check:")
c1.raw("ESL", "3e-9")  # wrong case: 'ESL' shadows nothing, 'esl' is the key
for i in d.netlist.annotation_issues():
    print(" ", i)

print()
print("--- checking the claims ---")
# Four answers, not two: pass, fail, could-not-check and nothing-can-check.
#
# The two i2c failures below are real: 2.2k against an assumed 20 pF of bus
# capacitance puts the RC corner at 3.6 MHz, under the ten-times-clock a
# 400 kHz bus wants. The assumption is reported rather than buried -- the
# answer rests on a number the netlist does not contain.
sys.exit(d.check())
