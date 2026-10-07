import std/[strutils, tables, unittest]

import verax/netlist
import verax/netlist/dsl
import verax/netlist/bomdefaults
import verax/units

proc board(): Netlist =
  result = newNetlist("t")
  let vdd = addNet(result, newNet("vdd", ntPower))
  let gnd = addNet(result, newNet("0", ntGround))
  let c1 = addComponent(result, newComponent("C1", kind = "capacitor"))
  discard connect(c1, "1", vdd, ptPassive)
  discard connect(c1, "2", gnd, ptPassive)

# --- authoring: a `bom:` block round-trips through `bomDefaults` ---------

test "a bom: block round-trips through bomDefaults":
  let nl = netlist("b"):
    bom:
      tolerance = 5.pct
      dielectric = "X7R"
      series = "e24"
      derating = 1.5
      resistor_package = "0603"
      capacitor_package = "0805"
      inductor_package = "1210"
      manufacturers = ["TDK", "Murata"]
    net gnd, kind = ntGround, name = "0"
  let d = bomDefaults(nl)
  check float(d.tolerance) == 0.05
  check d.dielectric == "X7R"
  check d.series == "e24"
  check d.derating == 1.5
  check d.resistorPackage == "0603"
  check d.capacitorPackage == "0805"
  check d.inductorPackage == "1210"
  check d.manufacturers == @["TDK", "Murata"]

test "a netlist that states no bom: block reads back the zero value":
  let d = bomDefaults(board())
  check float(d.tolerance) == 0.0
  check d.dielectric == ""
  check d.series == ""
  check d.derating == 0.0
  check d.resistorPackage == ""
  check d.capacitorPackage == ""
  check d.inductorPackage == ""
  check d.manufacturers.len == 0

test "each runtime setter round-trips on its own":
  let nl = board()
  setBomTolerance(nl, 1.pct)
  setBomDielectric(nl, "C0G")
  setBomSeries(nl, "e12")
  setBomDerating(nl, 2.0)
  setBomResistorPackage(nl, "0402")
  setBomCapacitorPackage(nl, "0603")
  setBomInductorPackage(nl, "1206")
  setBomManufacturers(nl, ["Yageo", "Vishay"])
  let d = bomDefaults(nl)
  check float(d.tolerance) == 0.01
  check d.dielectric == "C0G"
  check d.series == "e12"
  check d.derating == 2.0
  check d.resistorPackage == "0402"
  check d.capacitorPackage == "0603"
  check d.inductorPackage == "1206"
  check d.manufacturers == @["Yageo", "Vishay"]

# --- survival across the transforms every consumer holds a fragment through

test "defaults survive clone":
  let nl = board()
  setBomSeries(nl, "e96")
  setBomDerating(nl, 1.5)
  var globals: OrderedTable[string, Net]
  let copy = clone(nl, globals)
  let d = bomDefaults(copy)
  check d.series == "e96"
  check d.derating == 1.5

test "defaults survive instantiate":
  let templ = newNetlist("channel")
  let a = addNet(templ, newNet("a"))
  let gnd = addNet(templ, newNet("0", ntGround))
  let u1 = addComponent(templ, newComponent("U1", kind = "mcu"))
  discard connect(u1, "1", a, ptPassive)
  discard connect(u1, "2", gnd, ptGround)

  let top = newNetlist("top")
  setBomSeries(top, "e24")
  var globals: OrderedTable[string, Net]
  discard instantiate(top, "X1", templ, @[], globals)
  # The template states nothing, so the instance inherits the board's.
  check bomDefaults(top.children["X1"]).series == "e24"

# --- hierarchy: the most specific statement wins, field by field -----------

proc filterSheet(): Netlist =
  ## A library sheet with its own opinion about one field only.
  result = subckt("filt", [a]):
    bom:
      dielectric = "C0G"
    net a
    component C1, kind = "capacitor", value = "10n":
      pin "1", a
      pin "2", a

test "a child with no bom: block inherits every field from its parent":
  let nl = board()
  setBomTolerance(nl, 5.pct)
  let child = newNetlist("channel")
  addChild(nl, "XA", child)
  check float(bomDefaults(child).tolerance) == 0.05

