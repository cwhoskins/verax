## `dc_path_exists` -- the static isolation-barrier evaluator.

import std/[tables, unittest]

import verax/netlist
import verax/netlist/traversal
import verax/contract
import verax/analysis/evaluators/contract_eval

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

# --- a declared `traverse:` spec, beside an undeclared barrier ------------

proc switchAndTransformerDesign(): Design =
  ## An ADG904-shaped switch declaring `RFC <-> RF1`, beside an undeclared
  ## transformer: `dcConnected` resolves per component, so one part's
  ## declaration doesn't affect its neighbour.
  let nl = newNetlist("t")
  discard addNet(nl, newNet("0", ntGround))
  let rfc = addNet(nl, newNet("rfc", ntSignal))
  let rf1 = addNet(nl, newNet("rf1", ntSignal))
  let sw = addComponent(nl, newComponent("SW1", kind = "rf_switch"))
  discard connect(sw, "RFC", rfc, ptPassive)
  discard connect(sw, "RF1", rf1, ptPassive)
  discard connect(sw, "EN", nl.nets["0"], ptInput)
  addTraversalEdge(sw, "RFC", "RF1")

  let p = addNet(nl, newNet("p", ntSignal))
  let s = addNet(nl, newNet("s", ntSignal))
  let x = addComponent(nl, newComponent("T1", kind = "transformer"))
  discard connect(x, "P1", p, ptPassive)
  discard connect(x, "P2", nl.nets["0"], ptPassive)
  discard connect(x, "S1", s, ptPassive)
  discard connect(x, "S2", nl.nets["0"], ptPassive)
  x.attrs["lpri"] = "1e-3"

  result = newDesign(nl)
  result.assertThat(Assertion(
    id: "SW", subjects: @[Subject(kind: skNet, name: "rfc"),
                          Subject(kind: skNet, name: "rf1")],
    quantity: "dc_path_exists",
    expect: nominal(1.0, absTol = 0.5), unit: "", severity: sevError,
    origin: "t"))
  result.assertThat(Assertion(
    id: "XFMR", subjects: @[Subject(kind: skNet, name: "p"),
                            Subject(kind: skNet, name: "s")],
    quantity: "dc_path_exists",
    expect: nominal(0.0, absTol = 0.5), unit: "", severity: sevError,
    origin: "t"))

test "a declared switch is crossed while an undeclared transformer beside it stays a barrier":
  let d = switchAndTransformerDesign()
  var byId: Table[string, float]
  for r in evaluate(d, allCapabilities): byId[r.assertion.id] = r.value
  check byId["SW"] == 1.0     # RFC <-> RF1 declared: crossed
  check byId["XFMR"] == 0.0   # T1 declares nothing: still a barrier

test "the same switch, undeclared, is not crossed -- dc_path_exists is 0":
  let nl = newNetlist("t")
  discard addNet(nl, newNet("0", ntGround))
  let rfc = addNet(nl, newNet("rfc", ntSignal))
  let rf1 = addNet(nl, newNet("rf1", ntSignal))
  let sw = addComponent(nl, newComponent("SW1", kind = "rf_switch"))
  discard connect(sw, "RFC", rfc, ptPassive)
  discard connect(sw, "RF1", rf1, ptPassive)
  discard connect(sw, "EN", nl.nets["0"], ptInput)
  let d = newDesign(nl)
  d.assertThat(Assertion(
    id: "SW", subjects: @[Subject(kind: skNet, name: "rfc"),
                          Subject(kind: skNet, name: "rf1")],
    quantity: "dc_path_exists",
    expect: nominal(0.0, absTol = 0.5), unit: "", severity: sevError,
    origin: "t"))
  let r = evaluate(d, allCapabilities)[0]
  check r.status == esPass
  check r.value == 0.0

# --- a resistor overridden to `none` ---------------------------------------

proc resistorDesign(declareNone: bool): Design =
  let nl = newNetlist("t")
  let a = addNet(nl, newNet("a", ntSignal))
  let b = addNet(nl, newNet("b", ntSignal))
  let r = addComponent(nl, newComponent("R1", kind = "resistor"))
  r.attrs["value"] = "1k"
  discard connect(r, "1", a, ptPassive)
  discard connect(r, "2", b, ptPassive)
  if declareNone: setTraversalMode(r, tmNone)
  result = newDesign(nl)
  result.assertThat(Assertion(
    id: "R", subjects: @[Subject(kind: skNet, name: "a"),
                         Subject(kind: skNet, name: "b")],
    quantity: "dc_path_exists",
    expect: nominal(1.0, absTol = 0.5), unit: "", severity: sevError,
    origin: "t"))

test "an ordinary resistor conducts by default -- dc_path_exists is 1":
  let d = resistorDesign(declareNone = false)
  let r = evaluate(d, allCapabilities)[0]
  check r.status == esPass
  check r.value == 1.0

test "a resistor declared traverse: none breaks a DC path that previously existed":
  let d = resistorDesign(declareNone = true)
  let r = evaluate(d, allCapabilities)[0]
  check r.status == esFail
  check r.value == 0.0
