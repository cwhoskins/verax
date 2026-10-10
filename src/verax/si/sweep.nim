## Corner x stimulus x receiver sweeps of one net, with a worst-case report:
## per receiver, the worst value of each SI figure and the run that set it.
## The forward half of what `verify` checks (`analysis/analyses/si` adapts
## it); stage 5's constraint searches judge points the same way.
##
## - **Stimuli**: both single edges, and with a unit interval the ISI
##   pattern(s) at that UI, each transition measured on its own bit
##   (`measure.measurePattern`).
## - **Worst case**: higher is worse for overshoot, undershoot, flight and
##   settle time; lower for the two margins. A figure that some run cannot
##   produce (a receiver that never reaches its far threshold, a driver
##   with no timing load) is **undefined** over the sweep, never the worst
##   of the runs that happened to produce one -- that would be optimistic.
##   A flight or settle time that never comes counts as infinite.
## - **Settling** is judged against the exact level each edge settles to
##   (`settledLevels`: the DC point with the driver held at the end of that
##   edge's table). A single edge still outside the band at the end of its
##   run is re-run at four times the length (`maxExtensions`); a pattern
##   edge gets its bit.
## - **The first run that is unsupported or fails to solve decides the
##   status**; nothing after it is reported (decision 6).
## - **A pattern is skipped** (recorded as an `Assumption`) when every single
##   edge settles within the pattern's UI: the net is time-invariant, so
##   each bit then starts from the settled state the single edge started
##   from, to within the settle band. Only a net that does not settle in a
##   UI pays for the pattern. `skipSettledPatterns = false` runs it anyway.
## - `measured` keeps every edge at every receiver, which is what stage 5's
##   `constrain.judge` applies its criteria to.

import std/[math, strutils]
import ./simulate
import ./measure
import ./eye
import ../netlist/annotations

type
  SiFigure* = enum
    sfOvershoot, sfUndershoot, sfRingbackMargin, sfFlightTime, sfSettleTime,
    sfThresholdMargin, sfCrosstalk, sfNoiseMargin, sfEyeHeight, sfEyeWidth

  ProbeKind* = enum
    pkSignal   ## a receiver on a driven conductor: every SI figure
    pkDiff     ## a differential receiver `v(p) - v(n)` against `+-Vdiff`
    pkLeg      ## one leg of a differential receiver: overshoot only
    pkVictim   ## a quiet conductor's receiver or (near end) driver: crosstalk

  Probe* = object
    ## Where the sweep measures: one row of the report.
    label*: string
    kind*: ProbeKind
    index*: int
      ## Receiver index (`pkSignal`/`pkLeg`/`pkVictim` at a receiver),
      ## `diffReceivers` index (`pkDiff`), or `-1 - k` for extra driver `k`
      ## (a near-end victim probe).
    inverted*: bool
      ## On a conductor driven with the stimulus's complement.
    heldHigh*: bool
      ## A victim held high.

  WorstCase* = object
    value*: float
      ## `NaN`: no run produced it, or it is undefined (`undefined`).
    at*: string
      ## The run that set it: `"min rising"`, `"typ pattern ... bit 3 rising"`.
    undefined*: string

  Timing* = object
    ## The driver's timing-load crossing after the start of each edge
    ## (`NaN` and `why` when it has none). Depends on the driver only, so a
    ## caller judging many points of one template computes it once.
    offset*: array[Edge, float]
    why*: array[Edge, string]
    assumption*: Assumption
    hasAssumption*: bool

  SweepCorner* = object
    corner*: Corner
    net*: SiNet
    timing*: Timing
    hasTiming*: bool
      ## `timing` is precomputed (`timingOf`); otherwise the sweep runs it.

  SweepRun* = object
    corner*: Corner
    stimulus*: Stimulus
    status*: SiStatus
    reason*: string
    steps*: int
    extended*: int
      ## How many times a single edge's run was lengthened to let it settle.
    skipped*: bool
      ## A pattern not run because every edge settles within its UI.
    edgesMeasured*: int

  MeasuredEdge* = object
    ## One edge at one probe: what a criterion (stage 5) is judged on.
    corner*: Corner
    probe*: int
    kind*: ProbeKind
    receiver*: int
      ## The net's receiver index (`pkDiff`: its `p` leg; `-1`: a driver).
    run*: string
      ## `"rising"`, `"pattern 0001... @ 20 ns, bit 3 rising"`.
    m*: SiMeasures
      ## Signal, differential and leg probes.
    noise*: NoiseMeasures
      ## Victim probes.
    isEye*: bool
      ## A long pattern's eye (`eye`), not one edge.
    eye*: Eye
    timingWhy*: string
      ## Why there is no flight time, when there is none.

  SiSweep* = object
    net*: string
    status*: SiStatus
    reason*: string
    receivers*: seq[string]
      ## Every probe's label, in `probes` order.
    probes*: seq[Probe]
    eyes*: bool
      ## Some stimulus was long enough to fold into an eye.
    corners*: seq[Corner]
    stimuli*: seq[Stimulus]
    runs*: seq[SweepRun]
    measured*: seq[MeasuredEdge]
    worst*: seq[array[SiFigure, WorstCase]]
      ## Per probe. A single-conductor net's probes are its receivers in
      ## order.
    assumptions*: seq[Assumption]
    issues*: seq[Issue]

  SweepOptions* = object
    sim*: SiOptions
    measure*: MeasureOptions
    skipSettledPatterns*: bool
      ## Skip a pattern when every single edge settles within its UI.
    maxExtensions*: int
      ## A single edge whose receivers have not settled by the end of its
      ## run is re-run at four times the length, at most this many times
      ## (then its settle time is "never").
    eye*: EyeOptions
    eyeMinBits*: int
      ## A pattern at least this long is also folded into an eye (and never
      ## skipped as settled).