test "a child's stated field beats its parent's; unstated fields still inherit":
  let filt = filterSheet()
  let top = netlist("top"):
    bom:
      dielectric = "X7R"
      series = "e24"
    net n
    instance X1, filt, [n]
  let d = bomDefaults(top.children["X1"])
  check d.dielectric == "C0G"   # the sheet's own
  check d.series == "e24"       # the board's, the sheet stated none
  check bomDefaults(top).dielectric == "X7R"

test "the nearest ancestor wins across more than one level":
  let root = board()
  let mid = newNetlist("mid")
  let leaf = newNetlist("leaf")
  addChild(root, "XM", mid)
  addChild(mid, "XL", leaf)
  setBomSeries(root, "e12")
  setBomSeries(mid, "e96")
  check bomDefaults(leaf).series == "e96"
  check bomDefaults(mid).series == "e96"
  check bomDefaults(root).series == "e12"

test "a setter writes to the netlist it is given, never the root":
  let nl = board()
  let child = newNetlist("channel")
  addChild(nl, "XA", child)
  setBomSeries(child, "e12")
  check bomDefaults(child).series == "e12"
  check bomDefaults(nl).series == ""

test "a with = proc overrides one instance and leaves its sibling alone":
  let filt = filterSheet()
  let top = netlist("top"):
    net n
    instance X1, filt, [n], with = proc(sub: Netlist) =
      setBomDielectric(sub, "X7R")
    instance X2, filt, [n]
  check bomDefaults(top.children["X1"]).dielectric == "X7R"
  check bomDefaults(top.children["X2"]).dielectric == "C0G"
  check bomDefaults(filt).dielectric == "C0G"   # the template is untouched
  check bomDefaults(top).dielectric == ""       # nor is the board

test "a with = proc can override one component's own spec on one instance":
  # A default never reaches a part's own `spec:`; name the component on the
  # instance to change it.
  let sheet = subckt("rc", [a]):
    net a
    component C1, kind = "capacitor", value = "10n":
      spec:
        tolerance = 5.pct
      pin "1", a
      pin "2", a
  let top = netlist("top"):
    net n
    instance X1, sheet, [n], with = proc(sub: Netlist) =
      setAnnotation(findComponent(sub, "C1"), "tolerance", 1.pct)
    instance X2, sheet, [n]
  check annotationFloat(findComponent(top, "X1.C1"), "tolerance").value == 0.01
  check annotationFloat(findComponent(top, "X2.C1"), "tolerance").value == 0.05

# --- validation ------------------------------------------------------------

test "a netlist that states nothing about bom defaults is not nagged":
  check validateBomDefaults(board()).len == 0

test "a well-stated bom: block reports nothing":
  let nl = board()
  setBomSeries(nl, "e24")
  setBomDerating(nl, 1.5)
  setBomTolerance(nl, 5.pct)
  check validateBomDefaults(nl).len == 0

test "an unknown series name is reported, naming the four real ladders":
  let nl = board()
  setBomSeries(nl, "e48")
  let issues = validateBomDefaults(nl)
  check issues.len == 1
  check issues[0].kind == KindBomDefaultUnknownSeries
  check issues[0].severity == sevError
  check "e48" in issues[0].message
  check "e24" in issues[0].message

test "a derating factor below 1.0 is reported":
  let nl = board()
  setBomDerating(nl, 0.5)
  let issues = validateBomDefaults(nl)
  check issues.len == 1
  check issues[0].kind == KindBomDefaultDeratingTooLow
  check issues[0].severity == sevError

test "a negative tolerance is reported":
  let nl = board()
  setBomTolerance(nl, Fraction(-0.05))
  let issues = validateBomDefaults(nl)
  check issues.len == 1
  check issues[0].kind == KindBomDefaultNegativeTolerance
  check issues[0].severity == sevError

test "a bad value stated inside an instanced sheet is reported, by path":
  let top = board()
  let child = newNetlist("channel")
  addChild(top, "XA", child)
  setBomSeries(child, "e7")
  let issues = validateBomDefaults(top)
  check issues.len == 1
  check issues[0].kind == KindBomDefaultUnknownSeries
  check "XA" in issues[0].message

# --- compile-time strictness ------------------------------------------------

test "the bom block is validated at compile time":
  # Positive control first, so a false negative can't pass silently.
  check(compiles(block:
    discard netlist("ok"):
      bom:
        series = "e24"))
  check(not compiles(block:
    discard netlist("bad"):
      bom:
        seriess = "e24"))
  check(not compiles(block:
    discard netlist("bad"):
      bom:
        t_ambient_max = 85.degC))
