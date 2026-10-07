## The `safe_default` role from `designs/lib/xbar_parts.nim`: an RF switch
## enable sits low at power-up. Pins that a role registered from a
## design-side module expands like a built-in.

import std/[math, tables, unittest]

import verax/netlist
import verax/contract
import verax/units

import "../designs/lib/xbar_parts"

proc board(): Design =
  let nl = newNetlist("b")
  discard addNet(nl, newNet("0", ntGround))
  discard addNet(nl, newNet("en", ntSignal))
  newDesign(nl)

proc net(name: string): Subject = Subject(kind: skNet, name: name)

test "safe_default is registered and describes its part":
  check isRole("safe_default")
  let def = roleDef("safe_default")
  check def.parts.len == 1
  check def.parts[0].name == "control"

test "safe_default expands to one dc_voltage upper bound at fraction*rail":
  let d = board()
  discard d.addRole("safe_default", "sw1",
                    {"control": net("en")},
                    {"rail": "3.297", "maxFraction": "0.1"})
  let a = d.expandAll()
  check a.len == 1
  check a[0].quantity == "dc_voltage"
  check a[0].expect.kind == ekMax
  check abs(a[0].expect.hi - 0.3297) < 1e-6
  check a[0].subjects == @[net("en")]
  check a[0].origin == "sw1"

test "the defaults are 3.3 V and 10%":
  let d = board()
  discard d.addRole("safe_default", "sw2", {"control": net("en")})
  let a = d.expandAll()
  check abs(a[0].expect.hi - 0.33) < 1e-6

test "controlPulldowns adds one resistor to ground per named net":
  let nl = newNetlist("p")
  discard addNet(nl, newNet("0", ntGround))
  discard addNet(nl, newNet("a", ntSignal))
  discard addNet(nl, newNet("b", ntSignal))
  controlPulldowns(nl, ["a", "b"], "100k")
  check nl.components.len == 2
  for _, c in nl.components:
    check c.kind == "resistor"
    check c.attrs["value"] == "100k"
