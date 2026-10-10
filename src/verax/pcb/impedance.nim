## Closed-form transmission-line cross-section: characteristic impedance,
## per-metre RLGC and propagation for a microstrip or stripline stated as
## plain numbers.
##
## **Pure numeric, no `Pcb`**, so formulas are checkable against textbook
## examples; `pcb/tline.specFor` builds the `LineSpec`.
##
## **Accuracy ceiling**: quasi-static closed forms (Hammerstad-Jensen,
## IPC-2141), accurate to a few percent within their validated range, with
## no dispersion (`epsEff` is frequency-independent). A few percent off a
## field solver is expected.
import std/[math, complex]

type
  LineGeometry* = enum
    lgMicrostrip, lgCoveredMicrostrip, lgStripline, lgAsymStripline,
    lgEdgeCoupledMicrostrip, lgEdgeCoupledStripline

  LineSpec* = object
    geometry*: LineGeometry
    w*, t*: float
      ## Trace width and copper thickness, metres.
    h1*, h2*: float
      ## Dielectric to the near reference (`h1`) and, for stripline, the far
      ## one (`h2`).
    s*: float
      ## Edge-to-edge gap, metres -- coupled geometries only.
    er*, tand*: float
    rho*: float
      ## Conductor resistivity, ohm-metre (copper `1.72e-8`). Stated by the
      ## caller; the default and its `Assumption` live in `pcb/tline`.
    roughness*: float
      ## RMS copper roughness, metres; `0` is smooth. The caller records a
      ## default as an assumption.

const
  Eta0 = 376.730313668
    ## Free-space wave impedance `sqrt(mu0/eps0)`, exact rather than the
    ## `120*pi` shorthand.
  Mu0 = 4.0 * PI * 1e-7
  SpeedOfLight = 299_792_458.0

# ---------------------------------------------------------------- microstrip

proc effectiveWidth(w, h, t: float): float =
  ## Hammerstad thickness correction: a thick trace presents more edge than
  ## the zero-thickness formula assumes.
  if t <= 0.0 or h <= 0.0: return w
  let dw =
    if w / h <= 1.0 / (2.0 * PI):
      (1.25 / PI) * t * (1.0 + ln(2.0 * h / t))
    else:
      (1.25 / PI) * t * (1.0 + ln(2.0 * w / t))
  w + dw

proc microstripU(spec: LineSpec): float =
  effectiveWidth(spec.w, spec.h1, spec.t) / spec.h1

proc hammerstadJensenEpsEff(u, er: float): float =
  let a = 1.0 + (1.0 / 49.0) * ln((pow(u, 4) + pow(u / 52.0, 2)) /
                                   (pow(u, 4) + 0.432)) +
          (1.0 / 18.7) * ln(1.0 + pow(u / 18.1, 3))
  let b = 0.564 * pow((er - 0.9) / (er + 3.0), 0.053)
  (er + 1.0) / 2.0 + (er - 1.0) / 2.0 * pow(1.0 + 10.0 / u, -a * b)

proc hammerstadJensenZ0Air(u: float): float =
  let f = 6.0 + (2.0 * PI - 6.0) * exp(-pow(30.666 / u, 0.7528))
  (Eta0 / (2.0 * PI)) * ln(f / u + sqrt(1.0 + pow(2.0 / u, 2)))

const TypicalSolderMaskEr* = 3.3
  ## A representative soldermask permittivity (mid of the 3.0-4.0 range),
  ## never read off a board. Separate from `LineSpec.er` (the substrate), so
  ## one field never means two materials. `tline.characterize` records it as
  ## an `Assumption`.

proc coveredEpsEffCorrection(spec: LineSpec, epsEffBare: float): float =
  ## `lgCoveredMicrostrip`'s mask correction: the mask fills part of the
  ## fringing field, pulling `epsEff` toward `TypicalSolderMaskEr` by a
  ## bounded fraction set by mask thickness relative to height.
  let blend = clamp(spec.t / (spec.t + spec.h1), 0.0, 1.0) * 0.5
  epsEffBare + (TypicalSolderMaskEr - epsEffBare) * blend

proc epsEff*(spec: LineSpec): float =
  ## The effective permittivity the wave sees, between bulk `er` (fully
  ## embedded) and 1.0 (air).
  case spec.geometry
  of lgMicrostrip, lgEdgeCoupledMicrostrip:
    hammerstadJensenEpsEff(microstripU(spec), spec.er)
  of lgCoveredMicrostrip:
    coveredEpsEffCorrection(spec, hammerstadJensenEpsEff(microstripU(spec), spec.er))
  of lgStripline, lgAsymStripline, lgEdgeCoupledStripline:
    ## Homogeneous dielectric: `epsEff == er` exactly.
    spec.er

