import std/[math, strutils, unittest]

import nimcir/analysis/measure
import nimcir/analysis/report

# --- analytically generated curves -------------------------------------

const
  R = 1000.0
  C = 100e-9
  tau = R * C                       # 100 us
  fc = 1.0 / (2.0 * PI * tau)       # 1591.549... Hz

proc rcSweep(ptsPerDecade: int, fStart, fStop: float): tuple[f, magDb, phase: seq[float]] =
  ## Exact first-order low-pass response, so every extraction below is
  ## checked against closed form rather than against another simulation.
  let n = int(round(float(ptsPerDecade) * log10(fStop / fStart)))
  for k in 0 .. n:
    let f = fStart * pow(10.0, float(k) / float(ptsPerDecade))
    let w = f / fc
    result.f.add f
    result.magDb.add 20.0 * log10(1.0 / sqrt(1.0 + w * w))
    result.phase.add(-radToDeg(arctan(w)))

proc stepResponse(tStop: float, n: int, final: float): tuple[t, v: seq[float]] =
  ## v(t) = final * (1 - e^(-t/tau)); 10-90% rise time is exactly tau*ln(9).
  for k in 0 .. n:
    let t = tStop * float(k) / float(n)
    result.t.add t
    result.v.add final * (1.0 - exp(-t / tau))

# --- frequency-domain extraction ---------------------------------------

test "corner3dB recovers the exact RC corner from a decade sweep":
  let s = rcSweep(20, 10.0, 1e6)
  let got = corner3dB(s.f, s.magDb)
  check abs(got - fc) / fc < 0.005

test "logX interpolates geometrically, not arithmetically":
  # Halfway (in y) between decade-spaced samples is the geometric mean on a
  # log axis, not the arithmetic one. This is the whole reason the frequency
  # extractors pass logX = true.
  let x = @[100.0, 1000.0]
  let y = @[0.0, 10.0]
  check abs(interpCrossing(x, y, 5.0, logX = true) - sqrt(100.0 * 1000.0)) < 1e-9
  check abs(interpCrossing(x, y, 5.0, logX = false) - 550.0) < 1e-9

test "valueAt interpolates on the log axis and refuses to extrapolate":
  let s = rcSweep(20, 10.0, 1e6)
  check abs(valueAt(s.f, s.phase, fc, logX = true) - (-45.0)) < 0.05
  check valueAt(s.f, s.magDb, 1e9, logX = true).isNaN
  check valueAt(s.f, s.magDb, 0.1, logX = true).isNaN

test "unityGainFreq finds the 0 dB crossing, and reports NaN when there isn't one":
  let f = @[1.0, 10.0, 100.0, 1000.0]
  let g = @[20.0, 20.0, 6.0206, -20.0]     # crosses 0 dB between 100 and 1k
  let fu = unityGainFreq(f, g)
  check fu > 100.0 and fu < 1000.0
  check unityGainFreq(f, @[20.0, 20.0, 19.0, 18.0]).isNaN

test "interpCrossing catches a rising crossing, not just a falling one":
  check abs(interpCrossing(@[1.0, 2.0], @[-10.0, 10.0], 0.0) - 1.5) < 1e-12

# --- maxDeviation: two curves on one axis ------------------------------

test "maxDeviation reports the worst point and the x that witnesses it":
  let x  = @[1.0, 2.0, 3.0, 4.0, 5.0]
  let ya = @[0.0, 1.0, 2.0, 3.0, 4.0]
  let yb = @[0.0, 1.1, 1.5, 3.0, 4.2]
  let (dev, at) = maxDeviation(x, ya, yb)
  check abs(dev - 0.5) < 1e-12      # at x = 3
  check at == 3.0

test "the window restricts which samples are compared":
  let x  = @[10.0, 100.0, 1000.0, 10000.0]
  let ya = @[0.0, 0.0, 0.0, 0.0]
  let yb = @[9.0, 1.0, 2.0, 8.0]
  # Over the whole axis the worst is 9 at 10 Hz; inside 50 .. 5000 it is 2.
  check maxDeviation(x, ya, yb).dev == 9.0
  let (dev, at) = maxDeviation(x, ya, yb, 50.0, 5000.0)
  check dev == 2.0
  check at == 1000.0

test "a window with no sample in it is NaN, not a clamped endpoint":
  let x  = @[10.0, 100.0, 1000.0]
  let ya = @[0.0, 0.0, 0.0]
  let yb = @[1.0, 2.0, 3.0]
  check maxDeviation(x, ya, yb, 200.0, 900.0).dev.isNaN
  check maxDeviation(x, ya, yb, 200.0, 900.0).at.isNaN

