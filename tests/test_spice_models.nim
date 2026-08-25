import std/[math, sequtils, streams, strutils, tables, unittest]

import nimcir/netlist
import nimcir/netlist/formats/spice
import nimcir/netlist/annotations
import nimcir/netlist/kinds
import nimcir/spice/models

proc oneCap(attrs: openArray[(string, string)]): Netlist =
  result = newNetlist("t")
  let a = addNet(result, newNet("a"))
  let b = addNet(result, newNet("0", ntGround))
  let c = addComponent(result, newComponent("C1", kind = "capacitor"))
  discard connect(c, "1", a, ptPassive)
  discard connect(c, "2", b, ptPassive)
  c.attrs["value"] = "100n"
  for (k, v) in attrs: c.attrs[k] = v

test "a capacitor becomes C in series with its ESR and ESL":
  let nl = oneCap([("esr", "0.02"), ("esl", "1e-9")])
  let notes = expandCapacitorParasitics(nl)

  check nl.components.len == 3
  check nl.components["RC1_ESR"].kind == "resistor"
  check nl.components["LC1_ESL"].kind == "inductor"
  check parseFloat(nl.components["RC1_ESR"].attrs["value"]) == 0.02
  check parseFloat(nl.components["LC1_ESL"].attrs["value"]) == 1e-9
  # Explicit attributes are data, not assumptions.
  check notes.len == 0

  # The chain really is in series: C1 -> ESR node -> ESL node -> original net.
  check nl.components["C1"].pins["2"].net.name == "C1_ESR_N"
  check nl.components["RC1_ESR"].pins["2"].net.name == "C1_ESL_N"
  check nl.components["LC1_ESL"].pins["2"].net.name == "0"

test "a package default is used when nothing is annotated, and reported":
  let nl = oneCap([("package", "0603")])
  let notes = expandCapacitorParasitics(nl)
  # One assumption per invented value, not one per component: ESR and ESL are
  # separately sourced and a consumer must be able to tell them apart.
  check notes.len == 2
  check notes[0].entity == "C1"
  check notes[0].key == "esr"
  check notes[1].key == "esl"
  for n in notes:
    check n.source == annDefaulted
    check "package default (0603)" in n.detail
  check abs(notes[1].value - 0.8e-9) < 1e-18
  check notes[1].unit == "H"
  check parseFloat(nl.components["LC1_ESL"].attrs["value"]) == 0.8e-9

test "an unknown package falls back, and only the invented value is reported":
  let nl = oneCap([("package", "9999"), ("esr", "0.005")])
  let notes = expandCapacitorParasitics(nl)
  # The ESR was stated, so it is data rather than an assumption; only the ESL
  # had to be invented.
  check notes.len == 1
  check notes[0].key == "esl"
  check "fallback" in notes[0].detail
  check parseFloat(nl.components["RC1_ESR"].attrs["value"]) == 0.005

test "expanding twice is a no-op, not a doubling":
  let nl = oneCap([("esr", "0.02"), ("esl", "1e-9")])
  discard expandCapacitorParasitics(nl)
  let n = nl.components.len
  discard expandCapacitorParasitics(nl)
  check nl.components.len == n

test "an unparseable parasitic attribute raises rather than being ignored":
  let nl = oneCap([("esl", "1 nH")])
  expect(NetlistError):
    discard expandCapacitorParasitics(nl)

test "a dangling capacitor is left exactly as it is":
  let nl = newNetlist("t")
  let a = addNet(nl, newNet("a"))
  let c = addComponent(nl, newComponent("C1", kind = "capacitor"))
  discard connect(c, "1", a, ptPassive)
  discard addPin(c, newPin("2", ptPassive))
  discard expandCapacitorParasitics(nl)
  check nl.components.len == 1

test "idealOpAmp emits a valid SPICE subcircuit with the E devices in order":
  let tmpl = idealOpAmp("IDEAL_OPAMP", aol = 1.0e5, gbw = 1.0e6)
  check toSeq(tmpl.ports.keys) == @["INP", "INN", "OUT"]

  let s = newStringStream()
  writeNetlist(tmpl, s)
  let text = s.data
  # `Exxx n+ n- nc+ nc- gain` -- the node order is what makes the line mean
  # what it says, and it comes from the vcvs pin template.
  check "E1 N1 0 INP INN 1.000000000e+05" in text
  check "E2 OUT 0 N2 0 1.000000000e+00" in text

