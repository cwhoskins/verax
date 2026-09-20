## Closed-form transmission-line cross-section: characteristic impedance,
## per-metre RLGC and propagation, for a microstrip or stripline geometry
## stated as plain numbers.
##
## **Pure numeric, no `Pcb`**, on the `analysis/measure.nim` precedent: that
## module is deliberately curve math over plain floats "so it is testable
## offline", and the same reasoning applies here -- a closed-form formula
## should be checkable against a textbook example with no board file, no
## reader and no simulator anywhere near the test. `pcb/trace.nim` is the
## only thing that turns a `Pcb`'s stackup and geometry into the `LineSpec`
## this module consumes (`pcb/tline.specFor`); this module never imports
## `pcb/types` and does not know what a `Copper` is.
##
## **The accuracy ceiling, stated once rather than re-caveated at every
## call site.** Every formula here is a quasi-static closed form
## (Hammerstad-Jensen, IPC-2141), not a field solve: each is accurate to a
## few percent over the geometry range its own paper validated and
## degrades outside it, and none of them captures dispersion (`epsEff` is
## treated as frequency-independent throughout, which is the same
## simplification every closed-form PCB impedance calculator on the market
## ships). A number from here disagreeing with a fab's own field-solver
## report by a few percent is not a bug in either one -- `pcb/CLAUDE.md`
## records this so it is not mistaken for a regression.
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
      ## Dielectric to the near reference (`h1`) and, for a stripline
      ## geometry, to the far one (`h2`). Unused by a microstrip formula.
    s*: float
      ## Edge-to-edge gap, metres -- coupled geometries only.
    er*, tand*: float
    rho*: float
      ## Conductor resistivity, ohm-metre. Copper is `1.72e-8` (annealed,
      ## 20 degC) but this is stated by the caller, never defaulted here --
      ## see `rho*` on `pcb/tline.TlineSpec` for where a default actually
      ## lives, one layer up, alongside the `Assumption` that names it as
      ## invented.
    roughness*: float
      ## RMS copper roughness, metres. `0` is smooth, and the caller is the
      ## one who must say when that is a default rather than a measurement
      ## -- see `pcb/tline.nim`'s module doc.

const
  Eta0 = 376.730313668
    ## Free-space wave impedance, ohms (`sqrt(mu0/eps0)`), to the precision
    ## CODATA gives `mu0`/`eps0` -- the Hammerstad-Jensen formula is stated
    ## in terms of it, not the `120*pi` (~376.991) shorthand some textbooks
    ## substitute, which is close enough for a term inside a `ln(...)` but
    ## not worth being sloppy about when the exact constant is this cheap.
  Mu0 = 4.0 * PI * 1e-7
  SpeedOfLight = 299_792_458.0

# ---------------------------------------------------------------- microstrip

proc effectiveWidth(w, h, t: float): float =
  ## The Hammerstad thickness correction: a real (non-zero-thickness) trace
  ## presents more edge than a mathematically thin one, which a formula
  ## derived for zero thickness would otherwise get wrong on exactly the
  ## traces thick enough (2 oz+ copper) for the correction to matter.
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
  ## Representative soldermask permittivity -- standard green liquid
  ## photoimageable soldermask is commonly cited in the 3.0-4.0 range and
  ## this is a stated middle-of-range constant, never a value read off any
  ## board. `LineSpec.er` already means "the substrate's bulk permittivity"
  ## on every other geometry (it feeds `hammerstadJensenEpsEff` directly),
  ## so reusing it here as "the mask's er" would make the same field mean
  ## two different materials depending on which enum case a caller picked --
  ## exactly the kind of ambiguity `touchstone/types`' dB-pair split refuses
  ## to allow. `pcb/tline.characterize` is what records the use of this
  ## constant as an `Assumption` whenever `lgCoveredMicrostrip` is selected,
  ## since it is exactly the kind of invented input the house rule requires
  ## naming.

proc coveredEpsEffCorrection(spec: LineSpec, epsEffBare: float): float =
  ## `lgCoveredMicrostrip`'s solder-mask correction: the mask fills part of
  ## the fringing field that bare `lgMicrostrip` assumes is air, pulling
  ## `epsEff` toward `TypicalSolderMaskEr` by a fraction set by how thick the
  ## mask is relative to the trace height above the substrate; declared thin
  ## coverage (mask thickness << substrate height, the near-universal real
  ## case) asymptotes to a small, bounded correction rather than a runaway
  ## one for a formula with no thickness term of its own.
  let blend = clamp(spec.t / (spec.t + spec.h1), 0.0, 1.0) * 0.5
  epsEffBare + (TypicalSolderMaskEr - epsEffBare) * blend

proc epsEff*(spec: LineSpec): float =
  ## The effective permittivity a wave on this cross-section actually sees:
  ## between the bulk dielectric's `er` (fully embedded, as in a stripline)
  ## and `1.0` (fully in air), positioned by how much of the field a
  ## microstrip's fringe pulls above the board versus through it.
  case spec.geometry
  of lgMicrostrip, lgEdgeCoupledMicrostrip:
    hammerstadJensenEpsEff(microstripU(spec), spec.er)
  of lgCoveredMicrostrip:
    coveredEpsEffCorrection(spec, hammerstadJensenEpsEff(microstripU(spec), spec.er))
  of lgStripline, lgAsymStripline, lgEdgeCoupledStripline:
    ## A stripline's dielectric is homogeneous on every side, so there is no
    ## fringing-into-air to average against -- the *effective* permittivity
    ## is exactly the bulk one, which is also why `delayPerMetre` on a
    ## stripline reduces to the textbook `sqrt(er)/c` with no correction
    ## term at all.
    spec.er

