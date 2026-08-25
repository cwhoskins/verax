import std/[math, strutils, tables, unittest]

import nimcir/netlist
import nimcir/netlist/annotations
import nimcir/contract
import nimcir/units

proc board(): Design =
  let nl = newNetlist("board")
  let vdd = addNet(nl, newNet("vdd", ntPower))
  let gnd = addNet(nl, newNet("0", ntGround))
  let sda = addNet(nl, newNet("sda", ntSignal))
  let scl = addNet(nl, newNet("scl", ntSignal))
  let u1 = addComponent(nl, newComponent("U1", kind = "mcu"))
  discard connect(u1, "VDD", vdd, ptPower)
  discard connect(u1, "GND", gnd, ptGround)
  discard connect(u1, "SDA", sda, ptInOut)
  discard connect(u1, "SCL", scl, ptInOut)
  newDesign(nl)

proc net(name: string): Subject = Subject(kind: skNet, name: name)
proc comp(name: string): Subject = Subject(kind: skComponent, name: name)

# --- expectations ------------------------------------------------------

test "satisfies implements the acceptance interval":
  check nominal(3.3, fracTol = 0.05).satisfies(3.4)
  check not nominal(3.3, fracTol = 0.05).satisfies(3.6)
  check atLeast(1.0).satisfies(1.0)
  check not atLeast(1.0).satisfies(0.999)
  check atMost(0.1).satisfies(0.05)
  check between(1.0, 2.0).satisfies(1.5)
  check not between(1.0, 2.0).satisfies(2.5)

test "a NaN never satisfies anything -- 'not measured' is not a pass":
  check not nominal(3.3, fracTol = 0.5).satisfies(NaN)
  check not atLeast(0.0).satisfies(NaN)

test "when both tolerances are given the wider one wins":
  # Each is an independent statement of what is acceptable, so meeting
  # either should pass.
  let e = nominal(1.0, fracTol = 0.01, absTol = 0.5)
  check e.satisfies(1.4)
  check e.bounds.lo == 0.5

# --- roles -------------------------------------------------------------

test "the built-ins are registered and describe their own parts":
  check isRole("power_rail")
  check isRole("i2c")
  check roleDef("power_rail").parts[0].name == "rail"
  check roleDef("i2c").parts.len == 4

test "a power_rail writes its voltage where existing consumers already look":
  # This is the half of a role that is an *input* rather than a claim:
  # spice/isolate reads Net.attrs["voltage"] and knows nothing about roles.
  let d = board()
  discard d.addRole("power_rail", "vdd_rail", {"rail": net("vdd")},
                    {"voltage": "3.3"})
  let v = railVoltage(d.netlist.nets["vdd"])
  check v.has
  check abs(v.value - 3.3) < 1e-12
  check validateAnnotations(d.netlist).len == 0

test "a power_rail expands to a nominal-voltage assertion":
  let d = board()
  discard d.addRole("power_rail", "vdd_rail", {"rail": net("vdd")},
                    {"voltage": "3.3", "band": "0.05"})
  let a = d.expandAll()
  check a.len == 1
  check a[0].quantity == "dc_voltage"
  check a[0].id == "vdd_rail.voltage"
  check a[0].origin == "vdd_rail"
  check a[0].subjects == @[net("vdd")]
  check a[0].expect.satisfies(3.4)
  check not a[0].expect.satisfies(3.6)
  check a[0].rationale.len > 0

test "the band defaults to 5% and the default is applied by the role, not the registry":
  let d = board()
  discard d.addRole("power_rail", "r", {"rail": net("vdd")}, {"voltage": "3.3"})
  let a = d.expandAll()[0]
  check abs(a.expect.bounds.hi - 3.3 * 1.05) < 1e-12

