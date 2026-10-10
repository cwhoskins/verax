import std/[streams, strutils, tables, unittest]

import verax/netlist
import verax/ibis

const oneBuf = """
[IBIS Ver] 3.2
[Component] U_DEMO
[Pin] signal_name model_name
1 A drv
2 B drv
3 GND GND
[Model] drv
Model_type Output
[End Model]
[End]
"""

proc partWithPins(pins: openArray[string]): Netlist =
  ## A netlist holding one component `U1` with the given pin names.
  result = newNetlist("board")
  let n = addNet(result, newNet("n"))
  let c = addComponent(result, newComponent("U1", kind = "ic"))
  for p in pins:
    discard connect(c, p, n)

test "bindIbis accepts a component whose pins all match":
  let f = readIbis(newStringStream(oneBuf))
  let nl = partWithPins(["1", "2", "3"])
  let b = bindIbis(nl, "U1", f)
  check b.componentName == "U_DEMO"
  check b.modelFor("1").name == "drv"

test "bindIbis accepts a part declaring fewer pins than the file":
  let f = readIbis(newStringStream(oneBuf))
  let nl = partWithPins(["1", "2"])   # pin 3 (GND) not declared
  let b = bindIbis(nl, "U1", f)
  check b.pinMap.len == 2
  check b.modelFor("2").name == "drv"

const vendorBuf = """
[IBIS Ver] 4.2
[Component] U_VENDOR
[Pin] signal_name model_name
101 PA11 drv
102 PA12 drv
103 VDD POWER
104 VDD POWER
105 MIX drv
106 MIX GND
[Model] drv
Model_type Output
[End Model]
[End]
"""

test "bindIbis matches a netlist pin by signal_name when no pin name does":
  let f = readIbis(newStringStream(vendorBuf))
  let nl = partWithPins(["PA11", "PA12", "VDD", "MIX", "PH0"])
  let b = bindIbis(nl, "U1", f)
  check b.ibisPin("PA12") == "102"
  check b.netlistPin("101") == "PA11"
  check b.modelFor("PA11").name == "drv"
  # one signal on several rows with one model: matched (the first row)
  check b.ibisPin("VDD") == "103"
  # one signal on rows with different models: ambiguous, unmatched
  check "MIX" notin b.pinMap
  # no row at all: unmatched, looked up under its own name
  check "PH0" notin b.pinMap
  check b.ibisPin("PH0") == "PH0"

test "bindIbis prefers a pin-name match over a signal_name match":
  let f = readIbis(newStringStream(vendorBuf))
  let nl = partWithPins(["101", "PA11"])
  let b = bindIbis(nl, "U1", f)
  check b.ibisPin("101") == "101"
  check b.ibisPin("PA11") == "101"

test "bindIbis rejects a file with no row matching any netlist pin":
  let f = readIbis(newStringStream(oneBuf))
  let nl = partWithPins(["X", "Y"])
  try:
    discard bindIbis(nl, "U1", f)
    check false
  except IbisError as e:
    check "U_DEMO" in e.msg

test "bindIbis rejects an unknown designator":
  let f = readIbis(newStringStream(oneBuf))
  let nl = partWithPins(["1", "2", "3"])
  expect IbisError:
    discard bindIbis(nl, "U9", f)
