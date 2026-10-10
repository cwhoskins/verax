## Constraint derivation: the inverse question. Given a template (decision
## 8), the IBIS behaviours per corner and pass criteria, **which parameter
## values pass?** The answer is a routing rule the layout must obey.
##
## - **Gate**: sweep only what stage 3 validated (length on ideal and lossy
##   lines, series R, via count and stub once vias pass 3b). The template,
##   not a board, is the input.
## - **Search, without assuming monotonic.** Ringback and overshoot against
##   length are not monotonic (a short line looks lumped, a long one rings,
##   bad windows lie between). Each continuous parameter is swept on a
##   coarse grid; a pass/fail transition is bisected **only between two valid
##   samples** -- a solver failure or unsupported point is never a "fail",
##   it is an unexamined gap. The answer is a set of passing intervals with
##   the grid resolution and the gaps.
## - **Every corner the caller supplies** is judged; the worst decides.
## - **Explained**: the binding failure mode, and beside it the rule-of-thumb
##   figure (critical length `tr / (2 tpd)`, stub resonance
##   `1 / (4 td_stub)`).
## - **Crosstalk** (a template with a `prVictim` partner): the victim's
##   largest excursion (`maxCrosstalk`) and its noise margin
##   (`minNoiseMargin`, against its own `Vinh`/`Vinl`) are criteria too, so
##   sweeping `spSpacing` gives a **minimum spacing** for a coupled length
##   (KiCad `clearance` between the two nets, `druRules`).
## - **Differential pairs** (`prDiffPair`): the threshold criteria apply to
##   `v(p) - v(n)` against `+-Vdiff`; each leg only to overshoot.
## - **Identity**: an answer carries the template, line, termination,
##   driver, receivers, corners, criteria and assumptions. A bare "max
##   length" is never reported.

import std/[math, strutils, json]
import ./simulate
import ./measure
import ./sweep
import ../netlist/annotations
import ../pcb/formats/kicaddru

export kicaddru

type
  Criteria* = object
    ## Pass criteria. Defaults come from the IBIS data; a timing budget is
    ## the caller's.
    maxFlightTime*: float
      ## Seconds; `NaN` = no timing budget.
    minRingbackMargin*: float
    minThresholdMargin*: float
    useOvershootLimits*: bool
      ## Judge `[Model Spec]` `S_overshoot_high/low` where the receiver
      ## states them.
    maxOvershoot*, maxUndershoot*: float
      ## Volts beyond the rails; `NaN` = none.
    requireMonotonic*: bool
    maxSettleTime*: float
    edges*: set[Edge]
    edgeDelay*: float
    ui*: float
      ## Unit interval, s; positive adds the ISI pattern (`si/sweep`) to
      ## every point. `NaN`/`0`: single edges only.
    maxCrosstalk*: float
      ## Volts of excursion on a quiet victim (receivers and near end);
      ## `NaN` = none.
    minNoiseMargin*: float
      ## A victim receiver's noise margin (needs its `Vinh`/`Vinl`).
    eyeBits*: int
      ## With a UI, add this many PRBS7 bits and judge their eye; `0` = none.
    minEyeHeight*, minEyeWidth*: float
      ## Volts and seconds; `NaN` = none.

  Verdict* = enum
    vPass, vFail, vInvalid

  PointResult* = object
    verdict*: Verdict
    failures*: seq[string]
      ## Every unmet criterion; the first is the binding one.
    reason*: string
      ## Why a point is invalid.
    corners*: seq[Corner]
    measures*: seq[SiMeasures]

  SweepParam* = enum
    spLength, spStubLength, spSeriesR, spViaStub, spSpacing, spCoupledLength,
    spLegMismatch

  Interval* = tuple[lo, hi: float]

  Sweep* = object
    param*: SweepParam
    lo*, hi*: float
    grid*: int
    tolerance*: float
      ## Bisection resolution, in the parameter's unit.
    samples*: seq[tuple[x: float, p: PointResult]]
    passing*: seq[Interval]
    gaps*: seq[Interval]
      ## Ranges next to invalid samples: unexamined, not failing.
    binding*: string
      ## The failure at the first pass -> fail boundary, if any.

  StubVerdict* = object
    name*: string
    actualStub*, maxPassingStub*: float
    answer*: string

  AnswerIdentity* = object
    templateName*, topology*: string
    line*: string
    termination*: string
    partner*: string
      ## A victim or differential partner, and its coupling; empty if none.
    driver*: string
    receivers*: seq[string]
    corners*: seq[Corner]
    criteria*: string
    assumptions*: seq[string]

