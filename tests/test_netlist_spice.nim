import std/[streams, strutils, tables, unittest]

import nimcir/netlist
import nimcir/netlist/formats/spice

proc render(nl: Netlist): string =
  let outStream = newStringStream()
  writeNetlist(nl, outStream)
  result = outStream.data

test "round-trips a minimal RC deck":
  let deck = """Minimal RC
V1 vin 0 DC 5
R1 vin vout 1k
C1 vout 0 10uF
.END
"""
  let nl = readNetlist(newStringStream(deck))
  check nl.name == "Minimal RC"
  check nl.nets["0"].kind == ntGround
  check nl.components["R1"].kind == "resistor"
  check nl.components["R1"].pins["1"].net.name == "vin"
  check nl.components["R1"].pins["2"].net.name == "vout"
  check nl.components["R1"].attrs["value"] == "1k"
  check nl.components["V1"].attrs["value"] == "DC 5"
  check nl.components["C1"].pins["2"].net.name == "0"

  let reparsed = readNetlist(newStringStream(render(nl)))
  check reparsed.components.len == nl.components.len
  check reparsed.nets.len == nl.nets.len
  check reparsed.components["R1"].pins["1"].net.name == "vin"
  check reparsed.components["R1"].pins["2"].net.name == "vout"
  check reparsed.components["R1"].attrs["value"] == "1k"

test "SUBCKT + single X instantiation builds a hierarchical sub-netlist":
  let deck = """Sub Test
.SUBCKT BUF IN OUT
R1 IN OUT 100
.ENDS BUF
X1 net1 net2 BUF
.END
"""
  let nl = readNetlist(newStringStream(deck))
  check nl.children.hasKey("X1")
  let child = nl.children["X1"]
  check child.ports.hasKey("IN")
  check child.ports.hasKey("OUT")
  check nl.components["X1"].pins["IN"].net.name == "net1"
  check nl.components["X1"].pins["OUT"].net.name == "net2"
  check nl.components["X1"].pins["IN"].hierNet == child.nets["IN"]
  check child.instanceOf == nl.components["X1"]
  check child.parent == nl

  let reparsed = readNetlist(newStringStream(render(nl)))
  check reparsed.children.hasKey("X1")
  check reparsed.components["X1"].pins["IN"].net.name == "net1"
  check reparsed.children["X1"].components["R1"].attrs["value"] == "100"

test "two instantiations of the same SUBCKT emit one block, two X lines":
  let deck = """Two Instances
.SUBCKT BUF IN OUT
R1 IN OUT 100
.ENDS BUF
X1 a b BUF
X2 c d BUF
.END
"""
  let nl = readNetlist(newStringStream(deck))
  check nl.children.len == 2
  check nl.children["X1"].components["R1"] != nl.children["X2"].components["R1"]

  let text = render(nl)
  check text.count(".SUBCKT") == 1
  var xLines = 0
  for line in text.splitLines():
    if line.startsWith("X1 ") or line.startsWith("X2 "):
      inc xLines
  check xLines == 2

test "ground net '0' is identity-shared across hierarchy levels":
  let deck = """Ground Test
.SUBCKT GATE VDD 0
R1 VDD 0 1k
.ENDS GATE
X1 vddA 0 GATE
X2 vddB 0 GATE
.END
"""
  let nl = readNetlist(newStringStream(deck))
  check nl.nets["0"].kind == ntGround
  check nl.components["X1"].pins["0"].net == nl.nets["0"]
  check nl.components["X1"].pins["0"].hierNet == nl.nets["0"]
  check nl.components["X2"].pins["0"].hierNet == nl.nets["0"]
  check nl.components["X1"].pins["0"].hierNet == nl.components["X2"].pins["0"].hierNet

test "comment and continuation lines don't break tokenization":
  let deck = """Comment Test
* a full-line comment, ignored
R1 a
+ b 1k
.END
"""
  let nl = readNetlist(newStringStream(deck))
  check nl.components.len == 1
  check nl.components["R1"].pins["1"].net.name == "a"
  check nl.components["R1"].pins["2"].net.name == "b"
  check nl.components["R1"].attrs["value"] == "1k"