const
  figureHigherIsWorse*: array[SiFigure, bool] = [true, true, false, true, true, false, true,
                                                 false, false, false]
  figureUnit*: array[SiFigure, string] = ["V", "V", "V", "s", "s", "V", "V", "V", "V", "s"]
  figureName*: array[SiFigure, string] = ["overshoot", "undershoot", "ringback margin",
                                          "flight time", "settle time", "threshold margin",
                                          "crosstalk", "noise margin", "eye height", "eye width"]
  signalFigures* = {sfOvershoot .. sfThresholdMargin}
  isiPatterns* = ["0100", "1011"]
    ## An isolated one from a settled low, an isolated zero from a settled
    ## high (the run starts at its DC operating point, so a leading run of
    ## equal bits would only re-simulate DC): the first-order ISI worst
    ## cases, with the edge back after each.

proc figuresFor*(p: Probe): set[SiFigure] =
  ## The figures a probe reports.
  case p.kind
  of pkSignal, pkDiff: signalFigures
  of pkLeg: {sfOvershoot, sfUndershoot}
  of pkVictim: (if p.index >= 0: {sfCrosstalk, sfNoiseMargin} else: {sfCrosstalk})

proc figuresOf*(s: SiSweep, k: int): set[SiFigure] =
  ## What probe `k` of this sweep reports: `figuresFor`, and the eye when
  ## one was run.
  result = figuresFor(s.probes[k])
  if s.eyes and s.probes[k].kind in {pkSignal, pkDiff}: result.incl {sfEyeHeight, sfEyeWidth}

