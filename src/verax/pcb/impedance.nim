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

proc z0Differential*(spec: LineSpec): tuple[zDiff, zOdd, zEven: float] =
  ## Odd/even mode impedance from a **lumped mutual-capacitance** model:
  ## `Cp = sqrt(epsEff)/(z0*c)` per line and `Cm = eps0*epsEff*t/s` between
  ## facing edges. Exact as `s -> Inf` (both modes -> `z0`), but at tight
  ## coupling `zEven` never rises above `z0` as it really does. A full
  ## coupled-line solve would need unverified constants.
  if spec.geometry notin {lgEdgeCoupledMicrostrip, lgEdgeCoupledStripline}:
    let z = z0(spec)
    return (zDiff: 2.0 * z, zOdd: z, zEven: z)
  let single = z0(spec)
  let ee = epsEff(spec)
  let v = SpeedOfLight / sqrt(ee)
  let eps0 = 1.0 / (Mu0 * SpeedOfLight * SpeedOfLight)
  let cp = 1.0 / (single * v)
  let s = max(spec.s, 1e-12)
  let cm = eps0 * ee * spec.t / s
  let zOdd = 1.0 / (v * (cp + 2.0 * cm))
  let zEven = single
  (zDiff: 2.0 * zOdd, zOdd: zOdd, zEven: zEven)

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
