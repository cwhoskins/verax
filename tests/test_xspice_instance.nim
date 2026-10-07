import std/[sequtils, streams, strutils, tables, unittest]

import verax/netlist/types
import verax/netlist/graph
import verax/netlist/formats/spice as spiceFormat
import verax/spice/xspice

proc gainSpec(): ModelSpec =
  ModelSpec(
    name: "nimgain", cFunction: "cm_nimgain", description: "gain",
    ports: @[
      PortSpec(name: "inp", dir: xdIn, default: xpV, allowed: @[xpV]),
      PortSpec(name: "outp", dir: xdOut, default: xpV, allowed: @[xpV])],
    params: @[
      ParamSpec(name: "gain", dataType: xtReal, default: "1.0", nullAllowed: true),
      ParamSpec(name: "in_offset", dataType: xtReal, default: "0.0", nullAllowed: true)])

proc fixture(): (Netlist, Net, Net) =
  let nl = newNetlist("t")
  let vin = addNet(nl, Net(name: "vin"))
  let vout = addNet(nl, Net(name: "vout"))
  (nl, vin, vout)

proc render(nl: Netlist): string =
  let s = newStringStream()
  spiceFormat.writeNetlist(nl, s)
  s.setPosition(0)
  s.readAll()

test "an instance emits a positional A line plus its .MODEL card":
  let (nl, vin, vout) = fixture()
  discard addCodeModelInstance(nl, "a1", gainSpec(), [vin, vout],
                               {"gain": "2.0", "in_offset": "0.5"})
  let deck = render(nl)
  check "a1 vin vout a1" in deck
  check ".MODEL a1 nimgain(gain=2.0 in_offset=0.5)" in deck

test "pins are wired to the ports in declaration order":
  let (nl, vin, vout) = fixture()
  let c = addCodeModelInstance(nl, "a1", gainSpec(), [vin, vout])
  check toSeq(c.pins.keys) == @["inp", "outp"]
  check c.pins["inp"].net.name == "vin"
  check c.pins["outp"].net.name == "vout"
  # Real connectivity, so netlist walks see it.
  check vin.pins.len == 1
  check vout.pins[0].component.designator == "a1"

test "an explicit model name lets two instances share one code model":
  let (nl, vin, vout) = fixture()
  let mid = addNet(nl, Net(name: "mid"))
  discard addCodeModelInstance(nl, "a1", gainSpec(), [vin, mid],
                               {"gain": "2.0"}, modelName = "fast")
  discard addCodeModelInstance(nl, "a2", gainSpec(), [mid, vout],
                               {"gain": "-1.5"}, modelName = "slow")
  let deck = render(nl)
  check "a1 vin mid fast" in deck
  check "a2 mid vout slow" in deck
  check ".MODEL fast nimgain(gain=2.0)" in deck
  check ".MODEL slow nimgain(gain=-1.5)" in deck

test "a designator not starting with A is rejected":
  # SPICE infers the device from the designator letter.
  let (nl, vin, vout) = fixture()
  expect(XspiceInstanceError):
    discard addCodeModelInstance(nl, "U1", gainSpec(), [vin, vout])

test "a wrong number of nets is rejected":
  let (nl, vin, _) = fixture()
  expect(XspiceInstanceError):
    discard addCodeModelInstance(nl, "a1", gainSpec(), [vin])

test "an unknown parameter name is rejected":
  let (nl, vin, vout) = fixture()
  expect(XspiceInstanceError):
    discard addCodeModelInstance(nl, "a1", gainSpec(), [vin, vout], {"gian": "2.0"})

test "a duplicate .MODEL name is rejected":
  let (nl, vin, vout) = fixture()
  discard addCodeModelInstance(nl, "a1", gainSpec(), [vin, vout], modelName = "m")
  expect(XspiceInstanceError):
    discard addCodeModelInstance(nl, "a2", gainSpec(), [vin, vout], modelName = "m")

proc bridgeSpec(): ModelSpec =
  ## Shaped like ngspice's own `adc_bridge`: vector in, vector out.
  ModelSpec(
    name: "adc_bridge", cFunction: "cm_adc_bridge",
    ports: @[
      PortSpec(name: "inp", dir: xdIn, default: xpV, allowed: @[xpV],
               vector: true, vectorBounds: bounds(1, 4)),
      PortSpec(name: "outp", dir: xdOut, default: xpD, allowed: @[xpD],
               vector: true, vectorBounds: bounds(1, 4))])

