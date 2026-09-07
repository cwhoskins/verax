import std/[math, strutils, tables, unittest]

import verax/netlist
import verax/netlist/annotations
import verax/netlist/dsl
import verax/netlist/environment
import verax/units

proc board(): Netlist =
  ## An LDO that runs hot and a capacitor beside it that does not.
  result = newNetlist("t")
  let vin = addNet(result, newNet("vin", ntPower))
  let vdd = addNet(result, newNet("vdd", ntPower))
  let gnd = addNet(result, newNet("0", ntGround))
  let u1 = addComponent(result, newComponent("U1", kind = "ldo"))
  discard connect(u1, "IN", vin, ptPower)
  discard connect(u1, "OUT", vdd, ptOutput)
  discard connect(u1, "GND", gnd, ptGround)
  let c1 = addComponent(result, newComponent("C1", kind = "capacitor"))
  discard connect(c1, "1", vdd, ptPassive)
  discard connect(c1, "2", gnd, ptPassive)

# --- the vocabulary ----------------------------------------------------

test "the three keys are registered, in degC, at the right scopes":
  for k in ["t_ambient_min", "t_ambient_max", "delta_t"]:
    check isRegistered(k)
    check annDef(k).unit == "degC"
    check annDef(k).kind == akFloat
  # The board's range belongs to the board and a rise belongs to a part;
  # neither is stated where the other is.
  check annDef("t_ambient_min").scopes == {asNetlist}
  check annDef("t_ambient_max").scopes == {asNetlist}
  check annDef("delta_t").scopes == {asComponent}

test "a temperature literal cannot be confused with a voltage":
  let nl = board()
  expect(NetlistError):
    setAnnotation(nl, "t_ambient_max", 70.0.V)
  expect(NetlistError):
    setAnnotation(findComponent(nl, "U1"), "delta_t", 25.0.V)
  # And the range is not stateable on a part, nor a rise on the board.
  expect(NetlistError):
    setAnnotation(findComponent(nl, "U1"), "t_ambient_max", 70.degC)
  expect(NetlistError):
    setAnnotation(nl, "delta_t", 25.degC)

test "Celsius renders without SI prefixes":
  # `500 mdegC` is exactly the misread the typed units exist to remove.
  check $(0.5.degC) == "0.5 degC"
  check $(-40.degC) == "-40 degC"
  check $(70.degC) == "70 degC"
  check unitOf(70.degC) == "degC"

# --- the board's range -------------------------------------------------

test "an unstated environment is absent, not zero":
  let env = environmentOf(board())
  check not env.stated
  check env.tAmbientMin.source == annAbsent
  check env.tAmbientMax.source == annAbsent
  check $env == "no operating temperature stated"

test "a stated range reads back with its provenance":
  let nl = board()
  setOperatingTemperature(nl, -20.degC, 70.degC)
  let env = environmentOf(nl)
  check env.stated
  check env.tAmbientMin.value == -20.0
  check env.tAmbientMax.value == 70.0
  check env.tAmbientMin.source == annAuthored
  check $env == "ambient -20 degC to 70 degC"

test "an inverted range is refused at the setter":
  let nl = board()
  expect(NetlistError):
    setOperatingTemperature(nl, 70.degC, -20.degC)

test "half a range is not a range":
  let nl = board()
  setAnnotation(nl, "t_ambient_max", 70.degC)
  let env = environmentOf(nl)
  check not env.stated
  check env.tAmbientMax.has

test "a child netlist reads the board's range, not one of its own":
  # A subcircuit does not have weather of its own: a model pass holding a
  # fragment must get the same answer as one holding the whole board.
  let nl = board()
  setOperatingTemperature(nl, 0.degC, 85.degC)
  let child = newNetlist("channel")
  addChild(nl, "XA", child)
  check environmentOf(child).tAmbientMax.value == 85.0

test "the range survives a clone, which is why it lives in attrs":
  # Everything that will ever read this holds a *fragment*: analyses clone,
  # flatten and isolate before they model anything.
  let nl = board()
  setOperatingTemperature(nl, -20.degC, 70.degC)
  var globals: OrderedTable[string, Net]
  let copy = clone(nl, globals)
  check environmentOf(copy).tAmbientMax.value == 70.0
  check deltaT(findComponent(copy, "U1")).source == annAbsent

# --- a part's rise -----------------------------------------------------

test "a part defaults to no rise, and says that it defaulted":
  let c = findComponent(board(), "C1")
  check not deltaT(c).has                    # the pure accessor sees absence
  let rise = temperatureRise(c)              # the one with the default
  check rise.value == 0.0
  check rise.source == annDefaulted

test "a stated rise overrides the default and reads as authored":
  let nl = board()
  setDeltaT(findComponent(nl, "U1"), 25.degC)
  let rise = temperatureRise(findComponent(nl, "U1"))
  check rise.value == 25.0
  check rise.source == annAuthored

test "the rise assumption names the part and the default it applied":
  let a = riseAssumption(findComponent(board(), "C1"))
  check a.entity == "C1"
  check a.key == "delta_t"
  check a.value == 0.0
  check a.unit == "degC"
  check a.source == annDefaulted

# --- the join ----------------------------------------------------------