test "mismatched lengths are a caller bug and raise":
  expect ValueError:
    discard maxDeviation(@[1.0, 2.0], @[1.0, 2.0], @[1.0])
  expect ValueError:
    discard maxDeviation(@[1.0], @[1.0, 2.0], @[1.0])

test "corner3dB on a high-pass reports NaN rather than a bogus corner":
  var f, g: seq[float]
  for k in 0 .. 60:
    let fr = 10.0 * pow(10.0, float(k) / 20.0)
    let w = fr / fc
    f.add fr
    g.add 20.0 * log10(w / sqrt(1.0 + w * w))
  # Passband is at the *top* here, so the -3 dB point relative to the first
  # swept sample does not exist; the reference is the low-frequency value.
  check corner3dB(f, g).isNaN

test "localMaxima and localMinima find interior extrema only":
  let x = @[1.0, 2.0, 3.0, 4.0, 5.0]
  let y = @[0.0, 5.0, 1.0, 4.0, 9.0]
  let mx = localMaxima(x, y)
  check mx.len == 1
  check mx[0] == (x: 2.0, y: 5.0)
  let mn = localMinima(x, y)
  check mn.len == 1
  check mn[0] == (x: 3.0, y: 1.0)
  # y[3] = 4 rises into the endpoint y[4] = 9, so it is not an interior
  # maximum, and the endpoint itself is never reported -- a peak at the edge
  # of the swept band is not known to be a peak.

# --- time-domain extraction --------------------------------------------

test "riseTime recovers tau*ln(9) from an exponential step":
  let s = stepResponse(10.0 * tau, 20000, 3.3)
  let expected = tau * ln(9.0)
  check abs(riseTime(s.t, s.v, 3.3) - expected) / expected < 0.001

test "riseTime is NaN when the signal never reaches the high threshold":
  let s = stepResponse(0.5 * tau, 2000, 3.3)   # only gets to ~39%
  check riseTime(s.t, s.v, 3.3).isNaN

test "overshootFrac is zero for a monotonic step and correct for a ringing one":
  let s = stepResponse(10.0 * tau, 2000, 3.3)
  check overshootFrac(s.v, 3.3) == 0.0
  check abs(overshootFrac(@[0.0, 3.0, 3.6, 3.4, 3.3], 3.3) - 0.3 / 3.3) < 1e-12

test "overshootFrac is sign-aware for a negative rail":
  check abs(overshootFrac(@[0.0, -5.0, -5.6, -5.2, -5.0], -5.0) - 0.6 / 5.0) < 1e-12

test "settleTime measures the last exit from the band, not the first entry":
  let t = @[0.0, 1.0, 2.0, 3.0, 4.0, 5.0]
  # Enters the 2% band at t=1, rings back out at t=2, final re-entry at t=3.
  let v = @[0.0, 1.0, 1.5, 1.0, 1.0, 1.0]
  let ts = settleTime(t, v, 1.0, tol = 0.02)
  check ts > 2.0 and ts <= 3.0

test "settleTime is NaN when the record ends out of band":
  check settleTime(@[0.0, 1.0, 2.0], @[0.0, 0.5, 0.7], 1.0).isNaN

test "peak vs peakAbs: probe polarity must not change which point is found":
  let t = @[0.0, 1.0, 2.0, 3.0]
  let i = @[0.0, -2.5, 1.0, 0.2]
  check peak(t, i) == (t: 2.0, v: 1.0)
  check peakAbs(t, i) == (t: 1.0, v: -2.5)

# --- malformed input ---------------------------------------------------

test "mismatched or empty inputs raise rather than returning a wrong number":
  expect(ValueError):
    discard interpCrossing(@[1.0, 2.0], @[1.0], 0.5)
  expect(ValueError):
    discard peak(@[], @[])
  expect(ValueError):
    discard settleTime(@[0.0, 1.0], @[1.0, 1.0], 0.0)

# --- report plumbing ---------------------------------------------------

test "AnalysisReport lookup distinguishes 'not measured' from 'measured as NaN'":
  var r = AnalysisReport(name: "t")
  r.add "bw_3db", NaN, "Hz"
  check r.hasMeasurement("bw_3db")
  check r["bw_3db"].isNaN
  expect(KeyError):
    discard r["f_unity"]

