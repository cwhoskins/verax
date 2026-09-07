import std/[unittest]

import verax/spice/xspice

proc gainSpec(): ModelSpec =
  ## The `analog/gain` model from ngspice's own icm library, which is the
  ## smallest spec that still exercises every table: two ports of opposite
  ## direction, two real parameters, and one static var.
  ModelSpec(
    name: "gain", cFunction: "cm_gain",
    description: "a gain block",
    ports: @[
      PortSpec(name: "inp", description: "input", dir: xdIn, default: xpV,
               allowed: @[xpV, xpVd, xpI, xpId], nullAllowed: false),
      PortSpec(name: "outp", description: "output", dir: xdOut, default: xpV,
               allowed: @[xpV, xpVd, xpI, xpId], nullAllowed: false)],
    params: @[
      ParamSpec(name: "gain", description: "gain", dataType: xtReal,
                default: defaultOf(1.0), nullAllowed: true),
      ParamSpec(name: "in_offset", description: "input offset",
                dataType: xtReal, default: defaultOf(0.0), nullAllowed: true)],
    stateVars: @[
      StateVarSpec(name: "last_value", description: "previous output",
                   dataType: xtReal)])

test "a well-formed spec validates":
  validate(gainSpec())

test "indices are declaration order, which is what cmpp uses for conn[i]/param[i]":
  let s = gainSpec()
  check s.portIndex("inp") == 0
  check s.portIndex("outp") == 1
  check s.paramIndex("gain") == 0
  check s.paramIndex("in_offset") == 1
  check s.stateVarIndex("last_value") == 0

test "an unknown name yields -1 so the DSL can report it against its own AST node":
  let s = gainSpec()
  check s.portIndex("nosuch") == -1
  check s.paramIndex("nosuch") == -1
  check s.stateVarIndex("nosuch") == -1

test "duplicate port names are rejected":
  var s = gainSpec()
  s.ports.add s.ports[0]
  expect(XspiceSpecError): validate(s)

test "duplicate parameter names are rejected":
  var s = gainSpec()
  s.params.add s.params[0]
  expect(XspiceSpecError): validate(s)

test "duplicate static var names are rejected":
  var s = gainSpec()
  s.stateVars.add s.stateVars[0]
  expect(XspiceSpecError): validate(s)

test "a model with no ports is rejected":
  var s = gainSpec()
  s.ports = @[]
  expect(XspiceSpecError): validate(s)

test "Default_Type must appear in Allowed_Types":
  var s = gainSpec()
  s.ports[0].default = xpH
  expect(XspiceSpecError): validate(s)

test "an empty Allowed_Types list is rejected":
  var s = gainSpec()
  s.ports[0].allowed = @[]
  expect(XspiceSpecError): validate(s)

test "a port mixing digital and analog Allowed_Types is rejected":
  # ngspice's put_conn_type picks .pvalue for digital and .rvalue for every
  # analog type, so such a port has no single sound accessor field.
  var s = gainSpec()
  s.ports[0].allowed = @[xpV, xpD]
  expect(XspiceSpecError): validate(s)

test "an all-digital port is fine":
  var s = gainSpec()
  s.ports[0].default = xpD
  s.ports[0].allowed = @[xpD]
  validate(s)

test "Vector_Bounds without Vector is rejected":
  var s = gainSpec()
  s.ports[0].vectorBounds = bounds(1, 8)
  expect(XspiceSpecError): validate(s)
  var s2 = gainSpec()
  s2.params[0].vectorBounds = bounds(1, 8)
  expect(XspiceSpecError): validate(s2)

test "a vector port may set Vector_Bounds":
  var s = gainSpec()
  s.ports[0].vector = true
  s.ports[0].vectorBounds = bounds(1, 8)
  validate(s)

test "a string parameter with an unquoted default is rejected":
  var s = gainSpec()
  s.params[0].dataType = xtString
  s.params[0].default = "hello"
  expect(XspiceSpecError): validate(s)
  s.params[0].default = defaultOf("hello")
  validate(s)

test "non-identifier names are rejected":
  var s = gainSpec()
  s.name = "has space"
  expect(XspiceSpecError): validate(s)
  var s2 = gainSpec()
  s2.cFunction = ""
  expect(XspiceSpecError): validate(s2)
  var s3 = gainSpec()
  s3.ports[0].name = "1bad"
  expect(XspiceSpecError): validate(s3)

test "ifs spellings match what cmpp's lexer accepts":
  check xpV.ifsName == "v"
  check xpVd.ifsName == "vd"
  check xpVnam.ifsName == "vnam"
  check xpGd.ifsName == "gd"
  check xpHd.ifsName == "hd"
  check xpD.ifsName == "d"
  check xdIn.ifsName == "in"
  check xdInout.ifsName == "inout"
  check xtBool.ifsName == "boolean"
  check xtInt.ifsName == "int"
  check xtReal.ifsName == "real"
  check xtComplex.ifsName == "complex"
  check xtString.ifsName == "string"

test "defaultOf formats each data type the way the .ifs grammar wants":
  check defaultOf(true) == "TRUE"
  check defaultOf(false) == "FALSE"
  check defaultOf(3) == "3"
  check defaultOf("abc") == "\"abc\""

test "only digital ports read .pvalue":
  check xpD.isDigital
  for t in [xpV, xpVd, xpI, xpId, xpVnam, xpG, xpGd, xpH, xpHd]:
    check not t.isDigital
