## `verax/pcb/impedance`: closed-form cross-sections, no `Pcb`. Every check
## is a cross-check -- two independent formulas agreeing, or a limiting
## behaviour -- never a transcribed magic constant.

import std/[math, unittest]

import verax/pcb/impedance

proc approxRel(a, b, relTol: float): bool =
  abs(a - b) <= relTol * max(abs(a), abs(b))

proc wheelerZ0(u, er: float): float =
  ## Wheeler/Hammerstad (1965) single-equation microstrip, transcribed
  ## independently of `impedance.nim`'s Hammerstad-Jensen, so agreement is a
  ## real cross-check. ~1% for ordinary geometries.
  let epsEff =
    if u >= 1.0:
      (er + 1.0) / 2.0 + (er - 1.0) / 2.0 / sqrt(1.0 + 12.0 / u)
    else:
      (er + 1.0) / 2.0 + (er - 1.0) / 2.0 *
        (1.0 / sqrt(1.0 + 12.0 / u) + 0.04 * (1.0 - u) * (1.0 - u))
  if u >= 1.0:
    120.0 * PI / (sqrt(epsEff) * (u + 1.393 + 0.667 * ln(u + 1.444)))
  else:
    (60.0 / sqrt(epsEff)) * ln(8.0 / u + u / 4.0)

test "microstrip Z0 near 50 ohm on er=4.3 agrees with the independent Wheeler formula within 2%":
  # Bisect for the w/h giving 50 ohm, with t -> 0 to exclude the thickness
  # correction.
  proc z(u: float): float =
    z0(LineSpec(geometry: lgMicrostrip, w: u, t: 1e-9, h1: 1.0, er: 4.3))
  var lo = 0.1
  var hi = 10.0
  for _ in 0 ..< 100:
    let mid = (lo + hi) / 2.0
    if z(mid) > 50.0: lo = mid else: hi = mid
  let u = (lo + hi) / 2.0
  check approxRel(z(u), 50.0, 1e-6)
  # The rule of thumb for 50 ohm on er~4.3 is w ~ 2h.
  check u > 1.0 and u < 3.0
  check approxRel(wheelerZ0(u, 4.3), 50.0, 0.02)

test "epsEff sits strictly between 1 (air) and er (the bulk dielectric)":
  let spec = LineSpec(geometry: lgMicrostrip, w: 0.3e-3, t: 35e-6, h1: 0.5e-3, er: 4.3)
  let ee = epsEff(spec)
  check ee > 1.0
  check ee < 4.3

test "IPC-2141 stripline reproduces its own formula transcribed independently":
  # `Z0 = (60/sqrt(er)) * ln(1.9*b/(0.8*w+t))`, `b = h1+h2`: a transcription
  # check of `z0StriplineIpc2141`, not a literature check.
  let w = 0.2e-3
  let t = 35e-6
  let h1 = 0.4e-3
  let h2 = 0.4e-3
  let er = 4.3
  let want = (60.0 / sqrt(er)) * ln(1.9 * (h1 + h2) / (0.8 * w + t))
  let spec = LineSpec(geometry: lgStripline, w: w, t: t, h1: h1, h2: h2, er: er)
  check approxRel(z0(spec), want, 1e-9)

test "odd/even mode collapse to the single-ended value as s grows":
  let base = LineSpec(geometry: lgEdgeCoupledMicrostrip, w: 0.3e-3, t: 35e-6,
                      h1: 0.5e-3, er: 4.3, rho: 1.72e-8)
  let single = z0(LineSpec(geometry: lgMicrostrip, w: base.w, t: base.t,
                           h1: base.h1, er: base.er))
  var tight = base
  tight.s = 0.1e-3
  var wide = base
  wide.s = 500.0e-3
  let (_, zOddTight, _) = z0Differential(tight)
  let (_, zOddWide, zEvenWide) = z0Differential(wide)
  # Tight coupling pulls odd-mode Z well below single-ended; a wide gap
  # restores both modes (Kirschning-Jansen, `coupledModes`).
  check zOddTight < single * 0.9
  check approxRel(zOddWide, single, 2e-3)
  check approxRel(zEvenWide, single, 2e-3)
  let (_, _, zEvenTight) = z0Differential(tight)
  check zEvenTight > single

test "delayPerMetre of a stripline in er=4.3 equals sqrt(4.3)/c":
  let spec = LineSpec(geometry: lgStripline, w: 0.2e-3, t: 35e-6,
                      h1: 0.5e-3, h2: 0.5e-3, er: 4.3, tand: 0.02)
  const c = 299_792_458.0
  check approxRel(delayPerMetre(spec), sqrt(4.3) / c, 1e-12)
  # Microstrip is faster than embedded stripline at the same er (part of its
  # field is in air).
  let ms = LineSpec(geometry: lgMicrostrip, w: 0.3e-3, t: 35e-6, h1: 0.5e-3, er: 4.3)
  check delayPerMetre(ms) < delayPerMetre(spec)

test "rlgc and propagation stay internally consistent with z0/epsEff at DC-ish frequency":
  let spec = LineSpec(geometry: lgMicrostrip, w: 0.3e-3, t: 35e-6, h1: 0.5e-3,
                      er: 4.3, tand: 0.02, rho: 1.72e-8)
  let f = 1.0e9
  let rl = rlgc(spec, f)
  # L*C must equal epsEff/c^2, catching a slip in `rlgc` or `z0`/`epsEff`.
  const c = 299_792_458.0
  check approxRel(rl.l * rl.c, epsEff(spec) / (c * c), 1e-9)
  # Loss rises with frequency and further with roughness.
  let (gLow, _) = propagation(spec, 1.0e6)
  let (gHigh, _) = propagation(spec, 10.0e9)
  check gHigh.re > gLow.re
  var rough = spec
  rough.roughness = 5e-6
  let (gRough, _) = propagation(rough, 10.0e9)
  check gRough.re > gHigh.re
