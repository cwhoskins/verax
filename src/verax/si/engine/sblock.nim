## A 2-port S-parameter block (a Touchstone channel: connector, cable,
## backplane) by its impulse response, for the transient engine.
##
## - **Waves.** At each port, referenced to `z0`: incident `a = (v + z0 i)
##   / 2` and reflected `b = (v - z0 i) / 2` (volts; `i` into the block).
##   `b(t) = sum_k S[k] a(t - k dt)`, `S[k]` the 2x2 impulse-response taps.
##   With `S0 = S[0]` and the history `H(t) = sum_{k>=1} S[k] a(t - k dt)`,
##   each step is `(I - S0) v - z0 (I + S0) i = 2 H`, so the block stamps as
##   a conductance matrix `G = (I + S0)^-1 (I - S0) / z0` between its port
##   nodes plus injections `J = 2 (I + S0)^-1 H / z0` -- Bergeron's form,
##   generalised. The past is linearly interpolated from the recorded `a`,
##   so `h <= dt` (the step policy bounds it).
## - **Taps** (`impulseTaps`): the data resampled on an FFT grid of spacing
##   `1 / (n dt)` up to `1 / (2 dt)` (by default the file's top frequency),
##   magnitude and unwrapped phase interpolated linearly, extrapolated to DC
##   as a real value of the lowest point's magnitude; a cosine taper over the
##   top `taper` of the band (Gibbs); inverse DFT; the first half kept (the
##   rest is the non-causal and wrapped part, reported when it holds more
##   than 1 % of the energy). The taps' sum is corrected to `S(0)` so the
##   transient settles where the DC point says.
## - **DC** (`dcTwoPort`): `S(0)` as a pi -- series `B` of its ABCD, shunt
##   `(D - 1) / B` and `(A - 1) / B` (or `C / 2` each for a near-zero `B`).

import std/[math, complex, strutils]
import ../../touchstone/types

type
  SBlock* = object
    p1*, p2*: int
      ## Port nodes (ground-referenced).
    z0*: float
    dt*: float
    taps*: array[4, seq[float]]
      ## `S11, S12, S21, S22` (row-major), each `taps[_][k]` at `k dt`.
    g*: array[4, float]
      ## `G`, row-major.
    m*: array[4, float]
      ## `(I + S0)^-1`, row-major.
    s0dc*: array[4, float]
      ## `S(0)`.
    label*: string

  SBlockState* = object
    t*: seq[float]
    a1*, a2*: seq[float]

  TapsResult* = object
    sb*: SBlock
    nonCausal*: float
      ## Energy fraction outside the kept taps (non-causal or wrapped).
    note*: string

proc inv2(a: array[4, float]): array[4, float] =
  let det = a[0] * a[3] - a[1] * a[2]
  [a[3] / det, -a[1] / det, -a[2] / det, a[0] / det]

proc mul2(a, b: array[4, float]): array[4, float] =
  [a[0] * b[0] + a[1] * b[2], a[0] * b[1] + a[1] * b[3],
   a[2] * b[0] + a[3] * b[2], a[2] * b[1] + a[3] * b[3]]

proc finish(b: var SBlock) =
  ## `G` and `(I + S0)^-1` from the zeroth taps.
  let s0 = [b.taps[0][0], b.taps[1][0], b.taps[2][0], b.taps[3][0]]
  b.m = inv2([1.0 + s0[0], s0[1], s0[2], 1.0 + s0[3]])
  let g = mul2(b.m, [1.0 - s0[0], -s0[1], -s0[2], 1.0 - s0[3]])
  for k in 0 ..< 4: b.g[k] = g[k] / b.z0

proc dcValue(sp: SParams, ij: int): float =
  ## `S(0)`: the lowest point's magnitude, signed by its real part.
  let s = sp.points[0][ij]
  if s.re >= 0: abs(s) else: -abs(s)

