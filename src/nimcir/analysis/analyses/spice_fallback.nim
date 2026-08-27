## Opt-in SPICE-backed resolution of the `"ambiguous_dc_path"` issues that
## `nimcir/analysis/io_check.checkDCPaths` reports when a static graph walk
## can't classify a component's DC conductivity (diodes, transistors, ICs,
## opaque subcircuits, or any unrecognized `Component.kind`).
##
## This never parses ngspice's log text for something like "no dc path to
## ground" -- that's exactly the kind of empirically-unreliable/version-
## fragile signal `nimcir/spice/ngspice`'s own doc comments already warn
## against relying on. Instead it reuses the same tested idiom
## `tests/test_spice_ngspice.nim` already exercises: run one `.op` and read
## back `result["v(<netname>)"]`.
##
## What this can and cannot prove: a finite `.op` voltage on the ambiguous
## net is necessary but not sufficient evidence of a genuine, designed DC
## path -- ngspice's internal per-node gmin/per-junction leakage convergence
## aids can produce a defined voltage even for a node with no real
## low-impedance path. This is not a symbolic path-prover, and it needs the
## netlist it's given to already contain real excitation (sources) and a
## ground reference -- running it against a bare extracted fragment with no
## injected source is expected to be inconclusive (a `SpiceSimError`), not
## proof of "no path".
##
## Like `nimcir/spice/transform` and `nimcir/spice/probes`, this operates on
## a materialized clone (via `materializeSimNetlist`) -- the real design
## netlist passed in is never mutated or simulated directly.

import std/tables
import ../../netlist/types
import ../../netlist/graph
import ../../spice/transform
import ../../spice/flatten
import ../../spice/ngspice
import ../issue
import ../io_check

export issue, io_check

const
  KindDCPathResolvedBySpice* = "dc_path_resolved_by_spice"
  KindDCPathInconclusive* = "dc_path_inconclusive"

proc resolveAmbiguousDCPaths*(nl: Netlist, issues: seq[Issue]): seq[Issue] =
  ## Replaces each `"ambiguous_dc_path"` entry in `issues` 1:1 with either a
  ## `sevInfo` `"dc_path_resolved_by_spice"` (a finite `.op` voltage was
  ## found for the issue's net) or a `"dc_path_inconclusive"` (the run
  ## failed, or the net's vector wasn't present in the result); every other
  ## issue passes through unchanged. Never runs ngspice at all if `issues`
  ## contains no ambiguous entries.
  var hasAmbiguous = false
  for iss in issues:
    if iss.kind == "ambiguous_dc_path":
      hasAmbiguous = true
      break
  if not hasAmbiguous:
    return issues

  var globalNets: OrderedTable[string, Net]
  let simNl = materializeSimNetlist(root(nl), globalNets, purpose = spOperating)
  discard flatten(simNl)

  var simResult: SimResult
  var simErrorMsg = ""
  try:
    simResult = run(simNl, @[".op"], label = "dc path fallback")
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
