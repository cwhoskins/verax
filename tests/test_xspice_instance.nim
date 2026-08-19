import std/[sequtils, streams, strutils, tables, unittest]

import nimcir/netlist/types
import nimcir/netlist/graph
import nimcir/netlist/formats/spice as spiceFormat
import nimcir/spice/xspice

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
  # The connectivity is real, so ordinary netlist walks still see it.
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
  # SPICE infers the device type from the designator letter, so this would
  # silently become some other device.
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

test "a vector port is rejected rather than silently mis-emitted":
  # Vector ports need the bracketed %v([a b c]) syntax, which this helper
  # does not produce.
  var spec = gainSpec()
  spec.ports[0].vector = true
  let (nl, vin, vout) = fixture()
  expect(XspiceInstanceError):
    discard addCodeModelInstance(nl, "a1", spec, [vin, vout])