test "the pole is placed at gbw/aol":
  let tmpl = idealOpAmp("A", aol = 1.0e5, gbw = 1.0e6)
  let r = parseFloat(tmpl.components["R1"].attrs["value"])
  let c = parseFloat(tmpl.components["C1"].attrs["value"])
  let fPole = 1.0 / (2.0 * PI * r * c)
  check abs(fPole - 10.0) / 10.0 < 1e-9      # 1e6 / 1e5

test "the macromodel's own pole capacitor is never given parasitics":
  let tmpl = idealOpAmp("A")
  let before = tmpl.components.len
  discard expandCapacitorParasitics(tmpl)
  check tmpl.components.len == before

test "an impossible op-amp is rejected":
  expect(NetlistError):
    discard idealOpAmp("A", aol = 0.5)
  expect(NetlistError):
    discard idealOpAmp("A", gbw = 0.0)

# --- source output impedance ---------------------------------------------

proc railWithSource(annots: openArray[(string, string)] = []): Netlist =
  result = newNetlist("t")
  let vdd = addNet(result, newNet("vdd", ntPower))
  let gnd = addNet(result, newNet("0", ntGround))
  let v = addComponent(result, newComponent("V1", kind = "voltage_source"))
  discard connect(v, "+", vdd, ptPower)
  discard connect(v, "-", gnd, ptGround)
  v.attrs["value"] = "DC 3.3"
  for (k, val) in annots: v.attrs[k] = val

proc valueOf(nl: Netlist, designator: string): float =
  discard parseSpiceMagnitude(nl.components[designator].attrs["value"], result)

suite "source output impedance":
  test "a source is no longer a dead short":
    # An ideal source pins its rail at zero ohms, so a PDN sweep over a
    # design carrying its own regulator passes every target that exists.
    let nl = railWithSource()
    let notes = expandSourceImpedance(nl)
    check nl.components.hasKey("RV1_ROUT")
    check nl.components.hasKey("LV1_LOUT")
    check valueOf(nl, "RV1_ROUT") > 0.0
    check valueOf(nl, "LV1_LOUT") > 0.0
    check notes.len == 2

  test "the source no longer connects straight to the rail":
    let nl = railWithSource()
    discard expandSourceImpedance(nl)
    let plus = nl.components["V1"].pins["+"]
    check plus.net.name != "vdd"          # now behind the series network
    var railParts: seq[string]
    for c in connectedComponents(nl.nets["vdd"]): railParts.add c.designator
    check "LV1_LOUT" in railParts
    check "V1" notin railParts

  test "stated values are used and nothing is invented":
    let nl = railWithSource({"rout": "0.002", "lout": "2e-7"})
    let notes = expandSourceImpedance(nl)
    check notes.len == 0                  # nobody guessed, so nobody reports
    check abs(valueOf(nl, "RV1_ROUT") - 0.002) < 1e-12
    check abs(valueOf(nl, "LV1_LOUT") - 2e-7) < 1e-18

  test "a deliberately ideal source is left alone":
    let nl = railWithSource({"rout": "0", "lout": "0"})
    let notes = expandSourceImpedance(nl)
    check notes.len == 0
    check not nl.components.hasKey("RV1_ROUT")

  test "expanding twice does not stack two networks":
    let nl = railWithSource()
    discard expandSourceImpedance(nl)
    let before = nl.components.len
    discard expandSourceImpedance(nl)
    check nl.components.len == before

# --- pin-kind stand-ins ---------------------------------------------------

proc boardWithMcu(pinAnnots: openArray[(string, string)] = []): Netlist =
  result = newNetlist("t")
  let vdd = addNet(result, newNet("vdd", ntPower))
  let gnd = addNet(result, newNet("0", ntGround))
  let sda = addNet(result, newNet("sda"))
  let dout = addNet(result, newNet("dout"))
  let u = addComponent(result, newComponent("U1", kind = "mcu"))
  discard connect(u, "VDD", vdd, ptPower)
  discard connect(u, "VSS", gnd, ptGround)
  discard connect(u, "SDA", sda, ptInOut)
  discard connect(u, "OUT", dout, ptOutput)
  for (k, val) in pinAnnots: u.pins["VDD"].attrs[k] = val