proc defaultCriteria*(): Criteria =
  Criteria(maxFlightTime: NaN, minRingbackMargin: 0.0, minThresholdMargin: 0.0,
           useOvershootLimits: true, maxOvershoot: NaN, maxUndershoot: NaN,
           requireMonotonic: true, maxSettleTime: NaN,
           edges: {edRising, edFalling}, edgeDelay: 0.5e-9, ui: NaN,
           maxCrosstalk: NaN, minNoiseMargin: 0.0, eyeBits: 0, minEyeHeight: NaN,
           minEyeWidth: NaN)

proc `$`*(c: Criteria): string =
  var parts: seq[string]
  if not c.maxFlightTime.isNaN: parts.add "flight time <= " & formatFloat(c.maxFlightTime * 1e9, ffDecimal, 3) & " ns"
  parts.add "ringback margin >= " & $c.minRingbackMargin & " V"
  parts.add "threshold margin >= " & $c.minThresholdMargin & " V"
  if c.useOvershootLimits: parts.add "within [Model Spec] overshoot limits"
  if not c.maxOvershoot.isNaN: parts.add "overshoot <= " & $c.maxOvershoot & " V"
  if not c.maxUndershoot.isNaN: parts.add "undershoot <= " & $c.maxUndershoot & " V"
  if c.requireMonotonic: parts.add "monotonic through the threshold band"
  if not c.maxSettleTime.isNaN: parts.add "settled within " & formatFloat(c.maxSettleTime * 1e9, ffDecimal, 3) & " ns"
  var es: seq[string]
  for e in c.edges: es.add edgeName(e)
  parts.add "edges " & es.join("+")
  if not c.maxCrosstalk.isNaN: parts.add "crosstalk <= " & $c.maxCrosstalk & " V"
  parts.add "victim noise margin >= " & $c.minNoiseMargin & " V"
  if c.ui > 0 and c.eyeBits > 0:
    var e = $c.eyeBits & " bits of PRBS7"
    if not c.minEyeHeight.isNaN: e &= ", eye height >= " & $c.minEyeHeight & " V"
    if not c.minEyeWidth.isNaN: e &= ", eye width >= " & formatFloat(c.minEyeWidth * 1e9, ffDecimal, 3) & " ns"
    parts.add e
  if c.ui > 0: parts.add "ISI patterns " & isiPatterns.join("/") & " at UI " & formatFloat(c.ui * 1e9, ffDecimal, 3) & " ns"
  parts.join(", ")

proc f3(x: float): string = formatFloat(x, ffDecimal, 3)

type
  TimingRefs* = seq[Timing]
    ## Per template, the driver's timing-load crossings (`sweep.timingOf`).
    ## They depend on the driver only, so a sweep computes them once.

proc timingRefs*(templates: openArray[SiTemplate], so = defaultSiOptions()): TimingRefs =
  for t in templates: result.add timingOf(t.driver, so)

