## Curve math shared by the simulation-backed analyses: pure functions over
## `openArray[float]`, so most of each analysis's reasoning is testable
## without ngspice.
##
## **Log-axis interpolation**: in a `dec` sweep, linear interpolation biases
## a -3 dB corner by several percent, so frequency procs take `logX` (and
## `corner3dB`/`unityGainFreq` set it).
##
## Anything not found is `NaN`, never raised or clamped. Malformed input
## (empty or mismatched arrays) raises `ValueError`.

import std/math

proc checkPair(x, y: openArray[float], what: string) =
  if x.len != y.len:
    raise newException(ValueError,
      what & ": axis and value arrays differ in length (" & $x.len & " vs " & $y.len & ")")
  if x.len == 0:
    raise newException(ValueError, what & ": empty input")

proc lerpX(x0, x1, y0, y1, level: float, logX: bool): float =
  ## The x at which the segment (x0,y0)-(x1,y1) passes through `level`,
  ## interpolating in log10(x) when asked.
  if y1 == y0: return x0
  let f = (level - y0) / (y1 - y0)
  if logX:
    let lx0 = log10(x0)
    let lx1 = log10(x1)
    pow(10.0, lx0 + f * (lx1 - lx0))
  else:
    x0 + f * (x1 - x0)

proc interpCrossing*(x, y: openArray[float], level: float,
                     fromIdx = 0, logX = false): float =
  ## The first x at or after `fromIdx` where `y` crosses `level`, in either
  ## direction. `NaN` if it never does.
  checkPair(x, y, "interpCrossing")
  for i in max(fromIdx, 0) ..< x.len - 1:
    if (y[i] <= level and y[i + 1] >= level) or (y[i] >= level and y[i + 1] <= level):
      return lerpX(x[i], x[i + 1], y[i], y[i + 1], level, logX)
  NaN

proc valueAt*(x, y: openArray[float], at: float, logX = false): float =
  ## `y` interpolated at `at`; `NaN` outside the swept range (no
  ## extrapolation).
  checkPair(x, y, "valueAt")
  if x.len == 1:
    return (if at == x[0]: y[0] else: NaN)
  let ascending = x[^1] >= x[0]
  if ascending and (at < x[0] or at > x[^1]): return NaN
  if not ascending and (at > x[0] or at < x[^1]): return NaN
  for i in 0 ..< x.len - 1:
    let lo = min(x[i], x[i + 1])
    let hi = max(x[i], x[i + 1])
    if at >= lo and at <= hi:
      if x[i + 1] == x[i]: return y[i]
      let f =
        if logX: (log10(at) - log10(x[i])) / (log10(x[i + 1]) - log10(x[i]))
        else: (at - x[i]) / (x[i + 1] - x[i])
      return y[i] + f * (y[i + 1] - y[i])
  NaN

proc corner3dB*(freq, magDb: openArray[float]): float =
  ## The -3 dB corner relative to the *first* swept point (right for
  ## DC-coupled responses). Direction-agnostic.
  checkPair(freq, magDb, "corner3dB")
  interpCrossing(freq, magDb, magDb[0] - 3.0, logX = true)

proc peakIndex(y: openArray[float]): int =
  result = 0
  for i in 1 ..< y.len:
    if y[i] > y[result]: result = i

proc gainMax*(freq, magDb: openArray[float]): tuple[db, hz: float] =
  ## The response's maximum and its frequency: the midband gain of an
  ## AC-coupled stage, whose DC gain is unity by construction. No shape
  ## detection -- on a band-pass it's the passband, on a resonance the peak.
  checkPair(freq, magDb, "gainMax")
  let i = peakIndex(magDb)
  (db: magDb[i], hz: freq[i])

proc bandEdges*(freq, magDb: openArray[float], dropDb = 3.0): tuple[lo, hi: float] =
  ## The frequencies either side of the maximum where the response has
  ## fallen `dropDb` below it -- referenced to the maximum, unlike
  ## `corner3dB`, so it suits AC-coupled stages. A side that never falls
  ## that far is `NaN` (a DC-coupled stage has no lower edge).
  checkPair(freq, magDb, "bandEdges")
  let pk = peakIndex(magDb)
  let level = magDb[pk] - dropDb
  result = (lo: NaN, hi: NaN)

  var i = pk
  while i > 0:
    if magDb[i - 1] <= level:
      result.lo = lerpX(freq[i - 1], freq[i], magDb[i - 1], magDb[i], level, true)
      break
    dec i

  i = pk
  while i < magDb.len - 1:
    if magDb[i + 1] <= level:
      result.hi = lerpX(freq[i], freq[i + 1], magDb[i], magDb[i + 1], level, true)
      break
    inc i

proc unityGainFreq*(freq, magDb: openArray[float]): float =
  ## Where the response crosses 0 dB; `NaN` if it never does in the band.
  interpCrossing(freq, magDb, 0.0, logX = true)