proc sampleS(sp: SParams, ij: int, f: float, phase: seq[float], dc: float): Complex64 =
  ## Magnitude and unwrapped phase, linear in frequency; below the first
  ## point both run linearly to the real DC value.
  let fs = sp.freqs
  if f <= fs[0]:
    let x = if fs[0] > 0: f / fs[0] else: 1.0
    let ph0 = if dc >= 0: 0.0 else: PI
    # The DC phase nearest the first point's unwrapped phase.
    let ph0n = ph0 + 2 * PI * round((phase[0] - ph0) / (2 * PI))
    let mag = abs(dc) + (abs(sp.points[0][ij]) - abs(dc)) * x
    let ph = ph0n + (phase[0] - ph0n) * x
    return complex(mag * cos(ph), mag * sin(ph))
  if f >= fs[^1]:
    let s = sp.points[^1][ij]
    return s
  var k = 0
  while k < fs.len - 2 and fs[k + 1] < f: inc k
  let x = (f - fs[k]) / (fs[k + 1] - fs[k])
  let mag = abs(sp.points[k][ij]) + (abs(sp.points[k + 1][ij]) - abs(sp.points[k][ij])) * x
  let ph = phase[k] + (phase[k + 1] - phase[k]) * x
  complex(mag * cos(ph), mag * sin(ph))

proc ifft(x: var seq[Complex64]) =
  ## In-place inverse FFT (radix 2, `x.len` a power of two), scaled by
  ## `1 / n`.
  let n = x.len
  var j = 0
  for i in 1 ..< n:
    var bit = n shr 1
    while (j and bit) != 0:
      j = j xor bit
      bit = bit shr 1
    j = j or bit
    if i < j: swap(x[i], x[j])
  var len = 2
  while len <= n:
    let ang = 2.0 * PI / len.float
    let wl = complex(cos(ang), sin(ang))
    var i = 0
    while i < n:
      var w = complex(1.0, 0.0)
      for k in 0 ..< len div 2:
        let u = x[i + k]
        let v = x[i + k + len div 2] * w
        x[i + k] = u + v
        x[i + k + len div 2] = u - v
        w *= wl
      i += len
    len = len shl 1
  for k in 0 ..< n: x[k] /= complex(n.float, 0.0)

proc impulseTaps*(sp: SParams, a, b: int, dt = NaN, duration = NaN, taper = 0.2,
                  label = ""): TapsResult =
  ## A 2-port block between nodes `a` (port 1) and `b` (port 2).
  ## `dt`: tap spacing (default `1 / (2 f_max)`); `duration`: how long the
  ## response is kept (default `1 / df` of the data, at most 4096 taps).
  assert sp.nPorts == 2
  let fMax = sp.freqs[^1]
  let step = if dt.isNaN: 1.0 / (2.0 * fMax) else: dt
  var df = Inf
  for k in 1 ..< sp.freqs.len: df = min(df, sp.freqs[k] - sp.freqs[k - 1])
  let span = if duration.isNaN: (if df == Inf: 100 * step else: 1.0 / df) else: duration
  let nKeep = nextPowerOfTwo(clamp(int(ceil(span / step)), 8, 4096))
  let nFft = 2 * nKeep
  var blk = SBlock(p1: a, p2: b, z0: sp.z0, dt: step, label: label)
  var energyIn, energyOut: float
  for ij in 0 ..< 4:
    # Unwrapped phase of this entry.
    var phase = newSeq[float](sp.freqs.len)
    for k in 0 ..< sp.freqs.len:
      let p = arctan2(sp.points[k][ij].im, sp.points[k][ij].re)
      if k == 0: phase[k] = p
      else:
        var d = p - phase[k - 1]
        d -= 2 * PI * round(d / (2 * PI))
        phase[k] = phase[k - 1] + d
    let dc = dcValue(sp, ij)
    blk.s0dc[ij] = dc
    # Spectrum on the FFT grid, tapered.
    let fNyq = 1.0 / (2.0 * step)
    var spec = newSeq[Complex64](nFft div 2 + 1)
    for m in 0 .. nFft div 2:
      let f = m.float / (nFft.float * step)
      var s = if m == 0: complex(dc, 0.0) else: sampleS(sp, ij, min(f, fMax), phase, dc)
      if f > fMax: s = complex(0.0, 0.0)
      let edge = (1.0 - taper) * min(fNyq, fMax)
      if f > edge and taper > 0:
        let x = (f - edge) / (min(fNyq, fMax) - edge)
        s *= complex(0.5 * (1.0 + cos(PI * min(x, 1.0))), 0.0)
      spec[m] = s
    # Inverse DFT of the conjugate-symmetric spectrum: a real response.
    var x = newSeq[Complex64](nFft)
    for m in 0 .. nFft div 2:
      x[m] = spec[m]
      if m > 0 and m < nFft div 2: x[nFft - m] = conjugate(spec[m])
    x[nFft div 2] = complex(spec[nFft div 2].re, 0.0)
    ifft(x)
    var h = newSeq[float](nFft)
    for k in 0 ..< nFft: h[k] = x[k].re
    for k in 0 ..< nFft:
      if k < nKeep: energyIn += h[k] * h[k] else: energyOut += h[k] * h[k]
    var kept = h[0 ..< nKeep]
    # Settle exactly at S(0): the lost tail's DC goes onto the main peak.
    var sum = 0.0
    var peak = 0
    for k in 0 ..< nKeep:
      sum += kept[k]
      if abs(kept[k]) > abs(kept[peak]): peak = k
    kept[peak] += dc - sum
    blk.taps[ij] = kept
  blk.finish()
  result.sb = blk
  result.nonCausal = if energyIn + energyOut > 0: energyOut / (energyIn + energyOut) else: 0.0
  result.note = $nKeep & " taps at " & formatFloat(step * 1e12, ffDecimal, 2) & " ps (" &
    formatFloat(nKeep.float * step * 1e9, ffDecimal, 2) & " ns of response), " &
    "cosine taper over the top " & $int(taper * 100) & " % of the band"

