import std/[math, strutils, tables, unittest]

import nimcir/contract/dsl
import nimcir/netlist/annotations

proc board(): Design =
  design("board"):
    net vdd, kind = ntPower:
      spec:
        voltage = 3.3.V
    net gnd, kind = ntGround, name = "0"
    net sda, kind = ntSignal
    net scl, kind = ntSignal

    component R1, kind = "resistor", value = "2.2k":
      pin "1", vdd, kind = ptPassive
      pin "2", sda, kind = ptPassive
    component R2, kind = "resistor", value = "2.2k":
      pin "1", vdd, kind = ptPassive
      pin "2", scl, kind = ptPassive
    component U1, kind = "mcu":
      pin "VDD", vdd, kind = ptPower
      pin "GND", gnd, kind = ptGround
      pin "SDA", sda, kind = ptInOut
      pin "SCL", scl, kind = ptInOut
      spec:
        package = "QFN32"

    role "power_rail", vdd_rail, rail = vdd, voltage = 3.3.V, band = 5.pct
    role "i2c", i2c0, sda = sda, scl = scl, pullupRail = vdd,
                controller = U1, frequency = 400.kHz

    require dc_voltage(vdd) == 3.3.V, band = 5.pct,
            id = "REQ-PWR-001", because = "MCU VDD range is 3.0-3.6 V"
    require rc_corner(sda) >= 4.MHz, id = "REQ-I2C-002"

test "a design carries a netlist, its roles and its requirements":
  let d = board()
  check d.netlist.name == "board"
  check d.netlist.components.len == 3
  check d.roles.len == 2
  check d.assertions.len == 2

test "spec blocks inside a design work exactly as in a plain netlist":
  let d = board()
  check abs(railVoltage(d.netlist.nets["vdd"]).value - 3.3) < 1e-12
  check package(d.netlist.components["U1"]).value == "QFN32"
  check validateAnnotations(d.netlist).len == 0

test "bindings and parameters are told apart by type, not by position":
  let d = board()
  let i2c0 = d.roles["i2c0"]
  # Nets and components became bindings...
  check i2c0.bindings.len == 4
  check i2c0.bindings["sda"] == Subject(kind: skNet, name: "sda")
  check i2c0.bindings["controller"] == Subject(kind: skComponent, name: "U1")
  # ...and the quantity became a parameter.
  check i2c0.params.len == 1
  check abs(parseFloat(i2c0.params["frequency"]) - 400_000.0) < 1e-6

test "a role's apply half writes its parameter where consumers already look":
  let d = board()
  # spice/isolate reads Net.attrs["voltage"] and knows nothing about roles.
  check railVoltage(d.netlist.nets["vdd"]).has

test "role expansion produces the built-in claims":
  let d = board()
  let all = d.expandAll()
  var ids: seq[string]
  for a in all: ids.add a.id
  check "REQ-PWR-001" in ids
  check "REQ-I2C-002" in ids
  check "vdd_rail.voltage" in ids
  check "i2c0.sda.pullup" in ids
  check "i2c0.scl.rc_corner" in ids

test "require builds the expectation the comparison operator implies":
  let d = board()
  var byId: Table[string, Assertion]
  for a in d.expandAll(): byId[a.id] = a

  let pwr = byId["REQ-PWR-001"]
  check pwr.quantity == "dc_voltage"
  check pwr.unit == "V"
  check pwr.subjects == @[Subject(kind: skNet, name: "vdd")]
  check pwr.expect.kind == ekNominal
  check pwr.expect.satisfies(3.4)
  check not pwr.expect.satisfies(3.6)
  check "3.0-3.6" in pwr.rationale
  check pwr.origin == "authored"

  let i2c = byId["REQ-I2C-002"]
  check i2c.expect.kind == ekMin
  check abs(i2c.expect.lo - 4.0e6) < 1.0
  check i2c.unit == "Hz"

test "the unit comes from the literal, so it cannot drift from the value":
  let d = design("u"):
    net a, kind = ntSignal
    require z_max_in_band(a) <= 100.mohm, id = "Z"
  let x = d.expandAll()[0]
  check x.unit == "ohm"
  check abs(x.expect.hi - 0.1) < 1e-12

test "extra key=value pairs become conditions":
  let d = design("c"):
    net a, kind = ntSignal
    require z_max_in_band(a) <= 100.mohm, f_from = 100.kHz, f_to = 100.MHz, id = "Z"
  let x = d.expandAll()[0]
  check x.condition.len == 2
  check abs(parseFloat(x.condition["f_from"]) - 1.0e5) < 1e-3

