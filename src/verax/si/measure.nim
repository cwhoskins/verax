## The numbers an SI claim reads, measured on a forward run's receiver die
## waveform. Curve primitives come from `verax/waveform`; the definitions
## here are SI-specific and every voltage states its reference.
##
## - **Thresholds**: `Vinh`/`Vinl`, `[Model Spec]` first, else `[Model]`.
## - **Flight time** = receiver crossing - the crossing of the *same driver*
##   at `Vmeas` into its `Vref`/`Rref`/`Cref` timing load (IBIS's own
##   definition; it removes the buffer delay a datasheet's Tco already
##   counts). The timing load is a [Model]-level figure, so it is applied at
##   the die with no package (recorded as an `Assumption`). The timing-load
##   run is itself a tiny native simulation.
##   - `flightTimeMin`: first crossing of the *near* threshold (`Vinl` on a
##     rising edge) -- the earliest the receiver may switch.
##   - `flightTimeMax`: the **last** crossing of the far threshold (`Vinh`
##     rising) -- after it the input stays switched. The figure a timing
##     budget reads.
## - **Overshoot / undershoot**: peak beyond the driver's high / low rail,
##   volts (positive = beyond). `S_overshoot_high/low` limits are absolute,
##   so their margins are `limit - peak` (high) and `peak - limit` (low).
## - **Ringback margin**: after first reaching the far threshold, how far
##   the wave stays beyond it (rising: `min(v) - Vinh`); negative means it
##   rang back into the threshold band.
## - **Monotonic**: no reversal larger than `hysteresis` inside the band.
## - **Settle time**: from the timing reference until the wave stays within
##   `settleTol` (fraction of the swing) of the level it settles to -- the
##   caller's exact level when given, else the last sample; `NaN` if the
##   last sample is still outside the band.
## - **Threshold margin**: the final level beyond the far threshold.
## - **Bit patterns** (`measurePattern`): each transition on its own window,
##   up to the next one. The settle band is around the level the edge
##   settles to (the caller's: `si/sweep` uses the DC operating point of the
##   opposite single edge), and the threshold margin is read at
##   the window's end: inter-symbol interference shows as an edge that has
##   not crossed for good, or not settled, by the end of its bit.
## - **Crosstalk** (`measureNoise`): on a quiet victim, the largest
##   excursion from its quiet level, and the **noise margin** -- held low,
##   `Vinl - peak`; held high, `trough - Vinh` (negative: a false switch).
## - **Differential** (`diffWave`): `v(p) - v(n)` measured like a
##   single-ended edge against `+-Vdiff`, with the swing `+-(rail span)`
##   as its "rails"; each leg alone is only judged for overshoot.

import std/[math, strutils]
import ../waveform
import ./simulate
import ../netlist/annotations

export waveform

type
  SiMeasures* = object
    receiver*: string
    edge*: Edge
    vinh*, vinl*: float
    tRef*: float
      ## Absolute time the driver crossed `Vmeas` into its timing load.
    flightTimeMin*, flightTimeMax*: float
    peakHigh*, peakLow*: float
      ## Absolute volts at the receiver die.
    railHigh*, railLow*: float
    overshoot*, undershoot*: float
    overshootHighMargin*, overshootLowMargin*: float
      ## Against `S_overshoot_high/low`; `NaN` without a limit.
    ringbackMargin*: float
    monotonic*: bool
    reversals*: int
    settleTime*: float
    thresholdMargin*: float
    notes*: seq[string]
      ## Why a figure is `NaN`.
    assumptions*: seq[Assumption]

  MeasureOptions* = object
    settleTol*: float
    hysteresis*: float
      ## Volts: a reversal smaller than this is noise, not non-monotonicity.

proc defaultMeasureOptions*(): MeasureOptions =
  MeasureOptions(settleTol: 0.02, hysteresis: 0.01)

proc firstCrossing*(t, v: openArray[float], level: float, rising: bool,
                    fromT = 0.0): float =
  ## First time at or after `fromT` that `v` crosses `level` in the given
  ## direction. `NaN` if never.
  for k in 0 ..< t.len - 1:
    if t[k + 1] < fromT: continue
    let a = v[k]
    let b = v[k + 1]
    let hit = if rising: a < level and b >= level else: a > level and b <= level
    if hit:
      return t[k] + (level - a) / (b - a) * (t[k + 1] - t[k])
  NaN