proc diffSpec(): ModelSpec =
  ModelSpec(
    name: "diffamp", cFunction: "cm_diffamp",
    ports: @[
      PortSpec(name: "inp", dir: xdIn, default: xpVd, allowed: @[xpVd]),
      PortSpec(name: "outp", dir: xdOut, default: xpV, allowed: @[xpV],
               nullAllowed: true)])

test "a vector port renders as a bracketed list":
  let (nl, a, b) = fixture()
  let c = addNet(nl, Net(name: "c"))
  let d = addNet(nl, Net(name: "d"))
  discard addCodeModelInstance(nl, "a1", bridgeSpec(),
                               [wire([a, b]), wire([c, d])])
  check "a1 [vin vout] [c d] a1" in render(nl)

test "vector port pins are indexed, so graph walks still see real nets":
  let (nl, a, b) = fixture()
  let c = addNet(nl, Net(name: "c"))
  let comp = addCodeModelInstance(nl, "a1", bridgeSpec(),
                                  [wire([a, b]), wire([c])])
  check toSeq(comp.pins.keys) == @["inp[0]", "inp[1]", "outp[0]"]
  check comp.pins["inp[1]"].net.name == "vout"
  check c.pins[0].component.designator == "a1"

test "a differential port takes two nodes and splits into .p/.n pins":
  # ngspice needs an explicit second node for vd/id/gd/hd; ground is implied
  # only for single-ended types.
  let (nl, a, b) = fixture()
  let o = addNet(nl, Net(name: "o"))
  let comp = addCodeModelInstance(nl, "a1", diffSpec(), [wire(a, b), wire(o)])
  check "a1 vin vout o a1" in render(nl)
  check toSeq(comp.pins.keys) == @["inp.p", "inp.n", "outp"]
  check comp.pins["inp.n"].net.name == "vout"

test "giving a differential port one node is rejected with its node count":
  let (nl, a, _) = fixture()
  let o = addNet(nl, Net(name: "o"))
  expect(XspiceInstanceError):
    discard addCodeModelInstance(nl, "a1", diffSpec(), [wire(a), wire(o)])

test "a null port renders as the literal null":
  let (nl, a, b) = fixture()
  discard addCodeModelInstance(nl, "a1", diffSpec(), [wire(a, b), nullPort()])
  check "a1 vin vout null a1" in render(nl)

test "a null binding on a port that is not Null_Allowed is rejected":
  let (nl, a, b) = fixture()
  expect(XspiceInstanceError):
    discard addCodeModelInstance(nl, "a1", diffSpec(), [nullPort(), wire(a)])

test "a null port contributes no pins":
  let (nl, a, b) = fixture()
  let comp = addCodeModelInstance(nl, "a1", diffSpec(), [wire(a, b), nullPort()])
  check toSeq(comp.pins.keys) == @["inp.p", "inp.n"]

test "a vector of differential elements needs a whole number of pairs":
  var spec = bridgeSpec()
  spec.ports[0].default = xpVd
  spec.ports[0].allowed = @[xpVd]
  let (nl, a, b) = fixture()
  let c = addNet(nl, Net(name: "c"))
  expect(XspiceInstanceError):    # 3 nets, 2 nodes per element
    discard addCodeModelInstance(nl, "a1", spec, [wire([a, b, c]), wire([a])])
  let comp = addCodeModelInstance(nl, "a2", spec, [wire([a, b]), wire([c])])
  check toSeq(comp.pins.keys) == @["inp[0].p", "inp[0].n", "outp[0]"]

test "Vector_Bounds are enforced on the element count, not the node count":
  let (nl, a, b) = fixture()
  let c = addNet(nl, Net(name: "c"))
  let d = addNet(nl, Net(name: "d"))
  let e = addNet(nl, Net(name: "e"))
  expect(XspiceInstanceError):    # 5 elements, bound is [1 4]
    discard addCodeModelInstance(nl, "a1", bridgeSpec(),
                                 [wire([a, b, c, d, e]), wire([a])])

