import std/[math, sequtils, strutils, tables, unittest]

import verax/netlist
import verax/netlist/annotations
import verax/contract
import verax/units

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

# --- channel_match: a quantity whose subjects are two role instances ---

proc stereoBoard(): Design =
  let nl = newNetlist("stereo")
  for n in ["inL", "outL", "inR", "outR"]:
    discard addNet(nl, newNet(n, ntSignal))
  for u in ["UL", "UR"]:
    let sig = (if u == "UL": ("inL", "outL") else: ("inR", "outR"))
    let c = addComponent(nl, newComponent(u, kind = "opamp"))
    discard connect(c, "IN+", nl.nets[sig[0]], ptInput)
    discard connect(c, "OUT", nl.nets[sig[1]], ptOutput)
  newDesign(nl)

proc withStages(d: Design) =
  discard d.addRole("gain_stage", "left",
    {"opamp": comp("UL"), "input": net("inL"), "output": net("outL")},
    {"minGain": "20.0"})
  discard d.addRole("gain_stage", "right",
    {"opamp": comp("UR"), "input": net("inR"), "output": net("outR")},
    {"minGain": "20.0"})

test "roleRef binds another role instance as a skClass subject":
  let d = stereoBoard()
  withStages(d)
  let inst = d.addRole("channel_match", "stereo",
    {"a": roleRef("left"), "b": roleRef("right")}, {"maxGainDelta": "0.5"})
  check inst.bindings["a"].kind == skClass
  check inst.bindings["a"].name == "left"
  check inst.bindings["b"].name == "right"

test "channel_match expands to one claim carrying two skClass subjects":
  let d = stereoBoard()
  withStages(d)
  discard d.addRole("channel_match", "stereo",
    {"a": roleRef("left"), "b": roleRef("right")},
    {"maxGainDelta": "0.5", "fFrom": "20.0", "fTo": "20000.0"})
  let a = d.expandAll().filterIt(it.origin == "stereo")
  check a.len == 1
  check a[0].quantity == "gain_delta_max_db"
  check a[0].subjects.len == 2
  check a[0].subjects[0].kind == skClass
  check a[0].subjects[1].kind == skClass
  # The band is setup: it rides in the condition and never gates a claim.
  check a[0].condition["f_from"] == "20.0"
  check a[0].condition["f_to"] == "20000.0"
  check a[0].expect.satisfies(0.4)
  check not a[0].expect.satisfies(0.6)

test "maxEdgeRatio adds the two band-edge ratio claims, still two subjects":
  let d = stereoBoard()
  withStages(d)
  discard d.addRole("channel_match", "stereo",
    {"a": roleRef("left"), "b": roleRef("right")}, {"maxEdgeRatio": "1.1"})
  let a = d.expandAll().filterIt(it.origin == "stereo")
  var qs: seq[string]
  for x in a:
    qs.add x.quantity
    check x.subjects.len == 2
  check "f_lo_ratio" in qs
  check "f_hi_ratio" in qs

test "atF redirects the gain-delta claim rather than adding a second":
  let d = stereoBoard()
  withStages(d)
  discard d.addRole("channel_match", "stereo",
    {"a": roleRef("left"), "b": roleRef("right")},
    {"maxGainDelta": "0.5", "atF": "1000.0"})
  let a = d.expandAll().filterIt(it.origin == "stereo")
  check a.len == 1
  check a[0].quantity == "gain_delta_at_f"
  check a[0].condition["at_f"] == "1000.0"

test "a channel_match with no limits claims nothing":
  let d = stereoBoard()
  withStages(d)
  discard d.addRole("channel_match", "stereo",
    {"a": roleRef("left"), "b": roleRef("right")}, {"fFrom": "20.0"})
  check d.expandAll().filterIt(it.origin == "stereo").len == 0

test "referencing a role that is not declared yet raises, naming the ordering":
  let d = stereoBoard()
  # Neither stage declared -- `channel_match` cannot come first.
  try:
    discard d.addRole("channel_match", "stereo",
      {"a": roleRef("left"), "b": roleRef("right")}, {"maxGainDelta": "0.5"})
    check false
  except NetlistError as e:
    check "left" in e.msg
    check "after" in e.msg