proc judge*(templates: openArray[SiTemplate], p: TemplateParams, c: Criteria,
            so = defaultSiOptions(), refs: TimingRefs = @[]): PointResult =
  ## One point: every corner x the criteria's stimuli x every receiver, by
  ## `sweep.sweepNet` -- the same runs and measures `verify` checks a board
  ## with. Unsupported or a solver failure makes the point invalid, never a
  ## pass and never a fail. `refs` (from `timingRefs`) saves re-running the
  ## timing load at every point.
  result.verdict = vPass
  let refs = if refs.len == templates.len: refs else: timingRefs(templates, so)
  var corners: seq[SweepCorner]
  for ti in 0 ..< templates.len:
    template t: untyped = templates[ti]
    result.corners.add t.driver.corner
    corners.add SweepCorner(corner: t.driver.corner, net: t.build(p), timing: refs[ti],
                            hasTiming: true)
  var o = defaultSweepOptions()
  o.sim = so
  let sw = sweepNet(corners, sweepStimuli(c.ui, c.edgeDelay, c.edges,
                                          prbsBits = (if c.ui > 0: c.eyeBits else: 0)), o)
  case sw.status
  of ssUnsupported:
    result.verdict = vInvalid
    result.reason = "unsupported: " & sw.reason
    return
  of ssSolverFailed:
    result.verdict = vInvalid
    result.reason = "solver failure: " & sw.reason
    return
  of ssOk: discard
  let net0 = corners[0].net
  for me in sw.measured:
    let m = me.m
    let probe = sw.probes[me.probe]
    template fail(msg: string) =
      result.verdict = vFail
      result.failures.add msg & " at " & cornerName(me.corner) & ", " & probe.label & " " & me.run
    if me.isEye:
      let e = me.eye
      if not c.minEyeHeight.isNaN and (e.height.isNaN or e.height < c.minEyeHeight):
        fail("eye height " & (if e.height.isNaN: "n/a" else: f3(e.height) & " V"))
      if not c.minEyeWidth.isNaN and e.width < c.minEyeWidth:
        fail("eye width " & f3(e.width * 1e9) & " ns")
      continue
    case me.kind
    of pkVictim:
      let n = me.noise
      if not c.maxCrosstalk.isNaN and n.noise > c.maxCrosstalk:
        fail("crosstalk " & f3(n.noise) & " V")
      if probe.index >= 0:
        if n.noiseMargin.isNaN:
          result.verdict = vInvalid
          result.reason = probe.label & " (victim) has no Vinh/Vinl for a noise margin"
          return
        if n.noiseMargin < c.minNoiseMargin:
          fail("victim noise margin " & f3(n.noiseMargin) & " V")
      continue
    of pkLeg:
      result.measures.add m
      if c.useOvershootLimits:
        if not m.overshootHighMargin.isNaN and m.overshootHighMargin < 0:
          fail("peak " & f3(m.peakHigh) & " V over S_overshoot_high")
        if not m.overshootLowMargin.isNaN and m.overshootLowMargin < 0:
          fail("trough " & f3(m.peakLow) & " V under S_overshoot_low")
      if not c.maxOvershoot.isNaN and m.overshoot > c.maxOvershoot:
        fail("overshoot " & f3(m.overshoot) & " V")
      if not c.maxUndershoot.isNaN and m.undershoot > c.maxUndershoot:
        fail("undershoot " & f3(m.undershoot) & " V")
      continue
    of pkSignal, pkDiff: discard
    result.measures.add m
    let present =
      if me.kind == pkDiff: net0.diffReceivers[probe.index].hasVdiff
      else: net0.receivers[me.receiver].thresholds.present
    if not present:
      result.verdict = vInvalid
      result.reason = probe.label & (if me.kind == pkDiff: " has no Vdiff" else: " has no Vinh/Vinl")
      return
    if not c.maxFlightTime.isNaN:
      if me.timingWhy.len > 0:
        result.verdict = vInvalid
        result.reason = "a timing budget needs the driver's Vmeas/Rref/Cref"
        return
      if m.flightTimeMax.isNaN:
        fail("never settles past its threshold")
      elif m.flightTimeMax > c.maxFlightTime:
        fail("flight time " & f3(m.flightTimeMax * 1e9) & " ns > " & f3(c.maxFlightTime * 1e9) & " ns")
    if not m.ringbackMargin.isNaN and m.ringbackMargin < c.minRingbackMargin:
      fail("ringback margin " & f3(m.ringbackMargin) & " V")
    if m.ringbackMargin.isNaN:
      fail("never reaches its far threshold")
    if m.thresholdMargin < c.minThresholdMargin:
      fail("threshold margin " & f3(m.thresholdMargin) & " V")
    if c.useOvershootLimits:
      if not m.overshootHighMargin.isNaN and m.overshootHighMargin < 0:
        fail("peak " & f3(m.peakHigh) & " V over S_overshoot_high")
      if not m.overshootLowMargin.isNaN and m.overshootLowMargin < 0:
        fail("trough " & f3(m.peakLow) & " V under S_overshoot_low")
    if not c.maxOvershoot.isNaN and m.overshoot > c.maxOvershoot:
      fail("overshoot " & f3(m.overshoot) & " V")
    if not c.maxUndershoot.isNaN and m.undershoot > c.maxUndershoot:
      fail("undershoot " & f3(m.undershoot) & " V")
    if c.requireMonotonic and not m.monotonic:
      fail("non-monotonic through the threshold band")
    if not c.maxSettleTime.isNaN and (m.settleTime.isNaN or m.settleTime > c.maxSettleTime):
      fail("settle time " & (if m.settleTime.isNaN: "never" else: f3(m.settleTime * 1e9) & " ns"))