test "a part's range is the board's, shifted by its own rise at both ends":
  let nl = board()
  setOperatingTemperature(nl, -20.degC, 70.degC)
  setDeltaT(findComponent(nl, "U1"), 25.degC)
  let env = environmentOf(nl)

  # An ordinary part sits at ambient, both ends.
  let cool = partTemperatureRange(findComponent(nl, "C1"), env)
  check cool == (-20.0, 70.0)

  # A dissipating one is above it whatever the air is doing -- which is why
  # the cold end moves too, rather than the rise being added only on top.
  let hot = partTemperatureRange(findComponent(nl, "U1"), env)
  check hot == (5.0, 95.0)
  check partTemperature(findComponent(nl, "U1"), 25.0) == 50.0

test "with no range stated a part's range is NaN, not zero":
  let nl = board()
  setDeltaT(findComponent(nl, "U1"), 25.degC)
  let r = partTemperatureRange(findComponent(nl, "U1"), environmentOf(nl))
  check r.tMin.classify == fcNan
  check r.tMax.classify == fcNan

test "the hottest part is found across the hierarchy":
  let nl = board()
  setOperatingTemperature(nl, -20.degC, 70.degC)
  setDeltaT(findComponent(nl, "U1"), 25.degC)

  let child = newNetlist("channel")
  discard addComponent(child, newComponent("Q1", kind = "transistor"))
  setDeltaT(findComponent(child, "Q1"), 40.degC)
  addChild(nl, "XA", child)

  let hot = hottestPart(nl, environmentOf(nl))
  check hot.comp.designator == "Q1"
  check hot.temperature == 110.0
  check describeHottest(nl, environmentOf(nl)).startsWith("Q1 at 110 degC")

test "nothing is 'hottest' when no part states a rise":
  let nl = board()
  setOperatingTemperature(nl, -20.degC, 70.degC)
  check hottestPart(nl, environmentOf(nl)).comp == nil
  check describeHottest(nl, environmentOf(nl)) == ""

# --- validation --------------------------------------------------------

test "a board that says nothing about temperature is not nagged":
  check validateEnvironment(board()).len == 0

test "a well-stated environment reports nothing":
  let nl = board()
  setOperatingTemperature(nl, -20.degC, 70.degC)
  setDeltaT(findComponent(nl, "U1"), 25.degC)
  check validateEnvironment(nl).len == 0

test "an inverted range that got in some other way is reported":
  # `setOperatingTemperature` refuses it, but a file reader or a raw
  # annotation can still produce one, and it looks like a specification.
  let nl = board()
  setAnnotation(nl, "t_ambient_min", 70.degC)
  setAnnotation(nl, "t_ambient_max", -20.degC)
  let issues = validateEnvironment(nl)
  check issues.len == 1
  check issues[0].kind == KindTemperatureRangeInverted
  check issues[0].severity == sevError

test "half a range is reported, naming the end that is missing":
  let nl = board()
  setAnnotation(nl, "t_ambient_min", -20.degC)
  let issues = validateEnvironment(nl)
  check issues.len == 1
  check issues[0].kind == KindTemperatureRangeHalfStated
  check "t_ambient_max" in issues[0].message

test "a range stated inside a subcircuit is reported, not silently ignored":
  # `environmentOf` reads the root, which is the right rule and is exactly
  # what makes a range written inside a `subckt` invisible once it is
  # instanced -- indistinguishable, from the design file, from a live one.
  let nl = board()
  setOperatingTemperature(nl, 0.degC, 70.degC)
  let child = newNetlist("channel")
  addChild(nl, "XA", child)
  setAnnotation(child, "t_ambient_max", 105.degC)
  let issues = validateEnvironment(nl)
  check issues.len == 1
  check issues[0].kind == KindTemperatureRangeNotAtRoot
  check "channel" in issues[0].message
  # And the board's own figure is what anything reading it still gets.
  check environmentOf(child).tAmbientMax.value == 70.0

test "a rise with no range to add it to is reported, naming the parts":
  let nl = board()
  setDeltaT(findComponent(nl, "U1"), 25.degC)
  let issues = validateEnvironment(nl)
  check issues.len == 1
  check issues[0].kind == KindTemperatureRiseUnusable
  check issues[0].components.len == 1
  check issues[0].components[0].designator == "U1"

# --- authoring ---------------------------------------------------------

test "the environment block states the range from a design file":
  let nl = netlist("b"):
    environment:
      t_ambient_min = -40.degC
      t_ambient_max = 85.degC
    net gnd, kind = ntGround, name = "0"
    net vdd, kind = ntPower
    component U1, kind = "ldo":
      pin "OUT", vdd
      pin "GND", gnd
      spec:
        delta_t = 30.degC
  let env = environmentOf(nl)
  check env.stated
  check env.tAmbientMin.value == -40.0
  check partTemperatureRange(findComponent(nl, "U1"), env) == (-10.0, 115.0)

test "the environment block is validated at compile time":
  # The same strictness `spec:` has, and for the same reason: there is no
  # open-ended bag inside the block for a misspelling to mean anything.
  # The positive control first, so a false negative cannot pass this test.
  check(compiles(block:
    discard netlist("ok"):
      environment:
        t_ambient_max = 85.degC))
  check(not compiles(block:
    discard netlist("bad"):
      environment:
        t_ambient_maxx = 85.degC))
  # A key that is registered but belongs on a component is refused here.
  check(not compiles(block:
    discard netlist("bad"):
      environment:
        delta_t = 30.degC))
  # And a component's `spec:` still refuses the board's keys.
  check(not compiles(block:
    discard netlist("bad"):
      net gnd, kind = ntGround, name = "0"
      component U1, kind = "ldo":
        pin "GND", gnd
        spec:
          t_ambient_max = 85.degC))
