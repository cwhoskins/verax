## Lossy lines by **recursive convolution** (the universal-line-model form
## of the method of characteristics). With every current flowing *into* the
## line,
##
##   `i_k = Yc * v_k - H * w_m`,   `w_m = Yc * v_m + i_m`
##
## (`*` convolution, `k`/`m` the two ends), where `Yc(s)` is the
## characteristic admittance and `H(s) = exp(-gamma(s) l)` the propagation
## function. `H = exp(-s tau) Hm(s)`: the delay `tau` is taken out exactly
## (the line's asymptotic delay), the rest is fitted (`ratfit`). A lossless
## line is `Yc = 1/Z0`, `Hm = 1`: Bergeron.
##
## - **Each pole is a state** `x' = p x + r u`, advanced **exactly for an
##   input linear over the step**: `x1 = a x0 + r h (phi1 - phi2) u0 + r h
##   phi2 u1`, `a = exp(p h)`, `phi1 = (e^z - 1)/z`, `phi2 = (e^z - 1 - z)
##   /z^2`, `z = p h` (series for small `|z|`). Stable for any step, no
##   ringing; the only discretisation is that linear interpolation.
## - The `Yc * v_k` term involves `v_k` now, so it is a conductance `Geq`
##   plus a history current; `H * w_m` sees `w_m` at least `tau >= h` in the
##   past (the step policy), so it is pure history, interpolated linearly
##   like Bergeron's.
## - **DC**: the operating point uses the line's exact DC two-port (a series
##   `R0 l` when there is no DC shunt loss); every state starts at its
##   steady value for the DC inputs, and both fits carry the exact DC value,
##   so the operating point is the model's own steady state.

import std/[math, algorithm]
import ./ratfit

type
  ConvLine* = object
    a*, b*: int
    yc*, hm*: RationalFit
    tau*: float
    rDc*, gDc*: float
      ## Per metre at DC (the operating point's two-port).
    length*: float
    label*: string

  ConvEnd = object
    xy, xh: seq[float]
      ## Pole states of `Yc * v_k` and of `Hm * u_k` (`u_k = w_m(t - tau)`).
    vPrev, uPrev: float

  ConvState* = object
    ends: array[2, ConvEnd]
    t: seq[float]
    w: array[2, seq[float]]
      ## The wave each end launches, `w_k = Yc * v_k + i_k`, per accepted
      ## step.
    coefH: float
    ay, by0, by1, ah, bh0, bh1: seq[float]
      ## Per-pole step coefficients at step `coefH`.
    geq: float

proc phi(z: float): tuple[p1, p2: float] =
  if abs(z) < 1e-3:
    (1.0 + z / 2 + z * z / 6 + z * z * z / 24,
     0.5 + z / 6 + z * z / 24 + z * z * z / 120)
  else:
    let e = exp(z)
    ((e - 1.0) / z, (e - 1.0 - z) / (z * z))

proc coefficients*(s: var ConvState, ln: ConvLine, h: float) =
  ## Step coefficients for step `h` (cached on `h`).
  if s.coefH == h and s.ay.len == ln.yc.poles.len: return
  s.coefH = h
  proc fill(f: RationalFit, a, b0, b1: var seq[float]) =
    a.setLen f.poles.len
    b0.setLen f.poles.len
    b1.setLen f.poles.len
    for i, p in f.poles:
      let z = p * h
      let (p1, p2) = phi(z)
      a[i] = exp(z)
      b0[i] = f.residues[i] * h * (p1 - p2)
      b1[i] = f.residues[i] * h * p2
  fill(ln.yc, s.ay, s.by0, s.by1)
  fill(ln.hm, s.ah, s.bh0, s.bh1)
  s.geq = ln.yc.d
  for x in s.by1: s.geq += x