proc withParam(p: TemplateParams, param: SweepParam, x: float): TemplateParams =
  result = p
  case param
  of spLength: result.length = x
  of spStubLength: result.stubLength = x
  of spSeriesR: result.seriesR = x
  of spViaStub:
    result.viaStub = x
    result.hasViaStub = true
  of spSpacing:
    result.spacing = x
    result.hasSpacing = true
  of spCoupledLength: result.coupledLength = x
  of spLegMismatch: result.legMismatch = x

proc sweep*(templates: openArray[SiTemplate], base: TemplateParams,
            param: SweepParam, lo, hi: float, grid: int, c: Criteria,
            tolerance: float, so = defaultSiOptions()): Sweep =
  ## Coarse grid, then bisection of every pass/fail transition between two
  ## *valid* neighbours.
  result = Sweep(param: param, lo: lo, hi: hi, grid: grid, tolerance: tolerance)
  let templates = @templates   # captured by `boundary`
  let refs = timingRefs(templates, so)
  let n = max(grid, 2)
  for i in 0 ..< n:
    let x = lo + (hi - lo) * i.float / (n - 1).float
    result.samples.add (x, judge(templates, base.withParam(param, x), c, so, refs))
  proc boundary(a, b: float, aPass: bool): tuple[x: float, failure: string] =
    ## The transition between a valid `a` and a valid `b` of the other
    ## verdict, to `tolerance`. A point that turns invalid mid-bisection
    ## stops it at the last bracket (reported as a gap by the caller).
    var lo = a
    var hi = b
    var fails = ""
    while abs(hi - lo) > tolerance:
      let m = 0.5 * (lo + hi)
      let pr = judge(templates, base.withParam(param, m), c, so, refs)
      if pr.verdict == vInvalid: break
      if (pr.verdict == vPass) == aPass: lo = m
      else:
        hi = m
        if pr.failures.len > 0: fails = pr.failures[0]
    (0.5 * (lo + hi), fails)
  var open = NaN
  let s = result.samples
  for i in 0 ..< s.len:
    let v = s[i].p.verdict
    let prev = if i > 0: s[i - 1].p.verdict else: vInvalid
    case v
    of vPass:
      if open.isNaN:
        open =
          if i == 0: s[0].x
          elif prev == vFail: boundary(s[i - 1].x, s[i].x, false).x
          else: s[i].x
    of vFail:
      if not open.isNaN:
        let (bx, why) = boundary(s[i - 1].x, s[i].x, true)
        result.passing.add (open, bx)
        if result.binding.len == 0:
          result.binding = if why.len > 0: why else: s[i].p.failures[0]
        open = NaN
      elif i == 0 and result.binding.len == 0 and s[0].p.failures.len > 0:
        result.binding = s[0].p.failures[0]
    of vInvalid:
      if not open.isNaN:
        result.passing.add (open, s[i - 1].x)
        open = NaN
      let a = if i > 0: s[i - 1].x else: s[i].x
      let b = if i < s.len - 1: s[i + 1].x else: s[i].x
      if result.gaps.len > 0 and result.gaps[^1].hi >= a:
        result.gaps[^1].hi = b
      else:
        result.gaps.add (a, b)
  if not open.isNaN: result.passing.add (open, s[^1].x)

