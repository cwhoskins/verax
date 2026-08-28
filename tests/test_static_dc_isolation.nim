## `dc_path_exists` -- the static isolation-barrier evaluator.

import std/[tables, unittest]

import nimcir/netlist
import nimcir/contract
import nimcir/analysis/evaluators/contract_eval

proc barrierDesign(bridge: bool): Design =
  let nl = newNetlist("t")
  discard addNet(nl, newNet("0", ntGround))
  let a = addNet(nl, newNet("a", ntSignal))
  let b = addNet(nl, newNet("b", ntSignal))
  let x = addComponent(nl, newComponent("T1", kind = "transformer"))
  discard connect(x, "P1", a, ptPassive)
  discard connect(x, "P2", nl.nets["0"], ptPassive)
  discard connect(x, "S1", b, ptPassive)
  discard connect(x, "S2", nl.nets["0"], ptPassive)
  x.attrs["lpri"] = "1e-3"
  if bridge:
    let r = addComponent(nl, newComponent("RX", kind = "resistor"))
    r.attrs["value"] = "1k"
    discard connect(r, "1", a, ptPassive)
    discard connect(r, "2", b, ptPassive)
  result = newDesign(nl)
  result.assertThat(Assertion(
    id: "ISO",
    subjects: @[Subject(kind: skNet, name: "a"), Subject(kind: skNet, name: "b")],
    quantity: "dc_path_exists",
    expect: nominal(0.0, absTol = 0.5), unit: "", severity: sevError,
    origin: "t"))

test "a transformer between two nets is a barrier -- dc_path_exists is 0":
  let d = barrierDesign(bridge = false)
  let r = evaluate(d, allCapabilities)[0]
  check r.status == esPass
  check r.value == 0.0

test "a resistor bridging the barrier makes the claim fail":
  let d = barrierDesign(bridge = true)
  let r = evaluate(d, allCapabilities)[0]
  check r.status == esFail
  check r.value == 1.0

test "dc_path_exists needs two nets that exist":
  let d = barrierDesign(bridge = false)
  d.assertThat(Assertion(
    id: "BAD",
    subjects: @[Subject(kind: skNet, name: "a"),
               Subject(kind: skNet, name: "nope")],
    quantity: "dc_path_exists",
    expect: nominal(0.0, absTol = 0.5), unit: "", severity: sevError,
    origin: "t"))
  for r in evaluate(d, allCapabilities):
    if r.assertion.id == "BAD":
      check r.status == esNotEvaluable