test "an empty vector binding is rejected":
  let (nl, a, _) = fixture()
  expect(XspiceInstanceError):
    discard addCodeModelInstance(nl, "a1", bridgeSpec(), [wire([]), wire([a])])

test "a vnam port is rejected because it names a source, not a net":
  var spec = diffSpec()
  spec.ports[0].default = xpVnam
  spec.ports[0].allowed = @[xpVnam]
  let (nl, a, _) = fixture()
  expect(XspiceInstanceError):
    discard addCodeModelInstance(nl, "a1", spec, [wire(a), wire(a)])

suite "telling the simulator which code models a netlist needs":
  # The netlist reaching ngspice is a fragment several transforms removed
  # from the design, so the cm path travels on the components.

  test "a cm path is recorded on the component and collected back":
    let nl = newNetlist("board")
    let a = addNet(nl, newNet("a"))
    let b = addNet(nl, newNet("b"))
    discard addCodeModelInstance(nl, "A1", gainSpec(), [a, b],
                                 cmPath = "/tmp/gain.cm")
    check nl.components["A1"].attrs[xspiceCmAttr] == "/tmp/gain.cm"
    check collectCodeModels(nl) == @["/tmp/gain.cm"]

  test "two instances of one model are collected once":
    let nl = newNetlist("board")
    let a = addNet(nl, newNet("a"))
    let b = addNet(nl, newNet("b"))
    let c = addNet(nl, newNet("c"))
    discard addCodeModelInstance(nl, "A1", gainSpec(), [a, b], cmPath = "/tmp/g.cm")
    discard addCodeModelInstance(nl, "A2", gainSpec(), [b, c], cmPath = "/tmp/g.cm")
    check collectCodeModels(nl) == @["/tmp/g.cm"]

  test "a model inside a subcircuit is found too":
    # Found before and after flattening.
    let child = newNetlist("CH")
    let ci = addNet(child, newNet("i"))
    let co = addNet(child, newNet("o"))
    discard addCodeModelInstance(child, "A1", gainSpec(), [ci, co],
                                 cmPath = "/tmp/inner.cm")
    addPort(child, "I", ci)
    addPort(child, "O", co)
    let nl = newNetlist("top")
    let p = addNet(nl, newNet("p"))
    let q = addNet(nl, newNet("q"))
    var globals: OrderedTable[string, Net]
    discard instantiate(nl, "X1", child, @[p, q], globals)
    check collectCodeModels(nl) == @["/tmp/inner.cm"]

  test "a component with no cm path contributes nothing":
    let nl = newNetlist("board")
    let a = addNet(nl, newNet("a"))
    let b = addNet(nl, newNet("b"))
    discard addCodeModelInstance(nl, "A1", gainSpec(), [a, b])
    check collectCodeModels(nl).len == 0

test "a string parameter is quoted on the .model card, whatever its value":
  # ngspice reads an unquoted token starting with a letter as a parameter
  # reference (`uid=deadbeef` aborts), while one starting with a digit
  # parses. The failure depends on the value, so quoting can't be left to the
  # caller.
  let spec = ModelSpec(
    name: "tagged", cFunction: "cm_tagged", description: "tagged",
    ports: @[PortSpec(name: "a", dir: xdIn, default: xpV, allowed: @[xpV])],
    params: @[
      ParamSpec(name: "label", dataType: xtString, default: "\"x\"",
                nullAllowed: true),
      ParamSpec(name: "gain", dataType: xtReal, default: "1.0",
                nullAllowed: true)])
  let (nl, vin, _) = fixture()
  discard addCodeModelInstance(nl, "A1", spec, [vin],
                               {"label": "deadbeef", "gain": "2.5"})
  check nl.models["a1"] == "tagged(label=\"deadbeef\" gain=2.5)"

test "a string parameter the caller already quoted is not quoted again":
  let spec = ModelSpec(
    name: "tagged", cFunction: "cm_tagged", description: "tagged",
    ports: @[PortSpec(name: "a", dir: xdIn, default: xpV, allowed: @[xpV])],
    params: @[ParamSpec(name: "label", dataType: xtString, default: "\"x\"",
                        nullAllowed: true)])
  let (nl, vin, _) = fixture()
  discard addCodeModelInstance(nl, "A1", spec, [vin], {"label": "\"ok\""})
  check nl.models["a1"] == "tagged(label=\"ok\")"