proc dcTwoPort*(b: SBlock): tuple[series, shunt1, shunt2: float] =
  ## `S(0)` as a pi: series resistance and a shunt conductance at each port.
  let s = b.s0dc
  let s11 = s[0]
  let s12 = s[1]
  let s21 = s[2]
  let s22 = s[3]
  let z0 = b.z0
  if abs(s21) < 1e-12:
    # No transmission at DC: two one-ports.
    return (Inf, (1 - s11) / ((1 + s11) * z0), (1 - s22) / ((1 + s22) * z0))
  let aa = ((1 + s11) * (1 - s22) + s12 * s21) / (2 * s21)
  let bb = z0 * ((1 + s11) * (1 + s22) - s12 * s21) / (2 * s21)
  let cc = ((1 - s11) * (1 - s22) - s12 * s21) / (2 * s21 * z0)
  let dd = ((1 - s11) * (1 + s22) + s12 * s21) / (2 * s21)
  if abs(bb) < 1e-6 * z0:
    return (max(bb, 0.0), cc / 2, cc / 2)
  (bb, (dd - 1) / bb, (aa - 1) / bb)

proc initState*(b: SBlock, v1, i1, v2, i2: float): SBlockState =
  ## The DC operating point as the whole past.
  result.t = @[0.0]
  result.a1 = @[0.5 * (v1 + b.z0 * i1)]
  result.a2 = @[0.5 * (v2 + b.z0 * i2)]

proc history*(b: SBlock, st: SBlockState, t: float): tuple[h1, h2: float] =
  ## `H(t) = sum_{k>=1} S[k] a(t - k dt)`, the past linearly interpolated
  ## (the DC values before it began).
  let n = b.taps[0].len
  var idx = st.t.len - 1
  for k in 1 ..< n:
    let tq = t - k.float * b.dt
    var x1, x2: float
    if tq <= st.t[0]:
      x1 = st.a1[0]
      x2 = st.a2[0]
    else:
      while idx > 0 and st.t[idx] > tq: dec idx
      if idx >= st.t.len - 1:
        x1 = st.a1[^1]
        x2 = st.a2[^1]
      else:
        let f = (tq - st.t[idx]) / (st.t[idx + 1] - st.t[idx])
        x1 = st.a1[idx] + f * (st.a1[idx + 1] - st.a1[idx])
        x2 = st.a2[idx] + f * (st.a2[idx + 1] - st.a2[idx])
    result.h1 += b.taps[0][k] * x1 + b.taps[1][k] * x2
    result.h2 += b.taps[2][k] * x1 + b.taps[3][k] * x2

proc injections*(b: SBlock, h1, h2: float): tuple[j1, j2: float] =
  ## `J = 2 (I + S0)^-1 H / z0`: injected into each port node.
  ((2.0 / b.z0) * (b.m[0] * h1 + b.m[1] * h2), (2.0 / b.z0) * (b.m[2] * h1 + b.m[3] * h2))

proc record*(st: var SBlockState, b: SBlock, t, v1, v2, j1, j2: float) =
  ## After a step: the currents `i = G v - J`, the incident waves kept.
  let i1 = b.g[0] * v1 + b.g[1] * v2 - j1
  let i2 = b.g[2] * v1 + b.g[3] * v2 - j2
  st.t.add t
  st.a1.add 0.5 * (v1 + b.z0 * i1)
  st.a2.add 0.5 * (v2 + b.z0 * i2)