proc delayed(s: ConvState, k: int, tq: float): float =
  ## `w_k(tq)`, linearly interpolated; before the first sample, the DC value.
  let t = s.t
  let w = s.w[k]
  if tq <= t[0]: return w[0]
  if tq >= t[^1]: return w[^1]
  let j = upperBound(t, tq) - 1
  w[j] + (w[j + 1] - w[j]) * (tq - t[j]) / (t[j + 1] - t[j])

proc stamp*(s: ConvState, ln: ConvLine, t: float):
    tuple[geq: float, ja, jb: float, ua, ub: float] =
  ## For a step ending at `t` (after `coefficients`): the conductance at
  ## each end and the current injected into each end's node; `ua`/`ub` are
  ## the delayed waves used, for `advance`.
  result.geq = s.geq
  var inj: array[2, float]
  var us: array[2, float]
  for k in 0 .. 1:
    let e = s.ends[k]
    let u = s.delayed(1 - k, t - ln.tau)
    us[k] = u
    var yHist = 0.0
    for i in 0 ..< e.xy.len:
      yHist += s.ay[i] * e.xy[i] + s.by0[i] * e.vPrev
    var hH = ln.hm.d * u
    for i in 0 ..< e.xh.len:
      hH += s.ah[i] * e.xh[i] + s.bh0[i] * e.uPrev + s.bh1[i] * u
    # i_k = geq v_k + yHist - hH flows into the line: inject the rest.
    inj[k] = hH - yHist
  (s.geq, inj[0], inj[1], us[0], us[1])

proc advance*(s: var ConvState, ln: ConvLine, t, va, vb, ua, ub: float) =
  ## Accept a step ending at `t` with end voltages `va`/`vb`.
  let vs = [va, vb]
  let us = [ua, ub]
  var ws: array[2, float]
  for k in 0 .. 1:
    var y = ln.yc.d * vs[k]
    var hH = ln.hm.d * us[k]
    for i in 0 ..< s.ends[k].xy.len:
      let x = s.ay[i] * s.ends[k].xy[i] + s.by0[i] * s.ends[k].vPrev + s.by1[i] * vs[k]
      s.ends[k].xy[i] = x
      y += x
    for i in 0 ..< s.ends[k].xh.len:
      let x = s.ah[i] * s.ends[k].xh[i] + s.bh0[i] * s.ends[k].uPrev + s.bh1[i] * us[k]
      s.ends[k].xh[i] = x
      hH += x
    s.ends[k].vPrev = vs[k]
    s.ends[k].uPrev = us[k]
    # i = y - hH; w = y + i.
    ws[k] = 2.0 * y - hH
  s.t.add t
  s.w[0].add ws[0]
  s.w[1].add ws[1]

proc initState*(ln: ConvLine, va, ia, vb, ib: float): ConvState =
  ## Steady state for the DC operating point: end voltages and the currents
  ## flowing into the line.
  let vs = [va, vb]
  let cur = [ia, ib]
  var w: array[2, float]
  for k in 0 .. 1:
    w[k] = ln.yc.dcValue * vs[k] + cur[k]
  for k in 0 .. 1:
    var e = ConvEnd(vPrev: vs[k], uPrev: w[1 - k])
    for i, p in ln.yc.poles: e.xy.add -ln.yc.residues[i] / p * vs[k]
    for i, p in ln.hm.poles: e.xh.add -ln.hm.residues[i] / p * w[1 - k]
    result.ends[k] = e
  result.t = @[0.0]
  result.w = [@[w[0]], @[w[1]]]
  result.coefH = NaN

proc dcTwoPort*(ln: ConvLine): tuple[series, shuntEach: float] =
  ## The exact DC pi of a uniform line: series `Zc sinh(gl)` and
  ## `tanh(gl/2)/Zc` at each end (`R0 l` and `0` with no DC shunt loss).
  let r = ln.rDc
  let g = ln.gDc
  if g <= 0.0: return (r * ln.length, 0.0)
  let gl = sqrt(r * g) * ln.length
  let zc = sqrt(r / g)
  (zc * sinh(gl), tanh(gl / 2) / zc)
