import std/[streams, strutils, unittest]

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

test "bindIbis names the first pin that has no netlist match":
  let f = readIbis(newStringStream(oneBuf))
  let nl = partWithPins(["1", "2"])   # missing pin 3
  try:
    discard bindIbis(nl, "U1", f)
    check false
  except IbisError as e:
    check "3" in e.msg

test "bindIbis rejects an unknown designator":
  let f = readIbis(newStringStream(oneBuf))
  let nl = partWithPins(["1", "2", "3"])
  expect IbisError:
    discard bindIbis(nl, "U9", f)