test "binding a net to a skClass part is rejected":
  let d = stereoBoard()
  withStages(d)
  expect NetlistError:
    discard d.addRole("channel_match", "stereo",
      {"a": net("inL"), "b": roleRef("right")}, {"maxGainDelta": "0.5"})

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

# --- oscillator -------------------------------------------------------------

test "an oscillator role claims nothing by default and binds no driving part":
  # The same rule `settled_rail` follows, and for a sharper reason: there is
  # no default frequency for an oscillator, and defaulting one would state a
  # claim the designer never made and then report it as theirs.
  let d = board()
  discard d.addRole("oscillator", "osc", {"output": net("sda")},
                    {"tSettle": "0.15", "tWindow": "0.02"})
  check d.expandAll().len == 0

test "an oscillator role stamps its window and its kick into the condition":
  let d = board()
  discard d.addRole("oscillator", "osc",
                    {"output": net("sda"), "kick": net("scl")},
                    {"tSettle": "0.15", "tWindow": "0.02", "kickV": "0.01",
                     "freq": "1591.55", "band": "0.02",
                     "minSwing": "2.0", "maxSwing": "2.8", "maxThd": "6.0"})
  let a = d.expandAll()
  check a.len == 4
  var byId: Table[string, Assertion]
  for x in a: byId[x.id] = x
  check byId.hasKey("osc.freq")
  check byId.hasKey("osc.swing")
  check byId.hasKey("osc.swing_max")
  check byId.hasKey("osc.thd")
  for x in a:
    # Where the circuit was started from and how hard is setup, not a claim:
    # two claims started differently have to stay two runs.
    check x.condition["t_settle"] == "0.15"
    check x.condition["t_window"] == "0.02"
    check x.condition["kick_v"] == "0.01"
  check byId["osc.freq"].expect.satisfies(1591.55 * 1.019)
  check not byId["osc.freq"].expect.satisfies(1591.55 * 1.021)
  check byId["osc.swing"].expect.satisfies(2.4)
  check not byId["osc.swing"].expect.satisfies(1.9)
  check byId["osc.thd"].expect.satisfies(4.2)
  check not byId["osc.thd"].expect.satisfies(6.1)

test "the kick is optional -- a circuit that starts by itself binds none":
  let d = board()
  discard d.addRole("oscillator", "osc", {"output": net("sda")},
                    {"tSettle": "0.15", "freq": "1000.0"})
  let a = d.expandAll()
  check a.len == 1
  check a[0].quantity == "osc_freq"
  # Defaulted rather than absent, so the evaluator's setup key is total.
  check a[0].condition["kick_v"] == "0.1"

test "a regulator role stamps its run length onto every claim it makes":
  # Four of the five assertions sit behind an `if`, so a condition applied at
  # each `add` is how one of them ends up planned into a second run.
  let d = board()
  discard d.addRole("regulator", "reg",
                    {"regulator": comp("U1"), "output": net("vdd")},
                    {"voltage": "4.962", "tRun": "0.008",
                     "maxRiseTime": "0.005", "maxSettleTime": "0.006",
                     "maxInrush": "3.0"})
  let a = d.expandAll()
  check a.len == 5
  for x in a:
    check x.condition["t_run"] == "0.008"

# --- the load-step, rejection and output-current claims ------------------
#
# All three are `regulator`'s, and `linear_regulator` and
# `switching_regulator` reach them by expanding it rather than by repeating
# it. What the tests below pin is mostly that: what the base claims, that a
# specialisation adds to it and subtracts nothing, and that every parameter
# that changes a *run* reaches the assertion's condition -- because a
# condition that does not get stamped is a claim quietly planned into a
# second simulation, which is the one failure mode here that looks like
# success.

