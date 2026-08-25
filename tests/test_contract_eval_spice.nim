## The simulation-backed half of the evaluator layer.
##
## Skipped rather than failed when `ngspice` is not on `PATH`, matching
## `tests/test_spice_ngspice.nim`.

import std/[math, os, strutils, tables, unittest]

import nimcir/contract/dsl
import nimcir/analysis/contract_eval

let haveNgspice = findExe("ngspice").len > 0

proc resultFor(rs: seq[AssertionResult], id: string): AssertionResult =
  for r in rs:
    if r.assertion.id == id: return r
  raise newException(KeyError, "no result for " & id)

# --- fixtures -----------------------------------------------------------

proc dividerBoard(upper: string): Design =
  ## A 10 V source divided down to a nominal 3.3 V rail. With 2k/1k the rail
  ## sits at 3.333 V; changing the upper leg moves it off target.
  design("divider"):
    net vin, kind = ntPower
    net vdd, kind = ntPower
    net gnd, kind = ntGround, name = "0"

    component V1, kind = "voltage_source", value = "DC 10":
      pin "+", vin, kind = ptPower
      pin "-", gnd, kind = ptGround
    component R1, kind = "resistor", value = upper:
      pin "1", vin, kind = ptPassive
      pin "2", vdd, kind = ptPassive
    component R2, kind = "resistor", value = "1000":
      pin "1", vdd, kind = ptPassive
      pin "2", gnd, kind = ptPassive

    role "power_rail", vdd_rail, rail = vdd, voltage = 3.3.V, band = 5.pct

# --- planning needs no simulator ----------------------------------------

test "the simulated evaluators register themselves on import":
  check isEvaluable("dc_voltage")
  check isEvaluable("z_max_in_band")
  check isEvaluable("phase_margin_deg")
  check "spice.dc_voltage" in registeredEvaluators()

test "a simulated quantity is not *evaluated* when no simulator is offered":
  # The default capability set is offline, so importing this module must not
  # silently start running ngspice.
  let r = resultFor(evaluate(dividerBoard("2000")), "vdd_rail.voltage")
  check r.status == esNotEvaluated
  check "capSpiceOp" in r.reason

test "one .op answers every dc_voltage claim in the design":
  let d = design("rails"):
    net a, kind = ntPower
    net b, kind = ntPower
    net gnd, kind = ntGround, name = "0"
    component V1, kind = "voltage_source", value = "DC 5":
      pin "+", a, kind = ptPower
      pin "-", gnd, kind = ptGround
    component V2, kind = "voltage_source", value = "DC 12":
      pin "+", b, kind = ptPower
      pin "-", gnd, kind = ptGround
    require dc_voltage(a) == 5.0.V, id = "A"
    require dc_voltage(b) == 12.0.V, id = "B"

  let p = plan(d, allCapabilities)
  # Two rails, two claims, but a single node-voltage solve answers both.
  check p.steps.len == 1
  check p.steps[0].evaluator == "spice.dc_voltage"
  check p.steps[0].assertions.len == 2

# --- the end-to-end verdict ---------------------------------------------

test "a rail that meets its requirement passes against a real .op":
  if not haveNgspice:
    skip()
  else:
    let rs = evaluate(dividerBoard("2000"), allCapabilities)
    let r = resultFor(rs, "vdd_rail.voltage")
    check r.status == esPass
    check abs(r.value - 3.3333) < 1.0e-3
    check r.unit == "V"
    check r.evaluator == "spice.dc_voltage"

test "a rail that misses its requirement fails, and reports the witness":
  if not haveNgspice:
    skip()
  else:
    # 4k over 1k puts the rail at 2.0 V, well outside 3.3 V +-5%.
    let rs = evaluate(dividerBoard("4000"), allCapabilities)
    let r = resultFor(rs, "vdd_rail.voltage")
    check r.status == esFail
    check abs(r.value - 2.0) < 1.0e-3
    check "2" in r.reason and "3.3" in r.reason
    check failed(rs).len == 1
    check worstSeverity(rs) == sevError

test "an undriven rail measures zero and fails, which is a real verdict":
  if not haveNgspice:
    skip()
  else:
    # Worth pinning because the tempting answer is "unsolvable, so skip it".
    # ngspice does solve this network -- the rail genuinely sits at 0 V,
    # because nothing drives it -- so the honest report is a failure with a
    # witness, not a shrug. The paths that really cannot produce a number
    # (capability withheld, a NaN measurement, a simulation that raises) are
    # each covered separately.
    let d = design("floating"):
      net vdd, kind = ntPower
      net gnd, kind = ntGround, name = "0"
      component R1, kind = "resistor", value = "1000":
        pin "1", vdd, kind = ptPassive
        pin "2", gnd, kind = ptPassive
      require dc_voltage(vdd) == 3.3.V, id = "X"
    let r = resultFor(evaluate(d, allCapabilities), "X")
    check r.status == esFail
    check abs(r.value) < 1.0e-9

# --- setup recovered from the role that made the claim -------------------

test "a start-up claim with no regulator bound says exactly what is missing":
  # `overshoot_pct(vdd)` names the rail but not what drives it. Without a
  # role to read the topology back from, that is not evaluable -- and the
  # reason has to name the fix.
  let d = design("noreg"):
    net vdd, kind = ntPower
    net gnd, kind = ntGround, name = "0"
    component C1, kind = "capacitor", value = "10u":
      pin "1", vdd, kind = ptPassive
      pin "2", gnd, kind = ptGround
    require overshoot_pct(vdd) <= 5.0, id = "OS"
  let r = resultFor(evaluate(d, allCapabilities), "OS")
  check r.status == esNotEvaluable
  check "regulator" in r.reason

test "a regulator role supplies the topology its own claims need":
  let d = design("reg"):
    net vin, kind = ntPower
    net vdd, kind = ntPower
    net gnd, kind = ntGround, name = "0"
    component U1, kind = "regulator":
      pin "IN", vin, kind = ptPower
      pin "OUT", vdd, kind = ptPower
      pin "GND", gnd, kind = ptGround
    component C1, kind = "capacitor", value = "10u":
      pin "1", vdd, kind = ptPassive
      pin "2", gnd, kind = ptGround
    role "regulator", vdd_reg, regulator = U1, output = vdd,
                      voltage = 3.3.V, maxOvershoot = 5.0

  # The claim carries only the rail as its subject; the regulator designator
  # comes back through `Assertion.origin` -> the role instance's bindings.
  let p = plan(d, allCapabilities)
  var startupSteps = 0
  for s in p.steps:
    if s.evaluator == "spice.startup": inc startupSteps
  check startupSteps == 1
  check "U1" in p.steps[0].key

test "a PDN target is claimed only when the designer states one":
  let bare = design("bare"):
    net vdd, kind = ntPower
    role "power_rail", r0, rail = vdd, voltage = 3.3.V
  for a in bare.expandAll():
    check a.quantity != "z_max_in_band"

  let targeted = design("targeted"):
    net vdd, kind = ntPower
    role "power_rail", r0, rail = vdd, voltage = 3.3.V, targetZ = 50.mohm
  var found = false
  for a in targeted.expandAll():
    if a.quantity == "z_max_in_band":
      found = true
      check a.expect.kind == ekMax
      check abs(a.expect.hi - 0.05) < 1.0e-12
      # The band is bounded at both ends, or every board fails for something
      # no capacitor change can fix.
      check a.condition.hasKey("f_from")
      check a.condition.hasKey("f_to")
  check found
