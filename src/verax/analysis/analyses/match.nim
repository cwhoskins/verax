## Do two channels of one design actually match?
##
## A stereo board is one circuit built twice, and the ear hears a channel
## imbalance long before it hears absolute deviation from the target curve --
## a phono stage 0.5 dB off the RIAA curve sounds like a tone control, one
## whose channels differ by 0.5 dB sounds like the stereo image has moved.
## Two independent gain claims cannot catch that: both channels can sit 3 dB
## apart and still each land inside its own band.
##
## This is the first analysis whose subjects are *two* stages rather than one
## net, and it earns its own module for the reason `psrr.nim` does rather than
## growing `opamp.nim`: it composes rather than duplicates. It calls
## `opamp.analyzeOpAmpResponse` once per channel and reads the closed-loop
## gain curve back off each -- the drive that proc puts on the input is
## `DC 0 AC 1`, so `raw.db("v(" & out & ")")` *is* the gain in dB and
## `raw.freq()` is the axis.
##
## ## Four decisions, each against a specific way of being wrong
##
## * **A band worst and a single frequency are separate names**
##   (`gain_delta_max_db` vs `gain_delta_at_f`), exactly as `psrr_min_db` and
##   `psrr_at_f` are. A claim about a whole band must never be answerable with
##   a number from one point.
## * **Every figure is a magnitude.** Which channel is "A" is an authoring
##   order and no claim may turn on it -- the same rule `analyzeCurrent`
##   follows for a branch current's sign. The edge-frequency figures are
##   reported as `max/min`, so a ratio is `>= 1` whichever channel is faster.
## * **Both sweeps must share one frequency axis** or the point-by-point delta
##   is between two different grids. An identical `OpAmpSpec` produces an
##   identical `.ac dec` card, but that is *checked* elementwise and reported
##   as an `Issue` rather than assumed.
## * **Each channel's assumptions and issues are merged and deduplicated.**
##   Both channels substitute the same op-amp macromodel and would otherwise
##   report every invented value twice.
##
## If either channel's sweep returns no curve -- `checkFeedback` or
## `checkInjectionPoint` declined, or ngspice failed -- its issues come
## through and every measurement is `NaN`, which `verdict` renders as *not
## evaluated* rather than as a failure.

import std/math
import ../../netlist/types
import ../../netlist/graph
import ../../netlist/annotations
import ../measure
import ../report
import ./opamp

export report

const
  KindAxisMismatch* = "channel_match_axis_mismatch"
  KindChannelNoCurve* = "channel_match_no_curve"

type
  ChannelMatchSpec* = object
    opamp*: OpAmpSpec
      ## The sweep spec used for **both** channels. It has to be one object:
      ## two channels swept with two different `.ac` cards produce two
      ## frequency grids and the delta between them is meaningless.
    gainAtFreq*: float
      ## Hz; when `> 0` the result also reports `gain_delta_at_f`, the
      ## `|ΔdB|` at exactly that frequency. `0` disables it, the same way
      ## `OpAmpSpec.gainAtFreq` gates `gain_at_f`.

proc defaultChannelMatchSpec*(): ChannelMatchSpec =
  ChannelMatchSpec(opamp: defaultOpAmpSpec(), gainAtFreq: 0.0)

proc mergeDedup(dst: var seq[Assumption], src: seq[Assumption]) =
  ## Both channels are the same subcircuit, so the same macromodel
  ## substitution and the same package-typical parasitics come back on each.
  ## Pooled without this the report says "assumed a 1 MHz GBW" twice.
  for a in src:
    var seen = false
    for b in dst:
      if a.entity == b.entity and a.key == b.key and a.detail == b.detail and
         a.unit == b.unit and (a.value == b.value or
         (a.value.isNaN and b.value.isNaN)):
        seen = true
        break
    if not seen: dst.add a

proc mergeDedupIssues(dst: var seq[Issue], src: seq[Issue]) =
  for i in src:
    var seen = false
    for j in dst:
      if i.kind == j.kind and i.message == j.message:
        seen = true
        break
    if not seen: dst.add i

proc ratio(a, b: float): float =
  ## `max/min`, so the answer does not depend on which channel was named
  ## first. `NaN` propagates -- a channel with no measurable edge has no
  ## ratio to state.
  if a.isNaN or b.isNaN: return NaN
  let lo = min(abs(a), abs(b))
  let hi = max(abs(a), abs(b))
  if lo == 0.0: return NaN
  hi / lo