proc regBoard(): Design =
  ## A part with a rating on it, a rail, a supply and something carrying the
  ## output current -- the four things the specialised roles bind.
  let nl = newNetlist("reg")
  let vin = addNet(nl, newNet("vin", ntPower))
  let vdd = addNet(nl, newNet("vdd", ntPower))
  let sw = addNet(nl, newNet("sw", ntSignal))
  let gnd = addNet(nl, newNet("0", ntGround))
  let u1 = addComponent(nl, newComponent("U1", kind = "buck"))
  discard connect(u1, "VIN", vin, ptPower)
  discard connect(u1, "SW", sw, ptOutput)
  discard connect(u1, "GND", gnd, ptGround)
  u1.attrs["current_rating"] = "5.0"
  let l1 = addComponent(nl, newComponent("L1", kind = "inductor"))
  l1.attrs["value"] = "3.3u"
  discard connect(l1, "1", sw, ptPassive)
  discard connect(l1, "2", vdd, ptPassive)
  let v1 = addComponent(nl, newComponent("V1", kind = "voltage_source"))
  v1.attrs["value"] = "DC 12"
  discard connect(v1, "+", vin, ptPower)
  discard connect(v1, "-", gnd, ptGround)
  newDesign(nl)

proc byId(a: seq[Assertion], id: string): Assertion =
  for x in a:
    if x.id == id: return x
  raise newException(ValueError, "no assertion " & id & " in " &
    a.mapIt(it.id).join(", "))

proc ids(a: seq[Assertion]): seq[string] = a.mapIt(it.id)

test "a regulator claims no load step, no rejection and no current by default":
  # The whole point of putting these on the base role: every one of them is
  # opt-in, so the three designs and one template that already instantiate
  # `regulator` expand to exactly what they did before.
  let d = regBoard()
  discard d.addRole("regulator", "r",
                    {"regulator": comp("U1"), "output": net("vdd")},
                    {"voltage": "5.0", "tRun": "0.008"})
  let a = d.expandAll()
  for x in a:
    check x.quantity in ["final_v", "overshoot_pct"]

test "each load-step claim is gated on its own limit, not on the step":
  # `source_sweep`'s shape rather than an oversight. Gating the group on the
  # magnitude also hid it from `verify.claimingRoles`, which expands each
  # parameter alone and so never had a step and a limit at the same time.
  let d = regBoard()
  discard d.addRole("regulator", "r",
                    {"regulator": comp("U1"), "output": net("vdd")},
                    {"voltage": "5.0", "tRun": "0.008",
                     "without": "final_v,overshoot",
                     "maxDroop": "0.05"})
  let a = d.expandAll()
  check ids(a) == @["r.droop"]
  check a[0].quantity == "step_droop_v"

test "a load-step limit with no step still expands -- the evaluator refuses it":
  # The magnitude is setup and rides in the conditions, so a claim missing
  # one reaches the evaluator and is refused there by name. Expanding to
  # nothing instead would lose the claim silently.
  let d = regBoard()
  discard d.addRole("regulator", "r",
                    {"regulator": comp("U1"), "output": net("vdd")},
                    {"without": "overshoot", "maxRecover": "3.0e-5"})
  let a = d.expandAll()
  check ids(a) == @["r.recover"]
  check a[0].condition["step_to"] == "0.0"

test "everything that changes the load-step run reaches the condition":
  let d = regBoard()
  discard d.addRole("regulator", "r",
                    {"regulator": comp("U1"), "output": net("vdd")},
                    {"without": "overshoot",
                     "iFrom": "0.5", "iTo": "2.0", "tEdge": "1.0e-6",
                     "tStepAt": "3.0e-4", "tHold": "5.0e-5",
                     "tRecover": "4.0e-5", "stepPoints": "2000",
                     "stepBand": "0.001",
                     "maxDroop": "0.05", "maxDroopPct": "1.0",
                     "minStepV": "4.8", "maxStepOvershoot": "0.06",
                     "maxRecover": "3.0e-5"})
  let a = d.expandAll()
  check a.len == 5
  for x in a:
    check x.condition["step_from"] == "0.5"
    check x.condition["step_to"] == "2.0"
    check x.condition["step_edge"] == "0.000001"
    check x.condition["step_at"] == "0.0003"
    check x.condition["step_hold"] == "0.00005"
    check x.condition["step_recover"] == "0.00004"
    check x.condition["step_points"] == "2000.0"
    check x.condition["step_band"] == "0.001"
  # One run, therefore, for all five: identical conditions are what the
  # evaluator's setup key is built from.
  check a.mapIt($it.condition).deduplicate().len == 1

