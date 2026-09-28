"""Example: a Python-authored custom role and evaluator, round-tripped
through `plan`/`evaluate` -- §5/§8 phase 3 of `docs/python_compatibility.md`,
the study's own hardest question, now proven rather than just argued.

Defines a `fanout` role (`apply` writes the rail's voltage the way
`power_rail` does; `expand` claims a minimum `net_fanout`) and the
`net_fanout` evaluator behind it (a plain graph walk: how many components
have a pin on the net) -- neither exists in `verax/contract`'s own registry;
both are registered here, from Python, and then checked by the exact same
`Design.check()` a built-in role goes through.

Run with:

    cd python && python3 examples/custom_phase3.py
"""

import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from verax.contract import Design
from verax.custom import define_evaluator, define_role, at_least, measurement, find_net
from verax.units import V
import verax_py as _vx

# --- the evaluator: a graph walk, no simulator needed ----------------------
#
# `run` receives every claim sharing one setup (here, one per net, since
# `net_fanout` is measured per-net and no custom `setup_key` was given) and
# must return one result per assertion, in order. `measurement` runs the
# exact `Expectation.satisfies` comparison every built-in evaluator's
# verdict rests on, so this claim's pass/fail line is not a second,
# hand-rolled copy of that rule.


def run_fanout(ctx, batch):
    results = []
    for a in batch:
        net_subject = a.subjects[0]
        name = _vx.subject_name(net_subject)
        results.append(measurement(a, float(_fanout(ctx, name)), ""))
    return results


def _fanout(ctx, net_name: str) -> int:
    # `find_net`/`Net` do not expose "how many components connect here" yet
    # (Phase 1/2 wrap `graph.nim`'s mutators, not every reader), so this
    # walks the rendered SPICE deck instead -- crude, but it needs no new
    # Nim binding to prove the callback boundary, which is the point of this
    # example. A real evaluator would add the accessor it actually needs.
    deck = ctx.design.netlist.to_spice()
    return sum(1 for line in deck.splitlines()
               if line.split() and net_name in line.split()[1:])


define_evaluator("py.net_fanout", ["net_fanout"], run=run_fanout)

# --- the role: apply writes annotations, expand claims -----------------


def apply_fanout(inst, nl_handle):
    rail = inst.bindings["rail"]
    net = find_net(nl_handle, _vx.subject_name(rail))
    if inst.has_param("voltage"):
        net.spec(voltage=inst.param_float("voltage"))


def expand_fanout(inst):
    rail = inst.bindings["rail"]
    return [at_least("net_fanout", rail, lo=inst.param_float("min_fanout", 1.0),
                      id=inst.assertion_id("fanout"),
                      because="a rail nothing connects to is a design error, "
                              "not a circuit")]


define_role("py.fanout", expand=expand_fanout, apply=apply_fanout,
            parts=[{"name": "rail", "kind": "net"}],
            params=[{"key": "min_fanout"}, {"key": "voltage"}])

# --- the design -----------------------------------------------------------

d = Design("fanout_demo")
vdd = d.net("vdd", kind="power")
gnd = d.net("0", kind="ground")
sda = d.net("sda")  # deliberately left with only one component on it

r1 = d.component("R1", kind="resistor").spec(value="1k")
r1.connect("1", vdd)
r1.connect("2", gnd)
r2 = d.component("R2", kind="resistor").spec(value="2k")
r2.connect("1", vdd)
r2.connect("2", gnd)
r3 = d.component("R3", kind="resistor").spec(value="4.7k")
r3.connect("1", sda)
r3.connect("2", gnd)

d.role("py.fanout", "vdd_fanout", rail=vdd, min_fanout=2.0, voltage=V(3.3))
# Fails on purpose: sda has one part on it besides the pull-up, not three.
d.role("py.fanout", "sda_fanout", rail=sda, min_fanout=3.0)

print(d.explain())
print()
print("vdd voltage, written by this role's own apply():", vdd.annotation("voltage"))
print()
sys.exit(d.check())