proc z0Microstrip(spec: LineSpec): float =
  let u = microstripU(spec)
  hammerstadJensenZ0Air(u) / sqrt(epsEff(spec))

# ---------------------------------------------------------------- stripline

proc z0StriplineIpc2141(w, t, b, er: float): float =
  ## IPC-2141 stripline, `Z0 = (60/sqrt(er)) * ln(1.9*b/(0.8*w+t))`, `b` the
  ## plane spacing. Valid for a centred trace; also used for
  ## `lgAsymStripline` with `b = h1 + h2`, without Cohn's offset correction
  ## (the sharpest accuracy edge here -- hence a separate enum value).
  (60.0 / sqrt(er)) * ln(1.9 * b / (0.8 * w + t))

proc z0*(spec: LineSpec): float =
  ## Quasi-static single-ended characteristic impedance.
  case spec.geometry
  of lgMicrostrip, lgCoveredMicrostrip:
    z0Microstrip(spec)
  of lgStripline, lgAsymStripline:
    z0StriplineIpc2141(spec.w, spec.t, spec.h1 + spec.h2, spec.er)
  of lgEdgeCoupledMicrostrip:
    z0Microstrip(LineSpec(geometry: lgMicrostrip, w: spec.w, t: spec.t,
                          h1: spec.h1, er: spec.er))
  of lgEdgeCoupledStripline:
    z0StriplineIpc2141(spec.w, spec.t, spec.h1 + spec.h2, spec.er)

# ---------------------------------------------------------------- coupled lines

type
  CoupledModes* = object
    ## Even and odd modes of a symmetric edge-coupled pair, per line.
    zEven*, zOdd*: float
      ## Ohms: one line's impedance with both driven alike / opposite.
    epsEven*, epsOdd*: float
      ## Each mode's effective permittivity: its delay is
      ## `sqrt(eps)/c` per metre. Equal in a homogeneous stripline (no
      ## far-end crosstalk); in microstrip the odd mode is faster.
    inRange*: bool
      ## Inside the formulas' validated range (microstrip: `0.1 <= w/h,
      ## s/h <= 10`, `er <= 18`); outside they extrapolate.

proc agm(a0, b0: float): float =
  var a = a0
  var b = b0
  for _ in 0 ..< 60:
    let an = 0.5 * (a + b)
    b = sqrt(a * b)
    a = an
    if abs(a - b) <= 1e-15 * a: break
  a

proc kRatio(k: float): float =
  ## `K(k) / K(k')` by the arithmetic-geometric mean (`K(k) = pi /
  ## (2 agm(1, k'))`).
  let kp = sqrt(max(1.0 - k * k, 0.0))
  agm(1.0, k) / agm(1.0, kp)

proc coupledStripline(spec: LineSpec): CoupledModes =
  ## Cohn (1955), exact for zero-thickness strips centred between planes
  ## `b = h1 + h2` apart: `Z = 30 pi / sqrt(er) * K(k)/K(k')` with
  ## `k_e = tanh(pi w/2b) tanh(pi (w+s)/2b)`, `k_o = tanh(pi w/2b)
  ## coth(pi (w+s)/2b)` read as `K(k')/K(k)`. Both modes are scaled by the
  ## IPC-2141 single line over Cohn's zero-thickness single line, so the
  ## pair agrees with `z0` as `s` grows (thickness through that ratio).
  let b = spec.h1 + spec.h2
  let x = PI * spec.w / (2.0 * b)
  let y = PI * (spec.w + max(spec.s, 1e-12)) / (2.0 * b)
  let pre = 30.0 * PI / sqrt(spec.er)
  let single0 = pre * kRatio(1.0 / cosh(x))
  let scale = z0StriplineIpc2141(spec.w, spec.t, b, spec.er) / single0
  let ke = tanh(x) * tanh(y)
  let ko = tanh(x) / tanh(y)
  result.zEven = scale * pre / kRatio(ke)
  result.zOdd = scale * pre / kRatio(ko)
  result.epsEven = spec.er
  result.epsOdd = spec.er
  result.inRange = true