proc maxDeviation*(x, ya, yb: openArray[float],
                   xFrom = 0.0, xTo = 0.0): tuple[dev, at: float] =
  ## The largest `abs(ya[i] - yb[i])` and the `x` where it occurs (e.g. a
  ## channel-match figure in dB). Both curves must share one `x` grid -- the
  ## caller's contract. A `0.0 .. 0.0` window means the whole axis; a window
  ## with no samples gives `NaN`.
  checkPair(x, ya, "maxDeviation")
  checkPair(x, yb, "maxDeviation")
  let windowed = xFrom != 0.0 or xTo != 0.0
  let lo = min(xFrom, xTo)
  let hi = max(xFrom, xTo)
  result = (dev: NaN, at: NaN)
  for i in 0 ..< x.len:
    if windowed and (x[i] < lo or x[i] > hi): continue
    let d = abs(ya[i] - yb[i])
    if result.dev.isNaN or d > result.dev:
      result = (dev: d, at: x[i])

proc harmonicAmplitudes*(t, v: openArray[float], f0: float,
                         upTo = 9): seq[float] =
  ## Amplitudes of the fundamental (`A[0]`, at `f0`) and its harmonics.
  ##
  ## Integrated over the samples' own timestamps (trapezoidal against
  ## cos/sin), not resampled: ngspice takes its smallest steps at fast
  ## edges, where the harmonics are. The window is the **last whole number
  ## of periods** with interpolated endpoints; a fractional period leaks the
  ## fundamental into every bin. Fewer than two periods gives an empty seq.
  checkPair(t, v, "harmonicAmplitudes")
  if f0 <= 0.0 or upTo < 1 or t.len < 4: return @[]

  let period = 1.0 / f0
  let span = t[^1] - t[0]
  let whole = floor(span / period)
  if whole < 2.0: return @[]

  let t1 = t[^1]
  let t0 = t1 - whole * period
  let window = t1 - t0

  # Samples strictly inside the window, with exact interpolated endpoints.
  var ts = @[t0]
  var vs = @[valueAt(t, v, t0)]
  for i in 0 ..< t.len:
    if t[i] > t0 and t[i] < t1:
      ts.add t[i]
      vs.add v[i]
  ts.add t1
  vs.add v[^1]
  if ts.len < 4: return @[]

  for k in 1 .. upTo:
    let w = 2.0 * PI * float(k) * f0
    var a, b = 0.0
    for i in 0 ..< ts.len - 1:
      let dt = ts[i + 1] - ts[i]
      if dt <= 0.0: continue
      a += 0.5 * dt * (vs[i] * cos(w * ts[i]) + vs[i + 1] * cos(w * ts[i + 1]))
      b += 0.5 * dt * (vs[i] * sin(w * ts[i]) + vs[i + 1] * sin(w * ts[i + 1]))
    a *= 2.0 / window
    b *= 2.0 / window
    result.add sqrt(a * a + b * b)

proc thd*(t, v: openArray[float], f0: float, upTo = 9): float =
  ## THD as a **fraction**: RSS of harmonics 2..`upTo` over the fundamental.
  ## `NaN` with no measurable fundamental (not 0%).
  let a = harmonicAmplitudes(t, v, f0, upTo)
  if a.len < 2 or a[0] <= 0.0: return NaN
  var sumSq = 0.0
  for k in 1 ..< a.len: sumSq += a[k] * a[k]
  sqrt(sumSq) / a[0]

proc fundamentalFreq*(t, v: openArray[float], hysteresis = 0.1): float =
  ## The repetition rate of a settled periodic waveform, from rising
  ## crossings of the window **mean** (a single-supply oscillator never
  ## crosses zero). Not an FFT, whose resolution is 1/window; crossing
  ## counts resolve to the timestep. `hysteresis` (fraction of amplitude)
  ## stops a harmonic-rich wave being counted several times per period.
  ##
  ## `NaN` with fewer than two rising crossings -- a circuit that didn't
  ## start, which must stay distinct from 0 Hz.
  checkPair(t, v, "fundamentalFreq")
  if t.len < 4: return NaN

  var lo = v[0]
  var hi = v[0]
  var sum = 0.0
  for x in v:
    if x < lo: lo = x
    if x > hi: hi = x
    sum += x
  let mid = sum / float(v.len)
  let amp = 0.5 * (hi - lo)
  if amp <= 0.0: return NaN
  let band = amp * max(0.0, hysteresis)

  var first, last = NaN
  var count = 0
  var armed = false
  for i in 1 ..< t.len:
    if v[i] < mid - band:
      armed = true
    elif armed and v[i] >= mid and v[i - 1] < mid:
      # Interpolated, so the answer is set by the timestep rather than
      # snapped to it.
      let x = lerpX(t[i - 1], t[i], v[i - 1], v[i], mid, logX = false)
      if count == 0: first = x else: last = x
      inc count
      armed = false
  if count < 2: return NaN
  float(count - 1) / (last - first)

proc swing*(v: openArray[float]): tuple[lo, hi, pp: float] =
  ## The excursion reached: minimum, maximum, peak-to-peak. Separate from
  ## `thd`: a stage can clip on one rail with an unremarkable THD.
  if v.len == 0: return (NaN, NaN, NaN)
  var lo = v[0]
  var hi = v[0]
  for x in v:
    if x < lo: lo = x
    if x > hi: hi = x
  (lo: lo, hi: hi, pp: hi - lo)

