## `verax/pcb/impedance`: closed-form cross-section, pure numeric, no `Pcb`
## -- exactly the `analysis/measure.nim` precedent this module's own doc
## comment names. Every check here is a closed-form cross-check rather than
## a golden number (`tests/test_analysis_pdn.nim`'s pattern): either two
## independently-coded formulas agreeing, or the module's own limiting
## behaviour, never a magic constant transcribed from memory and trusted.

import std/[math, unittest]

import verax/pcb/impedance

proc approxRel(a, b, relTol: float): bool =
  abs(a - b) <= relTol * max(abs(a), abs(b))

proc wheelerZ0(u, er: float): float =
  ## The classical (1965) Wheeler/Hammerstad single-equation microstrip
  ## approximation -- independently transcribed here, not shared code with
  ## `impedance.nim`'s Hammerstad-Jensen (1980) implementation, so agreement
  ## between the two is a real cross-check and not a tautology. Accurate to
  ## roughly 1% against the more refined 1980 formula for ordinary
  ## geometries, which is the bound the test below asserts.
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
  # Bisect this module's own Hammerstad-Jensen formula for the w/h that
  # lands on 50 ohm (thin trace, t -> 0, to isolate the two formulas'
  # agreement from the thickness correction neither Wheeler formula has).
  proc z(u: float): float =
    z0(LineSpec(geometry: lgMicrostrip, w: u, t: 1e-9, h1: 1.0, er: 4.3))
  var lo = 0.1
  var hi = 10.0
  for _ in 0 ..< 100:
    let mid = (lo + hi) / 2.0
    if z(mid) > 50.0: lo = mid else: hi = mid
  let u = (lo + hi) / 2.0
  check approxRel(z(u), 50.0, 1e-6)
  # The commonly-cited rule of thumb for 50 ohm on FR4-like er~4.3 is a
  # trace roughly twice the substrate height -- this lands in that range.
  check u > 1.0 and u < 3.0
  check approxRel(wheelerZ0(u, 4.3), 50.0, 0.02)

test "epsEff sits strictly between 1 (air) and er (the bulk dielectric)":
  let spec = LineSpec(geometry: lgMicrostrip, w: 0.3e-3, t: 35e-6, h1: 0.5e-3, er: 4.3)
  let ee = epsEff(spec)
  check ee > 1.0
  check ee < 4.3

test "IPC-2141 stripline reproduces its own formula transcribed independently":
  # `Z0 = (60/sqrt(er)) * ln(1.9*b/(0.8*w+t))`, `b = h1+h2`. Same source
  # formula as `impedance.nim`'s `z0StriplineIpc2141`, so this is a
  # transcription check (did the module get the formula it names right),
  # not an external-literature check -- see this module's own accuracy
  # caveat on why a closed-form number here is never claimed exact.
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
  # Tight coupling pulls the odd-mode impedance well below the uncoupled
  # value; a very wide gap should have pulled it almost all the way back.
  check zOddTight < single * 0.9
  check approxRel(zOddWide, single, 1e-3)
  check approxRel(zEvenWide, single, 1e-9)
  check zEvenWide >= zOddWide

test "delayPerMetre of a stripline in er=4.3 equals sqrt(4.3)/c":
  let spec = LineSpec(geometry: lgStripline, w: 0.2e-3, t: 35e-6,
                      h1: 0.5e-3, h2: 0.5e-3, er: 4.3, tand: 0.02)
  const c = 299_792_458.0
  check approxRel(delayPerMetre(spec), sqrt(4.3) / c, 1e-12)
  # Microstrip's delay must be *faster* (lower epsEff) than the fully-embedded
  # stripline at the same nominal er -- part of its field is in air.
  let ms = LineSpec(geometry: lgMicrostrip, w: 0.3e-3, t: 35e-6, h1: 0.5e-3, er: 4.3)
  check delayPerMetre(ms) < delayPerMetre(spec)

test "rlgc and propagation stay internally consistent with z0/epsEff at DC-ish frequency":
  let spec = LineSpec(geometry: lgMicrostrip, w: 0.3e-3, t: 35e-6, h1: 0.5e-3,
                      er: 4.3, tand: 0.02, rho: 1.72e-8)
  let f = 1.0e9
  let rl = rlgc(spec, f)
  # L*C must reproduce 1/v^2 = epsEff/c^2 exactly -- both come from the same
  # z0/epsEff identity, so this is an internal-consistency check that would
  # catch a transcription slip in either `rlgc` or `z0`/`epsEff`.
  const c = 299_792_458.0
  check approxRel(rl.l * rl.c, epsEff(spec) / (c * c), 1e-9)
  # Loss must rise with frequency (skin effect) and rise further with
  # roughness.
  let (gLow, _) = propagation(spec, 1.0e6)
  let (gHigh, _) = propagation(spec, 10.0e9)
  check gHigh.re > gLow.re
  var rough = spec
  rough.roughness = 5e-6
  let (gRough, _) = propagation(rough, 10.0e9)
  check gRough.re > gHigh.re