proc lastCrossing*(t, v: openArray[float], level: float, rising: bool): float =
  ## The last crossing in the given direction; `NaN` if the wave never
  ## crosses, or ends on the wrong side (it never stays switched).
  let endOk = if rising: v[^1] >= level else: v[^1] <= level
  if not endOk: return NaN
  for k in countdown(t.len - 2, 0):
    let a = v[k]
    let b = v[k + 1]
    let hit = if rising: a < level and b >= level else: a > level and b <= level
    if hit:
      return t[k] + (level - a) / (b - a) * (t[k + 1] - t[k])
  if (if rising: v[0] >= level else: v[0] <= level): return t[0]
  NaN

proc timingReference*(d: DriverBehaviour, stim: Stimulus,
                      o = defaultSiOptions()): tuple[t: float, why: string, assumption: Assumption] =
  ## The driver alone into its `Vref`/`Rref`/`Cref` load, crossing `Vmeas`.
  let tl = d.timing
  if not tl.hasVmeas:
    return (NaN, d.model & " states no Vmeas", Assumption())
  if not tl.hasRref and not tl.hasCref:
    return (NaN, d.model & " states no Rref/Cref timing load", Assumption())
  var n = newSiNet("timing load")
  n.setDriver("drv", d, PackageRlc())
  let pad = n.driverPort.pinNode
  if tl.hasRref:
    let vr = n.addNode("vref")
    n.addResistor(pad, vr, tl.rref, "Rref")
    n.addSource(vr, 0, (if tl.hasVref: tl.vref else: 0.0), "Vref")
  if tl.hasCref and tl.cref > 0:
    n.addCapacitor(pad, 0, tl.cref, "Cref")
  let r = simulate(n, stim, o)
  if r.status != ssOk:
    return (NaN, "timing-load run: " & r.reason, Assumption())
  let rising = stim.kind == skEdge and stim.edge == edRising
  let tc = firstCrossing(r.t, r.driver.v, tl.vmeas, rising, stim.delay)
  if tc.isNaN:
    return (NaN, d.model & " never crosses Vmeas " & $tl.vmeas & " V into its timing load", Assumption())
  (tc, "", note(d.model, "timing load (Vref/Rref/Cref) applied at the die, without package"))

