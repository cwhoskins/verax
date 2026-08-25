## Curve math shared by the simulation-backed analyses in this submodule.
##
## Everything here is a pure function over `openArray[float]` -- no netlist,
## no simulator, no I/O -- so the bulk of each analysis's actual *reasoning*
## is testable with no ngspice on the machine. The analyses themselves stay
## thin: isolate, simulate, then call into here.
##
## **Interpolation on a log axis.** A `dec`-spaced frequency sweep puts
## points at multiplicative intervals, so linear interpolation between two
## adjacent samples is visibly wrong near a corner -- at 20 points/decade
## consecutive frequencies differ by 12%, and reading a -3 dB corner linearly
## biases it high by several percent. Every proc taking a frequency axis
## therefore accepts `logX`, and the frequency-domain wrappers
## (`corner3dB`, `unityGainFreq`) pass `logX = true` for you.
##
## Anything that cannot be found is reported as `NaN` rather than raised or
## silently clamped: "this response never crosses -3 dB in the swept band" is
## a real answer about the circuit, and a caller can test it with `isNaN`.
## Malformed *input* (empty or mismatched arrays) is a caller bug and does
## raise `ValueError`.

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
  ## `y` interpolated at `at`. `NaN` if `at` is outside the swept range --
  ## extrapolating a simulated response past the range that was actually
  ## simulated would be inventing data.
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
  ## The -3 dB corner relative to the *first* swept point, which for a sweep
  ## started well below the corner is the DC/passband value. Works for a
  ## rising response too, since `interpCrossing` is direction-agnostic.
  checkPair(freq, magDb, "corner3dB")
  interpCrossing(freq, magDb, magDb[0] - 3.0, logX = true)

proc peakIndex(y: openArray[float]): int =
  result = 0
  for i in 1 ..< y.len:
    if y[i] > y[result]: result = i

proc gainMax*(freq, magDb: openArray[float]): tuple[db, hz: float] =
  ## The response's maximum, and where in the band it occurs.
  ##
  ## For an AC-coupled stage this is the midband gain -- the number the
  ## circuit was designed around, and the one `gain_dc_db` structurally
  ## cannot report. A single-supply amplifier's gain-setting leg is
  ## capacitively coupled, so its gain at DC is unity *by construction*;
  ## that is what makes single-supply operation possible, not a fault, and a
  ## DC-referenced figure for such a stage is arithmetically correct and
  ## answers nothing anyone would ask.
  ##
  ## Named for what it measures rather than "passband", because no attempt is
  ## made to detect the shape of the response. On a flat-topped band-pass the
  ## maximum *is* the passband; on a resonant peak it is the peak. Guessing
  ## which is which would be a judgement this cannot back up, and the caller
  ## knows their own circuit.
  checkPair(freq, magDb, "gainMax")
  let i = peakIndex(magDb)
  (db: magDb[i], hz: freq[i])

proc bandEdges*(freq, magDb: openArray[float], dropDb = 3.0): tuple[lo, hi: float] =
  ## The frequencies either side of the maximum where the response has fallen
  ## `dropDb` below it.
  ##
  ## Referenced to the **maximum**, which is what makes this a band-pass
  ## answer. `corner3dB` references the *first swept point* and is right for a
  ## DC-coupled low-pass -- where the two agree -- and meaningless for a stage
  ## whose first swept point sits in its own stopband, which every
  ## single-supply audio stage's does.
  ##
  ## A side that never falls that far within the swept band comes back `NaN`.
  ## A DC-coupled stage genuinely has no lower edge, and reporting the bottom
  ## of the sweep as one would be inventing a corner the circuit does not
  ## have -- the same reason nothing here clamps.
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
  ## Where the response crosses 0 dB. `NaN` if it never does in the swept
  ## band -- which for a gain-of-10 amplifier swept only to 10 kHz is the
  ## correct answer, not an error.
  interpCrossing(freq, magDb, 0.0, logX = true)

proc harmonicAmplitudes*(t, v: openArray[float], f0: float,
                         upTo = 9): seq[float] =
  ## Amplitudes of the fundamental and its harmonics, `A[0]` being the
  ## fundamental at `f0`.
  ##
  ## Integrated directly over the samples' own timestamps rather than
  ## resampled onto a uniform grid first. A `.tran` result is **not**
  ## uniformly sampled -- ngspice takes the timestep it needs and takes it
  ## wherever the waveform is moving fastest, which is exactly where a
  ## clipped or slewing edge is -- so resampling would throw away resolution
  ## precisely where the harmonics live. Trapezoidal integration against
  ## cos/sin at each harmonic handles the non-uniform spacing natively.
  ##
  ## The window is the **last whole number of periods** in the data, and that
  ## matters more than it looks: a Fourier integral over a fractional period
  ## leaks the fundamental into every harmonic bin, and a leaked fundamental
  ## reads as distortion the circuit does not have. Endpoints are
  ## interpolated so the window is exact rather than snapped to a sample.
  ##
  ## Fewer than two whole periods yields an empty seq -- there is nothing to
  ## measure, and a number derived from one and a bit periods would be
  ## dominated by where the window happened to fall.
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
  ## Total harmonic distortion as a **fraction**, not a percentage: the
  ## root-sum-square of harmonics 2..`upTo` over the fundamental.
  ##
  ## `NaN` when there is no measurable fundamental -- a silent output, or too
  ## little data to place a window. That reads as "could not measure" rather
  ## than as 0% distortion, which is what a clamped zero would claim.
  let a = harmonicAmplitudes(t, v, f0, upTo)
  if a.len < 2 or a[0] <= 0.0: return NaN
  var sumSq = 0.0
  for k in 1 ..< a.len: sumSq += a[k] * a[k]
  sqrt(sumSq) / a[0]