proc probesOf*(net: SiNet): seq[Probe] =
  ## Signal receivers in receiver order (a single-conductor net: exactly
  ## its receivers), then differential receivers, then victims' near ends.
  var inPair = newSeq[bool](net.receivers.len)
  for d in net.diffReceivers:
    inPair[d.p] = true
    inPair[d.n] = true
  for k in 0 ..< net.receivers.len:
    let port = net.receiverPorts[k]
    let mode = net.conductorMode(port.conductor)
    let kind =
      if mode in {dmQuietLow, dmQuietHigh}: pkVictim
      elif inPair[k]: pkLeg
      else: pkSignal
    result.add Probe(label: port.label, kind: kind, index: k,
                     inverted: mode == dmInverted, heldHigh: mode == dmQuietHigh)
  for k, d in net.diffReceivers:
    result.add Probe(label: d.label & " (diff)", kind: pkDiff, index: k)
  for k, x in net.extraDrivers:
    if x.mode in {dmQuietLow, dmQuietHigh}:
      result.add Probe(label: x.port.label & " (near end)", kind: pkVictim, index: -1 - k,
                       heldHigh: x.mode == dmQuietHigh)

proc defaultSweepOptions*(): SweepOptions =
  SweepOptions(sim: defaultSiOptions(), measure: defaultMeasureOptions(), maxExtensions: 2,
               skipSettledPatterns: true, eye: defaultEyeOptions(), eyeMinBits: 32)

proc sweepStimuli*(ui: float, edgeDelay = 0.5e-9, edges = {edRising, edFalling},
                   patterns = @isiPatterns, prbsBits = 0, prbsKind = prbs7): seq[Stimulus] =
  ## Each single edge; with a positive `ui`, also each pattern at that UI,
  ## and with `prbsBits > 0` that many bits of `prbsKind` (an eye).
  for e in edges: result.add edgeStimulus(e, edgeDelay)
  if ui > 0:
    for p in patterns: result.add patternStimulus(p, ui, edgeDelay)
    if prbsBits > 0: result.add patternStimulus(prbs(prbsKind, prbsBits), ui, edgeDelay)

proc timingOf*(d: DriverBehaviour, so = defaultSiOptions()): Timing =
  const delay = 0.5e-9
  for e in Edge:
    let (tRef, w, tnote) = timingReference(d, edgeStimulus(e, delay), so)
    result.offset[e] = tRef - delay
    result.why[e] = w
    if w.len == 0:
      result.assumption = tnote
      result.hasAssumption = true

proc settledLevels*(net: SiNet, so = defaultSiOptions()): seq[array[Edge, float]] =
  ## Where each receiver settles after each edge of the stimulus: the DC
  ## operating point with the driver held at the end of that edge's table
  ## (a constant pattern; other conductors follow their `DriveMode`).
  ## `NaN` when it cannot be solved.
  result = newSeq[array[Edge, float]](net.receivers.len)
  for k in 0 ..< result.len:
    for e in Edge: result[k][e] = NaN
  var o = so
  o.tStop = 1e-12
  for e in Edge:
    let r = simulate(net, patternStimulus((if e == edRising: "1" else: "0"), 1e-9), o)
    if r.status == ssOk:
      for k in 0 ..< net.receivers.len: result[k][e] = r.receivers[k].v[0]

proc track(w: var WorstCase, x: float, f: SiFigure, at: string) =
  if x.isNaN: return
  if w.value.isNaN or (figureHigherIsWorse[f] and x > w.value) or
     (not figureHigherIsWorse[f] and x < w.value):
    w.value = x
    w.at = at

proc stimulusText(s: Stimulus): string =
  case s.kind
  of skEdge: edgeName(s.edge)
  of skPattern:
    (if s.bits.len > 16: $s.bits.len & "-bit pattern " & s.bits[0 ..< 8] & "..."
     else: "pattern " & s.bits) & " @ " & formatFloat(s.ui * 1e9, ffDecimal, 3) & " ns"