proc measureEdge*(t, v: openArray[float], label: string, rising: bool,
                  railHigh, railLow: float, thresholds: Thresholds,
                  overshoot: OvershootLimits, start, tRef, settled: float,
                  o = defaultMeasureOptions()): SiMeasures =
  ## Every figure of one edge on the samples `t`/`v` (the window). `start`
  ## is where the edge begins; `settled` the level it settles to (`NaN`:
  ## the window's last sample, as for a whole single-edge run). The rails
  ## set overshoot and the settle band (a fraction of their span).
  result = SiMeasures(receiver: label, vinh: thresholds.vinh, vinl: thresholds.vinl,
                      tRef: tRef, railHigh: railHigh, railLow: railLow,
                      edge: (if rising: edRising else: edFalling))
  result.peakHigh = max(v)
  result.peakLow = min(v)
  result.overshoot = result.peakHigh - result.railHigh
  result.undershoot = result.railLow - result.peakLow
  result.overshootHighMargin = if overshoot.hasHigh: overshoot.high - result.peakHigh else: NaN
  result.overshootLowMargin = if overshoot.hasLow: result.peakLow - overshoot.low else: NaN
  for f in [result.flightTimeMin.addr, result.flightTimeMax.addr, result.ringbackMargin.addr,
            result.settleTime.addr, result.thresholdMargin.addr]:
    f[] = NaN
  result.monotonic = true
  if not thresholds.present:
    result.notes.add "no Vinh/Vinl for " & label
    return
  let near = if rising: thresholds.vinl else: thresholds.vinh
  let far = if rising: thresholds.vinh else: thresholds.vinl
  let tNear = firstCrossing(t, v, near, rising, start)
  let tFarFirst = firstCrossing(t, v, far, rising, start)
  let tFarLast = lastCrossing(t, v, far, rising)
  if tRef.isNaN:
    result.notes.add "no timing reference (Vmeas/Rref/Cref), so no flight time"
  else:
    result.flightTimeMin = tNear - tRef
    result.flightTimeMax = tFarLast - tRef
  if tNear.isNaN: result.notes.add label & " never reaches " & $near & " V"
  if tFarLast.isNaN: result.notes.add label & " never settles past " & $far & " V"
  # Ringback: past the far threshold, the first peak, then the deepest
  # return after it (a wave that just keeps rising has its last sample as
  # the peak and no return).
  if not tFarFirst.isNaN:
    var k0 = 0
    while k0 < t.len and t[k0] < tFarFirst: inc k0
    var pk = k0
    while pk + 1 < t.len and (if rising: v[pk + 1] >= v[pk] else: v[pk + 1] <= v[pk]):
      inc pk
    var ext = v[pk]
    for k in pk ..< t.len:
      ext = if rising: min(ext, v[k]) else: max(ext, v[k])
    result.ringbackMargin = if rising: ext - far else: far - ext
  # Monotonicity through the band: from the first near-threshold crossing
  # to the last far one, count every fall back (rise, on a falling edge)
  # of more than `hysteresis` that lands inside or short of the band.
  # Ringing wholly beyond the far threshold is not a reversal.
  if not tNear.isNaN:
    let tEnd = if tFarLast.isNaN: t[^1] else: tFarLast
    var extreme = near
    for k in 0 ..< t.len:
      let tk = t[k]
      if tk <= tNear or tk > tEnd: continue
      let x = v[k]
      if rising:
        if x > extreme: extreme = x
        elif extreme - x > o.hysteresis and x <= far:
          inc result.reversals
          extreme = x
      else:
        if x < extreme: extreme = x
        elif x - extreme > o.hysteresis and x >= far:
          inc result.reversals
          extreme = x
  result.monotonic = result.reversals == 0
  # Settle and final margin. An absolute band (`waveform.settleTime` is
  # relative to the final value, which is ~0 after a falling edge).
  let final = if settled.isNaN: v[^1] else: settled
  let swing = abs(railHigh - railLow)
  let band = o.settleTol * swing
  var lastOut = -1
  for k in 0 ..< v.len:
    if abs(v[k] - final) > band: lastOut = k
  let st =
    if lastOut < 0: t[0]
    elif lastOut >= v.len - 1: NaN
    else:
      let lvl = if v[lastOut] > final: final + band else: final - band
      t[lastOut] + (lvl - v[lastOut]) / (v[lastOut + 1] - v[lastOut]) * (t[lastOut + 1] - t[lastOut])
  let ref0 = if tRef.isNaN: start else: tRef
  result.settleTime = if st.isNaN: NaN else: max(st - ref0, 0.0)
  # The level the next sampling sees: the window's end.
  result.thresholdMargin = if rising: v[^1] - far else: far - v[^1]

proc measure*(r: SiResult, rx: int, d: DriverBehaviour, thresholds: Thresholds,
              overshoot: OvershootLimits, tRef: float,
              o = defaultMeasureOptions(), settled = NaN): SiMeasures =
  ## Every figure for receiver `rx` of a single-edge run. `settled`: the
  ## level the edge settles to (`si/sweep.settledLevels`); `NaN` settles
  ## around the run's last sample, which is optimistic if it still rings.
  let w = r.receivers[rx]
  if r.stimulus.kind != skEdge:
    result = SiMeasures(receiver: w.label)
    result.notes.add "measures are defined on a single-edge run; use measurePattern"
    return
  measureEdge(r.t, w.v, w.label, r.stimulus.edge == edRising, d.rails.pullup,
              d.rails.pulldown, thresholds, overshoot, r.stimulus.delay, tRef, settled, o)

type
  PatternEdge* = object
    index*: int
      ## The bit that starts with this transition.
    edge*: Edge
    t0*, t1*: float
      ## The window: from this transition to the next (or the pattern's
      ## end).
    m*: SiMeasures

proc measurePatternWave*(s: Stimulus, t, v: openArray[float], label: string,
                         railHigh, railLow: float, thresholds: Thresholds,
                         overshoot: OvershootLimits, tRefOffset, settled: array[Edge, float],
                         o = defaultMeasureOptions(), inverted = false): seq[PatternEdge] =
  ## `measurePattern` on any wave of a pattern run (a differential one, an
  ## inverted leg: `inverted` reads each transition as the opposite edge).
  if s.kind != skPattern: return
  var trans: seq[tuple[i: int, t: float, e: Edge]]
  for i in 1 ..< s.bits.len:
    if s.bits[i] != s.bits[i - 1]:
      trans.add (i, s.delay + i.float * s.ui,
                 (if (s.bits[i] == '1') != inverted: edRising else: edFalling))
  for j, tr in trans:
    let tEnd = if j + 1 < trans.len: trans[j + 1].t
               else: min(t[^1], s.delay + s.bits.len.float * s.ui)
    var k0 = 0
    while k0 < t.len - 1 and t[k0 + 1] <= tr.t: inc k0
    var k1 = k0
    while k1 < t.len - 1 and t[k1] < tEnd: inc k1
    if k1 - k0 < 2: continue
    let tRef = tr.t + tRefOffset[tr.e]
    let m = measureEdge(t.toOpenArray(k0, k1), v.toOpenArray(k0, k1), label,
                        tr.e == edRising, railHigh, railLow, thresholds, overshoot, tr.t,
                        tRef, settled[tr.e], o)
    result.add PatternEdge(index: tr.i, edge: tr.e, t0: tr.t, t1: tEnd, m: m)

