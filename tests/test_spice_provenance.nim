## `spice/provenance`: every element a model pass, a scope or a probe adds
## says which design part it belongs to and what it is for.

import std/[tables, unittest]

import verax/netlist/dsl
import verax/spice/models
import verax/spice/transform
import verax/spice/probes
import verax/spice/provenance
import verax/spice/isolate

proc board(): Netlist =
  netlist("board"):
    net vdd, kind = ntPower, voltage = "3.3"
    net vin, kind = ntPower, voltage = "5"
    net gnd, kind = ntGround, name = "0"
    net sig, kind = ntSignal
    component C1, kind = "capacitor", value = "100n", package = "0402":
      pin "1", vdd, kind = ptPassive
      pin "2", gnd, kind = ptPassive
    component U1, kind = "adc":
      pin "IN", sig, kind = ptInput
      pin "VDD", vdd, kind = ptPower
      pin "GND", gnd, kind = ptGround
    component U2, kind = "buck":
      pin "IN", vin, kind = ptPower
      pin "OUT", vdd, kind = ptPower
      pin "GND", gnd, kind = ptGround
      simReplace kind = "voltage_source":
        pin "+", vdd
        pin "-", gnd
    component R1, kind = "resistor", value = "1k":
      pin "1", sig, kind = ptPassive
      pin "2", gnd, kind = ptPassive

proc owned(nl: Netlist, owner: string): seq[string] =
  for d, c in nl.components:
    if benchOf(c) == owner: result.add d

test "capacitor parasitics are models of the capacitor":
  let nl = board()
  discard expandCapacitorParasitics(nl)
  let parts = owned(nl, "C1")
  check parts.len == 2
  for d in parts: check benchRole(nl.components[d]) == "model"
  check benchRole(nl.components["C1"]) == ""   # the design part itself

test "per-pin stand-ins and simReplace stand in for their part":
  let nl = board()
  applySimReplacements(nl)
  let u2 = owned(nl, "U2")
  check u2.len == 1
  check benchRole(nl.components[u2[0]]) == "standin"
  discard expandPinModels(nl)
  let u1 = owned(nl, "U1")
  check u1.len >= 1
  for d in u1: check benchRole(nl.components[d]) == "standin"

test "a model of a stand-in belongs to the original design part":
  let nl = board()
  applySimReplacements(nl)
  discard expandSourceImpedance(nl)
  # U2's stand-in source gained rout/lout: both are U2's too.
  check owned(nl, "U2").len == 3

test "isolation terminations and probes are fixture parts":
  var g: OrderedTable[string, Net]
  let iso = isolate(board(), ["R1"], defaultIsolationSpec("f"), g)
  var roles: seq[string]
  for _, c in iso.netlist.components: roles.add benchRole(c)
  check "termination" in roles                     # the leak on `sig`
  let nl = board()
  let p = addImpedanceProbe(nl, nl.nets["vdd"], nl.nets["0"])
  check benchRole(p.source) == "stimulus"
  check benchRole(nl.nets["vdd"]) == "probe"
  let cp = addCurrentProbe(nl, nl.components["R1"].pins["1"])
  check benchRole(cp.source) == "probe"
  check benchOf(cp.source) == "R1"
