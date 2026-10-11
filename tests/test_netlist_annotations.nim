import std/[os, strutils, tables, unittest]

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
  # `value` is opaque: it can carry "DC 0 AC 1".
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
  # Namespaced keys are never checked; the namespace owner owns them.
  setAnnotation(nl.components["C1"], "acme.whatever", "anything")
  check nl.components["C1"].attrs["acme.whatever"] == "anything"
  # A bare unregistered key is rejected at the setter.
  expect(NetlistError):
    setAnnotation(nl.components["C1"], "esrr", "0.02")

test "an akEnum value outside `allowed` is rejected at the setter, not just at readiness":
  # `akEnum` values are checked at the setter, like `akFloat`; `part_use` is
  # written by `parts/annotate.applyChoice` far more often than designs are
  # re-validated.
  check annDef("part_use").kind == akEnum
  let nl = board()
  setAnnotation(nl.components["C1"], "part_use", "decoupling")
  check nl.components["C1"].attrs["part_use"] == "decoupling"
  expect(NetlistError):
    setAnnotation(nl.components["C1"], "part_use", "timming")

# --- units -------------------------------------------------------------

test "a unit literal and a bare SI number store identically":
  let a = board()
  let b = board()
  setAnnotation(a.components["C1"], "esr", 20.mohm)
  setAnnotation(b.components["C1"], "esr", 0.02)
  check a.components["C1"].attrs["esr"] == b.components["C1"].attrs["esr"]
  check abs(float(esr(a.components["C1"]).value) - 0.02) < 1e-15

test "a SPICE magnitude suffix is rejected, not silently interpreted":
  let nl = board()
  # "20m" is 20 milliohms in SPICE and 20 ohms naively; refuse rather than
  # pick.
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
  check abs(float(esl(c).value) - 1e-9) < 1e-18

  setAnnotation(c, "package", "0402", source = annDerived)
  check package(c).source == annDerived

test "an authored value costs no extra key; a non-authored one is marked":
  let nl = board()
  let c = nl.components["C1"]
  setAnnotation(c, "esr", 20.mohm)
  check not c.attrs.hasKey("ann.src.esr")
  setAnnotation(c, "esr", 30.mohm, source = annDefaulted)
  check c.attrs["ann.src.esr"] == "defaulted"
  # Re-authoring clears the marker.
  setAnnotation(c, "esr", 40.mohm)
  check not c.attrs.hasKey("ann.src.esr")
  check esr(c).source == annAuthored

test "annotations survive a clone, which is why they live in attrs":
  let nl = board()
  setAnnotation(nl.components["C1"], "esr", 20.mohm, source = annImported)
  setRailVoltage(nl.nets["vdd"], 3.3.V)
  var globals: OrderedTable[string, Net]
  let copy = clone(nl, globals)
  check abs(float(esr(copy.components["C1"]).value) - 0.02) < 1e-15
  check esr(copy.components["C1"]).source == annImported
  check abs(float(railVoltage(copy.nets["vdd"]).value) - 3.3) < 1e-12

# --- validation --------------------------------------------------------

test "a misspelled bare key is reported -- the whole point of the registry":
  let nl = board()
  # Bypass the setter as a file reader would.
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

test "footprint is registered, component-scope, and distinct from package":
  check isRegistered("footprint")
  check annDef("footprint").kind == akString
  check annDef("footprint").scopes == {asComponent}
  let nl = board()
  setAnnotation(nl.components["C1"], "footprint", "Capacitor_SMD:C_0402_1005Metric")
  check footprint(nl.components["C1"]).value == "Capacitor_SMD:C_0402_1005Metric"
  # `package` (case size) and `footprint` (land pattern) are separate keys.
  setAnnotation(nl.components["C1"], "package", "0402")
  check package(nl.components["C1"]).value == "0402"
  check footprint(nl.components["C1"]).value == "Capacitor_SMD:C_0402_1005Metric"

test "footprint is rejected at netlist scope":
  let nl = board()
  expect(NetlistError):
    setAnnotation(nl, "footprint", "Capacitor_SMD:C_0402_1005Metric")

test "a misspelling of footprint is reported as unknown_annotation":
  let nl = board()
  nl.components["C1"].attrs["footprnit"] = "Capacitor_SMD:C_0402_1005Metric"
  let issues = validateAnnotations(nl)
  check issues.len == 1
  check issues[0].kind == "unknown_annotation"
  check "footprnit" in issues[0].message

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

# --- the RF vocabulary --------------------------------------------------

test "gain_db is dB and rejects a dBm literal":
  let nl = board()
  setAnnotation(nl.components["C1"], "gain_db", 12.5.dB)
  check abs(annotationFloat(nl.components["C1"], "gain_db").value - 12.5) < 1e-9
  expect(NetlistError):
    setAnnotation(nl.components["C1"], "gain_db", 12.5.dBm)

test "oip3_dbm is dBm and rejects a dB literal":
  let nl = board()
  setAnnotation(nl.components["C1"], "oip3_dbm", 30.0.dBm)
  check abs(annotationFloat(nl.components["C1"], "oip3_dbm").value - 30.0) < 1e-9
  expect(NetlistError):
    setAnnotation(nl.components["C1"], "oip3_dbm", 30.0.dB)

