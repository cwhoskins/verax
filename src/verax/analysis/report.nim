## Result type for the simulation-backed analyses. Unlike an `Issue`
## (something is wrong), an analysis yields a curve plus derived scalars: an
## `AnalysisReport` holds the measurements, the `Issue`s they imply, and the
## raw `SimResult` for plotting.
##
## `assumptions` is load-bearing: every invented input (a soft-start ramp,
## a package ESL, an ideal op-amp) is an `Assumption` record, so it can be
## counted and filtered. `invented` is the set nobody stated.

import std/[math, strutils, tables]
import ../eng
import ../netlist/annotations
import ../spice/backend
import ./issue

# Re-export the `SimResult` accessors, so holders of a report need no second
# import.
export issue, backend, eng, annotations

type
  Measurement* = object
    name*: string
      ## Open identifier (`"bw_3db"`, `"z_min"`), a string so new analyses add
      ## names freely.
    value*: float
    unit*: string
      ## e.g. `"Hz"`, `"V"`, `"A"`, `"dB"`, `"ohm"`, `"deg"`, `"s"`, `""`.
    at*: string
      ## What the number is *about* when that isn't the assertion's subject;
      ## empty means the same. The subject also selects the setup:
      ## `inrush_peak` is probed on the source feeding the output net, while
      ## the subject must name the judged net the isolation seeds on.
    attrs*: OrderedTable[string, string]

  AnalysisReport* = object
    name*: string
    measurements*: seq[Measurement]
    issues*: seq[Issue]
    raw*: SimResult
      ## The full simulated curve behind the measurements.
    assumptions*: seq[Assumption]

proc measurement*(name: string, value: float, unit = ""): Measurement =
  Measurement(name: name, value: value, unit: unit)

proc add*(r: var AnalysisReport, name: string, value: float, unit = "",
          at = "") =
  var m = measurement(name, value, unit)
  m.at = at
  r.measurements.add m

proc hasMeasurement*(r: AnalysisReport, name: string): bool =
  for m in r.measurements:
    if m.name == name: return true
  false

proc `[]`*(r: AnalysisReport, name: string): float =
  ## The named measurement's value. Raises `KeyError` if not produced
  ## (distinct from `NaN`, "measured, never happened in range").
  for m in r.measurements:
    if m.name == name: return m.value
  raise newException(KeyError, "no such measurement: " & name)

proc invented*(r: AnalysisReport): seq[Assumption] =
  ## Every value behind this result that the design didn't state.
  for a in r.assumptions:
    if a.source != annAuthored: result.add a

proc worstSeverity*(r: AnalysisReport): Severity =
  result = sevInfo
  for i in r.issues:
    if i.severity > result: result = i.severity

proc `$`*(m: Measurement): string =
  ## Prints `at` when set, so per-part measurements (`analyzeCurrent`) are
  ## distinguishable.
  result = m.name & " = " & eng(m.value, m.unit)
  if m.at.len > 0: result &= "  [" & m.at & "]"

proc `$`*(r: AnalysisReport): string =
  ## Ready to print as-is, same convention as `Issue`.
  var lines = @["=== " & r.name & " ==="]
  for m in r.measurements: lines.add "  " & $m
  if r.issues.len > 0:
    lines.add "  issues:"
    for i in r.issues: lines.add "    " & $i
  if r.assumptions.len > 0:
    lines.add "  assumptions (values not present in the netlist):"
    for a in r.assumptions: lines.add "    - " & $a
  lines.join("\n")