proc add(w: var array[SiFigure, WorstCase], m: SiMeasures, tRefWhy: string,
         label, at: string, figs: set[SiFigure]) =
  if sfOvershoot in figs: w[sfOvershoot].track(m.overshoot, sfOvershoot, at)
  if sfUndershoot in figs: w[sfUndershoot].track(m.undershoot, sfUndershoot, at)
  if sfRingbackMargin in figs:
    if m.ringbackMargin.isNaN:
      w[sfRingbackMargin].undefined = label & " never reaches its far threshold (" & at & ")"
    w[sfRingbackMargin].track(m.ringbackMargin, sfRingbackMargin, at)
  if sfFlightTime in figs:
    if tRefWhy.len > 0:
      w[sfFlightTime].undefined = tRefWhy
    else:
      w[sfFlightTime].track((if m.flightTimeMax.isNaN: Inf else: m.flightTimeMax), sfFlightTime, at)
  if sfSettleTime in figs:
    w[sfSettleTime].track((if m.settleTime.isNaN: Inf else: m.settleTime), sfSettleTime, at)
  if sfThresholdMargin in figs:
    if m.thresholdMargin.isNaN and m.notes.len > 0:
      w[sfThresholdMargin].undefined = m.notes[0]
    w[sfThresholdMargin].track(m.thresholdMargin, sfThresholdMargin, at)

proc addNoise(w: var array[SiFigure, WorstCase], n: NoiseMeasures, at: string,
              figs: set[SiFigure]) =
  w[sfCrosstalk].track(n.noise, sfCrosstalk, at)
  if sfNoiseMargin in figs:
    if n.noiseMargin.isNaN:
      w[sfNoiseMargin].undefined = n.probe & " has no Vinh/Vinl"
    w[sfNoiseMargin].track(n.noiseMargin, sfNoiseMargin, at)

