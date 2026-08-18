import std/[os, streams, strutils, tables, unittest]

import nimcir/netlist
import nimcir/spice/ngspice
import nimcir/spice/probes

let haveNgspice = findExe("ngspice").len > 0

proc dividerNetlist(): Netlist =
  result = newNetlist("rc_divider")
  let vin = addNet(result, newNet("vin"))
  let vout = addNet(result, newNet("vout"))
  let gnd = addNet(result, newNet("0", ntGround))

  let v1 = addComponent(result, newComponent("V1", kind = "voltage_source"))
  discard connect(v1, "+", vin)
  discard connect(v1, "-", gnd)
  v1.attrs["value"] = "DC 10"

  let r1 = addComponent(result, newComponent("R1", kind = "resistor"))
  discard connect(r1, "1", vin, ptPassive)
  discard connect(r1, "2", vout, ptPassive)
  r1.attrs["value"] = "1k"

  let r2 = addComponent(result, newComponent("R2", kind = "resistor"))
  discard connect(r2, "1", vout, ptPassive)
  discard connect(r2, "2", gnd, ptPassive)
  r2.attrs["value"] = "1k"

test "writeDeck round-trips topology plus analysis cards":
  let nl = dividerNetlist()
  let s = newStringStream()
  writeDeck(nl, @[".op"], s)
  let lines = s.data.strip(trailing = true).splitLines()
  check "R1 vin vout 1k" in lines
  check lines[^1] == ".END"
  check lines[^2] == ".op" # written just before .END

test "run() rejects more than one analysis card":
  let nl = dividerNetlist()
  expect(SpiceSimError):
    discard run(nl, @[".op", ".tran 1u 1m"])

if not haveNgspice:
  echo "SKIP: ngspice not found on PATH, skipping real-simulation tests"
else:
  test "real .op run against a resistive divider matches hand-calculated values":
    let nl = dividerNetlist()
    let result = run(nl, @[".op"])
    check result.plotName == "Operating Point"
    check abs(result["v(vin)"][0] - 10.0) < 1e-6
    check abs(result["v(vout)"][0] - 5.0) < 1e-6

  test "current probe matches Ohm's law for a known resistor":
    let nl = dividerNetlist()
    let probe = addCurrentProbe(nl, nl.components["R2"].pins["1"])
    let result = run(nl, @[".op"])
    # 5V across R2 (1k) -> 5mA
    check abs(result[probe.label][0] - 0.005) < 1e-6

  test "a malformed deck raises SpiceSimError instead of a crash":
    # A deliberately unparseable component value (rather than e.g. a fully
    # disconnected device) so ngspice fails gracefully -- exit 1, no raw
    # file -- instead of hitting the internal assertion crash ngspice-46
    # triggers on an .op analysis over a circuit with zero valid devices
    # (confirmed empirically; see ngspice.nim's `run` doc comment).
    let nl = newNetlist("bad")
    let gnd = addNet(nl, newNet("0", ntGround))
    let a = addNet(nl, newNet("a"))
    let r1 = addComponent(nl, newComponent("R1", kind = "resistor"))
    discard connect(r1, "1", a, ptPassive)
    discard connect(r1, "2", gnd, ptPassive)
    r1.attrs["value"] = "notanumber"
    expect(SpiceSimError):
      discard run(nl, @[".op"])