test "an i2c bus expands to pull-up, RC-corner, sink-current and controller claims":
  let d = board()
  discard d.addRole("i2c", "i2c0",
                    {"sda": net("sda"), "scl": net("scl"),
                     "pullupRail": net("vdd"), "controller": comp("U1")},
                    {"frequency": "400000"})
  let a = d.expandAll()
  var quantities: seq[string]
  for x in a: quantities.add x.quantity
  check "pullup_count" in quantities
  check "rc_corner" in quantities
  check "controller_count" in quantities
  # The sink current bounds the pull-up from *below*, which rc_corner does
  # not: the two limits squeeze from opposite sides.
  check "pullup_sink_current" in quantities
  check a.len == 7      # 2 lines x (pullup + corner + sink), plus controllers

  for x in a:
    if x.quantity == "rc_corner":
      # 10x margin over the 400 kHz clock.
      check abs(x.expect.bounds.lo - 4.0e6) < 1.0
      check x.unit == "Hz"

test "role membership is tagged on the entities, not held only in the Design":
  let d = board()
  discard d.addRole("i2c", "i2c0",
                    {"sda": net("sda"), "scl": net("scl")}, {"frequency": "100000"})
  check d.netlist.nets["sda"].attrs["role.i2c0"] == "sda"
  check rolesOf(d.netlist.nets["scl"]) == @[(instance: "i2c0", part: "scl")]

test "membership survives a clone, which is why it lives on the entity":
  let d = board()
  discard d.addRole("i2c", "i2c0",
                    {"sda": net("sda"), "scl": net("scl")}, {"frequency": "100000"})
  var globals: OrderedTable[string, Net]
  let copy = clone(d.netlist, globals)
  check rolesOf(copy.nets["sda"]) == @[(instance: "i2c0", part: "sda")]

test "role membership tags are namespaced, so they never trip validation":
  let d = board()
  discard d.addRole("i2c", "i2c0",
                    {"sda": net("sda"), "scl": net("scl")}, {"frequency": "100000"})
  check validateAnnotations(d.netlist).len == 0

# --- validation --------------------------------------------------------

test "a missing required part is rejected at attach time":
  let d = board()
  expect(NetlistError):
    discard d.addRole("i2c", "i2c0", {"sda": net("sda")}, {"frequency": "100000"})

test "an optional part may be omitted":
  let d = board()
  discard d.addRole("i2c", "i2c0",
                    {"sda": net("sda"), "scl": net("scl")}, {"frequency": "100000"})
  check d.roles.len == 1

test "a part bound to the wrong kind of subject is rejected":
  let d = board()
  expect(NetlistError):
    discard d.addRole("power_rail", "r", {"rail": comp("U1")}, {"voltage": "3.3"})

test "a binding to something that does not exist is rejected":
  let d = board()
  expect(NetlistError):
    discard d.addRole("power_rail", "r", {"rail": net("nosuchnet")}, {"voltage": "3.3"})

test "unknown parts and unknown parameters are rejected, and say what is valid":
  let d = board()
  try:
    discard d.addRole("power_rail", "r",
                      {"rail": net("vdd"), "raill": net("vdd")}, {"voltage": "3.3"})
    check false
  except NetlistError as e:
    check "rail" in e.msg
  expect(NetlistError):
    discard d.addRole("power_rail", "r2", {"rail": net("vdd")}, {"voltag": "3.3"})

test "a parameter that is not a plain SI value is rejected":
  let d = board()
  expect(NetlistError):
    discard d.addRole("power_rail", "r", {"rail": net("vdd")}, {"voltage": "3v3"})

test "duplicate instance names are rejected":
  let d = board()
  discard d.addRole("power_rail", "r", {"rail": net("vdd")}, {"voltage": "3.3"})
  expect(NetlistError):
    discard d.addRole("power_rail", "r", {"rail": net("vdd")}, {"voltage": "3.3"})

# --- authored assertions and inspection --------------------------------