proc sweepNet*(corners: openArray[SweepCorner], stimuli: openArray[Stimulus],
               o = defaultSweepOptions()): SiSweep =
  ## Every corner x stimulus, every probe measured; the worst kept.
  if corners.len == 0:
    result.status = ssUnsupported
    result.reason = "no corner to run"
    return
  result.net = corners[0].net.name
  result.stimuli = @stimuli
  result.probes = probesOf(corners[0].net)
  for p in result.probes: result.receivers.add p.label
  result.worst = newSeq[array[SiFigure, WorstCase]](result.probes.len)
  for k in 0 ..< result.worst.len:
    for f in SiFigure: result.worst[k][f] = WorstCase(value: NaN)
  let band = o.measure.settleTol
  for ci in 0 ..< corners.len:
    template sc: untyped = corners[ci]
    let net = sc.net
    let cn = cornerName(sc.corner)
    result.corners.add sc.corner
    let tm = if sc.hasTiming: sc.timing else: timingOf(net.driver, o.sim)
    if ci == 0 and tm.hasAssumption:
      result.assumptions.add tm.assumption
    let settled = settledLevels(net, o.sim)
    let rails = net.driver.rails
    let swing = abs(rails.pullup - rails.pulldown)
    proc settledOf(p: Probe): array[Edge, float] =
      case p.kind
      of pkDiff:
        let d = net.diffReceivers[p.index]
        for e in Edge: result[e] = settled[d.p][e] - settled[d.n][e]
      of pkSignal, pkLeg, pkVictim:
        if p.index >= 0:
          result = settled[p.index]
          if p.inverted:
            # Indexed by the edge *this* conductor makes.
            result = [settled[p.index][edFalling], settled[p.index][edRising]]
        else: result = [NaN, NaN]
    # Latest settling instant after the start of each single edge, over
    # the signal and differential probes (`Inf`: never; `NaN`: that edge
    # was not run).
    var settleBy: array[Edge, float] = [NaN, NaN]
    var order: seq[int]
    for i, st in stimuli:
      if st.kind == skEdge: order.add i
    for i, st in stimuli:
      if st.kind != skEdge: order.add i
    for i in order:
      let stim = stimuli[i]
      let isEye = stim.kind == skPattern and stim.bits.len >= o.eyeMinBits
      if isEye: result.eyes = true
      if stim.kind == skPattern and o.skipSettledPatterns and not isEye:
        var worstBy = -Inf
        for e in Edge: worstBy = max(worstBy, settleBy[e])   # NaN never wins
        if not settleBy[edRising].isNaN and not settleBy[edFalling].isNaN and
           worstBy <= stim.ui:
          result.assumptions.add note("net " & net.name, stimulusText(stim) & " not run at " & cn &
            ": every edge settles to within " & $(band * 100) & " % of its level " &
            formatFloat(worstBy * 1e9, ffDecimal, 3) & " ns after it starts, inside the UI, " &
            "so each bit starts from the settled state (a single edge already measures it)")
          result.runs.add SweepRun(corner: sc.corner, stimulus: stim, status: ssOk,
                                   skipped: true)
          continue
      var so = o.sim
      var r = simulate(net, stim, so)
      var run = SweepRun(corner: sc.corner, stimulus: stim, status: r.status, reason: r.reason)
      # A single edge runs until every receiver has settled: settling is
      # never read off a wave that is still moving.
      while stim.kind == skEdge and r.status == ssOk and run.extended < o.maxExtensions:
        var still = false
        for k in 0 ..< net.receivers.len:
          let lvl = settled[k][stim.edge]
          if not lvl.isNaN and abs(r.receivers[k].v[^1] - lvl) > band * swing: still = true
        if not still: break
        so.tStop = 4.0 * r.t[^1]
        r = simulate(net, stim, so)
        run.status = r.status
        run.reason = r.reason
        inc run.extended
      run.steps = r.steps
      result.issues.add r.issues
      if r.status != ssOk:
        result.runs.add run
        result.status = r.status
        result.reason = cn & " " & stimulusText(stim) & ": " & r.reason
        return
      for pi in 0 ..< result.probes.len:
        let pr = result.probes[pi]
        let figs = figuresFor(pr)
        let lv = settledOf(pr)
        # The wave, the thresholds and the rails this probe is read against.
        var wave: seq[float]
        var th: Thresholds
        var os: OvershootLimits
        var railHigh = rails.pullup
        var railLow = rails.pulldown
        var rxIndex = pr.index
        case pr.kind
        of pkDiff:
          let d = net.diffReceivers[pr.index]
          wave = diffWave(r, d)
          th = diffThresholds(d)
          railHigh = swing
          railLow = -swing
          rxIndex = d.p
        of pkSignal, pkLeg, pkVictim:
          if pr.index >= 0:
            wave = r.receivers[pr.index].v
            if pr.kind == pkSignal: th = net.receivers[pr.index].thresholds
            if pr.kind == pkVictim: th = net.receivers[pr.index].thresholds
            os = net.receivers[pr.index].overshoot
          else:
            wave = r.extraDrivers[-1 - pr.index].v
            rxIndex = -1
        if pr.kind == pkVictim:
          let quiet = if lv[edRising].isNaN: wave[0] else: lv[edRising]
          let n = measureNoise(r.t, wave, pr.label, quiet, pr.heldHigh, th)
          let what = stimulusText(stim)
          result.worst[pi].addNoise(n, cn & " " & what, figs)
          result.measured.add MeasuredEdge(corner: sc.corner, probe: pi, kind: pkVictim,
                                           receiver: rxIndex, run: what, noise: n)
          inc run.edgesMeasured
          continue
        case stim.kind
        of skEdge:
          let e = if pr.inverted: (if stim.edge == edRising: edFalling else: edRising)
                  else: stim.edge
          let tRef = if tm.why[e].len > 0: NaN else: stim.delay + tm.offset[e]
          let m = measureEdge(r.t, wave, pr.label, e == edRising, railHigh, railLow, th, os,
                              stim.delay, tRef, lv[e], o.measure)
          result.worst[pi].add(m, tm.why[e], pr.label, cn & " " & edgeName(stim.edge), figs)
          result.measured.add MeasuredEdge(corner: sc.corner, probe: pi, kind: pr.kind,
                                           receiver: rxIndex, run: edgeName(stim.edge),
                                           m: m, timingWhy: tm.why[e])
          if pr.kind in {pkSignal, pkDiff}:
            let fromStart =
              if m.settleTime.isNaN: Inf
              elif tRef.isNaN: m.settleTime
              else: m.settleTime + (tRef - stim.delay)
            let se = stim.edge
            settleBy[se] = if settleBy[se].isNaN: fromStart else: max(settleBy[se], fromStart)
          inc run.edgesMeasured
        of skPattern:
          if isEye and pr.kind in {pkSignal, pkDiff}:
            var bits = stim.bits
            if pr.inverted:
              for ch in bits.mitems: ch = (if ch == '1': '0' else: '1')
            var eo = o.eye
            if eo.maxOffset.isNaN: eo.maxOffset = totalDelay(net) + 3.0 * stim.ui
            let ey = eyeOf(r.t, wave, bits, stim.ui, stim.delay, th.vinh, th.vinl,
                           th.present, eo)
            let what = stimulusText(stim) & " eye"
            result.worst[pi][sfEyeHeight].track(ey.height, sfEyeHeight, cn & " " & what)
            result.worst[pi][sfEyeWidth].track(ey.width, sfEyeWidth, cn & " " & what)
            result.measured.add MeasuredEdge(corner: sc.corner, probe: pi, kind: pr.kind,
                                             receiver: rxIndex, run: what, isEye: true,
                                             eye: ey)
          var offs: array[Edge, float]
          for e in Edge: offs[e] = if tm.why[e].len > 0: NaN else: tm.offset[e]
          for pe in measurePatternWave(stim, r.t, wave, pr.label, railHigh, railLow, th, os,
                                       offs, lv, o.measure, pr.inverted):
            let what = stimulusText(stim) & ", bit " & $pe.index & " " & edgeName(pe.edge)
            result.worst[pi].add(pe.m, tm.why[pe.edge], pr.label, cn & " " & what, figs)
            result.measured.add MeasuredEdge(corner: sc.corner, probe: pi, kind: pr.kind,
                                             receiver: rxIndex, run: what, m: pe.m,
                                             timingWhy: tm.why[pe.edge])
            inc run.edgesMeasured
      result.runs.add run
  result.status = ssOk

