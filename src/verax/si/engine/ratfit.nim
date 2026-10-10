## Rational approximation of a sampled transfer function for recursive
## convolution: `F(s) ~ d + sum_i r_i / (s - p_i)` with **real, negative,
## fixed** poles log-spaced over the band, so every term is stable and the
## time-domain kernel is a sum of decaying exponentials.
##
## - Fixed real poles and a linear least-squares fit for the residues (no
##   pole relocation, as in vector fitting). The functions fitted here -- a
##   line's characteristic admittance and its delay-free propagation
##   function -- are smooth and minimum-phase; real poles at a few per
##   decade fit them well, and the residual is reported, not assumed.
## - **The DC value is imposed exactly** (`d` eliminated), so a line's
##   operating point is the model's own steady state.
## - Relative weighting (`1 / max(|F|, floor)`) so a function that goes to
##   zero at DC, like `Yc` of a line with no shunt loss, is fitted in shape
##   and not only in its large values.
## - Least squares by Householder QR on the stacked real/imaginary rows.

import std/[complex, math]

type
  RationalFit* = object
    d*: float
    poles*, residues*: seq[float]
      ## rad/s; `poles[i] < 0`.
    maxErr*: float
      ## Largest `|F_fit - F|` over the samples, as a fraction of the
      ## largest `|F|` (an error where the function is tiny is tiny in the
      ## waveform too).
    fLo*, fHi*: float

proc eval*(f: RationalFit, s: Complex64): Complex64 =
  result = complex(f.d, 0.0)
  for i in 0 ..< f.poles.len:
    result += complex(f.residues[i], 0.0) / (s - complex(f.poles[i], 0.0))

proc dcValue*(f: RationalFit): float =
  result = f.d
  for i in 0 ..< f.poles.len: result -= f.residues[i] / f.poles[i]

proc logPoles*(fLo, fHi: float, perDecade: int): seq[float] =
  ## Real poles `-2 pi f` from `fLo` to `fHi`, `perDecade` per decade.
  let dec = log10(fHi / fLo)
  let n = max(2, int(ceil(dec * perDecade.float)) + 1)
  for k in 0 ..< n:
    result.add -2.0 * PI * fLo * pow(10.0, dec * k.float / (n - 1).float)

proc leastSquares(a: var seq[float], m, n: int, b: var seq[float]): seq[float] =
  ## Solve `min |A x - b|` (row-major `m x n`, `m >= n`) by Householder QR,
  ## in place. Columns are scaled to unit norm first; a column that is all
  ## zero gets a zero coefficient.
  var scale = newSeq[float](n)
  for j in 0 ..< n:
    var s = 0.0
    for i in 0 ..< m: s += a[i * n + j] * a[i * n + j]
    scale[j] = if s > 0: sqrt(s) else: 1.0
    for i in 0 ..< m: a[i * n + j] /= scale[j]
  var diag = newSeq[float](n)
  for k in 0 ..< n:
    var norm = 0.0
    for i in k ..< m: norm += a[i * n + k] * a[i * n + k]
    norm = sqrt(norm)
    if norm == 0.0:
      diag[k] = 0.0
      continue
    let alpha = if a[k * n + k] > 0: -norm else: norm
    # v = x - alpha e1, stored in column k.
    a[k * n + k] -= alpha
    var vnorm2 = 0.0
    for i in k ..< m: vnorm2 += a[i * n + k] * a[i * n + k]
    diag[k] = alpha
    if vnorm2 == 0.0: continue
    for j in k + 1 ..< n:
      var dot = 0.0
      for i in k ..< m: dot += a[i * n + k] * a[i * n + j]
      let f = 2.0 * dot / vnorm2
      for i in k ..< m: a[i * n + j] -= f * a[i * n + k]
    var dot = 0.0
    for i in k ..< m: dot += a[i * n + k] * b[i]
    let f = 2.0 * dot / vnorm2
    for i in k ..< m: b[i] -= f * a[i * n + k]
  result = newSeq[float](n)
  let tiny = 1e-13 * (block:
    var mx = 0.0
    for d in diag: mx = max(mx, abs(d))
    mx)
  for k in countdown(n - 1, 0):
    if abs(diag[k]) <= tiny:
      result[k] = 0.0
      continue
    var acc = b[k]
    for j in k + 1 ..< n: acc -= a[k * n + j] * result[j]
    result[k] = acc / diag[k]
  for j in 0 ..< n: result[j] /= scale[j]

proc fitRational*(freqs: openArray[float], values: openArray[Complex64],
                  dc: float, poles: openArray[float], floor = 0.0): RationalFit =
  ## Fit `values` at `j 2 pi freqs` with `F(0) = dc` exactly. `floor` bounds
  ## the relative weighting from below (default: 1e-3 of the largest
  ## `|F|`).
  let m = freqs.len
  let n = poles.len
  var fmax = abs(dc)
  for v in values: fmax = max(fmax, abs(v))
  let fl = if floor > 0: floor else: 1e-3 * max(fmax, 1e-300)
  # F(s) - F(0) = sum r_i * s / (p_i (s - p_i)).
  var a = newSeq[float](2 * m * n)
  var b = newSeq[float](2 * m)
  for k in 0 ..< m:
    let s = complex(0.0, 2.0 * PI * freqs[k])
    let w = 1.0 / max(abs(values[k]), fl)
    for i in 0 ..< n:
      let phi = s / (complex(poles[i], 0.0) * (s - complex(poles[i], 0.0)))
      a[(2 * k) * n + i] = w * phi.re
      a[(2 * k + 1) * n + i] = w * phi.im
    let rhs = values[k] - complex(dc, 0.0)
    b[2 * k] = w * rhs.re
    b[2 * k + 1] = w * rhs.im
  let r = leastSquares(a, 2 * m, n, b)
  result.poles = @poles
  result.residues = r
  result.d = dc
  for i in 0 ..< n: result.d += r[i] / poles[i]
  if m > 0:
    result.fLo = freqs[0]
    result.fHi = freqs[^1]
  for k in 0 ..< m:
    let s = complex(0.0, 2.0 * PI * freqs[k])
    let e = abs(result.eval(s) - values[k]) / max(fmax, 1e-300)
    result.maxErr = max(result.maxErr, e)