test "assertions can be authored directly alongside role-expanded ones":
  let d = board()
  discard d.addRole("power_rail", "vdd_rail", {"rail": net("vdd")}, {"voltage": "3.3"})
  d.assertThat Assertion(
    id: "REQ-1", subjects: @[net("sda")], quantity: "rc_corner",
    expect: atLeast(1.0e6), unit: "Hz", severity: sevWarning)
  let a = d.expandAll()
  check a.len == 2
  check a[0].origin == "authored"
  check a[1].origin == "vdd_rail"

test "explain prints what each role actually expanded to":
  let d = board()
  discard d.addRole("power_rail", "vdd_rail", {"rail": net("vdd")}, {"voltage": "3.3"})
  let text = d.explain()
  check "vdd_rail : power_rail" in text
  check "rail = net 'vdd'" in text
  check "dc_voltage" in text

# --- extensibility: the whole point ------------------------------------

proc myBusExpand(inst: RoleInstance): seq[Assertion] =
  let clk = inst.subject("clk")
  @[Assertion(id: inst.name & ".corner", subjects: @[clk], quantity: "rc_corner",
              expect: atLeast(paramFloat(inst, "frequency", 1.0e6) * 5.0),
              unit: "Hz", severity: sevWarning, origin: inst.name)]

test "a user-defined role uses exactly the same mechanism as a built-in":
  registerRole(RoleDef(
    name: "my_weird_bus",
    parts: @[RolePart(name: "clk", kind: skNet), RolePart(name: "data", kind: skNet)],
    params: @[AnnDef(key: "frequency", kind: akFloat, unit: "Hz", scopes: {asNet})],
    expand: myBusExpand))

  let d = board()
  discard d.addRole("my_weird_bus", "bus0",
                    {"clk": net("scl"), "data": net("sda")}, {"frequency": "2000000"})
  let a = d.expandAll()
  check a.len == 1
  check abs(a[0].expect.bounds.lo - 1.0e7) < 1.0
  # Same validation, same membership tagging, same expansion path.
  check rolesOf(d.netlist.nets["scl"]) == @[(instance: "bus0", part: "clk")]
  expect(NetlistError):
    discard d.addRole("my_weird_bus", "bus1", {"clk": net("scl")})

test "a role with no expander cannot be registered":
  expect(NetlistError):
    registerRole(RoleDef(name: "broken", parts: @[], expand: nil))

# --- gain_stage: claims for a stage that has no meaningful DC gain -----

proc ampBoard(): Design =
  let nl = newNetlist("amp")
  discard addNet(nl, newNet("vin", ntSignal))
  discard addNet(nl, newNet("vout", ntSignal))
  let u1 = addComponent(nl, newComponent("U1", kind = "opamp"))
  discard connect(u1, "IN+", nl.nets["vin"], ptInput)
  discard connect(u1, "OUT", nl.nets["vout"], ptOutput)
  newDesign(nl)

test "a gain_stage with no parameters claims nothing":
  # Same rule as power_rail's targetZ: a gain specification comes from what
  # the stage is for, and a default would manufacture a requirement the
  # designer never made.
  let d = ampBoard()
  discard d.addRole("gain_stage", "s", {"opamp": comp("U1"),
                                        "input": net("vin"),
                                        "output": net("vout")})
  check d.expandAll().len == 0

test "a gain_stage claims against the response maximum, not against DC":
  let d = ampBoard()
  discard d.addRole("gain_stage", "s", {"opamp": comp("U1"),
                                        "input": net("vin"),
                                        "output": net("vout")},
                    {"minGain": "20.0", "fLoMax": "100.0", "fHiMin": "20000.0"})
  let a = d.expandAll()
  check a.len == 3
  var byQuantity: seq[string]
  for x in a: byQuantity.add x.quantity
  check "gain_max_db" in byQuantity
  check "f_lo_3db" in byQuantity
  check "f_hi_3db" in byQuantity
  check "gain_dc_db" notin byQuantity
  for x in a:
    check x.origin == "s"
    check x.rationale.len > 0