test "the two rejection limits select two different quantities":
  # `minPsrrDb` is the tone through a `.tran`; `minPsrrBandDb` is the `.ac`
  # sweep. Which one runs is decided by which limit is stated rather than by
  # a mode string -- a string parameter is invisible to `claimingRoles`,
  # which expands with a numeric placeholder.
  let d = regBoard()
  discard d.addRole("linear_regulator", "r",
                    {"regulator": comp("U1"), "output": net("vdd"),
                     "source": comp("V1"), "input": net("vin")},
                    {"without": "overshoot",
                     "minPsrrDb": "55.0", "minPsrrBandDb": "40.0",
                     "psrrRippleV": "0.1", "psrrFrom": "10.0",
                     "psrrTo": "10000.0"})
  let a = d.expandAll()
  check byId(a, "r.psrr").quantity == "psrr_db"
  check byId(a, "r.psrr_swept").quantity == "psrr_min_db"
  check byId(a, "r.psrr_swept").condition["f_from"] == "10.0"
  check byId(a, "r.psrr_swept").condition["f_to"] == "10000.0"

test "psrrAtF redirects the swept claim rather than adding a second one":
  # The `gain_stage`/`atF` pattern. Two claims about one curve would be one
  # claim that can only ever be weaker than the other.
  let d = regBoard()
  discard d.addRole("linear_regulator", "r",
                    {"regulator": comp("U1"), "output": net("vdd"),
                     "source": comp("V1"), "input": net("vin")},
                    {"without": "overshoot",
                     "minPsrrBandDb": "55.0", "psrrAtF": "120.0"})
  let a = d.expandAll()
  check ids(a) == @["r.psrr_swept"]
  check a[0].quantity == "psrr_at_f"
  check a[0].condition["at_f"] == "120.0"

test "the tone claim carries the amplitude, because a .tran is not linear":
  let d = regBoard()
  discard d.addRole("linear_regulator", "r",
                    {"regulator": comp("U1"), "output": net("vdd"),
                     "source": comp("V1"), "input": net("vin")},
                    {"without": "overshoot",
                     "minPsrrDb": "55.0", "psrrAtF": "120.0",
                     "psrrRippleV": "0.1", "tSettle": "0.04",
                     "psrrPeriods": "6", "psrrPoints": "400"})
  let a = d.expandAll()
  check a[0].condition["ripple_f"] == "120.0"
  check a[0].condition["ripple_v"] == "0.1"
  check a[0].condition["t_settle"] == "0.04"
  check a[0].condition["ripple_periods"] == "6.0"
  check a[0].condition["ripple_points"] == "400.0"

test "the output-current claims are made about the sense part, not the regulator":
  # Forced rather than chosen: a regulator that reaches the deck as a code
  # model or a subcircuit has no terminal current of its own to probe.
  let d = regBoard()
  discard d.addRole("switching_regulator", "r",
                    {"regulator": comp("U1"), "output": net("vdd"),
                     "sense": comp("L1")},
                    {"without": "overshoot",
                     "tSettle": "3.0e-4", "tWindow": "2.0e-5",
                     "maxOutputCurrent": "5.6", "maxOutputAvg": "5.2",
                     "maxOutputDerating": "1.0"})
  let a = d.expandAll()
  check a.len == 3
  for x in a:
    check x.subjects[0] == comp("L1")
    check x.condition["t_settle"] == "0.0003"
    check x.condition["t_window"] == "0.00002"
  check byId(a, "r.i_out_peak").quantity == "i_peak"
  check byId(a, "r.i_out_avg").quantity == "i_avg"
  check byId(a, "r.i_out_derating").quantity == "i_out_derating"

test "no sense part means no current claims, whatever the limits say":
  # There is nothing to probe, and guessing which part carries the output
  # current is exactly the guess the binding exists to remove.
  let d = regBoard()
  discard d.addRole("switching_regulator", "r",
                    {"regulator": comp("U1"), "output": net("vdd")},
                    {"without": "overshoot",
                     "maxOutputCurrent": "5.6", "maxOutputDerating": "1.0"})
  check d.expandAll().len == 0

