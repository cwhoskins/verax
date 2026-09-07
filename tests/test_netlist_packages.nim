## Multi-channel packaging: the definition registry, the membership attrs,
## the global-pin identity check, and lifecycle through a clone.

import std/[strutils, tables, unittest]

import verax/netlist
import verax/netlist/dsl
import verax/netlist/packages

proc dualDef(name = "NE5532"): PackageDef =
  newPackageDef(name, [
    (id: "1", section: "A", logical: "OUT"),
    (id: "2", section: "A", logical: "IN-"),
    (id: "3", section: "A", logical: "IN+"),
    (id: "4", section: "",  logical: "V-"),
    (id: "5", section: "B", logical: "IN+"),
    (id: "6", section: "B", logical: "IN-"),
    (id: "7", section: "B", logical: "OUT"),
    (id: "8", section: "",  logical: "V+")],
    partNumber = name, footprint = "SOIC-8")

let counter = block:
  var i = 0
  proc(): string =
    inc i
    "PKG_TEST_" & $i
proc freshName(): string = counter()

# --- definition validation ---------------------------------------------

test "newPackageDef derives sections and globals from the pinout":
  let d = dualDef(freshName())
  check d.sectionNames == @["A", "B"]
  check d.section("A").pins == @["OUT", "IN-", "IN+"]
  check d.globalPins == @["V-", "V+"]
  check d.pins["7"] == PackagePin(section: "B", logical: "OUT")

test "registerPackage rejects an empty pin map":
  let d = PackageDef(name: freshName(), sections: @[PackageSection(name: "A")])
  expect NetlistError:
    registerPackage(d)

test "registerPackage rejects a pin naming an undeclared section":
  let broken = PackageDef(name: freshName(),
    sections: @[PackageSection(name: "A", pins: @["OUT"])])
  broken.pins["1"] = PackagePin(section: "A", logical: "OUT")
  broken.pins["2"] = PackagePin(section: "Z", logical: "OUT")
  expect NetlistError:
    registerPackage(broken)

test "registerPackage rejects a section pin missing from the map":
  let broken = PackageDef(name: freshName(),
    sections: @[PackageSection(name: "A", pins: @["OUT", "IN-"])])
  broken.pins["1"] = PackagePin(section: "A", logical: "OUT")
  expect NetlistError:
    registerPackage(broken)   # IN- never appears

test "registerPackage rejects a duplicate name":
  let n = freshName()
  registerPackage(dualDef(n))
  expect NetlistError:
    registerPackage(dualDef(n))

test "packageDef raises naming the known packages":
  expect NetlistError:
    discard packageDef("NO_SUCH_PACKAGE_XYZ")

# --- a hierarchical fixture: two instances of one channel -------------

proc channel(): Netlist =
  subckt("CH", [IN, OUT, VP, VN, GND]):
    net IN, kind = ntSignal
    net OUT, kind = ntSignal
    net VP, kind = ntPower
    net VN, kind = ntPower
    net GND, kind = ntGround, name = "0"
    net fb, kind = ntSignal
    component U1, kind = "opamp", partNumber = "NE5532":
      pin "IN+", IN, kind = ptInput
      pin "IN-", fb, kind = ptInput
      pin "OUT", OUT, kind = ptOutput
      pin "V+", VP, kind = ptPower
      pin "V-", VN, kind = ptGround
    component R1, kind = "resistor", value = "10k":
      pin "1", OUT, kind = ptPassive
      pin "2", fb, kind = ptPassive

proc stereo(defName: string; splitRails = false): (Netlist, PackageInstance) =
  let pkg = packageInstance(defName, "U10")
  let root = netlist("stereo"):
    net gnd, kind = ntGround, name = "0", global = true
    net vp, kind = ntPower
    net vn, kind = ntPower
    net vp2, kind = ntPower
    net inL, kind = ntSignal
    net outL, kind = ntSignal
    net inR, kind = ntSignal
    net outR, kind = ntSignal
    instance XL, channel(), [inL, outL, vp, vn, gnd],
      with = pkg.section("A", "U1")
    instance XR, channel(), [inR, outR, (if splitRails: vp2 else: vp), vn, gnd],
      with = pkg.section("B", "U1")
  (root, pkg)

test "the two sections carry the three package.* keys":
  let n = freshName()
  registerPackage(dualDef(n))
  let (root, _) = stereo(n)
  let a = findComponent(root, "XL.U1")
  let b = findComponent(root, "XR.U1")
  check packageRef(a) == (true, "U10")
  check packageSection(a).value == "A"
  check packageDefName(a).value == n
  check packageSection(b).value == "B"
  check displayDesignator(a) == "U10A"
  check displayDesignator(b) == "U10B"
  check isPackaged(a)