test "worstSeverity picks the highest severity present":
  var r = AnalysisReport(name: "t")
  check r.worstSeverity == sevInfo
  r.issues.add newIssue("a", sevWarning, "w")
  r.issues.add newIssue("b", sevError, "e")
  check r.worstSeverity == sevError

test "a report prints its assumptions alongside its measurements":
  var r = AnalysisReport(name: "pdn")
  r.add "z_min", 0.012, "ohm"
  r.assumptions.add assumption("C1", "esl", 0.5e-9, "H", annDefaulted,
                               "from package default (0402)")
  let s = $r
  check "z_min" in s
  check "0402" in s
  check "500 pH" in s
  check "assumptions" in s

test "invented() separates what was assumed from what the design stated":
  var r = AnalysisReport(name: "pdn")
  r.assumptions.add assumption("C1", "esr", 0.02, "ohm", annAuthored, "as annotated")
  r.assumptions.add assumption("C2", "esl", 1e-9, "H", annDefaulted, "from a default")
  r.assumptions.add note("U1 was cut at the boundary")
  check r.assumptions.len == 3
  check r.invented.len == 2      # the authored one does not count

# --- band-referenced extraction ----------------------------------------

proc bandpassSweep(ptsPerDecade: int, fStart, fStop, fLo, fHi, gain: float):
    tuple[f, magDb: seq[float]] =
  ## A single-pole high-pass cascaded with a single-pole low-pass, at gain
  ## `gain` in the midband. Exact, so the extractions below are checked
  ## against closed form. This is the shape of every AC-coupled stage.
  let n = int(round(float(ptsPerDecade) * log10(fStop / fStart)))
  for k in 0 .. n:
    let f = fStart * pow(10.0, float(k) / float(ptsPerDecade))
    let hp = (f / fLo) / sqrt(1.0 + pow(f / fLo, 2.0))
    let lp = 1.0 / sqrt(1.0 + pow(f / fHi, 2.0))
    result.f.add f
    result.magDb.add 20.0 * log10(gain * hp * lp)

test "gainMax reports the midband gain a DC-referenced figure cannot":
  # 100 Hz to 10 kHz at a gain of 20, sampled densely enough that the peak
  # lands near the geometric centre of the band.
  let s = bandpassSweep(200, 1.0, 1.0e6, 100.0, 10.0e3, 20.0)
  let g = gainMax(s.f, s.magDb)
  # Midband gain is 20x = 26.02 dB, less the small loss from each pole at
  # the band centre.
  check abs(g.db - 26.02) < 0.15
  check abs(g.hz - 1000.0) / 1000.0 < 0.05     # geometric centre of 100..10k
  # And the DC-referenced figure, for contrast: the first swept point is in
  # the stopband, so it says the stage has essentially no gain.
  check s.magDb[0] < 0.0

test "bandEdges finds both corners of an AC-coupled response":
  let s = bandpassSweep(200, 1.0, 1.0e6, 100.0, 10.0e3, 20.0)
  let e = bandEdges(s.f, s.magDb)
  check abs(e.lo - 100.0) / 100.0 < 0.03
  check abs(e.hi - 10.0e3) / 10.0e3 < 0.03

test "a DC-coupled response has no lower edge, and says so":
  # Reporting the bottom of the sweep as a corner would be inventing one.
  let s = rcSweep(50, 1.0, 1.0e6)
  let e = bandEdges(s.f, s.magDb)
  check e.lo.isNaN
  check abs(e.hi - fc) / fc < 0.01

test "on a DC-coupled response the upper edge agrees with corner3dB":
  # The two references coincide exactly when the first swept point *is* the
  # passband, which is what makes keeping both honest rather than redundant.
  let s = rcSweep(50, 1.0, 1.0e6)
  check abs(bandEdges(s.f, s.magDb).hi - corner3dB(s.f, s.magDb)) / fc < 0.01

test "bandEdges is measured from the maximum, not from the first point":
  # The sharpest version of why the two references are not interchangeable.
  # `corner3dB` looks for 3 dB below the *first swept point*, which here is
  # the bottom of the stopband -- and the response never goes lower, so it
  # reports no corner at all. The band-referenced pair finds both.
  #
  # A real stage can be worse than this rather than better: the TS808 drive
  # stage does fall back past its own starting point at high frequency, so
  # `corner3dB` returns a confident 710 kHz measured 3 dB below *unity*, on
  # the far side of a passband that ends at 7 kHz.
  let s = bandpassSweep(200, 1.0, 1.0e6, 100.0, 10.0e3, 20.0)
  let e = bandEdges(s.f, s.magDb)
  check corner3dB(s.f, s.magDb).isNaN
  check abs(e.lo - 100.0) / 100.0 < 0.03
  check abs(e.hi - 10.0e3) / 10.0e3 < 0.03