test "linear_regulator is regulator plus its own, and subtracts nothing":
  let d = regBoard()
  let common = @{"voltage": "5.0", "tRun": "0.008", "maxDroop": "0.05",
                 "iTo": "0.05", "minPsrrDb": "55.0", "psrrAtF": "120.0"}
  discard d.addRole("regulator", "base",
                    {"regulator": comp("U1"), "output": net("vdd")}, common)
  discard d.addRole("linear_regulator", "lin",
                    {"regulator": comp("U1"), "output": net("vdd"),
                     "source": comp("V1"), "input": net("vin")},
                    common & @{"maxLineReg": "0.25", "vinFrom": "8.0",
                               "vinTo": "20.0", "vinStep": "0.1"})
  let a = d.expandAll()
  let baseIds = ids(a.filterIt(it.origin == "base"))
  let linIds = ids(a.filterIt(it.origin == "lin"))
  for id in baseIds:
    check id.replace("base.", "lin.") in linIds
  check "lin.line_reg" in linIds
  check byId(a, "lin.line_reg").quantity == "line_reg_pct"
  check byId(a, "lin.line_reg").condition["sweep"] == "source"
  check byId(a, "lin.line_reg").condition["sweep_from"] == "8.0"

test "switching_regulator is regulator plus its own, and subtracts nothing":
  let d = regBoard()
  let common = @{"voltage": "5.0", "tRun": "0.008", "maxDroop": "0.05",
                 "iTo": "1.0", "minPsrrDb": "60.0", "psrrAtF": "100000.0"}
  discard d.addRole("regulator", "base",
                    {"regulator": comp("U1"), "output": net("vdd")}, common)
  discard d.addRole("switching_regulator", "sw",
                    {"regulator": comp("U1"), "output": net("vdd"),
                     "switch": net("sw"), "inductor": comp("L1"),
                     "sense": comp("L1"), "source": comp("V1"),
                     "input": net("vin")},
                    common & @{"tSettle": "3.0e-4", "tWindow": "2.0e-5",
                               "maxRipple": "0.01", "fSw": "1.0e6",
                               "fSwBand": "0.1", "maxSwitchCurrent": "6.0",
                               "maxIsatDerating": "0.6"})
  let a = d.expandAll()
  let baseIds = ids(a.filterIt(it.origin == "base"))
  let swIds = ids(a.filterIt(it.origin == "sw"))
  for id in baseIds:
    check id.replace("base.", "sw.") in swIds
  check byId(a, "sw.ripple").quantity == "ripple_pp"
  check byId(a, "sw.fsw").quantity == "osc_freq"
  check byId(a, "sw.fsw").subjects[0] == net("sw")
  check byId(a, "sw.i_switch").subjects[0] == comp("L1")
  check byId(a, "sw.isat_derating").quantity == "i_peak_derating"

test "the switching claims sharing a window share a setup key":
  # The ripple, the inductor current and the derating are all `t_settle` /
  # `t_window` claims, so they batch into one `.tran` -- which on a model
  # costing fifty timepoints a cycle is most of the check.
  let d = regBoard()
  discard d.addRole("switching_regulator", "sw",
                    {"regulator": comp("U1"), "output": net("vdd"),
                     "inductor": comp("L1"), "sense": comp("L1")},
                    {"without": "overshoot",
                     "tSettle": "3.0e-4", "tWindow": "2.0e-5",
                     "maxRipple": "0.01", "maxIsatDerating": "0.6",
                     "maxOutputAvg": "5.2"})
  let a = d.expandAll()
  check a.len == 3
  for x in a:
    check x.condition["t_settle"] == "0.0003"
    check x.condition["t_window"] == "0.00002"

test "all three roles accept every base parameter":
  # `RoleDef.params` is what `Design.validate` checks a stated parameter
  # against, so a specialisation that forgot to re-declare one would reject
  # a perfectly good design with a message about an unknown parameter.
  let base = roleDef("regulator").params.mapIt(it.key)
  for name in ["linear_regulator", "switching_regulator"]:
    let own = roleDef(name).params.mapIt(it.key)
    for k in base:
      check k in own