test "packages() reconstructs the group by walking children":
  let n = freshName()
  registerPackage(dualDef(n))
  let (root, _) = stereo(n)
  let g = packages(root)
  check g.hasKey("U10")
  check g["U10"].len == 2
  check packageMembers(root, "U10").len == 2

test "global-pin agreement passes when both V+ reach one rail":
  let n = freshName()
  registerPackage(dualDef(n))
  let (root, _) = stereo(n)
  let issues = validatePackages(root)
  for i in issues: check i.severity != sevError

test "global-pin conflict is an error when the sections sit on different rails":
  let n = freshName()
  registerPackage(dualDef(n))
  let (root, _) = stereo(n, splitRails = true)
  let issues = validatePackages(root)
  var kinds: seq[string]
  for i in issues: kinds.add i.kind
  check "package_global_pin_conflict" in kinds

test "packageInstance raises for an unregistered definition":
  expect NetlistError:
    discard packageInstance("DEFINITELY_NOT_REGISTERED", "U1")

test "assignSection raises on an undeclared section":
  let n = freshName()
  registerPackage(dualDef(n))
  let pkg = packageInstance(n, "U9")
  let nl = netlist("flat"):
    net gnd, kind = ntGround, name = "0"
    component U9A, kind = "opamp", partNumber = "NE5532":
      pin "OUT", gnd
  expect NetlistError:
    pkg.assign(nl, "Z", "U9A")

test "assignSection raises on a duplicate section letter":
  let n = freshName()
  registerPackage(dualDef(n))
  let pkg = packageInstance(n, "U8")
  let nl = netlist("flat"):
    net gnd, kind = ntGround, name = "0"
    component U8A, kind = "opamp", partNumber = "NE5532":
      pin "OUT", gnd
    component U8B, kind = "opamp", partNumber = "NE5532":
      pin "OUT", gnd
  pkg.assign(nl, "A", "U8A")
  expect NetlistError:
    pkg.assign(nl, "A", "U8B")

test "assignSection raises past the section count":
  let n = freshName()
  registerPackage(dualDef(n))
  let pkg = packageInstance(n, "U7")
  let nl = netlist("flat"):
    net gnd, kind = ntGround, name = "0"
    component U7A, kind = "opamp", partNumber = "NE5532":
      pin "OUT", gnd
    component U7B, kind = "opamp", partNumber = "NE5532":
      pin "OUT", gnd
    component U7C, kind = "opamp", partNumber = "NE5532":
      pin "OUT", gnd
  pkg.assign(nl, "A", "U7A")
  pkg.assign(nl, "B", "U7B")
  expect NetlistError:
    pkg.assign(nl, "A", "U7C")

# --- lifecycle: clone the packaged root ------------------------------

test "cloning a packaged root carries package.* to the clone":
  let n = freshName()
  registerPackage(dualDef(n))
  let (root, _) = stereo(n)
  var g: OrderedTable[string, Net]
  let cl = clone(root, g)
  let a = findComponent(cl, "XL.U1")
  check a != nil
  check packageRef(a) == (true, "U10")
  check packageSection(a).value == "A"

test "removing a member simply drops it from the reconstructed group":
  let n = freshName()
  registerPackage(dualDef(n))
  let (root, _) = stereo(n)
  let child = root.children["XR"]
  removeComponent(child, "U1")
  let g = packages(root)
  check g["U10"].len == 1
  check g["U10"][0].designator == "U1"   # XL.U1, local designator

# --- SPICE lossiness --------------------------------------------------

import verax/netlist/formats/spice as spiceFmt
import std/streams

test "a SPICE round trip drops every package.* key":
  let n = freshName()
  registerPackage(dualDef(n))
  # A flat, cleanly round-tripping graph: two resistor "sections".
  let nl = netlist("flatpack"):
    net gnd, kind = ntGround, name = "0"
    net a, kind = ntSignal
    net b, kind = ntSignal
    component RA, kind = "resistor", value = "1k":
      pin "1", a
      pin "2", gnd
    component RB, kind = "resistor", value = "1k":
      pin "1", b
      pin "2", gnd
  let pkg = packageInstance(n, "U10")
  pkg.assign(nl, "A", "RA")
  pkg.assign(nl, "B", "RB")
  check packageRef(findComponent(nl, "RA")).value == "U10"

  let s = newStringStream()
  writeNetlist(nl, s)
  let text = s.data
  check "package." notin text
  s.setPosition(0)
  let back = readNetlist(s, "flatpack")
  for _, c in back.components:
    for k in c.attrs.keys:
      check not k.startsWith("package.")
  # electrical graph unchanged
  check back.components.len == 2
  check connectedComponents(back.nets["0"]).len == 2
