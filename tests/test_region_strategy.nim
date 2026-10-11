## `source_closed`: the measurement's connected component, nothing
## terminated, load ICs optionally drawn as sinks; benches record it.

import std/[strutils, tables, unittest]

import verax/netlist/dsl
import verax/spice/bench
import verax/spice/transform

proc board(): Netlist =
  netlist("board"):
    net vdd, kind = ntPower, voltage = "3.3"
    net gnd, kind = ntGround, name = "0"
    net sig, kind = ntSignal
    net x1, kind = ntSignal
    net x2, kind = ntSignal
    component V1, kind = "voltage_source", value = "DC 3.3":
      pin "+", vdd, kind = ptPower
      pin "-", gnd, kind = ptGround
    component C1, kind = "capacitor", value = "100n":
      pin "1", vdd, kind = ptPassive
      pin "2", gnd, kind = ptPassive
    component R1, kind = "resistor", value = "10k":
      pin "1", vdd, kind = ptPassive
      pin "2", sig, kind = ptPassive
    component U1, kind = "mcu":
      pin "VDD", vdd, kind = ptPower
      pin "PA0", sig, kind = ptInOut
      pin "GND", gnd, kind = ptGround
    component U2, kind = "sensor", supply_current = "0.01":
      pin "VDD", vdd, kind = ptPower
      pin "GND", gnd, kind = ptGround
    # An island sharing only ground with the rest: a crystal's load caps.
    component Y1, kind = "resistor", value = "1meg":
      pin "1", x1, kind = ptPassive
      pin "2", x2, kind = ptPassive
    component CX1, kind = "capacitor", value = "12p":
      pin "1", x1, kind = ptPassive
      pin "2", gnd, kind = ptPassive

proc benchOn(icSinks: bool): Bench =
  result = openBench(board(), "t", spSteadyState)
  result.modelUnmodelled()
  result.scopeBench(ScopeChoice(strategy: "source_closed", icSinks: icSinks),
                    [], ["vdd"])

proc sinks(b: Bench): Table[string, string] =
  for d, c in b.netlist.components:
    if c.kind == "current_source": result[benchOf(c) & "." & c.attrs[benchPinKey]] =
      c.attrs["value"]

test "parts sharing only ground with the measurement are left out, exactly":
  let b = benchOn(false)
  check "Y1" notin b.netlist.components
  check "CX1" notin b.netlist.components
  check "V1" in b.netlist.components     # the real source: never terminated
  check "C1" in b.netlist.components
  check b.info.strategy == "source_closed"
  check sinks(b).len == 0                # stand-ins kept without icSinks

test "load ICs on a rail become sinks: stated current, else the stand-in's":
  let b = benchOn(true)
  let s = sinks(b)
  check s["U2.VDD"] == "DC 1.000000000e-02"
  check s["U1.VDD"].startsWith("DC 3.3")  # 3.3 V across the 1 Mohm stand-in
  check "e-06" in s["U1.VDD"]
  # U1's signal pin keeps its stand-in: it is on a measured path.
  var signalStandIn = false
  for d, c in b.netlist.components:
    if benchOf(c) == "U1" and c.kind == "resistor": signalStandIn = true
  check signalStandIn
  var noted = false
  for a in b.assumptions:
    if "open at AC" in a.detail: noted = true
  check noted

test "a rail with no stated voltage keeps its stand-ins":
  var nl = board()
  nl.nets["vdd"].attrs.del "voltage"
  var b = openBench(nl, "t", spSteadyState)
  b.modelUnmodelled()
  b.scopeBench(ScopeChoice(strategy: "source_closed", icSinks: true), [], ["vdd"])
  check sinks(b).len == 1                # only U2, whose current is stated
