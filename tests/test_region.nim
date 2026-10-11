## `netlist/region.growRegion` and the `spice/region_strategy` registry.

import std/[sets, tables, unittest]

import verax/netlist/dsl
import verax/netlist/region
import verax/spice/region_strategy

proc board(): Netlist =
  ## U1 drives `outn`; R3/R4 lead to an ADC two hops away; C1 decouples VDD.
  netlist("board"):
    net vdd, kind = ntPower, voltage = "3.3"
    net gnd, kind = ntGround, name = "0"
    net inn, kind = ntSignal
    net outn, kind = ntSignal
    net mid, kind = ntSignal
    net far, kind = ntSignal
    component U1, kind = "opamp":
      pin "INN", inn, kind = ptInput
      pin "OUT", outn, kind = ptOutput
      pin "V+", vdd, kind = ptPower
      pin "V-", gnd, kind = ptGround
    component R1, kind = "resistor", value = "10k":
      pin "1", outn, kind = ptPassive
      pin "2", inn, kind = ptPassive
    component R3, kind = "resistor", value = "1k":
      pin "1", outn, kind = ptPassive
      pin "2", mid, kind = ptPassive
    component R4, kind = "resistor", value = "1k":
      pin "1", mid, kind = ptPassive
      pin "2", far, kind = ptPassive
    component C1, kind = "capacitor", value = "100n":
      pin "1", vdd, kind = ptPassive
      pin "2", gnd, kind = ptPassive
    component U2, kind = "adc":
      pin "IN", far, kind = ptInput
      pin "VDD", vdd, kind = ptPower
      pin "GND", gnd, kind = ptGround

proc passivesOnly(c: Component, via: Net): RegionAction =
  if c.kind in ["resistor", "capacitor"]: raInclude else: raBoundary

test "boundary parts are kept but not walked through; rails stop the walk":
  let nl = board()
  let r = growRegion(nl, [], [nl.nets["outn"]],
    RegionRules(maxHops: 5, absorb: passivesOnly))
  check r.parts.toHashSet == ["U1", "R1", "R3", "R4", "U2"].toHashSet
  check r.boundary.toHashSet == ["U1", "U2"].toHashSet
  check "C1" notin r.parts          # only reachable through vdd
  check "vdd" notin r.nets          # only a boundary part touches it

test "dropped parts are recorded and the hop cap bounds the walk":
  let nl = board()
  let r = growRegion(nl, [], [nl.nets["outn"]], RegionRules(maxHops: 1,
    absorb: proc (c: Component, via: Net): RegionAction =
      if c.kind == "opamp": raDrop else: raInclude))
  check "U1" in r.dropped
  check "R3" in r.parts
  check "R4" in r.parts             # reached on `mid`, hop 1
  check "U2" notin r.parts          # `far` is hop 2

test "a seeded rail is walked; an unseeded one is not":
  let nl = board()
  let seeded = growRegion(nl, [], [nl.nets["vdd"]], RegionRules(maxHops: 3))
  check "C1" in seeded.parts
  let unseeded = growRegion(nl, ["C1"], [], RegionRules(maxHops: 3))
  check unseeded.parts == @["C1"]

test "strategies are looked up by name; a custom one can be registered":
  check "whole" in regionStrategyNames()
  check "terminated" in regionStrategyNames()
  expect KeyError: discard regionStrategy("no_such")
  registerRegionStrategy RegionStrategy(name: "test_only_r1",
    apply: proc (work: Netlist, req: ScopeRequest,
                 globals: var OrderedTable[string, Net]): Scoped =
      result.netlist = work
      result.region.parts = @["R1"])
  var g: OrderedTable[string, Net]
  let s = scope(board(), ScopeRequest(strategy: "test_only_r1"), g)
  check s.region.parts == @["R1"]

test "terminated matches isolate":
  var g: OrderedTable[string, Net]
  var req = ScopeRequest(strategy: "terminated", seedParts: @["R3"],
                         isolation: defaultIsolationSpec("frag"))
  let s = scope(board(), req, g)
  check s.netlist.name == "frag"
  check "U1" in s.region.dropped
  check "R4" in s.region.parts