suite "pin-kind stand-ins":
  test "a part with no model becomes one impedance per pin":
    let nl = boardWithMcu()
    let notes = expandPinModels(nl)
    check not nl.components.hasKey("U1")
    check nl.components.hasKey("RU1_VDD")
    check nl.components.hasKey("RU1_SDA")
    check nl.components.hasKey("RU1_OUT")
    check notes.len == 3

  test "the ground pin is left alone, being the reference itself":
    let nl = boardWithMcu()
    discard expandPinModels(nl)
    check not nl.components.hasKey("RU1_VSS")

  test "outputs are low impedance and everything else is high":
    let nl = boardWithMcu()
    discard expandPinModels(nl)
    check valueOf(nl, "RU1_OUT") < valueOf(nl, "RU1_SDA")
    check valueOf(nl, "RU1_VDD") >= 1.0e5
    check valueOf(nl, "RU1_SDA") >= 1.0e5

  test "a stated zin is used and reported as nobody's guess":
    let nl = boardWithMcu({"zin": "33"})
    let notes = expandPinModels(nl)
    check abs(valueOf(nl, "RU1_VDD") - 33.0) < 1e-9
    check notes.len == 2                  # VDD was stated; SDA and OUT were not
    for n in notes:
      check "U1.VDD" notin $n

  test "a passive part is never replaced":
    let nl = boardWithMcu()
    let r = addComponent(nl, newComponent("R9", kind = "resistor"))
    discard connect(r, "1", nl.nets["sda"], ptPassive)
    discard connect(r, "2", nl.nets["0"], ptPassive)
    r.attrs["value"] = "1k"
    discard expandPinModels(nl)
    check nl.components.hasKey("R9")

  test "without a ground reference nothing is touched, and it says why":
    let nl = newNetlist("t")
    let a = addNet(nl, newNet("a"))
    let u = addComponent(nl, newComponent("U1", kind = "mcu"))
    discard connect(u, "IN", a, ptInput)
    let notes = expandPinModels(nl)
    check nl.components.hasKey("U1")
    check notes.len == 1
    check "ground" in $notes[0]

  test "every stand-in carries its provenance":
    let nl = boardWithMcu()
    for n in expandPinModels(nl):
      check n.source == annDefaulted
      check n.key == "zin"
      check n.unit == "ohm"
      check "no model" in n.detail

# --- behavioural models ---------------------------------------------------

proc ldoBoard(kind = "regulator", vout = "", outPinName = "OUT"): Netlist =
  result = newNetlist("t")
  let vin = addNet(result, newNet("vin", ntPower))
  let vdd = addNet(result, newNet("vdd", ntPower))
  let gnd = addNet(result, newNet("0", ntGround))
  let u = addComponent(result, newComponent("U1", kind = kind))
  discard connect(u, "IN", vin, ptPower)
  discard connect(u, outPinName, vdd, ptPower)
  discard connect(u, "GND", gnd, ptGround)
  if vout.len > 0: u.attrs["voltage"] = vout

proc drivenBy(nl: Netlist, netName: string): seq[string] =
  for c in connectedComponents(nl.nets[netName]): result.add c.designator

