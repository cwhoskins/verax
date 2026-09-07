import std/[strutils, unittest]

import verax/spice/xspice

proc minimalSpec(): ModelSpec =
  ## Deliberately the smallest thing that renders every table exactly once,
  ## so the golden text below stays readable.
  ModelSpec(
    name: "unity", cFunction: "cm_unity",
    description: "unity buffer",
    ports: @[
      PortSpec(name: "inp", description: "input", dir: xdIn, default: xpV,
               allowed: @[xpV], nullAllowed: false),
      PortSpec(name: "outp", description: "output", dir: xdOut, default: xpV,
               allowed: @[xpV, xpVd], nullAllowed: true)],
    params: @[
      ParamSpec(name: "gain", description: "gain", dataType: xtReal,
                default: defaultOf(1.0), limits: atLeast(0.0),
                nullAllowed: true)],
    stateVars: @[
      StateVarSpec(name: "seen", description: "call count", dataType: xtInt)])

const golden = """NAME_TABLE:

C_Function_Name:      cm_unity
Spice_Model_Name:     unity
Description:          "unity buffer"


PORT_TABLE:

Port_Name:            inp
Description:          "input"
Direction:            in
Default_Type:         v
Allowed_Types:        [v]
Vector:               no
Vector_Bounds:        -
Null_Allowed:         no


PORT_TABLE:

Port_Name:            outp
Description:          "output"
Direction:            out
Default_Type:         v
Allowed_Types:        [v,vd]
Vector:               no
Vector_Bounds:        -
Null_Allowed:         yes


PARAMETER_TABLE:

Parameter_Name:       gain
Description:          "gain"
Data_Type:            real
Default_Value:        1.0
Limits:               [0.0 -]
Vector:               no
Vector_Bounds:        -
Null_Allowed:         yes


STATIC_VAR_TABLE:

Static_Var_Name:      seen
Description:          "call count"
Data_Type:            int
"""

test "renderIfs emits the exact ifspec.ifs text cmpp expects":
  check renderIfs(minimalSpec()) == golden

test "one table block per row, repeated -- as ngspice's own d_dff ifspec does":
  let s = renderIfs(minimalSpec())
  check s.count("PORT_TABLE:") == 2
  check s.count("PARAMETER_TABLE:") == 1
  check s.count("STATIC_VAR_TABLE:") == 1

test "the STATIC_VAR_TABLE is omitted entirely when there are no static vars":
  var spec = minimalSpec()
  spec.stateVars = @[]
  check "STATIC_VAR_TABLE" notin renderIfs(spec)

test "bounds render with an open side as '-', and an inactive bound as '-'":
  var spec = minimalSpec()
  spec.params[0].limits = bounds(1.5, 9.5)
  check "Limits:               [1.5 9.5]" in renderIfs(spec)
  spec.params[0].limits = atMost(2.0)
  check "Limits:               [- 2.0]" in renderIfs(spec)
  spec.params[0].limits = atLeast(1)
  check "Limits:               [1 -]" in renderIfs(spec)
  spec.params[0].limits = noBound
  check "Limits:               -" in renderIfs(spec)

test "vector bounds render on the row they belong to":
  var spec = minimalSpec()
  spec.ports[0].vector = true
  spec.ports[0].vectorBounds = bounds(1, 8)
  let s = renderIfs(spec)
  check "Vector:               yes" in s
  check "Vector_Bounds:        [1 8]" in s

test "descriptions are quoted, and embedded quotes escaped":
  var spec = minimalSpec()
  spec.description = "a \"quoted\" thing"
  check "Description:          \"a \\\"quoted\\\" thing\"" in renderIfs(spec)

test "every port type has a distinct ifs spelling in Allowed_Types":
  var spec = minimalSpec()
  spec.ports[0].allowed = @[xpV, xpVd, xpI, xpId, xpVnam, xpG, xpGd, xpH, xpHd]
  check "Allowed_Types:        [v,vd,i,id,vnam,g,gd,h,hd]" in renderIfs(spec)
