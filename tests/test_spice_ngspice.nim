import std/[os, streams, strutils, tables, unittest]

import nimcir/netlist
import nimcir/netlist/dsl
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

suite "a rawfile is not the same as a solution":
  # ngspice reports a failed DC solve as a *warning*, writes whatever its
  # last iterate was, and exits zero -- so the numbers arrive looking exactly
  # like an answer. The LT8640A reference design found this: one node left
  # floating at DC made the matrix singular and the 5 V rail read 1.71 V, as
  # a clean FAIL against a real number rather than as an error.

  test "a node with no DC path is refused rather than reported":
    if not haveNgspice:
      skip()
    else:
      let nl = netlist("floating"):
        net gnd, kind = ntGround, name = "0"
        net vin, kind = ntPower
        net orphan, kind = ntSignal
        component V1, kind = "voltage_source", value = "DC 5":
          pin "+", vin, kind = ptPower
          pin "-", gnd, kind = ptGround
        component R1, kind = "resistor", value = "1k":
          pin "1", vin, kind = ptPassive
          pin "2", gnd, kind = ptPassive
        # Reachable only through capacitors, so it has no DC path anywhere.
        component C1, kind = "capacitor", value = "100n":
          pin "1", vin, kind = ptPassive
          pin "2", orphan, kind = ptPassive
        component C2, kind = "capacitor", value = "100n":
          pin "1", orphan, kind = ptPassive
          pin "2", gnd, kind = ptPassive
      var raised = ""
      try:
        discard run(nl, @[".op"])
      except SpiceSimError as e:
        raised = e.msg
      check "did not converge" in raised
      check "no DC path" in raised

  test "a circuit that does converge is unaffected":
    if not haveNgspice:
      skip()
    else:
      let nl = netlist("divider"):
        net gnd, kind = ntGround, name = "0"
        net vin, kind = ntPower
        net mid, kind = ntSignal
        component V1, kind = "voltage_source", value = "DC 10":
          pin "+", vin, kind = ptPower
          pin "-", gnd, kind = ptGround
        component R1, kind = "resistor", value = "1k":
          pin "1", vin, kind = ptPassive
          pin "2", mid, kind = ptPassive
        component R2, kind = "resistor", value = "1k":
          pin "1", mid, kind = ptPassive
          pin "2", gnd, kind = ptPassive
      let r = run(nl, @[".op"])
      check abs(r["v(mid)"][0] - 5.0) < 1e-6
