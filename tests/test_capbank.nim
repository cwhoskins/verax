import std/[math, strutils, unittest]

import verax/units
import verax/parts
import designs/lib/capbank

proc isSeriesValue(s: ESeries, x: float): bool =
  ## Whether `x` is (to floating-point tolerance) a value `s` actually
  ## carries -- normalizing to a mantissa in `[1, 10)` the same way
  ## `capbank.roundUpSeries` does, since a rounded-up value may legitimately
  ## be the *next* decade's first mantissa rather than anything in this
  ## decade.
  let decade = pow(10.0, floor(log10(x)))
  let m = x / decade
  for cand in s.mantissas:
    if abs(cand - m) < 1e-6: return true
  abs(s.mantissas[0] - m / 10.0) < 1e-6

suite "splitting a target capacitance into a real bank":
  # `capBank`'s whole point: a ripple equation's farad figure becomes parts
  # that can be bought, sized so that after the simulator's own DC-bias
  # derating (`spice/models/derating`, read through here) the bank still
  # delivers what was asked for.

  test "the bank's effective total reaches the target":
    # 37.5 uF at 3.298 V, the datalogger's own COUT figure. Rated 10 V (the
    # standard rating at or above 2x 3.298 V) puts the working ratio at
    # 0.3298, which the X7R curve interpolates to 78.6% remaining -- so the
    # bank is sized larger than the target on paper and lands on it after
    # bias.
    let b = capBank(37.5.uF, 3.298.V, capBankSpec())
    check b.parts.len == 5
    check b.parts[0].package == "0805"
    check float(b.parts[0].voltageRating) == 10.0
    check abs(b.biasFraction - 0.78616) < 1e-5
    # Not a coincidence -- `effectiveTotal` is defined as exactly this
    # product, so this pins the relationship rather than the arithmetic.
    check abs(float(b.effectiveTotal) - float(b.nominalTotal) * b.biasFraction) < 1e-15
    check float(b.effectiveTotal) >= float(b.target) - 1e-12

  test "a smaller maxPackage produces more, smaller parts for the same target":
    # Same 30 uF at 5 V target, two package ceilings. 1206 holds enough per
    # part that two suffice; 0805 does not, and five are needed instead --
    # the knob a keepout-constrained board actually wants to turn.
    let wide = capBank(30.0.uF, 5.0.V, capBankSpec(maxPackage = "1206"))
    let narrow = capBank(30.0.uF, 5.0.V, capBankSpec())  # default 0805
    check wide.parts[0].package == "1206"
    check narrow.parts[0].package == "0805"
    check narrow.parts.len > wide.parts.len
    check float(narrow.parts[0].value) < float(wide.parts[0].value)

  test "minCount forces more parts, and the case shrinks to match":
    # The same 10 uF target and 3.298 V working voltage split two ways: left
    # to itself the bank needs only 2 parts (0805, the case a ~7 uF part
    # needs); forcing 13 pushes each part's value down far enough to fit in
    # a 0603 instead -- `minCount`'s real effect, not just a part count.
    let free = capBank(10.0.uF, 3.298.V, capBankSpec())
    check free.parts.len == 2
    check free.parts[0].package == "0805"

    let forced = capBank(10.0.uF, 3.298.V, capBankSpec(minCount = 13))
    check forced.parts.len == 13
    check forced.parts[0].package == "0603"
    check float(forced.parts[0].value) == 1.0e-6

  test "a stated voltage rating changes the bias fraction, and a stated one wins":
    # Left to derive its own rating (2x 3.298 V, rounded up to the standard
    # 10 V), the bank keeps 78.6% of nominal at bias; stated at 16 V instead,
    # the same part sits at a gentler fraction of its rating and keeps more.
    let derived = capBank(37.5.uF, 3.298.V, capBankSpec())
    let stated = capBank(37.5.uF, 3.298.V, capBankSpec(voltageRating = 16.0.V))
    check float(derived.parts[0].voltageRating) == 10.0
    check float(stated.parts[0].voltageRating) == 16.0
    check abs(derived.biasFraction - 0.78616) < 1e-5
    check abs(stated.biasFraction - 0.876325) < 1e-5
    check stated.biasFraction > derived.biasFraction

  test "a Class 1 bank does not bias-derate at all":
    # C0G/NP0 is paraelectric: it does not lose capacitance to DC bias, so
    # the bank is not oversized to compensate and its nominal and effective
    # totals coincide exactly.
    let b = capBank(10.0.nF, 5.0.V, capBankSpec(dielectric = "C0G"))
    check b.biasFraction == 1.0
    check float(b.nominalTotal) == float(b.effectiveTotal)

  test "every part's nominal value is a member of the stated series":
    let b12 = capBank(37.5.uF, 3.298.V, capBankSpec(series = seriesE12))
    for p in b12.parts:
      check isSeriesValue(seriesE12, float(p.value))
    let b24 = capBank(37.5.uF, 3.298.V, capBankSpec(series = seriesE24))
    for p in b24.parts:
      check isSeriesValue(seriesE24, float(p.value))

  test "a target needing more parts than maxCount allows raises, naming the knob":
    try:
      discard capBank(1.0.F, 5.0.V, capBankSpec(maxCount = 2))
      fail()
    except ValueError as e:
      check "maxCount" in e.msg