# --- large-signal extraction -------------------------------------------

proc distorted(f0, a2, a3: float; n: int; periods: float;
               jitter = false): tuple[t, v: seq[float]] =
  ## A fundamental plus stated 2nd and 3rd harmonics, so THD is known in
  ## closed form: sqrt(a2^2 + a3^2) / 1.
  var rng = 12345
  for k in 0 .. n:
    var frac = float(k) / float(n)
    if jitter and k > 0 and k < n:
      # Deterministic non-uniform spacing, standing in for an adaptive
      # timestep -- the case a resampling implementation would blur.
      rng = (rng * 1103515245 + 12345) and 0x7fffffff
      frac += (float(rng mod 1000) / 1000.0 - 0.5) * 0.8 / float(n)
    let t = frac * periods / f0
    result.t.add t
    result.v.add sin(2.0 * PI * f0 * t) +
                 a2 * sin(2.0 * PI * 2.0 * f0 * t) +
                 a3 * sin(2.0 * PI * 3.0 * f0 * t)

test "thd recovers a known harmonic content":
  let s = distorted(1000.0, 0.1, 0.05, 4000, 8.0)
  # sqrt(0.1^2 + 0.05^2) = 0.1118
  check abs(thd(s.t, s.v, 1000.0) - 0.1118) < 0.002

test "the harmonic amplitudes themselves come back":
  let s = distorted(1000.0, 0.1, 0.05, 4000, 8.0)
  let a = harmonicAmplitudes(s.t, s.v, 1000.0, 5)
  check abs(a[0] - 1.0) < 0.01
  check abs(a[1] - 0.1) < 0.005
  check abs(a[2] - 0.05) < 0.005
  check a[3] < 0.01        # no 4th harmonic was put in
  check a[4] < 0.01

test "non-uniform sampling is integrated, not resampled":
  # A .tran result is never uniformly sampled, and the timestep shrinks
  # exactly where the harmonics live.
  let s = distorted(1000.0, 0.1, 0.05, 4000, 8.0, jitter = true)
  check abs(thd(s.t, s.v, 1000.0) - 0.1118) < 0.004

test "a pure sine has essentially no distortion":
  let s = distorted(1000.0, 0.0, 0.0, 4000, 8.0)
  check thd(s.t, s.v, 1000.0) < 0.002

test "the window is a whole number of periods, so nothing leaks":
  # Over a fractional window the fundamental leaks into every harmonic bin
  # and reads as distortion the circuit does not have. 8.37 periods of a
  # pure sine must still measure as clean.
  let s = distorted(1000.0, 0.0, 0.0, 4000, 8.37)
  check thd(s.t, s.v, 1000.0) < 0.01

test "too little data is NaN, not a confident zero":
  let s = distorted(1000.0, 0.1, 0.05, 200, 1.2)
  check thd(s.t, s.v, 1000.0).isNaN

test "a silent output has no fundamental to measure against":
  var t, v: seq[float]
  for k in 0 .. 1000:
    t.add float(k) * 1e-5
    v.add 0.0
  check thd(t, v, 1000.0).isNaN

test "swing reports the excursion actually reached":
  let s = distorted(1000.0, 0.0, 0.0, 4000, 8.0)
  let sw = swing(s.v)
  check abs(sw.hi - 1.0) < 0.01
  check abs(sw.lo + 1.0) < 0.01
  check abs(sw.pp - 2.0) < 0.02

# --- fundamentalFreq ----------------------------------------------------

proc periodic(f0, offset: float; n: int; periods: float;
              shape: proc (phase: float): float {.closure.}): tuple[t, v: seq[float]] =
  for k in 0 .. n:
    let t = float(k) / float(n) * periods / f0
    result.t.add t
    result.v.add offset + shape(2.0 * PI * f0 * t)

test "fundamentalFreq recovers a sine's rate from its mean crossings":
  let s = periodic(1584.3, 0.0, 8000, 30.0, proc (p: float): float = sin(p))
  check abs(fundamentalFreq(s.t, s.v) - 1584.3) < 0.5