test "stating atF moves the gain claim onto that frequency":
  let d = ampBoard()
  discard d.addRole("gain_stage", "s", {"opamp": comp("U1"),
                                        "input": net("vin"),
                                        "output": net("vout")},
                    {"minGain": "20.0", "maxGain": "26.0", "atF": "1000.0"})
  let a = d.expandAll()
  check a.len == 2
  for x in a:
    check x.quantity == "gain_at_f"
    check x.unit == "dB"
    # The frequency has to reach the evaluator, which reads it back off the
    # condition -- an assertion carries no other channel for it.
    check x.condition["at_f"] == "1000.0"
  check a[0].expect.satisfies(22.0)
  check not a[0].expect.satisfies(18.0)

test "a gain_stage makes no stability claim":
  # peaking_db cannot tell an intentional band-pass shape from resonance,
  # and a margin belongs to opamp_stage, which can be stated alongside.
  let d = ampBoard()
  discard d.addRole("gain_stage", "s", {"opamp": comp("U1"),
                                        "input": net("vin"),
                                        "output": net("vout")},
                    {"minGain": "20.0", "maxGain": "26.0",
                     "fLoMax": "100.0", "fHiMin": "20000.0"})
  for x in d.expandAll():
    check x.quantity notin ["peaking_db", "phase_margin_deg", "gain_margin_db"]

# --- declining a role's always-claims ----------------------------------

test "a role instance can decline one of its always-claims":
  # opamp_stage claims phase_margin_deg unconditionally, and there are
  # topologies -- a Sallen-Key -- where analyzeLoopGain cannot open the loop
  # and the claim can only ever come back unchecked.
  let d = ampBoard()
  discard d.addRole("opamp_stage", "s", {"opamp": comp("U1"),
                                         "input": net("vin"),
                                         "output": net("vout")},
                    {"without": "phase_margin"})
  var quantities: seq[string]
  for a in d.expandAll(): quantities.add a.quantity
  check "phase_margin_deg" notin quantities
  check "peaking_db" in quantities

test "declining several claims at once":
  let d = ampBoard()
  discard d.addRole("opamp_stage", "s", {"opamp": comp("U1"),
                                         "input": net("vin"),
                                         "output": net("vout")},
                    {"without": "phase_margin, peaking"})
  check d.expandAll().len == 0

test "declining a claim the role does not make is an error":
  # The same hazard as a misspelled annotation key: indistinguishable from
  # an absent one, and it would leave the claim standing while reading as
  # though it had been dropped.
  let d = ampBoard()
  expect NetlistError:
    discard d.addRole("opamp_stage", "s", {"opamp": comp("U1"),
                                           "input": net("vin"),
                                           "output": net("vout")},
                      {"without": "phase_margn"})

test "the error names what the role actually claims":
  let d = ampBoard()
  try:
    discard d.addRole("opamp_stage", "s", {"opamp": comp("U1"),
                                           "input": net("vin"),
                                           "output": net("vout")},
                      {"without": "nonsense"})
    check false
  except NetlistError as e:
    check "phase_margin" in e.msg
    check "peaking" in e.msg

test "`without` is not treated as a role parameter":
  # It is reserved on every role rather than declared by each one, so it must
  # not reach parameter validation -- which would reject it as unknown.
  let d = ampBoard()
  let inst = d.addRole("opamp_stage", "s", {"opamp": comp("U1"),
                                            "input": net("vin"),
                                            "output": net("vout")},
                       {"without": "phase_margin"})
  check not inst.params.hasKey("without")
  check inst.declined == @["phase_margin"]

test "explain says what was declined -- dropping a claim is never silent":
  let d = ampBoard()
  discard d.addRole("opamp_stage", "s", {"opamp": comp("U1"),
                                         "input": net("vin"),
                                         "output": net("vout")},
                    {"without": "phase_margin"})
  let text = d.explain()
  check "declines phase_margin" in text
  # And what it prints matches what it checks.
  check "phase_margin_deg" notin text

# --- large_signal: drive level is a condition, not a limit -------------