test "a multi-subject requirement is expressible, ready for relational quantities":
  let d = design("m"):
    net miso, kind = ntSignal
    net sclk, kind = ntSignal
    require setup_margin(miso, sclk) >= 0.0, id = "REQ-SPI-001"
  let x = d.expandAll()[0]
  check x.subjects.len == 2
  check x.subjects[0].name == "miso"
  check x.subjects[1].name == "sclk"

test "explain prints the whole contract, authored and expanded alike":
  let text = board().explain()
  check "vdd_rail : power_rail" in text
  check "i2c0 : i2c" in text
  check "dc_voltage" in text
  check "REQ-PWR-001" in text

test "a design with no contract at all is still a valid design":
  let d = design("bare"):
    net a, kind = ntSignal
  check d.roles.len == 0
  check d.expandAll().len == 0
  check "no roles or assertions" in d.explain()

test "a role naming a net that does not exist fails when it is attached":
  # Compile-time checking covers annotation keys; binding validity is a
  # runtime check, because the role registry is a runtime table.
  expect(NetlistError):
    discard design("bad"):
      net a, kind = ntSignal
      role "power_rail", r, rail = a, voltag = 3.3.V

# --- compile-time strictness -------------------------------------------
#
# `check not compiles(...)` is unusable for a macro that calls `error()`:
# the same trap `tests/test_xspice_dsl.nim` documents. A macro error aborts
# the compilation rather than making an expression ill-formed, so the only
# honest way to assert one is to compile a fixture in a subprocess and read
# what the compiler said.

import std/[os, osproc, tempfiles]

let repoSrc = currentSourcePath().parentDir.parentDir / "src"

proc compileFixture(source: string): tuple[ok: bool, output: string] =
  let bd = createTempDir("nimcir_spectest_", "")
  defer: removeDir(bd)
  let f = bd / "fixture.nim"
  writeFile(f, source)
  let (output, code) = execCmdEx(quoteShellCommand(@[
    "nim", "check", "--hints:off", "--path:" & repoSrc,
    "--nimcache:" & bd / "nc", f]))
  (code == 0, output)

const preamble = """
import nimcir/contract/dsl
let d = design("f"):
"""

test "a valid spec block compiles -- the control for the two tests below":
  let (ok, output) = compileFixture(preamble & """
  net vdd, kind = ntPower:
    spec:
      voltage = 3.3.V
""")
  check ok
  if not ok: echo output

test "a misspelled annotation key is a compile error naming the real keys":
  let (ok, output) = compileFixture(preamble & """
  net gnd, kind = ntGround, name = "0"
  component C1, kind = "capacitor":
    pin "1", gnd, kind = ptPassive
    spec:
      esrr = 20.mohm
""")
  check not ok
  check "unknown annotation 'esrr'" in output
  # The message has to say what *is* valid, or it just moves the guessing.
  check "esr" in output
  check "package" in output

test "an annotation used on the wrong kind of entity is a compile error":
  let (ok, output) = compileFixture(preamble & """
  net vdd, kind = ntPower:
    spec:
      esr = 20.mohm
""")
  check not ok
  check "does not apply to a net" in output

test "the permissive statement-head fallback is untouched by any of this":
  # An unknown key on the head still lands in attrs, deliberately: a file
  # format needs somewhere to put data this library has never heard of.
  let (ok, output) = compileFixture(preamble & """
  net gnd, kind = ntGround, name = "0"
  component R1, kind = "resistor", somethingNobodyKnows = "yes":
    pin "1", gnd, kind = ptPassive
""")
  check ok
  if not ok: echo output

proc stage(): Netlist =
  subckt("STAGE", [IN, OUT, VP, GND]):
    net GND, kind = ntGround, name = "0"
    net VP, kind = ntPower
    net IN, kind = ntSignal
    net OUT, kind = ntSignal
    net fb, kind = ntSignal
    component U1, kind = "opamp":
      pin "IN+", IN, kind = ptInput
      pin "IN-", fb, kind = ptInput
      pin "OUT", OUT, kind = ptOutput
      pin "V+", VP, kind = ptPower
      pin "V-", GND, kind = ptGround
    component RF, kind = "resistor", value = "10k":
      pin "1", OUT, kind = ptPassive
      pin "2", fb, kind = ptPassive
    component RG, kind = "resistor", value = "1k":
      pin "1", fb, kind = ptPassive
      pin "2", GND, kind = ptPassive

