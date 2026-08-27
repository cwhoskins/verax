## The `.dc` source sweep: the analysis, the roles, and the evaluator.
##
## The simulated half is skipped rather than failed when `ngspice` is not on
## `PATH`, matching `tests/test_spice_ngspice.nim`.

import std/[math, os, strutils, tables, unittest]

import nimcir/netlist
import nimcir/netlist/dsl as netdsl
import nimcir/contract/dsl
import nimcir/analysis/analyses/dcsweep
import nimcir/analysis/evaluators/contract_eval
import nimcir/verify

let haveNgspice = findExe("ngspice").len > 0

proc resultFor(rs: seq[AssertionResult], id: string): AssertionResult =
  for r in rs:
    if r.assertion.id == id: return r
  raise newException(KeyError, "no result for " & id)

# --- fixtures -----------------------------------------------------------

proc dividerNetlist(top = "75k", bot = "25k"): Netlist =
  ## 10 V across a 100 k string tapped at 25%: the tap sits at 2.5 V, follows
  ## the input with a slope of exactly 0.25, and looks back into
  ## 75k || 25k = 18.75 k. Every one of those is a closed-form identity, so a
  ## measurement that disagrees is the tool being wrong rather than the
  ## fixture being approximate.
  netdsl.netlist("dcdiv"):
    net gnd, kind = ntGround, name = "0", global = true
    net vin, kind = ntPower
    net tap, kind = ntSignal
    component V1, kind = "voltage_source", value = "DC 10":
      pin "+", vin, kind = ptPower
      pin "-", gnd, kind = ptGround
    component R1, kind = "resistor", value = top:
      pin "1", vin, kind = ptPassive
      pin "2", tap, kind = ptPassive
    component R2, kind = "resistor", value = bot:
      pin "1", tap, kind = ptPassive
      pin "2", gnd, kind = ptPassive

proc lineSpec(): DcSweepSpec =
  result = defaultDcSweepSpec()
  result.fromVal = 0.0
  result.toVal = 10.0

proc loadSpec(): DcSweepSpec =
  result = defaultDcSweepSpec()
  result.fromVal = 0.0
  result.toVal = 10.0e-6

# --- the capability itself, which needs no simulator --------------------

test "the .dc capability exists and is offered by default":
  check capSpiceDc in allCapabilities
  check capSpiceDc in simCapabilities
  check capSpiceDc notin offlineCapabilities
  check capLabel(capSpiceDc) == ".dc"

test "--caps=dc parses, and withholding it withholds only .dc":
  check parseCapabilities("dc") == {capStatic, capSpiceDc}
  check capSpiceDc in parseCapabilities("all")
  check capSpiceDc notin parseCapabilities("op,ac,tran")

test "the sweep evaluator registers itself and claims its quantities":
  check "spice.dc_sweep" in registeredEvaluators()
  for q in ["dc_transfer", "line_reg_pct", "line_reg_pct_per_v", "dropout_v",
            "load_reg_pct", "z_out_dc", "dc_out_min", "dc_out_max",
            "dc_out_delta"]:
    check isEvaluable(q)
    check evaluatorFor(q).get.name == "spice.dc_sweep"
    check evaluatorFor(q).get.needs == {capSpiceDc}

# --- the roles ----------------------------------------------------------

test "source_sweep stamps the range into every claim's condition":
  let d = design("sweep_role"):
    net gnd, kind = ntGround, name = "0"
    net vin, kind = ntPower
    net tap, kind = ntSignal
    component V1, kind = "voltage_source", value = "DC 10":
      pin "+", vin, kind = ptPower
      pin "-", gnd, kind = ptGround
    component R1, kind = "resistor", value = "75k":
      pin "1", vin, kind = ptPassive
      pin "2", tap, kind = ptPassive
    component R2, kind = "resistor", value = "25k":
      pin "1", tap, kind = ptPassive
      pin "2", gnd, kind = ptPassive
    role "source_sweep", line, source = V1, output = tap,
         vFrom = 0.0.V, vTo = 10.0.V, ratio = 25.pct, band = 1.pct

  let claims = d.expandAll()
  check claims.len == 1
  check claims[0].quantity == "dc_transfer"
  check claims[0].condition["sweep"] == "source"
  check claims[0].condition["sweep_to"] == "10.0"
  # The unit is empty because a slope in V/V has none, and `unitsAgree` must
  # not then compare it against volts.
  check claims[0].unit == ""

test "load_sweep binds no part and still carries its whole setup":
  let d = design("load_role"):
    net gnd, kind = ntGround, name = "0"
    net tap, kind = ntSignal
    component R2, kind = "resistor", value = "25k":
      pin "1", tap, kind = ptPassive
      pin "2", gnd, kind = ptPassive
    role "load_sweep", ld, output = tap,
         iFrom = 0.0.A, iTo = 10.uA, zOut = 18.75.kohm, band = 1.pct

  let claims = d.expandAll()
  check claims.len == 1
  check claims[0].quantity == "z_out_dc"
  check claims[0].condition["sweep"] == "load"
  check claims[0].unit == "ohm"

test "every sweep claim is opt-in -- a role with no limit claims nothing":
  let d = design("silent"):
    net gnd, kind = ntGround, name = "0"
    net tap, kind = ntSignal
    component R2, kind = "resistor", value = "25k":
      pin "1", tap, kind = ptPassive
      pin "2", gnd, kind = ptPassive
    role "load_sweep", ld, output = tap, iFrom = 0.0.A, iTo = 10.uA
  check d.expandAll().len == 0