proc z0Microstrip(spec: LineSpec): float =
  let u = microstripU(spec)
  hammerstadJensenZ0Air(u) / sqrt(epsEff(spec))

# ---------------------------------------------------------------- stripline

proc z0StriplineIpc2141(w, t, b, er: float): float =
  ## IPC-2141's stripline formula, `Z0 = (60/sqrt(er)) * ln(1.9*b/(0.8*w+t))`,
  ## where `b` is the total spacing between the two reference planes. Valid
  ## for a *centred* trace; `z0` below reuses it for `lgAsymStripline` too
  ## with `b = h1 + h2` regardless of how unevenly split -- Cohn's exact
  ## offset correction is a real, larger effect the closer the trace sits to
  ## one plane, and is not implemented here. That is the sharpest edge of
  ## this module's accuracy ceiling and is why `lgAsymStripline` exists as
  ## its own enum value rather than being silently folded into
  ## `lgStripline`: a caller reading `LineGeometry` back at least sees that
  ## the geometry it asked for and the formula that answered are not a
  ## perfect match.
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
  ## Odd/even mode impedance from a **lumped mutual-capacitance** model, not
  ## a conformal-mapping coupled-line solve: `Cp`, the single line's own
  ## per-metre capacitance, comes straight out of `z0`/`epsEff`
  ## (`Cp = sqrt(epsEff)/(z0*c)`, the same `L`/`C` identity `rlgc` uses); the
  ## coupling itself is modelled as a parallel-plate capacitor between the
  ## two facing trace edges (`Cm = eps0*epsEff*t/s`), which is exact only in
  ## the limit the plan's own test checks -- `s -> Inf` drives `Cm -> 0` and
  ## both modes collapse onto the uncoupled `z0`. It is *not* exact at tight
  ## coupling: a real coupled pair's even-mode impedance rises above the
  ## uncoupled `Z0` (the inner fringing field that an isolated line bends
  ## toward its neighbour's position is suppressed when both traces sit at
  ## the same potential), and this model holds `Cp` fixed for even mode, so
  ## `zEven` here never exceeds `z0`. A full quasi-static solve (elliptic
  ## integrals or Kirschning-Jansen coefficients) would fix that at the cost
  ## of several more magic constants this module would then be asserting
  ## without having verified them against a published table -- the explicit
  ## trade this codebase asks for over presenting an unverified number as
  ## exact.
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
  ## Lossless propagation delay, `sqrt(epsEff)/c`. For a stripline this is
  ## exactly the textbook `sqrt(er)/c` (`epsEff` reduces to `er` there, with
  ## no fringing term to correct for), which is the closed-form
  ## cross-check `tests/test_pcb_impedance.nim` pins.
  sqrt(epsEff(spec)) / SpeedOfLight

proc rlgc*(spec: LineSpec, f: float): tuple[r, l, g, c: float] =
  ## Per-metre R, L, G, C at frequency `f` (Hz).
  ##
  ## `l`/`c` come from the same lossless `Z0`/`epsEff` identity used
  ## everywhere else in this module (`l = z0*sqrt(epsEff)/c0`,
  ## `c = sqrt(epsEff)/(z0*c0)`) -- quasi-static and frequency-independent,
  ## the accuracy ceiling this module's doc comment states once rather than
  ## re-deriving per proc.
  ##
  ## `r` is the DC term (`rho/(w*t)`) combined smoothly with the classical
  ## skin-effect term via `sqrt(Rdc^2 + Rac^2)` -- a smooth blend rather than
  ## a `max()` or a frequency threshold, because either of those would put a
  ## kink in `r(f)` at the crossover that has no physical counterpart and
  ## would show up as a visible corner in a swept-frequency loss plot --
  ## then scaled by the Hammerstad-Jensen roughness factor
  ## `1 + (2/pi)*atan(1.4*(roughness/skinDepth)^2)`, the default
  ## (`roughness = 0`) leaving `r` exactly the smooth-copper value.
  ##
  ## `g = omega*c*tand`, current dielectric loss only -- there is no
  ## closed-form leakage-conductance term independent of `tand` at this
  ## level of model.
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
  ## The telegrapher's-equation propagation constant and characteristic
  ## impedance from `rlgc`'s own R/L/G/C: `gamma = sqrt((R+jwL)*(G+jwC))`,
  ## `Zc = sqrt((R+jwL)/(G+jwC))`. `pcb/tline.nim` is what turns this into a
  ## per-section ABCD matrix and cascades it along a route; this proc only
  ## does the one-section arithmetic.
  let rlgcV = rlgc(spec, f)
  let omega = 2.0 * PI * f
  let zSeries = complex(rlgcV.r, omega * rlgcV.l)
  let yShunt = complex(rlgcV.g, omega * rlgcV.c)
  let gamma = sqrt(zSeries * yShunt)
  let zc = sqrt(zSeries / yShunt)
  (gamma: gamma, zc: zc)
