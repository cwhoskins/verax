## Preferred-value ladders, and the rounding a builder asks for by name.

import std/[math, unittest]

import verax/units
import verax/parts/series

suite "the tables are the standard ones":
  test "each ladder has the count its name states":
    check seriesE12.mantissas.len == 12
    check seriesE24.mantissas.len == 24
    check seriesE96.mantissas.len == 96

  test "every mantissa is in one decade and strictly increasing":
    for s in [seriesE12, seriesE24, seriesE96]:
      for m in s.mantissas:
        check m >= 1.0 and m < 10.0
      for i in 1 ..< s.mantissas.len:
        check s.mantissas[i] > s.mantissas[i - 1]

  test "the values that deviate from the geometric ideal are the standard ones":
    # This is the reason the tables are written out rather than computed.
    # `10^(n/24)` to two significant figures gives 2.6, 2.9, 3.2, 3.5, 3.8,
    # 4.2, 4.6 through the middle of the decade; what is manufactured is
    # 2.7, 3.0, 3.3, 3.6, 3.9, 4.3, 4.7. A computed ladder would be a
    # plausible list of numbers nobody sells.
    let deviating = [2.7, 3.0, 3.3, 3.6, 3.9, 4.3, 4.7]
    for v in deviating:
      check v in seriesE24.mantissas
    for n in 10 .. 16:
      let ideal = round(pow(10.0, n.float / 24.0), 1)
      check ideal notin seriesE24.mantissas

suite "nearest is nearest by ratio":
  test "a value already in the series is returned unchanged":
    check abs(nearest(seriesE24, 240.0) - 240.0) < 1.0e-9
    check abs(nearest(seriesE12, 4700.0) - 4700.0) < 1.0e-9
    check abs(nearest(seriesE96, 7150.0) - 7150.0) < 1.0e-9

  test "240 R is an E24 value and not an E96 one":
    # Worth pinning because it is the trap the regulator builder sidesteps by
    # never rounding a resistance the design stated: a naive pass over every
    # value would move a perfectly ordinary 240 R reference resistor to 243 R
    # and take the divider's ratio with it.
    check abs(e24(240.ohm).float - 240.0) < 1.0e-9
    check abs(e96(240.ohm).float - 243.0) < 1.0e-9

  test "the ladder is followed across decades":
    check abs(nearest(seriesE96, 2044.37) - 2050.0) < 1.0e-9
    check abs(nearest(seriesE96, 0.204437) - 0.205) < 1.0e-12
    check abs(nearest(seriesE96, 2.04437e6) - 2.05e6) < 1.0

  test "a mantissa just under ten rounds up into the next decade":
    # The candidate that is not in the table: 9.9 is 1.0% below 10 and 1.4%
    # above E96's top value, so the nearest preferred value is 10.
    check abs(nearest(seriesE96, 9.9) - 10.0) < 1.0e-9
    check abs(nearest(seriesE12, 9.5) - 10.0) < 1.0e-9
    # And it is a boundary, not a ceiling: 9.0 is still nearer E12's 8.2.
    check abs(nearest(seriesE12, 9.0) - 8.2) < 1.0e-9

  test "nearest is by ratio, not by difference":
    # 2200 and 2700 are half a step apart at 2450 in absolute terms and at
    # 2437 geometrically, so anything in between separates the two rules.
    # By difference 2445 is nearer 2200; by ratio -- which is the one that
    # matters, because the tolerance either part is bought at is a
    # percentage -- it is nearer 2700.
    check abs(nearest(seriesE12, 2445.0) - 2700.0) < 1.0e-9
    check abs(nearest(seriesE12, 2430.0) - 2200.0) < 1.0e-9

  test "no value is further from its ladder than its worst half-gap":
    # Not the figure the name suggests. 10^(1/96) is 1.0242, so an ideal E96
    # ladder would never be more than 1.2% from anything -- but the table is
    # the standard one, rounded to three significant figures, and 1.33 -> 1.37
    # is a 3.01% gap. So rounding to E96 can cost 1.49%, and a design that
    # budgeted the nominal 1.2% budgeted too little.
    for (s, bound) in [(seriesE96, 0.0149), (seriesE24, 0.0742),
                       (seriesE12, 0.1180)]:
      var x = 1.0
      while x < 10.0:
        check abs(relativeError(s, x)) <= bound
        x += 0.001
    # Pinned from the other side: the widest gap in each table is what that
    # bound is, so a mistyped entry moves both together.
    for (s, gap) in [(seriesE96, 1.0301), (seriesE24, 1.1539),
                     (seriesE12, 1.2500)]:
      var widest = 1.0
      let ladder = s.mantissas & @[10.0]
      for i in 1 ..< ladder.len:
        widest = max(widest, ladder[i] / ladder[i - 1])
      check abs(widest - gap) < 1.0e-3

suite "quantities and refusals":
  test "any unit rounds, because a ladder is a ladder":
    check abs(nearest(seriesE12, 22.5.nF).float - 22.0e-9) < 1.0e-15
    check abs(nearest(seriesE24, 3.9.uH).float - 3.9e-6) < 1.0e-12
    check abs(nearest(seriesE96, 4.99.kohm).float - 4990.0) < 1.0e-9

  test "a value with no preferred neighbour comes back unchanged":
    # Turning a caller's arithmetic mistake into a plausible component is the
    # one thing this must not do.
    check nearest(seriesE96, 0.0) == 0.0
    check nearest(seriesE96, -713.0) == -713.0
    check nearest(seriesE96, Inf) == Inf
    check nearest(seriesE96, NaN).classify == fcNan

  test "an empty ladder rounds nothing":
    let none = ESeries(name: "none", mantissas: @[])
    check nearest(none, 713.152) == 713.152

  test "exactSeries is the default a builder carries, and rounds nothing":
    let s: PreferredSeries = exactSeries
    check abs(s(713.152.ohm).float - 713.152) < 1.0e-9

  test "the rounders fit the hook a builder takes":
    # The point of the proc type: a builder never learns which ladder it got.
    # 2044.37 ohm is what `designs/lib/adjreg.nim` computes for its 12 V rail,
    # and the four answers to "what can I buy" are four different resistors.
    var picked: seq[float]
    for s in [PreferredSeries(exactSeries), e12, e24, e96]:
      picked.add s(2044.37.ohm).float
    check picked == @[2044.37, 2200.0, 2000.0, 2050.0]

  test "relativeError is signed, so the direction of a rounding is visible":
    check relativeError(seriesE96, 2044.37) > 0.0    # 2050, upwards
    check relativeError(seriesE12, 713.152) < 0.0    # 680, downwards
    check abs(relativeError(seriesE96, 715.0)) < 1.0e-12