proc maxFromStart*(s: Sweep): float =
  ## The top of the passing interval that starts at the sweep's low end
  ## (`NaN` if the low end fails): "how long may it be".
  if s.passing.len > 0 and s.passing[0].lo == s.lo: s.passing[0].hi else: NaN

proc minToEnd*(s: Sweep): float =
  ## The bottom of the passing interval that reaches the sweep's high end
  ## (`NaN` if the high end fails): "how far apart must they be".
  if s.passing.len > 0 and s.passing[^1].hi == s.hi: s.passing[^1].lo else: NaN

proc spacingFor*(templates: openArray[SiTemplate], base: TemplateParams,
                 lo, hi: float, grid: int, c: Criteria, tolerance: float,
                 so = defaultSiOptions()): Sweep =
  ## The edge-to-edge gap to a victim partner that passes, over `lo .. hi`
  ## (the minimum is `minToEnd`).
  sweep(templates, base, spSpacing, lo, hi, grid, c, tolerance, so)

# --- trade-off tables --------------------------------------------------------

proc viaTable*(templates: openArray[SiTemplate], base: TemplateParams,
               viaCounts: openArray[int], lengthLo, lengthHi: float, grid: int,
               c: Criteria, tolerance: float,
               so = defaultSiOptions()): seq[tuple[vias: int, s: Sweep]] =
  ## Max length for each via count (integer parameter: enumerated).
  for n in viaCounts:
    var p = base
    p.viaCount = n
    result.add (n, sweep(templates, p, spLength, lengthLo, lengthHi, grid, c, tolerance, so))

proc terminationTable*(templates: openArray[SiTemplate], base: TemplateParams,
                       seriesRs: openArray[float], lengthLo, lengthHi: float,
                       grid: int, c: Criteria, tolerance: float,
                       so = defaultSiOptions()): tuple[rows: seq[tuple[r: float, s: Sweep]], best: float] =
  ## Max length with each series R (0 = none); `best` passes the longest.
  var bestLen = -1.0
  result.best = NaN
  for r in seriesRs:
    var p = base
    p.seriesR = r
    let s = sweep(templates, p, spLength, lengthLo, lengthHi, grid, c, tolerance, so)
    result.rows.add (r, s)
    let m = s.maxFromStart
    if not m.isNaN and m > bestLen:
      bestLen = m
      result.best = r

proc stubRemoval*(templates: openArray[SiTemplate], base: TemplateParams,
                  transitions: openArray[tuple[name: string, stub: float]],
                  grid: int, c: Criteria, tolerance: float,
                  so = defaultSiOptions()): seq[StubVerdict] =
  ## Per layer transition: the longest stub that passes vs the stub the
  ## stack-up leaves. `base.viaCount` must be at least 1.
  var hi = 0.0
  for t in transitions: hi = max(hi, t.stub)
  let s = sweep(templates, base, spViaStub, 0.0, hi, grid, c, tolerance, so)
  let maxStub = s.maxFromStart
  for t in transitions:
    var v = StubVerdict(name: t.name, actualStub: t.stub, maxPassingStub: maxStub)
    v.answer =
      if maxStub.isNaN: "avoid this transition (fails even with no stub)"
      elif t.stub <= maxStub: "backdrill not needed"
      else: "backdrill needed: residual stub <= " & f3(maxStub * 1e3) & " mm"
    result.add v

# --- rules of thumb and identity --------------------------------------------

proc criticalLength*(tr, tdPerM: float): float =
  ## Beyond `tr / (2 tpd)` a line stops looking lumped.
  tr / (2.0 * tdPerM)

proc stubResonance*(stubLength, tdPerM: float): float =
  ## Quarter-wave frequency of an open stub.
  1.0 / (4.0 * stubLength * tdPerM)

