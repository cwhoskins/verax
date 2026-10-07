## Do two channels of one design match? Imbalance is audible long before
## absolute deviation, and two independent gain claims can each pass while
## the channels sit 3 dB apart.
##
## Composes `opamp.analyzeOpAmpResponse` per channel (its `DC 0 AC 1` drive
## makes the output in dB the gain).
##
## * **Band worst and single frequency are separate names**
##   (`gain_delta_max_db` vs `gain_delta_at_f`).
## * **Every figure is a magnitude**; edge-frequency figures are `max/min`
##   (>= 1), so channel order doesn't matter.
## * **Both sweeps must share one frequency axis** -- checked, reported as
##   an `Issue` if not.
## * **Assumptions and issues are merged and deduplicated.**
##
## If either channel yields no curve, its issues come through and every
## measurement is `NaN` (not evaluated).

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
      ## The sweep spec for **both** channels, so they share one grid.
    gainAtFreq*: float
      ## Hz; when `> 0`, also report `gain_delta_at_f` (`|dB delta|` there).

proc defaultChannelMatchSpec*(): ChannelMatchSpec =
  ChannelMatchSpec(opamp: defaultOpAmpSpec(), gainAtFreq: 0.0)

proc mergeDedup(dst: var seq[Assumption], src: seq[Assumption]) =
  ## Merge both channels' assumptions/issues without duplicates.
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
  ## `max/min`, independent of channel order; `NaN` propagates.
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

  # A declined check leaves issues and no curve: name the channel and emit
  # every measurement as `NaN`.
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

  # Check the axes actually line up. On mismatch, an `Issue` and `NaN` band
  # figures; single-frequency reads stay valid.
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
    # Read each curve independently, so this survives an axis mismatch.
    let a = valueAt(fA, gA, spec.gainAtFreq, logX = true)
    let b = valueAt(fB, gB, spec.gainAtFreq, logX = true)
    let d = (if a.isNaN or b.isNaN: NaN else: abs(a - b))
    result.add "gain_delta_at_f", d, "dB"

  result.add "f_lo_ratio",
    ratio(repA["f_lo_3db"], repB["f_lo_3db"]), ""
  result.add "f_hi_ratio",
    ratio(repA["f_hi_3db"], repB["f_hi_3db"]), ""

  result.raw = repA.raw