suite "behavioural models":
  test "a regulator that states its output becomes a source on that net":
    let nl = ldoBoard(vout = "3.3")
    let notes = expandPinModels(nl)
    check not nl.components.hasKey("U1")
    check "VU1_OUT" in drivenBy(nl, "vdd")
    check nl.components["VU1_OUT"].attrs["value"].startsWith("DC ")
    check notes.len == 2      # the modelling narrative, and the input's load

  test "the modelled source carries the part's voltage, not the rail's":
    # The whole reason a dc_voltage claim stays worth making: read the output
    # off the net and the check measures its own assumption back.
    let nl = ldoBoard(vout = "5")
    nl.nets["vdd"].attrs["voltage"] = "3.3"    # what the rail is required to be
    discard expandPinModels(nl)
    var v: float
    discard parseSpiceMagnitude(
      nl.components["VU1_OUT"].attrs["value"].split(' ')[1], v)
    check abs(v - 5.0) < 1e-9

  test "a regulator stating nothing is left alone, not tied to ground":
    # Two independent resistors to ground would report vdd as 0 V: a
    # confident wrong answer where refusing to simulate is the honest one.
    let nl = ldoBoard()
    let notes = expandPinModels(nl)
    check nl.components.hasKey("U1")
    check not nl.components.hasKey("RU1_OUT")
    check notes.len == 1
    check "voltage" in $notes[0]

  test "a regulator with no recognisable output pin says which pins it has":
    let nl = ldoBoard(vout = "3.3", outPinName = "PIN2")
    let notes = expandPinModels(nl)
    check nl.components.hasKey("U1")
    check notes.len == 1
    check "PIN2" in $notes[0]

  test "a part with no behavioural model still gets per-pin impedances":
    let nl = ldoBoard(kind = "mcu")
    discard expandPinModels(nl)
    check not nl.components.hasKey("U1")
    check nl.components.hasKey("RU1_OUT")

  test "every kind the regulator model claims is actually registered":
    for kind in ["regulator", "ldo", "vreg", "dcdc", "smps", "buck", "boost"]:
      check behavioralModelFor(kind) != nil
      check kind in modelledKinds()
    check behavioralModelFor("mcu") == nil

  test "a kind can be modelled without editing this library":
    registerBehavioralModel("test_widget",
      proc (nl: Netlist, c: Component, gnd: Net): BehavioralResult {.nimcall.} =
        removeComponent(nl, c.designator)
        (true, @[note("widget replaced")]))
    let nl = ldoBoard(kind = "test_widget")
    let notes = expandPinModels(nl)
    check not nl.components.hasKey("U1")
    check notes.len == 1
    check "widget replaced" in $notes[0]

  test "re-registering the built-ins does not multiply them":
    let before = modelledKinds().len
    registerBuiltinBehavioralModels()
    check modelledKinds().len == before

proc stageWithTwoOpAmps(): Netlist =
  ## Two amplifiers, only one of which an analysis would name.
  result = newNetlist("t")
  let gnd = addNet(result, newNet("0", ntGround))
  let vin = addNet(result, newNet("vin"))
  let mid = addNet(result, newNet("mid"))
  let vout = addNet(result, newNet("vout"))
  for (desig, inNet, outNet) in [("U1", vin, mid), ("U2", mid, vout)]:
    let u = addComponent(result, newComponent(desig, kind = "opamp"))
    discard connect(u, "IN+", inNet, ptInput)
    discard connect(u, "IN-", outNet, ptInput)
    discard connect(u, "OUT", outNet, ptOutput)
    discard connect(u, "V-", gnd, ptGround)

test "an op-amp with no model becomes a macromodel, not impedances to ground":
  # The pin model is the last resort in the chain, not the first answer: a
  # part with a registered kind gets that kind's model. Without this every
  # op-amp but the one an analysis names became three resistors to ground,
  # which deletes the stage rather than approximating it.
  let nl = stageWithTwoOpAmps()
  discard expandPinModels(nl, exclude = ["U2"])

  check not nl.components.hasKey("U1")
  check nl.components.hasKey("U2")           # excluded, modelled deliberately
  check nl.components.hasKey("EU1_AOL")
  check nl.components.hasKey("RU1_POLE")
  check nl.components.hasKey("CU1_POLE")
  check nl.components.hasKey("EU1_BUF")
  # ...and no per-pin stand-in was left behind.
  check not nl.components.hasKey("RU1_IN+")
  check not nl.components.hasKey("RU1_OUT")

test "the substituted macromodel is flat, so isolate can walk through it":
  # Built as an instance of `idealOpAmp` instead, every part of it would sit
  # behind a `subNetlist`, which `spice/isolate` refuses to traverse -- and
  # the stage would be cut at the very boundary the model exists to bridge.
  let nl = stageWithTwoOpAmps()
  discard expandPinModels(nl, exclude = ["U2"])
  check nl.children.len == 0
  for desig in ["EU1_AOL", "RU1_POLE", "CU1_POLE", "EU1_BUF"]:
    check nl.components[desig].subNetlist == nil
    check isPassive(nl.components[desig])