proc valueText(f: SiFigure, x: float): string =
  if x.isNaN: "n/a"
  elif x == Inf: "never"
  elif figureUnit[f] == "s": formatFloat(x * 1e9, ffDecimal, 3) & " ns"
  else: formatFloat(x, ffDecimal, 3) & " V"

proc renderText*(s: SiSweep): string =
  ## The worst-case report.
  var cs: seq[string]
  for c in s.corners: cs.add cornerName(c)
  var st: seq[string]
  for x in s.stimuli: st.add stimulusText(x)
  var steps = 0
  var edges = 0
  for r in s.runs:
    steps += r.steps
    edges += r.edgesMeasured
  result.add "SI sweep of net " & s.net & ": " & $s.corners.len & " corner(s) (" & cs.join(", ") &
    ") x " & $s.stimuli.len & " stimuli (" & st.join("; ") & ") x " & $s.receivers.len &
    " receiver(s)\n"
  result.add "  " & $s.runs.len & " runs, " & $steps & " steps, " & $edges & " edges measured\n"
  if s.status != ssOk:
    result.add "  " & ($s.status)[2 .. ^1] & ": " & s.reason & "\n"
    return
  for k, rx in s.receivers:
    result.add "  " & rx & "\n"
    for f in SiFigure:
      if f notin s.figuresOf(k): continue
      let w = s.worst[k][f]
      result.add "    " & alignLeft(figureName[f], 17) &
        (if w.undefined.len > 0: "undefined: " & w.undefined
         else: alignLeft(valueText(f, w.value), 12) & (if w.at.len > 0: "worst at " & w.at else: "")) & "\n"