proc timeMean*(t, v: openArray[float]): float =
  ## The time-weighted average of `v` (trapezoidal over its own timestamps),
  ## since ngspice samples non-uniformly and a sample mean over-weights
  ## edges. `NaN` for fewer than two samples or zero elapsed time.
  checkPair(t, v, "timeMean")
  if t.len < 2: return NaN
  let span = t[^1] - t[0]
  if span <= 0.0: return NaN
  var acc = 0.0
  for i in 0 ..< t.len - 1:
    let dt = t[i + 1] - t[i]
    if dt <= 0.0: continue
    acc += 0.5 * dt * (v[i] + v[i + 1])
  acc / span

proc timeRms*(t, v: openArray[float]): float =
  ## Time-weighted RMS over the window. The square is integrated exactly per
  ## linear segment (`dt*(v0^2 + v0*v1 + v1^2)/3`), which the trapezoid on
  ## `v*v` overestimates for coarsely sampled triangles.
  checkPair(t, v, "timeRms")
  if t.len < 2: return NaN
  let span = t[^1] - t[0]
  if span <= 0.0: return NaN
  var acc = 0.0
  for i in 0 ..< t.len - 1:
    let dt = t[i + 1] - t[i]
    if dt <= 0.0: continue
    acc += dt * (v[i] * v[i] + v[i] * v[i + 1] + v[i + 1] * v[i + 1]) / 3.0
  let ms = acc / span
  if ms <= 0.0: 0.0 else: sqrt(ms)

proc localMaxima*(x, y: openArray[float]): seq[tuple[x, y: float]] =
  ## Strict interior maxima at sweep resolution (always simulated points; at
  ## 20 points/decade, about +-6% in frequency).
  checkPair(x, y, "localMaxima")
  for i in 1 ..< x.len - 1:
    if y[i] > y[i - 1] and y[i] > y[i + 1]:
      result.add (x: x[i], y: y[i])

proc localMinima*(x, y: openArray[float]): seq[tuple[x, y: float]] =
  ## See `localMaxima` for the resolution caveat.
  checkPair(x, y, "localMinima")
  for i in 1 ..< x.len - 1:
    if y[i] < y[i - 1] and y[i] < y[i + 1]:
      result.add (x: x[i], y: y[i])

proc peak*(t, v: openArray[float]): tuple[t, v: float] =
  ## Global maximum.
  checkPair(t, v, "peak")
  var bi = 0
  for i in 1 ..< v.len:
    if v[i] > v[bi]: bi = i
  (t: t[bi], v: v[bi])

proc peakAbs*(t, v: openArray[float]): tuple[t, v: float] =
  ## Global maximum by magnitude, returning the signed value (probe polarity
  ## is arbitrary).
  checkPair(t, v, "peakAbs")
  var bi = 0
  for i in 1 ..< v.len:
    if abs(v[i]) > abs(v[bi]): bi = i
  (t: t[bi], v: v[bi])

proc riseTime*(t, v: openArray[float], final: float, lo = 0.1, hi = 0.9): float =
  ## Time from the first `lo*final` crossing to the first `hi*final` after
  ## it; `NaN` if either level is never reached.
  checkPair(t, v, "riseTime")
  let tLo = interpCrossing(t, v, lo * final)
  if tLo.isNaN: return NaN
  var startIdx = 0
  while startIdx < t.len - 1 and t[startIdx] < tLo: inc startIdx
  let tHi = interpCrossing(t, v, hi * final, fromIdx = max(startIdx - 1, 0))
  if tHi.isNaN: return NaN
  tHi - tLo

proc overshootFrac*(v: openArray[float], final: float): float =
  ## Peak excursion beyond `final`, as a fraction of it; `0.0` if never
  ## exceeded. Sign-aware.
  if v.len == 0:
    raise newException(ValueError, "overshootFrac: empty input")
  if final == 0.0:
    raise newException(ValueError, "overshootFrac: final value is zero")
  var extreme = v[0]
  for x in v:
    if (final > 0.0 and x > extreme) or (final < 0.0 and x < extreme):
      extreme = x
  let over = (extreme - final) / final
  max(over, 0.0)

proc settleTime*(t, v: openArray[float], final: float, tol = 0.02): float =
  ## The time after which `v` stays within `tol` of `final`; `NaN` if never.
  ## Measured from the last exit from the band, so ringing back out isn't
  ## credited as settled.
  checkPair(t, v, "settleTime")
  if final == 0.0:
    raise newException(ValueError, "settleTime: final value is zero")
  let band = abs(final) * tol
  var lastOut = -1
  for i in 0 ..< v.len:
    if abs(v[i] - final) > band: lastOut = i
  if lastOut < 0: return t[0]
  if lastOut >= v.len - 1: return NaN
  # Interpolate the exact re-entry between the last out-of-band sample and
  # the next one, which is in-band by construction.
  let level = if v[lastOut] > final: final + band else: final - band
  lerpX(t[lastOut], t[lastOut + 1], v[lastOut], v[lastOut + 1], level, logX = false)