proc stereo(): Design =
  design("stereo"):
    net gnd, kind = ntGround, name = "0", global = true
    net vp, kind = ntPower:
      spec:
        voltage = 15.0.V
    net inL, kind = ntSignal
    net outL, kind = ntSignal
    net inR, kind = ntSignal
    net outR, kind = ntSignal
    component V1, kind = "voltage_source", value = "DC 15":
      pin "+", vp, kind = ptPower
      pin "-", gnd, kind = ptGround
    instance XL, stage(), [inL, outL, vp, gnd]
    instance XR, stage(), [inR, outR, vp, gnd]

suite "binding a role to something inside a subcircuit instance":
  # A stereo board is one channel instanced twice. A claim about the left
  # channel's amplifier has no way to say *which* amplifier it means unless a
  # subject can address into the instance -- and the identifier `U1` was
  # bound inside a `subckt` in another module and is long out of scope.

  test "an instance can be asked for a component inside it":
    let d = stereo()
    let s = d.netlist.components["XL"].innerComponent("U1")
    check s.kind == skComponent
    check s.name == "XL.U1"

  test "a typo raises here, naming what the instance actually contains":
    let d = stereo()
    expect NetlistError:
      discard d.netlist.components["XL"].innerComponent("U2")
    try:
      discard d.netlist.components["XL"].innerComponent("U2")
    except NetlistError as e:
      check "U1" in e.msg
      check "RF" in e.msg

  test "a role binds it, and the two channels do not cross-talk":
    # `instantiate` deep-clones, so XL's U1 and XR's U1 are distinct objects;
    # role membership is tagged on the entity and must land on exactly one.
    var d = stereo()
    discard d.addRole("opamp_stage", "left", {
      "opamp": d.netlist.components["XL"].innerComponent("U1"),
      "input": Subject(kind: skNet, name: "inL"),
      "output": Subject(kind: skNet, name: "outL")})
    let l = d.netlist.children["XL"].components["U1"]
    let r = d.netlist.children["XR"].components["U1"]
    check l.attrs.hasKey("role.left")
    check not r.attrs.hasKey("role.left")

  test "a net inside an instance is addressable too":
    let d = stereo()
    check d.netlist.components["XL"].innerNet("fb").name == "XL.fb"

  test "and a pin, spelled the same way a flat pin is":
    let d = stereo()
    let s = d.netlist.components["XL"].innerPin("U1", "IN-")
    check s.kind == skPin
    check s.name == "XL.U1.IN-"

  test "asking a component that is not an instance says so":
    let d = stereo()
    expect NetlistError:
      discard d.netlist.components["V1"].innerComponent("U1")

suite "claims cannot be made inside control flow":
  test "a role nested in a for is refused with the reason":
    # `design`'s splitter hoists role/require to after the netlist is built,
    # so a nested one has no defined place: the netlist it would attach to
    # does not exist yet. Reachable only via `for`, which is why the message
    # lives in the netlist dispatcher.
    check(not compiles(block:
      discard design("r"):
        net gnd, kind = ntGround, name = "0"
        net vdd, kind = ntPower
        for i in 1 .. 2:
          role "power_rail", r, rail = vdd, voltage = 3.3.V))

  test "but looping over the parts and claiming afterwards is fine":
    let d = design("ok"):
      net gnd, kind = ntGround, name = "0"
      net vdd, kind = ntPower:
        spec:
          voltage = 3.3.V
      for i in 1 .. 4:
        component C, designator = "C" & $i, kind = "capacitor", value = "100n":
          pin "1", vdd, kind = ptPassive
          pin "2", gnd, kind = ptPassive
      role "power_rail", rail0, rail = vdd, voltage = 3.3.V
    check d.netlist.components.len == 4
    check d.roles.hasKey("rail0")

  test "and the same for an if":
    check(not compiles(block:
      discard design("r"):
        net gnd, kind = ntGround, name = "0"
        net vdd, kind = ntPower
        if true:
          role "power_rail", r, rail = vdd, voltage = 3.3.V))

  test "a design may still be built conditionally and claimed afterwards":
    proc board(bulk: bool): Design =
      design("v"):
        net gnd, kind = ntGround, name = "0"
        net vdd, kind = ntPower:
          spec:
            voltage = 3.3.V
        component V1, kind = "voltage_source", value = "DC 3.3":
          pin "+", vdd, kind = ptPower
          pin "-", gnd, kind = ptGround
        if bulk:
          component C1, kind = "capacitor", value = "220u":
            pin "1", vdd, kind = ptPassive
            pin "2", gnd, kind = ptPassive
        else:
          discard
        role "power_rail", rail0, rail = vdd, voltage = 3.3.V
    check board(true).netlist.components.len == 2
    check board(false).netlist.components.len == 1
    check board(false).roles.hasKey("rail0")