proc measurePattern*(r: SiResult, rx: int, d: DriverBehaviour, thresholds: Thresholds,
                     overshoot: OvershootLimits, tRefOffset, settled: array[Edge, float],
                     o = defaultMeasureOptions()): seq[PatternEdge] =
  ## Every transition of a bit-pattern run, each measured on its own window
  ## (to the next transition): the ISI view. `tRefOffset[e]` is the timing
  ## load's crossing after the start of an `e` edge (`NaN`: no flight
  ## time); `settled[e]` the level an `e` edge settles to (`NaN`: the
  ## window's end). An edge that has not
  ## settled, or not crossed for good, by the window's end gets `NaN` there
  ## -- it did not make it within the bit.
  let w = r.receivers[rx]
  measurePatternWave(r.stimulus, r.t, w.v, w.label, d.rails.pullup, d.rails.pulldown,
                     thresholds, overshoot, tRefOffset, settled, o)

type
  NoiseMeasures* = object
    ## Crosstalk on a quiet conductor.
    probe*: string
    quiet*: float
      ## The level it sits at undisturbed, volts.
    heldHigh*: bool
    peakHigh*, peakLow*: float
    noise*: float
      ## Largest excursion from `quiet`, volts.
    noiseMargin*: float
      ## Held low: `Vinl - peakHigh`; held high: `peakLow - Vinh`. `NaN`
      ## without thresholds (a near-end probe at a driver).
    tPeak*: float
      ## When the largest excursion happened.

proc measureNoise*(t, v: openArray[float], probe: string, quiet: float, heldHigh: bool,
                   thresholds: Thresholds): NoiseMeasures =
  result = NoiseMeasures(probe: probe, quiet: quiet, heldHigh: heldHigh,
                         peakHigh: -Inf, peakLow: Inf, noiseMargin: NaN, tPeak: NaN)
  for k in 0 ..< v.len:
    result.peakHigh = max(result.peakHigh, v[k])
    result.peakLow = min(result.peakLow, v[k])
    let e = abs(v[k] - quiet)
    if e > result.noise or result.tPeak.isNaN:
      result.noise = max(result.noise, e)
      result.tPeak = t[k]
  if thresholds.present:
    result.noiseMargin = if heldHigh: result.peakLow - thresholds.vinh
                         else: thresholds.vinl - result.peakHigh

proc diffWave*(r: SiResult, d: DiffReceiver): seq[float] =
  ## `v(p) - v(n)` at the two receivers' dies.
  let p = r.receivers[d.p].v
  let n = r.receivers[d.n].v
  result = newSeq[float](p.len)
  for k in 0 ..< p.len: result[k] = p[k] - n[k]

proc diffThresholds*(d: DiffReceiver): Thresholds =
  if d.hasVdiff: Thresholds(vinh: d.vdiff, vinl: -d.vdiff, present: true)
  else: Thresholds()

proc `$`*(m: SiMeasures): string =
  proc f(x: float, unit: string, scale = 1.0): string =
    if x.isNaN: "n/a" else: formatFloat(x * scale, ffDecimal, 3) & " " & unit
  m.receiver & " (" & edgeName(m.edge) & "): flight " & f(m.flightTimeMin, "ns", 1e9) & " .. " &
    f(m.flightTimeMax, "ns", 1e9) & ", overshoot " & f(m.overshoot, "V") &
    ", undershoot " & f(m.undershoot, "V") & ", ringback margin " & f(m.ringbackMargin, "V") &
    ", settle " & f(m.settleTime, "ns", 1e9) & (if m.monotonic: "" else: ", NON-MONOTONIC")