test "the crossing level is the mean, not zero -- a single-supply oscillator never reaches zero":
  # Offset well clear of ground, which is what a mid-rail-biased oscillator
  # looks like. A zero-crossing detector finds nothing here at all.
  let s = periodic(1584.3, 2.5, 8000, 30.0, proc (p: float): float = sin(p))
  check abs(fundamentalFreq(s.t, s.v) - 1584.3) < 0.5

test "hysteresis keeps a harmonic-rich wave from counting three times its rate":
  # A fundamental with a 3rd harmonic 70% of it crosses the mean six times a
  # period, not twice. Without the hysteresis band this reads 3*f0.
  let s = periodic(1000.0, 0.0, 20000, 30.0,
                   proc (p: float): float = sin(p) + 0.7 * sin(3.0 * p))
  check abs(fundamentalFreq(s.t, s.v) - 1000.0) < 2.0

test "a square wave is measured as readily as a sine":
  let s = periodic(400.0, 0.0, 20000, 30.0,
                   proc (p: float): float = (if sin(p) >= 0.0: 1.0 else: -1.0))
  check abs(fundamentalFreq(s.t, s.v) - 400.0) < 1.0

test "a flat line is NaN, not 0 Hz -- an oscillator that did not start":
  var t, v: seq[float]
  for k in 0 .. 1000:
    t.add float(k) * 1e-5
    v.add 3.3
  check fundamentalFreq(t, v).isNaN

test "less than two crossings is NaN rather than a rate from one":
  let s = periodic(1000.0, 0.0, 400, 0.9, proc (p: float): float = sin(p))
  check fundamentalFreq(s.t, s.v).isNaN

# --- time-weighted window statistics -----------------------------------

test "timeMean weights by elapsed time, not by sample count":
  # A square wave, 25% high at 4 V and 75% low at 0, sampled *densely* over
  # the high part and sparsely over the low part -- which is what ngspice
  # does around an edge. The time-weighted answer is 1 V; a plain mean over
  # these samples is 2.9 V, because most of the samples sit on the quarter of
  # the period that is high.
  var t, v: seq[float]
  for k in 0 .. 100:                      # 0 .. 25 us, dense
    t.add float(k) * 0.25e-6
    v.add 4.0
  for k in 1 .. 5:                        # 25 .. 100 us, sparse
    t.add 25.0e-6 + float(k) * 15.0e-6
    v.add 0.0
  # The step down lands between two samples, so the trapezoid spreads it over
  # the first sparse interval: 4 V for 25 us plus the ramp's 15 us at a mean
  # of 2 V, over 100 us.
  check abs(timeMean(t, v) - 1.3) < 1e-9
  var plain = 0.0
  for x in v: plain += x
  check plain / float(v.len) > 2.5        # what sample-counting would say

test "timeRms integrates the square exactly for a triangle":
  # A symmetric triangle of amplitude 1 has an RMS of 1/sqrt(3), and it is the
  # shape a converter's inductor ripple takes -- sampled coarsely between
  # corners, which is exactly where the trapezoid rule over v*v is worst.
  # Four samples per period is deliberately brutal.
  var t, v: seq[float]
  let period = 1.0e-6
  for k in 0 .. 40:
    t.add float(k) * period / 4.0
    v.add(case k mod 4
          of 0: 0.0
          of 1: 1.0
          of 2: 0.0
          else: -1.0)
  check abs(timeRms(t, v) - 1.0 / sqrt(3.0)) < 1e-9
  # What a trapezoid over v*v would have said, for contrast: the square of a
  # triangle is a parabola, and joining its samples with straight lines
  # overestimates by 22% -- 0.7071 against 0.5774, which would read as a part
  # running hotter than it does.
  var trap = 0.0
  for i in 0 ..< t.len - 1:
    trap += 0.5 * (t[i + 1] - t[i]) * (v[i] * v[i] + v[i + 1] * v[i + 1])
  check abs(sqrt(trap / (t[^1] - t[0])) - 1.0 / sqrt(2.0)) < 1e-9

test "a DC level is its own mean and its own RMS":
  var t, v: seq[float]
  for k in 0 .. 50:
    t.add float(k) * 1e-6
    v.add(-2.5)
  check abs(timeMean(t, v) + 2.5) < 1e-12
  check abs(timeRms(t, v) - 2.5) < 1e-12

test "a window of no elapsed time is NaN, not zero":
  check timeMean([1.0], [3.0]).isNaN
  check timeRms([1.0], [3.0]).isNaN
  check timeMean([1.0, 1.0], [3.0, 3.0]).isNaN