proc identity*(t: SiTemplate, corners: openArray[Corner], p: TemplateParams,
               c: Criteria): AnswerIdentity =
  result.templateName = t.name
  result.topology =
    case t.topology
    of ttPointToPoint: "point-to-point"
    of ttDaisyChain: "daisy chain"
    of ttStar: "star"
  result.line = "Z0 " & f3(t.line.z0) & " ohm, " & f3(t.line.tdPerM * 1e9) & " ns/m" &
    (if t.line.lossy: ", lossy" else: ", lossless") &
    (if t.line.layer.len > 0: ", layer " & t.line.layer else: "") &
    (if t.line.reference.len > 0: " over " & t.line.reference else: "")
  var term: seq[string]
  if p.seriesR > 0: term.add "series " & f3(p.seriesR) & " ohm"
  if p.parallelR > 0: term.add "parallel " & f3(p.parallelR) & " ohm to " & f3(p.parallelV) & " V"
  if p.diffR > 0: term.add "differential " & f3(p.diffR) & " ohm across the receivers"
  result.termination = if term.len == 0: "none" else: term.join(", ")
  let pt = t.partner
  if pt.role != prNone:
    let gap = if p.hasSpacing: p.spacing else: pt.coupled.s
    result.partner =
      (if pt.role == prDiffPair: "differential pair with " & pt.name & " (" & pt.driver.model & ")"
       else: "victim " & pt.name & " held " & (if pt.quietHigh: "high" else: "low") &
             " (" & pt.driver.model & ") over " & f3(p.coupledLength * 1e3) & " mm") &
      ", gap " & f3(gap * 1e3) & " mm"
  var src: seq[string]
  for e in Edge: src.add edgeName(e) & " from " & (if t.driver.edges[e].source == ksRamp: "[Ramp]" else: "V/T tables")
  result.driver = t.driver.model & (if t.driver.file.len > 0: " (" & t.driver.file & ")" else: "") &
    " [" & (if t.driver.model.len > 0: "Model_type " & ($t.driver.modelType)[2 .. ^1] else: "") &
    "; " & src.join(", ") & "]"
  for k, r in t.receivers: result.receivers.add t.receiverPorts[k].label & ": " & r.model
  result.corners = @corners
  result.criteria = $c
  let net = t.build(p)
  for a in net.assumptions: result.assumptions.add $a
  result.assumptions.add "line Z0/delay are closed-form quasi-static (pcb/impedance)"
  result.assumptions.add "derived for this template: a real route with an extra via, branch or " &
    "reference change invalidates the rule; check the routed board (stage 6)"

# --- report ------------------------------------------------------------------

type
  ConstraintReport* = object
    net*: string
    identity*: AnswerIdentity
    length*: Sweep
    hasLength*: bool
    vias*: seq[tuple[vias: int, s: Sweep]]
    termination*: seq[tuple[r: float, s: Sweep]]
    bestSeriesR*: float
    stubs*: seq[StubVerdict]
    spacing*: Sweep
      ## Gap to a victim partner (`spSpacing`), when `hasSpacing`.
    hasSpacing*: bool
    victimNet*: string
    coupledLength*: float
      ## The parallel run `spacing` was derived for, metres.
    skew*: Sweep
      ## Differential pair: extra length on one leg (`spLegMismatch`), when
      ## `hasSkew`.
    hasSkew*: bool
    pairNet*: string
      ## The pair's other leg.
    criticalLength*: float
    stubResonances*: seq[tuple[name: string, hz: float]]
    notes*: seq[string]

proc paramUnit(p: SweepParam): (string, float) =
  case p
  of spLength, spStubLength, spViaStub, spSpacing, spCoupledLength,
     spLegMismatch: ("mm", 1e3)
  of spSeriesR: ("ohm", 1.0)

proc intervalsText(s: Sweep): string =
  let (u, k) = paramUnit(s.param)
  var parts: seq[string]
  for iv in s.passing: parts.add f3(iv.lo * k) & ".." & f3(iv.hi * k) & " " & u
  result = if parts.len == 0: "none passes" else: parts.join(", ")
  if s.gaps.len > 0:
    var g: seq[string]
    for iv in s.gaps: g.add f3(iv.lo * k) & ".." & f3(iv.hi * k)
    result &= " (unexamined: " & g.join(", ") & " " & u & ")"

