import std/[math, strutils, unittest]

import verax/units
import verax/parts
import designs/lib/capbank

proc isSeriesValue(s: ESeries, x: float): bool =
  ## Whether `x` is a value `s` carries, normalized as
  ## `capbank.roundUpSeries` does (possibly the next decade's first value).
  let decade = pow(10.0, floor(log10(x)))
  let m = x / decade
  for cand in s.mantissas:
    if abs(cand - m) < 1e-6: return true
  abs(s.mantissas[0] - m / 10.0) < 1e-6

suite "splitting a target capacitance into a real bank":
  # The bank's effective total, after DC-bias derating, reaches the target.

  test "the bank's effective total reaches the target":
    # 37.5 uF at 3.298 V, rated 10 V: the X7R curve leaves 78.6%, so the bank
    # is oversized on paper and lands on target after bias.
    let b = capBank(37.5.uF, 3.298.V, capBankSpec())
    check b.parts.len == 5
    check b.parts[0].package == "0805"
    check float(b.parts[0].voltageRating) == 10.0
    check abs(b.biasFraction - 0.78616) < 1e-5
    # `effectiveTotal` is defined as this product.
    check abs(float(b.effectiveTotal) - float(b.nominalTotal) * b.biasFraction) < 1e-15
    check float(b.effectiveTotal) >= float(b.target) - 1e-12

  test "a smaller maxPackage produces more, smaller parts for the same target":
    # 30 uF at 5 V: 1206 needs two parts, 0805 five.
    let wide = capBank(30.0.uF, 5.0.V, capBankSpec(maxPackage = "1206"))
    let narrow = capBank(30.0.uF, 5.0.V, capBankSpec())  # default 0805
    check wide.parts[0].package == "1206"
    check narrow.parts[0].package == "0805"
    check narrow.parts.len > wide.parts.len
    check float(narrow.parts[0].value) < float(wide.parts[0].value)

  test "minCount forces more parts, and the case shrinks to match":
    # 10 uF at 3.298 V: two 0805s by default; `minCount` 13 pushes each part
    # into 0603.
    let free = capBank(10.0.uF, 3.298.V, capBankSpec())
    check free.parts.len == 2
    check free.parts[0].package == "0805"

    let forced = capBank(10.0.uF, 3.298.V, capBankSpec(minCount = 13))
    check forced.parts.len == 13
    check forced.parts[0].package == "0603"
    check float(forced.parts[0].value) == 1.0e-6

  test "a stated voltage rating changes the bias fraction, and a stated one wins":
    # A derived 10 V rating keeps 78.6%; a stated 16 V keeps more.
    let derived = capBank(37.5.uF, 3.298.V, capBankSpec())
    let stated = capBank(37.5.uF, 3.298.V, capBankSpec(voltageRating = 16.0.V))
    check float(derived.parts[0].voltageRating) == 10.0
    check float(stated.parts[0].voltageRating) == 16.0
    check abs(derived.biasFraction - 0.78616) < 1e-5
    check abs(stated.biasFraction - 0.876325) < 1e-5
    check stated.biasFraction > derived.biasFraction

  test "a Class 1 bank does not bias-derate at all":
    # C0G doesn't lose capacitance to bias, so nominal equals effective.
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
