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
## - **Identity**: an answer carries the template, line, termination,
##   driver, receivers, corners, criteria and assumptions. A bare "max
##   length" is never reported.

import std/[math, strutils, json]
import ./simulate
import ./measure
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
    spLength, spStubLength, spSeriesR, spViaStub

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
    driver*: string
    receivers*: seq[string]
    corners*: seq[Corner]
    criteria*: string
    assumptions*: seq[string]

proc defaultCriteria*(): Criteria =
  Criteria(maxFlightTime: NaN, minRingbackMargin: 0.0, minThresholdMargin: 0.0,
           useOvershootLimits: true, maxOvershoot: NaN, maxUndershoot: NaN,
           requireMonotonic: true, maxSettleTime: NaN,
           edges: {edRising, edFalling}, edgeDelay: 0.5e-9)

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
  parts.join(", ")

proc f3(x: float): string = formatFloat(x, ffDecimal, 3)

proc judge*(templates: openArray[SiTemplate], p: TemplateParams, c: Criteria,
            so = defaultSiOptions()): PointResult =
  ## One point at every corner and edge. Unsupported or a solver failure
  ## makes the point invalid, never a pass and never a fail.
  result.verdict = vPass
  for t in templates:
    result.corners.add t.driver.corner
    let net = t.build(p)
    for e in c.edges:
      let stim = edgeStimulus(e, c.edgeDelay)
      let r = simulate(net, stim, so)
      case r.status
      of ssUnsupported:
        result.verdict = vInvalid
        result.reason = "unsupported: " & r.reason
        return
      of ssSolverFailed:
        result.verdict = vInvalid
        result.reason = "solver failure: " & r.reason
        return
      of ssOk: discard
      let (tRef, _, _) = timingReference(t.driver, stim, so)
      for k in 0 ..< r.receivers.len:
        let rx = net.receivers[k]
        let m = measure(r, k, t.driver, rx.thresholds, rx.overshoot, tRef)
        result.measures.add m
        let at = " at " & cornerName(t.driver.corner) & ", " & m.receiver & " " & edgeName(e)
        template fail(msg: string) =
          result.verdict = vFail
          result.failures.add msg & at
        if not rx.thresholds.present:
          result.verdict = vInvalid
          result.reason = m.receiver & " has no Vinh/Vinl"
          return
        if not c.maxFlightTime.isNaN:
          if m.flightTimeMax.isNaN:
            if tRef.isNaN:
              result.verdict = vInvalid
              result.reason = "a timing budget needs the driver's Vmeas/Rref/Cref"
              return
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

proc sweep*(templates: openArray[SiTemplate], base: TemplateParams,
            param: SweepParam, lo, hi: float, grid: int, c: Criteria,
            tolerance: float, so = defaultSiOptions()): Sweep =
  ## Coarse grid, then bisection of every pass/fail transition between two
  ## *valid* neighbours.
  result = Sweep(param: param, lo: lo, hi: hi, grid: grid, tolerance: tolerance)
  let templates = @templates   # captured by `boundary`
  let n = max(grid, 2)
  for i in 0 ..< n:
    let x = lo + (hi - lo) * i.float / (n - 1).float
    result.samples.add (x, judge(templates, base.withParam(param, x), c, so))
  proc boundary(a, b: float, aPass: bool): tuple[x: float, failure: string] =
    ## The transition between a valid `a` and a valid `b` of the other
    ## verdict, to `tolerance`. A point that turns invalid mid-bisection
    ## stops it at the last bracket (reported as a gap by the caller).
    var lo = a
    var hi = b
    var fails = ""
    while abs(hi - lo) > tolerance:
      let m = 0.5 * (lo + hi)
      let pr = judge(templates, base.withParam(param, m), c, so)
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
  result.termination = if term.len == 0: "none" else: term.join(", ")
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
    criticalLength*: float
    stubResonances*: seq[tuple[name: string, hz: float]]
    notes*: seq[string]

proc paramUnit(p: SweepParam): (string, float) =
  case p
  of spLength, spStubLength, spViaStub: ("mm", 1e3)
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
                 "termination": id.termination, "driver": id.driver,
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