proc renderText*(r: ConstraintReport): string =
  let id = r.identity
  result.add "SI constraints for net " & r.net & "\n"
  result.add "  template:    " & id.templateName & " (" & id.topology & ")\n"
  result.add "  line:        " & id.line & "\n"
  result.add "  termination: " & id.termination & "\n"
  if id.partner.len > 0: result.add "  partner:     " & id.partner & "\n"
  result.add "  driver:      " & id.driver & "\n"
  for rx in id.receivers: result.add "  receiver:    " & rx & "\n"
  var cs: seq[string]
  for c in id.corners: cs.add cornerName(c)
  result.add "  corners run: " & cs.join(", ") & "\n"
  result.add "  criteria:    " & id.criteria & "\n"
  if r.hasLength:
    let (u, k) = paramUnit(r.length.param)
    result.add "\n  length passes: " & intervalsText(r.length) & "  [grid " & $r.length.grid &
      ", resolution " & f3(r.length.tolerance * k) & " " & u & "]\n"
    if r.length.binding.len > 0: result.add "    binding failure: " & r.length.binding & "\n"
    if not r.criticalLength.isNaN:
      result.add "    rule of thumb: critical length tr/(2 tpd) = " & f3(r.criticalLength * 1e3) & " mm"
      let m = r.length.maxFromStart
      if not m.isNaN and (m > 3 * r.criticalLength or m < r.criticalLength / 3):
        result.add "  -- disagrees with the simulated limit by more than 3x"
      result.add "\n"
  if r.vias.len > 0:
    result.add "\n  max length by via count:\n"
    for (n, s) in r.vias:
      result.add "    " & $n & " via(s): " & intervalsText(s) & "\n"
  if r.termination.len > 0:
    result.add "\n  series termination:\n"
    for (rr, s) in r.termination:
      result.add "    " & (if rr == 0: "none" else: f3(rr) & " ohm") & ": " & intervalsText(s) & "\n"
    if not r.bestSeriesR.isNaN:
      result.add "    best: " & (if r.bestSeriesR == 0: "none" else: f3(r.bestSeriesR) & " ohm") & "\n"
  if r.hasSpacing:
    result.add "\n  spacing to " & r.victimNet & " over a " & f3(r.coupledLength * 1e3) &
      " mm parallel run: " & intervalsText(r.spacing) & "\n"
    let m = r.spacing.minToEnd
    result.add "    min spacing: " & (if m.isNaN: "none passes up to " & f3(r.spacing.hi * 1e3) & " mm"
                                      else: f3(m * 1e3) & " mm") & "\n"
    if r.spacing.binding.len > 0: result.add "    binding failure: " & r.spacing.binding & "\n"
  if r.hasSkew:
    result.add "\n  intra-pair length mismatch with " & r.pairNet & ": " & intervalsText(r.skew) & "\n"
    let m = r.skew.maxFromStart
    result.add "    max mismatch: " & (if m.isNaN: "none passes" else: f3(m * 1e3) & " mm") & "\n"
    if r.skew.binding.len > 0: result.add "    binding failure: " & r.skew.binding & "\n"
  if r.stubs.len > 0:
    result.add "\n  via stubs:\n"
    for v in r.stubs:
      result.add "    " & v.name & ": stub " & f3(v.actualStub * 1e3) & " mm -> " & v.answer & "\n"
    for (n, hz) in r.stubResonances:
      result.add "    rule of thumb: " & n & " stub resonance " & f3(hz / 1e9) & " GHz\n"
  result.add "\n  assumptions:\n"
  for a in id.assumptions: result.add "    - " & a & "\n"
  for n in r.notes: result.add "  note: " & n & "\n"

proc jnum(x: float): JsonNode =
  if x.isNaN or x.classify in {fcInf, fcNegInf}: newJNull() else: %x

proc toJson(s: Sweep): JsonNode =
  result = %*{"param": ($s.param)[2 .. ^1], "lo": jnum(s.lo), "hi": jnum(s.hi),
              "grid": s.grid, "resolution": jnum(s.tolerance), "binding": s.binding}
  var p = newJArray()
  for iv in s.passing: p.add %*[jnum(iv.lo), jnum(iv.hi)]
  result["passing"] = p
  var g = newJArray()
  for iv in s.gaps: g.add %*[jnum(iv.lo), jnum(iv.hi)]
  result["gaps"] = g

