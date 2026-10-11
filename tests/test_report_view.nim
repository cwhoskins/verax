## `report/view`: the circuit-under-test picture -- reach, trimming,
## folding of model elements, and current-sense sources merged away.

import std/[sets, tables, unittest]

import verax/netlist/dsl
import verax/netlist/graph
import verax/spice/models
import verax/spice/probes
import verax/report/view

proc board(): Netlist =
  netlist("board"):
    net vdd, kind = ntPower, voltage = "3.3"
    net gnd, kind = ntGround, name = "0"
    net sda, kind = ntSignal
    net scl, kind = ntSignal
    net xa, kind = ntSignal
    net xb, kind = ntSignal
    net spare, kind = ntSignal
    component R1, kind = "resistor", value = "1.2k":
      pin "1", vdd, kind = ptPassive
      pin "2", sda, kind = ptPassive
    component R2, kind = "resistor", value = "1.2k":
      pin "1", vdd, kind = ptPassive
      pin "2", scl, kind = ptPassive
    component C1, kind = "capacitor", value = "100n", package = "0402":
      pin "1", vdd, kind = ptPassive
      pin "2", gnd, kind = ptPassive
    component U1, kind = "mcu":
      pin "VDD", vdd, kind = ptPower
      pin "SDA", sda, kind = ptInOut
      pin "SCL", scl, kind = ptInOut
      pin "XI", xa, kind = ptInput
      pin "XO", xb, kind = ptOutput
      pin "PA0", spare, kind = ptInOut
      pin "PA1", spare, kind = ptInOut
      pin "GND", gnd, kind = ptGround
    component Y1, kind = "resistor", value = "1meg":
      pin "1", xa, kind = ptPassive
      pin "2", xb, kind = ptPassive

proc names(v: View): HashSet[string] =
  for d in v.netlist.components.keys: result.incl d

test "a bus view: the parts on it, the MCU trimmed to its bus pins":
  let nl = board()
  let v = buildView(nl, ["sda", "scl"], [], nl)
  check names(v) == ["R1", "R2", "U1"].toHashSet
  check "U1" in v.trimmed
  let u1 = v.netlist.components["U1"]
  check "SDA" in u1.pins and "SCL" in u1.pins
  check "XI" notin u1.pins and "PA0" notin u1.pins
  check "Y1" notin names(v)          # the crystal is behind the MCU

test "an IC named as a seed is drawn, not walked through":
  let nl = board()
  let v = buildView(nl, ["sda"], ["U1"], nl)
  check "U1" in names(v)
  check "Y1" notin names(v)

test "model elements fold into the design part they belong to":
  let design = board()
  var g: OrderedTable[string, Net]
  let sim = clone(design, g)
  discard expandCapacitorParasitics(sim)
  let v = buildView(sim, ["vdd"], [], design)
  check "C1" in names(v)
  for d in v.netlist.components.keys: check d != "RC1_ESR" and d != "LC1_ESL"
  let c1 = v.netlist.components["C1"]
  check c1.pins["1"].net.name == "vdd"
  check c1.pins["2"].net.name == "0"
  check v.folded.len == 1 and v.folded[0].part == "C1"

test "a current-sense source is not drawn and its split net merges back":
  let design = board()
  var g: OrderedTable[string, Net]
  let sim = clone(design, g)
  discard addCurrentProbe(sim, sim.components["R1"].pins["2"])
  let v = buildView(sim, ["sda"], [], design)
  check "VPROBE_R1_2" notin names(v)
  check v.netlist.components["R1"].pins["2"].net.name == "sda"

test "the view key ignores order and changes with content":
  let nl = board()
  let a = buildView(nl, ["sda", "scl"], [], nl)
  let b = buildView(nl, ["scl", "sda"], [], nl)
  check viewKey(a) == viewKey(b)
  check viewKey(a) != viewKey(buildView(nl, ["sda"], [], nl))
