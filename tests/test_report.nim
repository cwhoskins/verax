## `report`: the run observer files each ngspice run under the check that
## made it, unchecked claims land at the end, the HTML is self-contained,
## and plain `readiness` is unaffected (no observer left installed).
## Simulation parts skip without ngspice.

import std/[os, strutils, tables, tempfiles, unittest]

import verax/contract/dsl
import verax/spice/ngspice
import verax/verify
import verax/report

let haveNgspice = findExe("ngspice").len > 0

proc dividerBoard(): Design =
  design("divider"):
    net vin, kind = ntPower, voltage = "10"
    net vdd, kind = ntPower
    net gnd, kind = ntGround, name = "0"
    component V1, kind = "voltage_source", value = "DC 10":
      pin "+", vin, kind = ptPower
      pin "-", gnd, kind = ptGround
    component R1, kind = "resistor", value = "2000":
      pin "1", vin, kind = ptPassive
      pin "2", vdd, kind = ptPassive
    component R2, kind = "resistor", value = "1000":
      pin "1", vdd, kind = ptPassive
      pin "2", gnd, kind = ptPassive
    component C1, kind = "capacitor", value = "100n":
      pin "1", vdd, kind = ptPassive
      pin "2", gnd, kind = ptPassive
    component U1, kind = "mcu":
      pin "VDD", vdd, kind = ptPower
      pin "GND", gnd, kind = ptGround
    role "power_rail", vdd_rail, rail = vdd, voltage = 3.3.V, band = 5.pct
    require no_such_quantity(vdd) <= 1.0.V

suite "report collection":
  test "offline: no runs, everything still reported":
    let r = collectReport(dividerBoard(), offlineCapabilities)
    check r.runsByStep.len == 0
    let m = buildModel(r)
    check m.unchecked.len > 0
    var found = false
    for e in m.unchecked:
      if e.claim.quantity == "no_such_quantity": found = true
    check found

  test "runs are filed under their check":
    if not haveNgspice: skip()
    else:
      let r = collectReport(dividerBoard())
      check r.unattributed.len == 0
      var total = 0
      for c in r.readiness.checks:
        let runs = r.runsOf(c)
        total += runs.len
        for run in runs:
          check run.ok
          check run.netlist != nil
          check run.result.vectors.len > 0
      check total > 0
      let m = buildModel(r)
      var opTable = false
      for s in m.tests:
        for run in s.runs:
          if run.opValues.len > 0: opTable = true
      check opTable

  test "the observer is removed afterwards":
    if not haveNgspice: skip()
    else:
      discard collectReport(dividerBoard())
      var seen = 0
      setRunObserver(proc (r: RunRecord) = inc seen)
      clearRunObserver()
      discard readiness(dividerBoard())
      check seen == 0

suite "report html":
  test "self-contained, anchors resolve, unchecked last":
    let r = collectReport(dividerBoard(),
      if haveNgspice: allCapabilities else: offlineCapabilities)
    let html = renderHtml(buildModel(r))
    check html.startsWith("<!doctype html>")
    check "<?xml" notin html          # inline SVG carries no prolog
    check "src=\"http" notin html and "href=\"http" notin html
    # Every in-page link has a target.
    var i = html.find("href=\"#")
    while i >= 0:
      let start = i + len("href=\"#")
      let stop = html.find('"', start)
      check ("id=\"" & html[start ..< stop] & "\"") in html
      i = html.find("href=\"#", stop)
    let incon = html.find("id=\"inconclusive\"")
    check incon > 0
    for s in buildModel(r).tests:
      check html.find("id=\"" & s.anchor & "\"") < incon

  test "writeReportFile writes html; .pdf falls back to html":
    let dir = createTempDir("verax_report_", "")
    defer: removeDir(dir)
    let r = collectReport(dividerBoard(), offlineCapabilities)
    discard writeReportFile(r, dir / "r.html")
    check fileExists(dir / "r.html")
    let msg = writeReportFile(r, dir / "r.pdf")
    check fileExists(dir / "r.html")
    if findPdfConverter().len == 0:
      check "no PDF" in msg
