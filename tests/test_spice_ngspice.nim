import std/[math, os, streams, strutils, tables, unittest]

import verax/netlist
import verax/netlist/dsl
import verax/spice/ngspice
import verax/spice/probes

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
  # ngspice's default `write` keeps only the last plot, and a SimResult
  # holds one.
  let nl = dividerNetlist()
  expect(SpiceSimError):
    discard run(nl, @[".op", ".tran 1u 1m"])
  expect(SpiceSimError):
    discard run(nl, ".tran 1u 1m", setup = @[".op"])

test "a setup card is not an analysis card":
  # Setup cards like `.ic` produce no plot and don't count as analyses.
  check isAnalysisCard(".op")
  check isAnalysisCard(".TRAN 1u 1m")
  check isAnalysisCard(".ac dec 10 1 1k")
  check not isAnalysisCard(".ic v(out)=0.1")
  check not isAnalysisCard(".nodeset v(a)=1")
  check not isAnalysisCard(".options reltol=1e-4")
  check not isAnalysisCard(".temp 85")
  check not isAnalysisCard(".param x=1")

test "setup cards reach the deck ahead of the analysis":
  let nl = dividerNetlist()
  var s = newStringStream()
  writeDeck(nl, @[".ic v(vout)=0.5", ".tran 1u 1m uic"], s)
  let lines = s.data.strip().splitLines()
  check lines[^1] == ".END"
  check lines[^2] == ".tran 1u 1m uic"
  check lines[^3] == ".ic v(vout)=0.5"

if not haveNgspice:
  echo "SKIP: ngspice not found on PATH, skipping real-simulation tests"
else:
  test "an .ic kicks a circuit that will not start from its operating point":
    # A source-less LC tank sits at 0 V from its operating point; kicked
    # with an initial capacitor voltage it rings at 5033 Hz.
    let tank = netlist("tank"):
      net gnd, kind = ntGround, name = "0"
      net vout, kind = ntSignal
      component L1, kind = "inductor", value = "1e-3":
        pin "1", vout, kind = ptPassive
        pin "2", gnd, kind = ptPassive
      component C1, kind = "capacitor", value = "1e-6":
        pin "1", vout, kind = ptPassive
        pin "2", gnd, kind = ptPassive
      component R1, kind = "resistor", value = "1e6":
        pin "1", vout, kind = ptPassive
        pin "2", gnd, kind = ptPassive

    proc swing(r: SimResult): float =
      let v = r["v(vout)"]
      var lo = v[0]
      var hi = v[0]
      for x in v:
        if x < lo: lo = x
        if x > hi: hi = x
      hi - lo

    # Unkicked, it does nothing.
    check swing(run(tank, ".tran 1u 5m")) < 1e-6

    let kicked = run(tank, ".tran 1u 5m uic", setup = @[".ic v(vout)=1.0"])
    check abs(swing(kicked) - 2.0) < 0.1

    let v = kicked["v(vout)"]
    let t = kicked["time"]
    var crossings = 0
    for i in 1 ..< v.len:
      if (v[i - 1] < 0.0) != (v[i] < 0.0): inc crossings
    let f0 = float(crossings) / 2.0 / (t[^1] - t[0])
    check abs(f0 - 5033.0) < 100.0

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
    # An unparseable value makes ngspice fail gracefully (exit 1, no raw
    # file); a circuit with zero valid devices crashes ngspice-46 on .op.
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
  # ngspice reports a failed DC solve as a warning, writes its last iterate
  # and exits zero, so the numbers look like an answer.

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
        # Reachable only through capacitors: no DC path.
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
