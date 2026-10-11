## Opt-in SPICE resolution of `io_check`'s `"ambiguous_dc_path"` issues
## (diodes, transistors, ICs, unknown kinds): run one `.op` and read
## `v(<net>)`, never ngspice's log text.
##
## A finite voltage is necessary, not sufficient, evidence of a real DC path
## (gmin and leakage aids can define a node). It needs real sources and a
## ground; a bare fragment is expected to be inconclusive.
##
## Runs on a clone, flattened then sim-replaced (so nested XSPICE ports use
## post-flatten names).

import std/tables
import ../../netlist/types
import ../../netlist/graph
import ../../spice/transform
import ../../spice/ngspice
import ../../spice/bench
import ../issue
import ../io_check

export issue, io_check

const
  KindDCPathResolvedBySpice* = "dc_path_resolved_by_spice"
  KindDCPathInconclusive* = "dc_path_inconclusive"

proc resolveAmbiguousDCPaths*(nl: Netlist, issues: seq[Issue]): seq[Issue] =
  ## Replaces each `"ambiguous_dc_path"` 1:1 with `sevInfo`
  ## `"dc_path_resolved_by_spice"` (finite `.op` voltage) or
  ## `"dc_path_inconclusive"`; other issues pass through. Doesn't run
  ## ngspice when nothing is ambiguous.
  var hasAmbiguous = false
  for iss in issues:
    if iss.kind == "ambiguous_dc_path":
      hasAmbiguous = true
      break
  if not hasAmbiguous:
    return issues

  var b = openBench(root(nl), "dc path fallback", spOperating)
  b.scopeBench ScopeRequest(strategy: "whole")
  let simNl = b.netlist

  var simResult: SimResult
  var simErrorMsg = ""
  try:
    simResult = b.run(@[".op"], label = "dc path fallback")
  except SpiceSimError as e:
    simErrorMsg = e.msg

  for iss in issues:
    if iss.kind != "ambiguous_dc_path":
      result.add iss
      continue
    if simErrorMsg.len > 0:
      var resolved = iss
      resolved.kind = KindDCPathInconclusive
      resolved.attrs["spiceError"] = simErrorMsg
      result.add resolved
      continue
    try:
      let voltage = simResult["v(" & iss.net.name & ")"][0]
      result.add newIssue(KindDCPathResolvedBySpice, sevInfo,
        "ngspice .op found a finite DC operating point (V=" & $voltage & ") for net '" &
        iss.net.name & "'; this is necessary but not sufficient evidence of a designed " &
        "DC path through " & componentListLabel(iss.components) & " -- ngspice's internal " &
        "gmin/leakage conductances can produce a defined voltage even for a node with no " &
        "real low-impedance path.",
        net = iss.net, pins = iss.pins, components = iss.components)
    except KeyError:
      var resolved = iss
      resolved.kind = KindDCPathInconclusive
      result.add resolved

proc analyzeIOWithSpiceFallback*(nl: Netlist, recursive = true): seq[Issue] =
  resolveAmbiguousDCPaths(nl, analyzeIO(nl, recursive))