proc coupledMicrostrip(spec: LineSpec): CoupledModes =
  ## Kirschning and Jansen (1984), static: each mode's `epsEff` and
  ## impedance from the single line's (Hammerstad-Jensen, the same `u`
  ## with Hammerstad's thickness correction as `z0`). No dispersion, like
  ## the rest of this module.
  let u = microstripU(spec)
  let g = max(spec.s, 1e-6 * spec.h1) / spec.h1
  let er = spec.er
  let ee = hammerstadJensenEpsEff(u, er)
  let zl = hammerstadJensenZ0Air(u) / sqrt(ee)
  # Even mode.
  let v = u * (20.0 + g * g) / (10.0 + g * g) + g * exp(-g)
  result.epsEven = hammerstadJensenEpsEff(v, er)
  # Odd mode.
  let d = 0.593 + 0.694 * exp(-0.562 * u)
  let bo = 0.747 * er / (0.15 + er)
  let co = bo - (bo - 0.207) * exp(-0.414 * u)
  let ao = 0.7287 * (ee - 0.5 * (er + 1.0)) * (1.0 - exp(-0.179 * u))
  result.epsOdd = (0.5 * (er + 1.0) + ao - ee) * exp(-co * pow(g, d)) + ee
  # Impedances.
  let q1 = 0.8695 * pow(u, 0.194)
  let q2 = 1.0 + 0.7519 * g + 0.189 * pow(g, 2.31)
  let q3 = 0.1975 + pow(16.6 + pow(8.4 / g, 6.0), -0.387) +
           ln(pow(g, 10.0) / (1.0 + pow(g / 3.4, 10.0))) / 241.0
  let q4 = q1 / q2 * 2.0 / (exp(-g) * pow(u, q3) + (2.0 - exp(-g)) * pow(u, -q3))
  result.zEven = sqrt(ee / result.epsEven) * zl / (1.0 - zl * sqrt(ee) * q4 / Eta0)
  let q5 = 1.794 + 1.14 * ln(1.0 + 0.638 / (g + 0.517 * pow(g, 2.43)))
  let q6 = 0.2305 + ln(pow(g, 10.0) / (1.0 + pow(g / 5.8, 10.0))) / 281.3 +
           ln(1.0 + 0.598 * pow(g, 1.154)) / 5.1
  let q7 = (10.0 + 190.0 * g * g) / (1.0 + 82.3 * g * g * g)
  let q8 = exp(-6.5 - 0.95 * ln(g) - pow(g / 0.15, 5.0))
  let q9 = ln(q7) * (q8 + 1.0 / 16.5)
  let q10 = q4 - q5 / q2 * pow(u, q6 * pow(u, -q9))
  result.zOdd = sqrt(ee / result.epsOdd) * zl / (1.0 - zl * sqrt(ee) * q10 / Eta0)
  result.inRange = u >= 0.1 and u <= 10.0 and g >= 0.1 and g <= 10.0 and er <= 18.0

proc coupledModes*(spec: LineSpec): CoupledModes =
  ## Even/odd modes of an edge-coupled pair (closed form, quasi-static). A
  ## single-line geometry has no partner: both modes are the line itself.
  case spec.geometry
  of lgEdgeCoupledMicrostrip: coupledMicrostrip(spec)
  of lgEdgeCoupledStripline: coupledStripline(spec)
  else:
    let z = z0(spec)
    let e = epsEff(spec)
    CoupledModes(zEven: z, zOdd: z, epsEven: e, epsOdd: e, inRange: true)

proc z0Differential*(spec: LineSpec): tuple[zDiff, zOdd, zEven: float] =
  ## Odd/even mode impedance (`coupledModes`); `zDiff = 2 zOdd`.
  let m = coupledModes(spec)
  (zDiff: 2.0 * m.zOdd, zOdd: m.zOdd, zEven: m.zEven)

# ---------------------------------------------------------------- RLGC / propagation

proc delayPerMetre*(spec: LineSpec): float =
  ## Lossless delay, `sqrt(epsEff)/c` (`sqrt(er)/c` for a stripline).
  sqrt(epsEff(spec)) / SpeedOfLight

proc rlgc*(spec: LineSpec, f: float): tuple[r, l, g, c: float] =
  ## Per-metre R, L, G, C at `f` (Hz). `l`/`c` from the lossless `Z0`/`epsEff`
  ## identity. `r` blends DC and skin-effect resistance as
  ## `sqrt(Rdc^2 + Rac^2)` (no kink at the crossover), times the
  ## Hammerstad-Jensen roughness factor `1 + (2/pi)*atan(1.4*(rough/delta)^2)`.
  ## `g = omega*c*tand`.
  let z = z0(spec)
  let ee = epsEff(spec)
  let l = z * sqrt(ee) / SpeedOfLight
  let c = sqrt(ee) / (z * SpeedOfLight)
  let omega = 2.0 * PI * f
  let rdc = spec.rho / max(spec.w * spec.t, 1e-18)
  let skinDepth = sqrt(spec.rho / (PI * max(f, 1e-9) * Mu0))
  let perimeter = 2.0 * (spec.w + spec.t)
  let rac = spec.rho / max(perimeter * skinDepth, 1e-18)
  var r = sqrt(rdc * rdc + rac * rac)
  if spec.roughness > 0.0 and skinDepth > 0.0:
    r *= 1.0 + (2.0 / PI) * arctan(1.4 * pow(spec.roughness / skinDepth, 2))
  let g = omega * c * spec.tand
  (r: r, l: l, g: g, c: c)