proc fundamentalFreq*(t, v: openArray[float], hysteresis = 0.1): float =
  ## The repetition rate of a settled periodic waveform, in hertz, from its
  ## rising mean-crossings.
  ##
  ## **This is where an oscillator's specification starts**, and it is
  ## deliberately not a spectral estimate. An FFT's resolution is one over
  ## the window, so a twenty-millisecond window resolves 50 Hz and would
  ## report a 1.59 kHz oscillator to within 3% -- useless against a network
  ## whose whole job is to place that frequency. Counting crossings over the
  ## same window instead gives a resolution set by the *timestep*, which is
  ## nanoseconds, and the answer is the average over every period in the
  ## window rather than the peak of a smeared bin.
  ##
  ## The crossing level is the window's own **mean**, not zero: a
  ## single-supply oscillator sits at mid-rail and has no zero crossings at
  ## all. `hysteresis` is a fraction of the amplitude the waveform must first
  ## fall below before the next rising crossing is counted, which is what
  ## keeps a harmonic-rich wave -- anything clipped, or a relaxation
  ## oscillator's exponential -- from being counted at three times its rate
  ## because it wobbles across the mean on the way up.
  ##
  ## `NaN` when fewer than two rising crossings are found. That is the answer
  ## for a circuit that **did not start**, and it must stay distinguishable
  ## from a frequency of zero: an oscillator sitting at its operating point
  ## is a flat line, and reporting 0 Hz for it would be a measurement where
  ## there was none. See `analysis/transient.analyzeOscillation`, which turns
  ## it into an issue naming the likeliest cause.
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
      # Interpolated so the answer is set by the timestep rather than snapped
      # to it -- on a 1.59 kHz sine sampled every 100 ns, snapping alone is
      # worth 0.016% per crossing and it does not average out.
      let x = lerpX(t[i - 1], t[i], v[i - 1], v[i], mid, logX = false)
      if count == 0: first = x else: last = x
      inc count
      armed = false
  if count < 2: return NaN
  float(count - 1) / (last - first)

proc swing*(v: openArray[float]): tuple[lo, hi, pp: float] =
  ## The excursion actually reached: minimum, maximum, and peak-to-peak.
  ##
  ## Separate from `thd` because they answer different halves of the same
  ## question. A stage can be clipping hard against one rail and symmetric
  ## enough that its distortion figure looks unremarkable, and a stage can
  ## have plenty of headroom and still distort.
  if v.len == 0: return (NaN, NaN, NaN)
  var lo = v[0]
  var hi = v[0]
  for x in v:
    if x < lo: lo = x
    if x > hi: hi = x
  (lo: lo, hi: hi, pp: hi - lo)

proc localMaxima*(x, y: openArray[float]): seq[tuple[x, y: float]] =
  ## Strict interior maxima, at sweep resolution -- no parabolic refinement,
  ## so a reported peak is always an actually-simulated point rather than an
  ## inferred one. Resolution is therefore the sweep's own: at 20 points per
  ## decade a peak frequency is good to about +-6%.
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
  ## Global maximum by magnitude, returning the *signed* value. Inrush
  ## current is measured through an inserted probe source whose polarity
  ## depends on which pin was probed, so "largest current" must not depend on
  ## that arbitrary sign choice while the reported number still shows it.
  checkPair(t, v, "peakAbs")
  var bi = 0
  for i in 1 ..< v.len:
    if abs(v[i]) > abs(v[bi]): bi = i
  (t: t[bi], v: v[bi])

proc riseTime*(t, v: openArray[float], final: float, lo = 0.1, hi = 0.9): float =
  ## Time from the first `lo*final` crossing to the first `hi*final` crossing
  ## after it. `NaN` if either level is never reached -- i.e. if the signal
  ## never got where it was supposed to go.
  checkPair(t, v, "riseTime")
  let tLo = interpCrossing(t, v, lo * final)
  if tLo.isNaN: return NaN
  var startIdx = 0
  while startIdx < t.len - 1 and t[startIdx] < tLo: inc startIdx
  let tHi = interpCrossing(t, v, hi * final, fromIdx = max(startIdx - 1, 0))
  if tHi.isNaN: return NaN
  tHi - tLo

proc overshootFrac*(v: openArray[float], final: float): float =
  ## Peak excursion beyond `final`, as a fraction of it. `0.0` when the
  ## signal never exceeds `final`. Sign-aware, so it works for a negative
  ## rail too.
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
  ## The time after which `v` stays within `tol` (fractional) of `final` for
  ## the rest of the record. `NaN` if it never does. Measured as "last exit
  ## from the band" rather than "first entry", so a response that enters the
  ## band and then rings back out is not credited with settling early.
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
