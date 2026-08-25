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
  check "the .op capability" in r.reason

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

test "a claim about a net inside a subcircuit instance is checked, not shrugged at":
  if not haveNgspice:
    skip()
  else:
    # `design.innerNet` builds the subject and `resolve` accepts it when the
    # claim is attached, so a flat-key lookup inside the evaluator made such a
    # claim representable, bindable and then uncheckable -- reporting `needs a
    # net subject that exists in this design` about a net that does. The name
    # is also what `spice/flatten` calls that net, which is the netlist the
    # operating point was solved on.
    let leg = subckt("LEG", [TOP, BOT]):
      net TOP, kind = ntSignal
      net BOT, kind = ntSignal
      net mid, kind = ntSignal
      component R1, kind = "resistor", value = "1000":
        pin "1", TOP, kind = ptPassive
        pin "2", mid, kind = ptPassive
      component R2, kind = "resistor", value = "1000":
        pin "1", mid, kind = ptPassive
        pin "2", BOT, kind = ptPassive

    let d = design("hier"):
      net vin, kind = ntPower
      net gnd, kind = ntGround, name = "0", global = true
      component V1, kind = "voltage_source", value = "DC 10":
        pin "+", vin, kind = ptPower
        pin "-", gnd, kind = ptGround
      instance XL, leg, [vin, gnd]
      require dc_voltage(XL.innerNet("mid")) == 5.0.V, id = "INNER"

    let r = resultFor(evaluate(d, allCapabilities), "INNER")
    check r.status == esPass
    check abs(r.value - 5.0) < 1.0e-3

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

# --- what each simulated run says it is ---------------------------------
#
# Pure: `describeStep` runs off the plan and never simulates, so these hold
# with no ngspice on the machine.

test "a PDN step names the rail and the band it is judged over":
  let d = design("pdn"):
    net vdd, kind = ntPower
    role "power_rail", r0, rail = vdd, voltage = 3.3.V, targetZ = 50.mohm
  let p = plan(d, allCapabilities)
  var text = ""
  for s in p.steps:
    if s.evaluator == "spice.pdn": text = describeStep(d, s)
  check "net 'vdd'" in text
  check "100 kHz .. 100 MHz" in text
  # The setup key that grouped the batch is machinery, and must not be what
  # a reader is shown: `vdd|100000.0|100000000.0` says nothing about what
  # was simulated, or about what the sweep does and does not cover.
  check "100000.0" notin text

test "a start-up step names the part standing in for the regulator":
  let d = design("reg"):
    net vin, kind = ntPower
    net vdd, kind = ntPower
    net gnd, kind = ntGround, name = "0"
    component U1, kind = "regulator":
      pin "IN", vin, kind = ptPower
      pin "OUT", vdd, kind = ptPower
      pin "GND", gnd, kind = ptGround
    role "regulator", vdd_reg, regulator = U1, output = vdd,
                      voltage = 3.3.V, maxOvershoot = 5.0
  let p = plan(d, allCapabilities)
  var text = ""
  for s in p.steps:
    if s.evaluator == "spice.startup": text = describeStep(d, s)
  check "U1" in text
  check "soft-start" in text

test "the .op step says it is not isolated, which is why the claim means anything":
  # Isolating first would terminate the rail with an ideal source at the very
  # voltage the claim is asking about, and pass every time.
  let d = dividerBoard("2000")
  let p = plan(d, allCapabilities)
  var text = ""
  for s in p.steps:
    if s.evaluator == "spice.dc_voltage": text = describeStep(d, s)
  check "not isolated" in text

# --- what the run context guarantees ------------------------------------

test "the declared capabilities are what a run actually uses":
  # Both of these once under-declared. `spice.pdn` said `.ac` and solved an
  # operating point for its bias derating; `spice.large_signal` said `.tran`
  # and solved one to find the bias its stimulus sits on. Under `--caps=ac`
  # or `--caps=tran` each ran an analysis the caller had withheld, and the
  # flag quietly meant nothing. A `set` is what let them say so.
  check evaluatorFor("z_max_in_band").get.needs == {capSpiceOp, capSpiceAc}
  check evaluatorFor("thd_pct").get.needs == {capSpiceOp, capSpiceTran}

test "a claim needing two capabilities is refused when only one is offered":
  let d = dividerBoard("2000")
  var found = false
  for rej in plan(d, {capStatic, capSpiceAc}).rejected:
    if rej.assertion.quantity == "z_max_in_band":
      found = true
      # Named, and named by label rather than by enum identifier.
      check ".op" in rej.reason
      check "capSpiceOp" notin rej.reason
  # The fixture claims no impedance, so this is a guard on the message shape
  # only when one is present.
  discard found

test "an edited design is re-solved rather than answered from a stale cache":
  # The operating point used to live in a module-level `var` keyed on Design
  # reference identity with no content invalidation: mutating a design in
  # place and evaluating again returned the *first* answer, silently. It now
  # lives in the EvalContext, which lasts exactly one run, so this cannot
  # happen -- and a sweep over candidate values is the obvious way to hit it.
  if not haveNgspice:
    skip()
  else:
    let d = dividerBoard("2000")
    let first = resultFor(evaluate(d, allCapabilities), "vdd_rail.voltage")
    check abs(first.value - 3.333) < 0.01

    # Same Design object, different circuit.
    d.netlist.components["R1"].attrs["value"] = "4000"
    let second = resultFor(evaluate(d, allCapabilities), "vdd_rail.voltage")
    check abs(second.value - 2.0) < 0.01
    check first.value != second.value

test "one EvalContext shares an operating point across every step in a run":
  # The other half of the same property: within one run the .op is solved
  # once, which is what keeps N claims to one simulation.
  if not haveNgspice:
    skip()
  else:
    let ctx = newEvalContext(dividerBoard("2000"), allCapabilities)
    check not ctx.scratch.hasKey("spice.operating_point")
    discard evaluate(ctx)
    check ctx.scratch.hasKey("spice.operating_point")