test "a large_signal role stamps the drive into the assertion's condition":
  # It is the only channel an assertion has for a setup parameter, and the
  # evaluator's setup key reads it back so two drive levels stay two runs.
  let d = ampBoard()
  discard d.addRole("large_signal", "od", {"opamp": comp("U1"),
                                           "input": net("vin"),
                                           "output": net("vout")},
                    {"driveV": "0.05", "driveF": "1000.0", "maxThd": "45.0"})
  let a = d.expandAll()
  check a.len == 1
  check a[0].quantity == "thd_pct"
  check a[0].condition["drive_v"] == "0.05"
  check a[0].condition["drive_f"] == "1000.0"

test "a large_signal role with no limits claims nothing":
  let d = ampBoard()
  discard d.addRole("large_signal", "od", {"opamp": comp("U1"),
                                           "input": net("vin"),
                                           "output": net("vout")},
                    {"driveV": "0.05"})
  check d.expandAll().len == 0

test "too little distortion can be the defect":
  # On an overdrive a stage measuring clean has lost its clippers, so the
  # claim goes both ways.
  let d = ampBoard()
  discard d.addRole("large_signal", "od", {"opamp": comp("U1"),
                                           "input": net("vin"),
                                           "output": net("vout")},
                    {"driveV": "0.05", "minThd": "10.0", "maxThd": "45.0"})
  let a = d.expandAll()
  check a.len == 2
  for x in a: check x.quantity == "thd_pct"
  check a[0].expect.satisfies(20.0)
  check a[1].expect.satisfies(20.0)
  check not a[0].expect.satisfies(60.0)     # over the ceiling
  check not a[1].expect.satisfies(2.0)      # under the floor

# --- settled_rail -----------------------------------------------------------

test "a settled_rail role binds no driving part and claims nothing by default":
  # Which is the point of it: `regulator` needs a part to stand up as a ramp
  # and `opamp_stage` needs an amplifier, so neither reaches a charge pump, an
  # oscillator or a converter measured cycle by cycle. This one names a net
  # and a window.
  let d = board()
  discard d.addRole("settled_rail", "r", {"rail": net("vdd")},
                    {"tSettle": "0.0003", "tWindow": "0.00002"})
  check d.expandAll().len == 0

test "a settled_rail role stamps its window into the assertion's condition":
  let d = board()
  discard d.addRole("settled_rail", "r", {"rail": net("vdd")},
                    {"tSettle": "0.0003", "tWindow": "0.00002",
                     "voltage": "4.962", "band": "0.02",
                     "maxRipple": "0.01"})
  let a = d.expandAll()
  check a.len == 2
  var byQty: Table[string, Assertion]
  for x in a: byQty[x.quantity] = x
  check byQty.hasKey("settled_v")
  check byQty.hasKey("ripple_pp")
  for x in a:
    # The window is what was *run*, not what is claimed, so it rides in
    # `condition` and the evaluator's setup key reads it back -- two claims
    # over two windows have to stay two runs.
    check x.condition["t_settle"] == "0.0003"
    check x.condition["t_window"] == "0.00002"
  check byQty["settled_v"].expect.satisfies(4.962 * 1.019)
  check not byQty["settled_v"].expect.satisfies(4.962 * 1.021)
  check byQty["ripple_pp"].expect.satisfies(0.0099)
  check not byQty["ripple_pp"].expect.satisfies(0.0101)

test "a ripple budget alone is a claim; a voltage alone is a different one":
  let d1 = board()
  discard d1.addRole("settled_rail", "r", {"rail": net("vdd")},
                     {"tSettle": "0.001", "maxRipple": "0.01"})
  let a1 = d1.expandAll()
  check a1.len == 1
  check a1[0].quantity == "ripple_pp"

  let d2 = board()
  discard d2.addRole("settled_rail", "r", {"rail": net("vdd")},
                     {"tSettle": "0.001", "voltage": "3.3"})
  let a2 = d2.expandAll()
  check a2.len == 1
  check a2[0].quantity == "settled_v"
