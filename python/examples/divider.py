"""Example: build a netlist from Python, then write it out as a SPICE deck.

The Python equivalent of `examples/divider.nim`. Run with:

    cd python && python3 examples/divider.py

(needs `verax_py.so` built alongside this directory -- see `python/README.md`)
"""

import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from verax import Netlist

nl = Netlist("divider")

vin = nl.net("vin", kind="signal")
vout = nl.net("vout", kind="signal")
gnd = nl.net("0", kind="ground")

r1 = nl.component("R1", kind="resistor", part_number="RC0603").spec(value="1k")
r1.connect("1", vin, kind="passive")
r1.connect("2", vout, kind="passive")

r2 = nl.component("R2", kind="resistor", part_number="RC0603").spec(value="1k")
r2.connect("1", vout, kind="passive")
r2.connect("2", gnd, kind="passive")

print(f"Built netlist {nl.name!r} with {len(nl)} components.")
print("R1 value annotation:", r1.text_annotation("value"))
print()
print("--- as SPICE ---")
print(nl.to_spice())
