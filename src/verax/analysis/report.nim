## Result type for the simulation-backed analyses in this submodule.
##
## `verax/analysis/issue.Issue` answers a yes/no question about a netlist:
## something is wrong, here is what and where. A frequency response or a
## start-up transient is not that shape -- it is a *curve* plus derived
## scalars, some of which may be perfectly acceptable. So an analysis returns
## an `AnalysisReport`: the measurements it extracted, the `Issue`s those
## measurements imply, and the raw `SimResult` so a caller can plot or do its
## own math without re-running the simulation.
##
## `assumptions` is not decoration. Every analysis here works by filling in
## data a netlist does not carry -- an assumed regulator soft-start ramp, a
## package-typical capacitor ESL, a substituted ideal op-amp macromodel --
## and a number derived from an invented input must say so where the reader
## will actually see it.
##
## They are `Assumption` records (from `netlist/annotations`), not prose, so
## a consumer can count them, filter them by provenance, or eventually rank
## them by influence. `invented` is the filter that matters: it is the set of
## values the result rests on that nobody actually stated.

import std/[math, strutils, tables]
import ../eng
import ../netlist/annotations
import ../spice/backend
import ./issue

# `AnalysisReport.raw` is a `SimResult`, so anything holding a report needs the
# accessors that read one (`freq`, `mag`, `db`, `phaseDeg`, `[]`) without a
# second import.
export issue, backend, eng, annotations

type
  Measurement* = object
    name*: string
      ## Open-ended identifier, e.g. `"bw_3db"`, `"z_min"`, `"inrush_peak"` --
      ## a string rather than an enum, matching `Issue.kind` and
      ## `Component.kind` elsewhere in this codebase, so a new analysis adds
      ## its own names without editing this type.
    value*: float
    unit*: string
      ## e.g. `"Hz"`, `"V"`, `"A"`, `"dB"`, `"ohm"`, `"deg"`, `"s"`, `""`.
    at*: string
      ## What the number is *about*, when that is not the subject the
      ## assertion names. Empty means they are the same thing.
      ##
      ## They can differ because an assertion's subject does two jobs at
      ## once: it says what the claim is about, and it selects the analysis
      ## setup. `inrush_peak` is probed on the source feeding the regulator's
      ## output, so the figure is the current into that net whatever the
      ## subject says -- while the subject still has to name the *judged*
      ## net, because that is what the isolation seeds on, and naming the
      ## other one reports 2.8 kA instead of 163 mA. Both are right and they
      ## are not the same net, so the report says where the number came from
      ## rather than letting the subject imply it.
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
  ## The named measurement's value. Raises `KeyError` if the analysis did not
  ## produce it -- distinct from producing it as `NaN`, which means "measured,
  ## and the answer is 'never happened in the swept range'".
  for m in r.measurements:
    if m.name == name: return m.value
  raise newException(KeyError, "no such measurement: " & name)

proc invented*(r: AnalysisReport): seq[Assumption] =
  ## Every value behind this result that the design did not state. The
  ## question "how much of this answer did we make up?" is unanswerable while
  ## assumptions are prose.
  for a in r.assumptions:
    if a.source != annAuthored: result.add a

proc worstSeverity*(r: AnalysisReport): Severity =
  result = sevInfo
  for i in r.issues:
    if i.severity > result: result = i.severity

proc `$`*(m: Measurement): string =
  ## `at` is printed when it is set, because an analysis that measures the
  ## same quantity for several subjects (`analyzeCurrent`, one `i_peak` per
  ## part) otherwise prints identical-looking lines with no way to tell which
  ## part each belongs to.
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