proc renderJson*(r: ConstraintReport): JsonNode =
  ## `verax.si_constraints/1`. SI base units throughout.
  let id = r.identity
  var corners = newJArray()
  for c in id.corners: corners.add %cornerName(c)
  result = %*{
    "schema": "verax.si_constraints/1",
    "net": r.net,
    "identity": {"template": id.templateName, "topology": id.topology, "line": id.line,
                 "termination": id.termination, "partner": id.partner,
                 "driver": id.driver,
                 "receivers": id.receivers, "corners": corners,
                 "criteria": id.criteria, "assumptions": id.assumptions},
  }
  if r.hasLength:
    result["length"] = r.length.toJson
    result["critical_length_rule_of_thumb"] = jnum(r.criticalLength)
  var vias = newJArray()
  for (n, s) in r.vias: vias.add %*{"vias": n, "sweep": s.toJson}
  result["vias"] = vias
  var term = newJArray()
  for (rr, s) in r.termination: term.add %*{"series_r": rr, "sweep": s.toJson}
  result["termination"] = term
  result["best_series_r"] = jnum(r.bestSeriesR)
  var stubs = newJArray()
  for v in r.stubs:
    stubs.add %*{"transition": v.name, "stub": jnum(v.actualStub),
                 "max_passing_stub": jnum(v.maxPassingStub), "answer": v.answer}
  result["stubs"] = stubs
  if r.hasSkew:
    result["skew"] = %*{"pair": r.pairNet, "max_mismatch": jnum(r.skew.maxFromStart),
                        "sweep": r.skew.toJson}
  if r.hasSpacing:
    result["spacing"] = %*{"victim": r.victimNet, "coupled_length": jnum(r.coupledLength),
                           "min_spacing": jnum(r.spacing.minToEnd), "sweep": r.spacing.toJson}
  result["notes"] = %r.notes

proc druRules*(r: ConstraintReport, netName: string, baseVias = 0): seq[DruRule] =
  ## The KiCad-expressible part of a report. KiCad cannot tie a length to a
  ## via count, so the pair emitted must hold jointly: with a via table, the
  ## largest via count `n` that passes at all, and the *shortest* max length
  ## over `0 .. n` vias (safe for any route with at most `n` vias). Without
  ## one, the base sweep's length at `baseVias`. A passing set that does not
  ## start at zero length is not a "max length" and is not emitted. The rule
  ## is only as good as the template it came from (see the report).
  let who = "verax SI constraint for " & netName & " (" & r.identity.templateName &
            ", " & r.identity.criteria & ")"
  var maxLen = NaN
  var vias = baseVias
  if r.vias.len > 0:
    var running = Inf
    for (n, sw) in r.vias:
      let m = sw.maxFromStart
      if m.isNaN: break
      running = min(running, m)
      maxLen = running
      vias = n
  elif r.hasLength:
    maxLen = r.length.maxFromStart
  if not maxLen.isNaN:
    let capped = if r.hasLength and maxLen >= r.length.hi: "\nthe whole swept range passes; the limit is the sweep's end" else: ""
    result.add druRule(netName & " max length", netCondition(netName),
                       maxLength = maxLen, comment = who & capped)
    result.add druRule(netName & " max vias", netCondition(netName),
                       maxViaCount = vias, comment = who)
  if r.hasSkew and r.pairNet.len > 0:
    let m = r.skew.maxFromStart
    if not m.isNaN:
      result.add druRule(netName & "/" & r.pairNet & " skew", eitherCondition(netName, r.pairNet),
                         maxSkew = m, comment = who)
  if r.hasSpacing and r.victimNet.len > 0:
    let m = r.spacing.minToEnd
    if not m.isNaN:
      result.add druRule(netName & "/" & r.victimNet & " spacing",
                         pairCondition(netName, r.victimNet), minClearance = m,
                         comment = who & "\nparallel run " & f3(r.coupledLength * 1e3) &
                           " mm; a longer run needs more")