test "a bare require is refused, naming the two roles that reach it":
  # The subjects name the node and nothing else: an assertion has no channel
  # for what to sweep or over what range, so guessing would run *a* sweep and
  # report it as the one asked for.
  let d = design("bare"):
    net gnd, kind = ntGround, name = "0"
    net tap, kind = ntSignal
    component R2, kind = "resistor", value = "25k":
      pin "1", tap, kind = ptPassive
      pin "2", gnd, kind = ptPassive
    require dc_transfer(tap) == 0.25, band = 1.pct, id = "BARE"

  let r = resultFor(evaluate(d, allCapabilities), "BARE")
  check r.status == esNotEvaluable
  check "source_sweep" in r.reason
  check "load_sweep" in r.reason

# --- the analysis -------------------------------------------------------

if not haveNgspice:
  echo "ngspice not found on PATH -- skipping the simulated dc-sweep tests"
else:
  test "a line sweep measures the divider ratio as a slope":
    let rep = analyzeLineSweep(dividerNetlist(), "V1", "tap", lineSpec())
    check abs(rep["dc_transfer"] - 0.25) < 1.0e-9
    check abs(rep["dc_out_max"] - 2.5) < 1.0e-6
    check abs(rep["dc_out_min"]) < 1.0e-9

  test "a load sweep measures the Thevenin resistance of the tap":
    let rep = analyzeLoadSweep(dividerNetlist(), "tap", loadSpec())
    check abs(rep["z_out_dc"] - 18750.0) / 18750.0 < 1.0e-6
    # 10 uA through 18.75 k is 187.5 mV of sag, against 2.5 V.
    check abs(rep["load_reg_pct"] - 7.5) < 1.0e-3

  test "the injected sink is not left in the design netlist":
    let nl = dividerNetlist()
    let before = nl.components.len
    discard analyzeLoadSweep(nl, "tap", loadSpec())
    check nl.components.len == before

  test "a sweep with no range refuses rather than answering trivially":
    var spec = defaultDcSweepSpec()
    spec.fromVal = 5.0
    spec.toVal = 5.0
    expect NetlistError:
      discard analyzeLineSweep(dividerNetlist(), "V1", "tap", spec)

  test "sweeping something that is not a voltage source says so":
    expect NetlistError:
      discard analyzeLineSweep(dividerNetlist(), "R1", "tap", lineSpec())

  test "an output that never leaves regulation reports no dropout, not zero":
    # A divider's tap follows its input all the way down, so a wide sweep
    # does find a dropout -- meaninglessly, but it finds one. Swept over a
    # range narrower than the 2% band, nothing ever falls out, which is what
    # an ideal regulator model reports over any range at all: the answer must
    # then be "not found", never zero.
    var spec = lineSpec()
    spec.fromVal = 9.9
    spec.toVal = 10.0
    let rep = analyzeLineSweep(dividerNetlist(), "V1", "tap", spec)
    check rep["dropout_v"].isNaN
    var said = false
    for i in rep.issues:
      if i.kind == KindNoDropout: said = true
    check said

  test "the injected load is declared as an assumption":
    let rep = analyzeLoadSweep(dividerNetlist(), "tap", loadSpec())
    var declared = false
    for a in rep.invented():
      if "constant-current sink" in a.detail: declared = true
    check declared

  # --- through the contract layer ---------------------------------------

  proc sweptDesign(): Design =
    design("dcsweep_design"):
      net gnd, kind = ntGround, name = "0"
      net vin, kind = ntPower
      net tap, kind = ntSignal
      component V1, kind = "voltage_source", value = "DC 10":
        pin "+", vin, kind = ptPower
        pin "-", gnd, kind = ptGround
      component R1, kind = "resistor", value = "75k":
        pin "1", vin, kind = ptPassive
        pin "2", tap, kind = ptPassive
      component R2, kind = "resistor", value = "25k":
        pin "1", tap, kind = ptPassive
        pin "2", gnd, kind = ptPassive
      role "source_sweep", line, source = V1, output = tap,
           vFrom = 0.0.V, vTo = 10.0.V, ratio = 25.pct, band = 1.pct
      role "load_sweep", ld, output = tap,
           iFrom = 0.0.A, iTo = 10.uA, zOut = 18.75.kohm, band = 1.pct

  test "both roles check through the evaluator":
    let rs = evaluate(sweptDesign(), allCapabilities)
    check resultFor(rs, "line.transfer").status == esPass
    check resultFor(rs, "ld.z_out").status == esPass

  test "withholding .dc leaves the claims unevaluated, and says which":
    let r = resultFor(evaluate(sweptDesign(), {capStatic, capSpiceOp}),
                      "line.transfer")
    check r.status == esNotEvaluated
    check "the .dc capability" in r.reason

  test "a source sweep and a load sweep are two runs, not one":
    # They share a subject and an evaluator and differ only in the `sweep`
    # condition, which is exactly the case a setup key has to keep apart.
    let p = plan(sweptDesign(), allCapabilities)
    var steps = 0
    for s in p.steps:
      if s.evaluator == "spice.dc_sweep": inc steps
    check steps == 2