proc propagation*(spec: LineSpec, f: float): tuple[gamma, zc: Complex64] =
  ## Propagation constant and characteristic impedance from `rlgc`:
  ## `gamma = sqrt((R+jwL)*(G+jwC))`, `Zc = sqrt((R+jwL)/(G+jwC))`. One
  ## section only; `pcb/tline` cascades.
  let rlgcV = rlgc(spec, f)
  let omega = 2.0 * PI * f
  let zSeries = complex(rlgcV.r, omega * rlgcV.l)
  let yShunt = complex(rlgcV.g, omega * rlgcV.c)
  let gamma = sqrt(zSeries * yShunt)
  let zc = sqrt(zSeries / yShunt)
  (gamma: gamma, zc: zc)

# ---------------------------------------------------------------- causal form

const
  DsOmega1 = 1e4
  DsOmega2 = 1e12
    ## Djordjevic-Sarkar band, rad/s (`m1 = 4`, `m2 = 12`).

proc dsK(omega: float): Complex64 =
  ## The Djordjevic-Sarkar shape `log10((w2 + jw) / (w1 + jw)) / (m2 - m1)`:
  ## `1` at DC, `0` at infinity.
  let z = complex(DsOmega2, omega) / complex(DsOmega1, omega)
  ln(z) / complex(ln(10.0) * (log10(DsOmega2) - log10(DsOmega1)), 0.0)

proc causalLine*(spec: LineSpec, f: float, fRef = 1e9): tuple[z, y: Complex64] =
  ## Per-metre series impedance and shunt admittance at `f`, in a **causal**
  ## form (a transient model's kernel must be). `rlgc` is not: its
  ## `sqrt(f)` resistance has no matching internal reactance, and a
  ## constant `tand` has no dispersion (Kramers-Kronig).
  ##
  ## - Series: `Rdc * sqrt(1 + jw/w0) + jwL`, the smooth causal
  ##   skin-effect impedance: `Rdc` at DC, `(1 + j) Rac(f)` (internal
  ##   inductance equal to the AC resistance) well above the crossover `w0`,
  ##   chosen so the asymptote is `rlgc`'s `Rac`. `rlgc`'s roughness factor
  ##   multiplies it.
  ## - Shunt: `jwC * eps(w) / eps'(wRef)` with `eps` a Djordjevic-Sarkar
  ##   wideband Debye model (10^4..10^12 rad/s) fitted to `tand` at `fRef`,
  ##   so it equals `rlgc`'s `G + jwC` at `fRef` and stays causal elsewhere.
  let q = rlgc(spec, fRef)
  let omega = 2.0 * PI * f
  let rdc = spec.rho / max(spec.w * spec.t, 1e-18)
  # Rac = A sqrt(w); Rdc sqrt(w / (2 w0)) = A sqrt(w) gives w0.
  let perimeter = 2.0 * (spec.w + spec.t)
  let a = sqrt(spec.rho * Mu0 / 2.0) / max(perimeter, 1e-18)
  let w0 = rdc * rdc / (2.0 * a * a)
  var z = complex(rdc, 0.0) * sqrt(complex(1.0, omega / w0))
  if spec.roughness > 0.0 and f > 0:
    let skinDepth = sqrt(spec.rho / (PI * f * Mu0))
    z *= complex(1.0 + (2.0 / PI) * arctan(1.4 * pow(spec.roughness / skinDepth, 2)), 0.0)
  z += complex(0.0, omega * q.l)
  let kRef = dsK(2.0 * PI * fRef)
  # eps(w) = eInf + dE * K(w); at wRef: Re = 1 (normalised), -Im/Re = tand.
  let dE = if spec.tand > 0: spec.tand / kRef.im.abs else: 0.0
  let eInf = 1.0 - dE * kRef.re
  let eps = complex(eInf, 0.0) + complex(dE, 0.0) * dsK(omega)
  let y = complex(0.0, omega * q.c) * eps
  (z: z, y: y)

proc causalHighFrequencyC*(spec: LineSpec, fRef = 1e9): float =
  ## Per-metre C as `f -> infinity` in `causalLine` (the dielectric's
  ## `eps_inf`): with `rlgc`'s constant `L`, it sets the line's asymptotic
  ## (fastest) delay `sqrt(L * C_inf)`.
  let q = rlgc(spec, fRef)
  let kRef = dsK(2.0 * PI * fRef)
  let dE = if spec.tand > 0: spec.tand / kRef.im.abs else: 0.0
  q.c * (1.0 - dE * kRef.re)