test "z0 is ohms and applies at both component and pin scope":
  check asComponent in annDef("z0").scopes
  check asPin in annDef("z0").scopes
  let nl = board()
  setAnnotation(nl.components["C1"], "z0", 50.0.ohm)
  check abs(annotationFloat(nl.components["C1"], "z0").value - 50.0) < 1e-9

test "sparams is an opaque file path, like dielectric and value":
  check annDef("sparams").kind == akString
  let nl = board()
  setAnnotation(nl.components["C1"], "sparams", "parts/lna_gain.s2p")
  check annotation(nl.components["C1"], "sparams").value == "parts/lna_gain.s2p"

test "trace_width is a dimensionless-registered geometry key, metres by convention":
  # Registered unit-less (no `Metres` type); a bare number is accepted.
  check annDef("trace_width").unit == ""
  let nl = board()
  setAnnotation(nl.components["C1"], "trace_width", 0.2e-3)
  check abs(annotationFloat(nl.components["C1"], "trace_width").value - 0.2e-3) < 1e-12

test "a key can be registered at runtime, keeping the plugin path open":
  check not isRegistered("slew_rate")
  registerAnnotation(AnnDef(key: "slew_rate", kind: akFloat, unit: "V",
                            scopes: {asComponent}, doc: "test-only"))
  check isRegistered("slew_rate")
  let nl = board()
  setAnnotation(nl.components["C1"], "slew_rate", 1.5.V)
  check validateAnnotations(nl).len == 0

test "dnp and bom_exclude are true/false keys":
  let nl = board()
  let c = nl.components["C1"]
  check not dnp(c).has
  setAnnotation(c, "dnp", true)
  check dnp(c).has and dnp(c).value
  setAnnotation(c, "bom_exclude", "false")
  check bomExclude(c).has and not bomExclude(c).value
  check validateAnnotations(nl).len == 0
  # Through the setters a non-boolean never lands...
  expect NetlistError: setAnnotation(c, "dnp", "yes")
  expect NetlistError: setAnnotation(c, "tolerance", true)
  # ...written raw, the validator reports it.
  setRawAnnotation(c, "dnp", "yes")
  var kinds: seq[string]
  for i in validateAnnotations(nl): kinds.add i.kind
  check "annotation_unparseable" in kinds

# --- typed reads and the provenance side door (design review R1.3/R1.4) ---

test "typed accessors carry the unit type":
  let nl = newNetlist("t")
  let c = nl.addComponent(newComponent("C1", kind = "capacitor"))
  setAnnotation(c, "esr", 20.mohm)
  setAnnotation(c, "voltage_rating", 16.V)
  let e: AnnValue[Ohms] = esr(c)
  check e.has and abs(float(e.value) - 0.02) < 1e-15
  check float(voltageRating(c).value) == 16.0
  check not currentRating(c).has

test "a typed read in the wrong unit is a programming error":
  let nl = newNetlist("t")
  let c = nl.addComponent(newComponent("C1", kind = "capacitor"))
  setAnnotation(c, "esr", 20.mohm)
  expect NetlistError:
    discard annotationAs(c, "esr", Volts)

test "a raw write clears a stale provenance marker":
  let nl = newNetlist("t")
  let c = nl.addComponent(newComponent("C1", kind = "capacitor"))
  setAnnotation(c, "esr", 20.mohm, annDefaulted)
  check esr(c).source == annDefaulted
  setRawAnnotation(c, "esr", "0.05")
  check esr(c).source == annAuthored

test "a provenance marker whose value is gone is reported":
  let nl = newNetlist("t")
  let c = nl.addComponent(newComponent("C1", kind = "capacitor"))
  setAnnotation(c, "esr", 20.mohm, annDefaulted)
  c.attrs.del("esr")
  var kinds: seq[string]
  for i in validateAnnotations(nl): kinds.add i.kind
  check "annotation_orphan_provenance" in kinds

test "spice/ and analysis/ read registered float keys only through accessors":
  # A raw `attrs["esr"]` read re-parses text and drops provenance; a key
  # with a typed accessor must not be read as a bare `annotationFloat`.
  const typed = ["esr", "esl", "voltage", "voltage_rating", "current_rating",
                 "power_rating"]
  var floatKeys: seq[string]
  for k in registeredKeys():
    if annDef(k).kind in {akFloat, akInt}: floatKeys.add k
  var offenders: seq[string]
  let root = currentSourcePath().parentDir.parentDir / "src" / "verax"
  for sub in ["spice", "analysis"]:
    for f in walkDirRec(root / sub):
      if not f.endsWith(".nim"): continue
      var n = 0
      for line in lines(f):
        inc n
        let code = line.split("##")[0].split("#")[0]
        for k in floatKeys:
          for form in ["attrs[\"" & k & "\"]", "attrs.getOrDefault(\"" & k & "\"",
                       "attrs.hasKey(\"" & k & "\")"]:
            # Writes (`attrs["k"] = ...`) are stand-in construction, not reads.
            let at = code.find(form)
            if at >= 0 and not code[at + form.len .. ^1].strip.startsWith("= "):
              offenders.add f & ":" & $n
        for k in typed:
          if ("annotationFloat(") in code and ("\"" & k & "\")") in code:
            offenders.add f & ":" & $n
  checkpoint offenders.join("\n")
  check offenders.len == 0
