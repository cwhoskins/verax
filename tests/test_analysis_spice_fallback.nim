import std/[os, strutils, tables, unittest]

import nimcir/netlist
import nimcir/analysis
import nimcir/analysis/spice_fallback

let haveNgspice = findExe("ngspice").len > 0

proc diodeGatedNetlist(): Netlist =
  ## V1 (DC 5V) -> R1 -> diode anode `a`; diode cathode `b` is otherwise
  ## unloaded and tagged `ptInput`, so a static walk can't classify D1
  ## (an unrecognized "diode" kind) and reports `b` as ambiguous.
  result = newNetlist("diode_gated")
  let vcc = addNet(result, newNet("vcc", ntPower))
  let gnd = addNet(result, newNet("0", ntGround))
  let a = addNet(result, newNet("a"))
  let b = addNet(result, newNet("b"))

  let v1 = addComponent(result, newComponent("V1", kind = "voltage_source"))
  discard connect(v1, "+", vcc, ptPassive)
  discard connect(v1, "-", gnd, ptPassive)
  v1.attrs["value"] = "DC 5"

  let r1 = addComponent(result, newComponent("R1", kind = "resistor"))
  discard connect(r1, "1", vcc, ptPassive)
  discard connect(r1, "2", a, ptPassive)
  r1.attrs["value"] = "1k"

  let d1 = addComponent(result, newComponent("D1", kind = "diode"))
  discard connect(d1, "A", a, ptPassive)
  discard connect(d1, "K", b, ptInput)
  d1.attrs["value"] = "DMOD"
  result.models["DMOD"] = "D"

test "resolveAmbiguousDCPaths returns issues unchanged when there's nothing ambiguous":
  let nl = newNetlist("t")
  let gnd = addNet(nl, newNet("0", ntGround))
  let u1 = addComponent(nl, newComponent("U1", kind = "receiver_ic"))
  discard connect(u1, "IN", gnd, ptInput)

  let issues = analyzeIO(nl)
  check issues.len == 0
  check resolveAmbiguousDCPaths(nl, issues) == issues

if not haveNgspice:
  echo "SKIP: ngspice not found on PATH, skipping real-simulation tests"
else:
  test "spice fallback resolves a static-ambiguous diode-gated input":
    let nl = diodeGatedNetlist()

    let staticIssues = checkDCPaths(nl)
    check staticIssues.len == 1
    check staticIssues[0].kind == "ambiguous_dc_path"
    check staticIssues[0].components.len == 1
    check staticIssues[0].components[0].designator == "D1"

    let resolved = resolveAmbiguousDCPaths(nl, staticIssues)
    check resolved.len == 1
    check resolved[0].kind == KindDCPathResolvedBySpice
    check resolved[0].severity == sevInfo
    check "necessary but not sufficient" in resolved[0].message

  test "analyzeIOWithSpiceFallback bundles the static pass and the fallback":
    let nl = diodeGatedNetlist()
    let issues = analyzeIOWithSpiceFallback(nl)
    check issues.len == 1
    check issues[0].kind == KindDCPathResolvedBySpice
