import std/[tables, unittest]

import nimcir/netlist
import nimcir/spice/probes

test "voltage probe is a pure label/lookup: no graph mutation":
  let nl = newNetlist("t")
  let vout = addNet(nl, newNet("vout", ntSignal))
  let compsBefore = nl.components.len
  let netsBefore = nl.nets.len

  let p = addVoltageProbe(vout)
  check p.kind == pkVoltage
  check p.label == "v(vout)"
  check p.net == vout
  check nl.components.len == compsBefore
  check nl.nets.len == netsBefore

test "differential voltage probe labels both nets":
  let nl = newNetlist("t")
  let a = addNet(nl, newNet("a"))
  let b = addNet(nl, newNet("b"))
  let p = addVoltageProbe(a, b)
  check p.label == "v(a,b)"
  check p.net == a

test "current probe splits the pin onto a fresh net via a 0V source":
  let nl = newNetlist("t")
  let vout = addNet(nl, newNet("vout"))
  let gnd = addNet(nl, newNet("0", ntGround))
  let r1 = addComponent(nl, newComponent("R1", kind = "resistor"))
  let pin = connect(r1, "2", vout, ptPassive)

  let p = addCurrentProbe(nl, pin)
  check p.kind == pkCurrent
  check p.label == "i(VPROBE_R1_2)"
  check p.source.designator == "VPROBE_R1_2"
  check p.source.kind == "voltage_source"
  check p.source.pins["+"].net == vout
  check p.source.pins["-"].net == p.net
  check pin.net == p.net
  check pin.net != vout
  check nl.components.hasKey("VPROBE_R1_2")

test "current probe accepts an explicit V-prefixed designator":
  let nl = newNetlist("t")
  let vout = addNet(nl, newNet("vout"))
  let r1 = addComponent(nl, newComponent("R1", kind = "resistor"))
  let pin = connect(r1, "2", vout, ptPassive)

  let p = addCurrentProbe(nl, pin, designator = "VSENSE")
  check p.source.designator == "VSENSE"
  check p.label == "i(VSENSE)"

test "current probe rejects a non-V designator":
  let nl = newNetlist("t")
  let vout = addNet(nl, newNet("vout"))
  let r1 = addComponent(nl, newComponent("R1", kind = "resistor"))
  let pin = connect(r1, "2", vout, ptPassive)

  expect(NetlistError):
    discard addCurrentProbe(nl, pin, designator = "X1")

test "current probe on an unconnected pin raises":
  let nl = newNetlist("t")
  let r1 = addComponent(nl, newComponent("R1", kind = "resistor"))
  let pin = addPin(r1, newPin("2"))

  expect(NetlistError):
    discard addCurrentProbe(nl, pin)

test "current probe refuses an XSPICE code model, whose ports are not its pins":
  # An `A` line's port text is rendered from the model's own `ModelSpec` at
  # instantiation and kept verbatim in `attrs["xspice.ports"]`. Re-netting a
  # pin would move it in the graph and not in the deck, leaving the probe
  # source in series with nothing while the code model went on driving the
  # original net -- a probe reading zero on a branch that carries current.
  let nl = newNetlist("t")
  let sw = addNet(nl, newNet("sw", ntSignal))
  let a1 = addComponent(nl, newComponent("AU1", kind = "code_model"))
  a1.attrs["xspice.ports"] = "vin fb en trss sw pg bst"
  let pin = connect(a1, "SW", sw, ptOutput)

  expect(NetlistError):
    discard addCurrentProbe(nl, pin)