test "unrecognized simulation directives are skipped without side effects":
  let deck = """Directive Test
.OPTIONS reltol=1e-3
.TRAN 1n 1u
R1 a b 1k
.END
"""
  let nl = readNetlist(newStringStream(deck))
  check nl.components.len == 1
  check nl.components.hasKey("R1")
  check nl.nets.len == 3 # "0" (seeded) + a + b

test "unrecognized device prefix falls back to generic pins":
  let deck = """Fallback Test
Z1 n1 n2 n3 weirdmodel
.END
"""
  let nl = readNetlist(newStringStream(deck))
  check nl.components.hasKey("Z1")
  let z1 = nl.components["Z1"]
  check z1.pins.len == 3
  check z1.pins["pin1"].net.name == "n1"
  check z1.pins["pin3"].net.name == "n3"
  check z1.attrs["value"] == "weirdmodel"

test "the device letter comes from kind, not from the designator":
  # SPICE infers device type from the first letter and nothing else, so a
  # designator that disagrees with `kind` silently simulates a different
  # part. These are all ordinary EDA designators.
  var nl = newNetlist("d")
  let a = addNet(nl, newNet("a"))
  let b = addNet(nl, newNet("0", ntGround))
  for (desig, kind, want) in [("FB1", "inductor", "LFB1"),
                              ("BT1", "voltage_source", "VBT1"),
                              ("J1", "voltage_source", "VJ1"),
                              ("VR1", "resistor", "RVR1"),
                              ("TP1", "capacitor", "CTP1"),
                              ("C12", "inductor", "LC12"),
                              ("L7", "resistor", "RL7")]:
    let c = addComponent(nl, newComponent(desig, kind = kind))
    discard connect(c, "1", a, ptPassive)
    discard connect(c, "2", b, ptPassive)
    check deckDesignator(c) == want

test "a designator that already agrees with its kind is left alone":
  var nl = newNetlist("d")
  let a = addNet(nl, newNet("a"))
  for (desig, kind) in [("R1", "resistor"), ("C4", "capacitor"),
                        ("L2", "inductor"), ("D3", "diode"),
                        ("V1", "voltage_source"), ("Q7", "bjt")]:
    let c = addComponent(nl, newComponent(desig, kind = kind))
    discard connect(c, "1", a, ptPassive)
    check deckDesignator(c) == desig

test "a kind with no known letter keeps its designator":
  # Nothing to correct it against. Such a part is substituted before it ever
  # reaches a deck, or written as a subcircuit instance.
  var nl = newNetlist("d")
  let c = addComponent(nl, newComponent("U1", kind = "mcu"))
  check deckDesignator(c) == "U1"

test "the corrected letter is prepended, never substituted":
  # Substituting would merge FB1 and L1 into one device on a board with both.
  var nl = newNetlist("d")
  let a = addNet(nl, newNet("a"))
  let b = addNet(nl, newNet("0", ntGround))
  for desig in ["FB1", "L1"]:
    let c = addComponent(nl, newComponent(desig, kind = "inductor"))
    discard connect(c, "1", a, ptPassive)
    discard connect(c, "2", b, ptPassive)
  check deckDesignator(nl.components["FB1"]) == "LFB1"
  check deckDesignator(nl.components["L1"]) == "L1"

test "a written deck spells every device from its kind":
  var nl = newNetlist("d")
  let a = addNet(nl, newNet("a"))
  let b = addNet(nl, newNet("0", ntGround))
  let fb = addComponent(nl, newComponent("FB1", kind = "inductor"))
  discard connect(fb, "1", a, ptPassive)
  discard connect(fb, "2", b, ptPassive)
  fb.attrs["value"] = "600n"

  let s = newStringStream()
  writeNetlist(nl, s)
  check "LFB1 a 0 600n" in s.data
  check "\nFB1 " notin s.data
