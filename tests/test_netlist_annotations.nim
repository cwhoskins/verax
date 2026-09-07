import std/[strutils, tables, unittest]

import verax/netlist
import verax/netlist/annotations
import verax/units

proc board(): Netlist =
  result = newNetlist("t")
  let vdd = addNet(result, newNet("vdd", ntPower))
  let gnd = addNet(result, newNet("0", ntGround))
  let c1 = addComponent(result, newComponent("C1", kind = "capacitor"))
  discard connect(c1, "1", vdd, ptPassive)
  discard connect(c1, "2", gnd, ptPassive)

# --- the vocabulary ----------------------------------------------------

test "the five live keys plus tolerance are registered, with units":
  for k in ["value", "voltage", "esr", "esl", "package", "tolerance"]:
    check isRegistered(k)
  check annDef("esr").unit == "ohm"
  check annDef("esl").unit == "H"
  check annDef("voltage").unit == "V"
  # `value` is opaque on purpose: it can carry "DC 0 AC 1", not just a number.
  check annDef("value").kind == akString

test "scopes are declared and enforced":
  check asNet in annDef("voltage").scopes
  check asNet notin annDef("esr").scopes
  let nl = board()
  expect(NetlistError):
    setAnnotation(nl.nets["vdd"], "esr", 1.0.ohm)

test "bare means registered, dotted means owned":
  check isNamespaced("kicad.Value")
  check not isNamespaced("voltage")
  let nl = board()
  # A namespaced key is never checked -- whoever owns the namespace owns it.
  setAnnotation(nl.components["C1"], "acme.whatever", "anything")
  check nl.components["C1"].attrs["acme.whatever"] == "anything"
  # A bare unregistered key is rejected at the setter.
  expect(NetlistError):
    setAnnotation(nl.components["C1"], "esrr", "0.02")

# --- units -------------------------------------------------------------

test "a unit literal and a bare SI number store identically":
  let a = board()
  let b = board()
  setAnnotation(a.components["C1"], "esr", 20.mohm)
  setAnnotation(b.components["C1"], "esr", 0.02)
  check a.components["C1"].attrs["esr"] == b.components["C1"].attrs["esr"]
  check abs(esr(a.components["C1"]).value - 0.02) < 1e-15

test "a SPICE magnitude suffix is rejected, not silently interpreted":
  let nl = board()
  # "20m" is 20 milliohms in SPICE and 20 ohms if read naively: a factor of
  # 1000 either way. Refuse it rather than pick.
  expect(NetlistError):
    setAnnotation(nl.components["C1"], "esr", "20m")
  expect(NetlistError):
    setAnnotation(nl.components["C1"], "esl", "1n")

test "the wrong unit is rejected even though both are floats":
  let nl = board()
  expect(NetlistError):
    setAnnotation(nl.components["C1"], "esr", 20.nF)
  setAnnotation(nl.components["C1"], "esr", 20.mohm)   # the right one is fine

test "a percentage is accepted for a dimensionless key":
  let nl = board()
  setAnnotation(nl.components["C1"], "tolerance", "5%")
  check abs(annotationFloat(nl.components["C1"], "tolerance").value - 0.05) < 1e-15
  setAnnotation(nl.components["C1"], "tolerance", 5.pct)
  check abs(annotationFloat(nl.components["C1"], "tolerance").value - 0.05) < 1e-15

# --- provenance --------------------------------------------------------

test "an absent annotation is annAbsent and never defaults":
  let nl = board()
  let e = esr(nl.components["C1"])
  check not e.has
  check e.source == annAbsent

test "provenance distinguishes authored from imported and defaulted":
  let nl = board()
  let c = nl.components["C1"]
  setAnnotation(c, "esr", 20.mohm)
  check esr(c).source == annAuthored

  setAnnotation(c, "esl", 1.nH, source = annImported)
  check esl(c).source == annImported
  check abs(esl(c).value - 1e-9) < 1e-18

  setAnnotation(c, "package", "0402", source = annDerived)
  check package(c).source == annDerived

test "an authored value costs no extra key; a non-authored one is marked":
  let nl = board()
  let c = nl.components["C1"]
  setAnnotation(c, "esr", 20.mohm)
  check not c.attrs.hasKey("ann.src.esr")
  setAnnotation(c, "esr", 30.mohm, source = annDefaulted)
  check c.attrs["ann.src.esr"] == "defaulted"
  # Re-authoring clears the marker rather than leaving it stale.
  setAnnotation(c, "esr", 40.mohm)
  check not c.attrs.hasKey("ann.src.esr")
  check esr(c).source == annAuthored

test "annotations survive a clone, which is why they live in attrs":
  let nl = board()
  setAnnotation(nl.components["C1"], "esr", 20.mohm, source = annImported)
  setRailVoltage(nl.nets["vdd"], 3.3.V)
  var globals: OrderedTable[string, Net]
  let copy = clone(nl, globals)
  check abs(esr(copy.components["C1"]).value - 0.02) < 1e-15
  check esr(copy.components["C1"]).source == annImported
  check abs(railVoltage(copy.nets["vdd"]).value - 3.3) < 1e-12

# --- validation --------------------------------------------------------

test "a misspelled bare key is reported -- the whole point of the registry":
  let nl = board()
  # Bypass the setter the way a file reader or hand-written attrs would.
  nl.components["C1"].attrs["ESL"] = "1e-9"
  let issues = validateAnnotations(nl)
  check issues.len == 1
  check issues[0].kind == "unknown_annotation"
  check issues[0].severity == sevWarning
  check "ESL" in issues[0].message
  check issues[0].components[0].designator == "C1"

test "a clean netlist validates with nothing to report":
  let nl = board()
  setAnnotation(nl.components["C1"], "esr", 20.mohm)
  setAnnotation(nl.components["C1"], "package", "0402")
  setRailVoltage(nl.nets["vdd"], 3.3.V)
  nl.components["C1"].attrs["parasitics.expanded"] = "true"   # namespaced: ignored
  check validateAnnotations(nl).len == 0

test "an unparseable value is an error, not a warning":
  let nl = board()
  nl.components["C1"].attrs["esr"] = "20m"
  let issues = validateAnnotations(nl)
  check issues.len == 1
  check issues[0].kind == "annotation_unparseable"
  check issues[0].severity == sevError

test "a key on the wrong entity is reported":
  let nl = board()
  nl.nets["vdd"].attrs["esr"] = "0.02"
  let issues = validateAnnotations(nl)
  check issues.len == 1
  check issues[0].kind == "annotation_wrong_scope"

test "validation recurses into child netlists":
  let nl = board()
  let child = newNetlist("sub")
  discard addNet(child, newNet("inner"))
  child.nets["inner"].attrs["voltag"] = "3.3"
  addChild(nl, "X1", child)
  check validateAnnotations(nl, recursive = true).len == 1
  check validateAnnotations(nl, recursive = false).len == 0

test "the provenance markers themselves are not reported as unknown keys":
  let nl = board()
  setAnnotation(nl.components["C1"], "esr", 20.mohm, source = annDefaulted)
  check validateAnnotations(nl).len == 0

# --- extensibility -----------------------------------------------------

test "a key can be registered at runtime, keeping the plugin path open":
  check not isRegistered("slew_rate")
  registerAnnotation(AnnDef(key: "slew_rate", kind: akFloat, unit: "V",
                            scopes: {asComponent}, doc: "test-only"))
  check isRegistered("slew_rate")
  let nl = board()
  setAnnotation(nl.components["C1"], "slew_rate", 1.5.V)
  check validateAnnotations(nl).len == 0