test "the macromodel's own pole capacitor never gets parasitics":
  # It is a modelling element, not a part; an ESL on it would put a
  # resonance in the amplifier's response that the real device lacks.
  let nl = stageWithTwoOpAmps()
  discard expandPinModels(nl, exclude = ["U2"])
  check nl.components["CU1_POLE"].attrs["parasitics.expanded"] == "true"
  let before = nl.components.len
  discard expandCapacitorParasitics(nl)
  check nl.components.len == before

test "a stated gain becomes the macromodel's open-loop gain":
  let nl = stageWithTwoOpAmps()
  nl.components["U1"].attrs["gain"] = "2e4"
  let notes = expandPinModels(nl, exclude = ["U2"])
  check parseFloat(nl.components["EU1_AOL"].attrs["value"]) == 2.0e4
  # Stated, so it is not reported as an invented value.
  check not notes.anyIt(it.key == "gain" and it.entity == "U1")

test "a stated gbw becomes the macromodel's pole, and is not reported as invented":
  # This was a `const` in `models.opampModel` until it was noticed that the
  # assumption line reported 1 MHz as invented while a stated `gbw` sat one
  # field away unread -- the worst shape a default can take, since the report
  # then reads as the design not having stated one. `analysis/opamp` already
  # honoured it, so the two paths disagreed about the same part.
  let nl = stageWithTwoOpAmps()
  nl.components["U1"].attrs["gain"] = "2e5"
  nl.components["U1"].attrs["gbw"] = "3e6"
  let notes = expandPinModels(nl, exclude = ["U2"])
  # The pole sits at gbw/aol into a 1 kohm series resistor.
  let rPole = parseFloat(nl.components["RU1_POLE"].attrs["value"])
  let cPole = parseFloat(nl.components["CU1_POLE"].attrs["value"])
  let fPole = 1.0 / (2.0 * PI * rPole * cPole)
  check abs(fPole * 2.0e5 - 3.0e6) / 3.0e6 < 1.0e-9
  for n in notes:
    if n.entity == "U1" and n.key == "gbw":
      check n.value == 3.0e6
      check n.source == annAuthored

test "an unstated gbw still defaults to 1 MHz and still says that it did":
  let nl = stageWithTwoOpAmps()
  let notes = expandPinModels(nl, exclude = ["U2"])
  var seen = false
  for n in notes:
    if n.entity == "U1" and n.key == "gbw":
      seen = true
      check n.value == 1.0e6
      check n.source == annDefaulted
  check seen

test "an amplifier whose pins cannot be identified is left alone, not grounded":
  # Tying an unrecognised part's pins to ground independently would open any
  # loop through it, which is the failure this whole registry exists to stop.
  var nl = newNetlist("t")
  let gnd = addNet(nl, newNet("0", ntGround))
  let a = addNet(nl, newNet("a"))
  let u = addComponent(nl, newComponent("U9", kind = "opamp"))
  discard connect(u, "pin1", a, ptInput)
  discard connect(u, "pin2", gnd, ptGround)
  let notes = expandPinModels(nl)
  check nl.components.hasKey("U9")
  check notes.anyIt("U9" in it.detail)

test "a part with a .MODEL card is never stood in for":
  # The pin model exists because nothing described the part. A registered
  # `.MODEL` describes it, so substituting would replace a real device with
  # two resistors to ground -- which for a clipping diode pair across a
  # feedback network shunts the inverting node with 500k and quietly acts as
  # a second gain leg.
  var nl = newNetlist("t")
  let gnd = addNet(nl, newNet("0", ntGround))
  let a = addNet(nl, newNet("a"))
  setModel(nl, "1N4148", "D(IS=2.52n)")
  for (desig, value) in [("D1", "1N4148"), ("D2", "1N5819")]:
    let d = addComponent(nl, newComponent(desig, kind = "diode"))
    discard connect(d, "A", a, ptPassive)
    discard connect(d, "K", gnd, ptPassive)
    d.attrs["value"] = value

  discard expandPinModels(nl)
  check nl.components.hasKey("D1")          # modelled, left alone
  check not nl.components.hasKey("D2")      # no card, stood in for
  check nl.components.hasKey("RD2_A")