proc analyzeChannelMatch*(nl: Netlist,
                          ampA, inA, outA, ampB, inB, outB: string,
                          spec = defaultChannelMatchSpec()): AnalysisReport =
  ## The closed-loop gain of two stages, compared point by point.
  result.name = "Channel match: " & ampA & " vs " & ampB

  var chSpec = spec.opamp
  chSpec.gainAtFreq = spec.gainAtFreq

  var repA, repB: AnalysisReport
  try:
    repA = analyzeOpAmpResponse(nl, ampA, inA, outA, chSpec)
    repB = analyzeOpAmpResponse(nl, ampB, inB, outB, chSpec)
  except CatchableError as e:
    result.issues.add newIssue(KindChannelNoCurve, sevWarning,
      "a channel sweep raised: " & e.msg)
    return

  mergeDedup(result.assumptions, repA.assumptions)
  mergeDedup(result.assumptions, repB.assumptions)
  mergeDedupIssues(result.issues, repA.issues)
  mergeDedupIssues(result.issues, repB.issues)

  # A declined feedback or injection check leaves the report with issues and
  # no curve. Say which channel, and emit every measurement as `NaN` so the
  # verdict reads as "could not check" rather than "the channels differ by 0".
  proc noCurve(rep: AnalysisReport): bool =
    not rep.hasMeasurement("gain_max_db")

  if noCurve(repA) or noCurve(repB):
    let which =
      if noCurve(repA) and noCurve(repB): ampA & " and " & ampB
      elif noCurve(repA): ampA
      else: ampB
    result.issues.add newIssue(KindChannelNoCurve, sevWarning,
      "no gain curve for " & which & ", so the two channels cannot be " &
      "compared -- the issues above say why that channel's sweep produced " &
      "nothing")
    result.add "gain_delta_max_db", NaN, "dB"
    result.add "f_gain_delta_max", NaN, "Hz"
    if spec.gainAtFreq > 0.0:
      result.add "gain_delta_at_f", NaN, "dB"
    result.add "f_lo_ratio", NaN, ""
    result.add "f_hi_ratio", NaN, ""
    return

  let fA = repA.raw.freq()
  let fB = repB.raw.freq()
  let gA = repA.raw.db("v(" & outA & ")")
  let gB = repB.raw.db("v(" & outB & ")")

  # Identical specs give an identical sweep card, but the point-by-point delta
  # is only meaningful if the axes actually line up -- so check rather than
  # trust. A mismatch is an `Issue` and every band figure is `NaN`; a single
  # frequency read with `valueAt` on each curve is still safe and is kept.
  var axisOk = fA.len == fB.len
  if axisOk:
    for i in 0 ..< fA.len:
      if abs(fA[i] - fB[i]) > 1.0e-6 * max(abs(fA[i]), 1.0):
        axisOk = false
        break
  if not axisOk:
    result.issues.add newIssue(KindAxisMismatch, sevWarning,
      "the two channels were swept onto different frequency axes (" &
      $fA.len & " vs " & $fB.len & " points), so a point-by-point gain " &
      "delta is not defined -- the band figures are reported as NaN")

  if axisOk:
    let (dev, at) = maxDeviation(fA, gA, gB, spec.opamp.fStart, spec.opamp.fStop)
    result.add "gain_delta_max_db", dev, "dB"
    result.add "f_gain_delta_max", at, "Hz"
  else:
    result.add "gain_delta_max_db", NaN, "dB"
    result.add "f_gain_delta_max", NaN, "Hz"

  if spec.gainAtFreq > 0.0:
    # Read each curve at the stated frequency independently, so this survives
    # an axis mismatch that the band figure cannot.
    let a = valueAt(fA, gA, spec.gainAtFreq, logX = true)
    let b = valueAt(fB, gB, spec.gainAtFreq, logX = true)
    let d = (if a.isNaN or b.isNaN: NaN else: abs(a - b))
    result.add "gain_delta_at_f", d, "dB"

  result.add "f_lo_ratio",
    ratio(repA["f_lo_3db"], repB["f_lo_3db"]), ""
  result.add "f_hi_ratio",
    ratio(repA["f_hi_3db"], repB["f_hi_3db"]), ""

  result.raw = repA.raw
