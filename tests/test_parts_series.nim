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
    # Why the tables are written out: `10^(n/24)` gives 2.6, 2.9, 3.2... but
    # what's manufactured is 2.7, 3.0, 3.3...
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
    # A naive rounding pass would move an ordinary 240 R to 243 R (E96) and
    # break a divider's ratio.
    check abs(e24(240.ohm).float - 240.0) < 1.0e-9
    check abs(e96(240.ohm).float - 243.0) < 1.0e-9

  test "the ladder is followed across decades":
    check abs(nearest(seriesE96, 2044.37) - 2050.0) < 1.0e-9
    check abs(nearest(seriesE96, 0.204437) - 0.205) < 1.0e-12
    check abs(nearest(seriesE96, 2.04437e6) - 2.05e6) < 1.0

  test "a mantissa just under ten rounds up into the next decade":
    # 9.9 is nearer the next decade's 10 than E96's top value.
    check abs(nearest(seriesE96, 9.9) - 10.0) < 1.0e-9
    check abs(nearest(seriesE12, 9.5) - 10.0) < 1.0e-9
    # A boundary, not a ceiling: 9.0 is still nearer 8.2.
    check abs(nearest(seriesE12, 9.0) - 8.2) < 1.0e-9

  test "nearest is by ratio, not by difference":
    # Rounding is by ratio (tolerances are percentages): 2445 is nearer 2200
    # by difference but 2700 by ratio.
    check abs(nearest(seriesE12, 2445.0) - 2700.0) < 1.0e-9
    check abs(nearest(seriesE12, 2430.0) - 2200.0) < 1.0e-9

  test "no value is further from its ladder than its worst half-gap":
    # Not the figure the name suggests: the standard E96 table has a 3.01%
    # gap (1.33 -> 1.37), so rounding can cost 1.49%, not 1.2%.
    for (s, bound) in [(seriesE96, 0.0149), (seriesE24, 0.0742),
                       (seriesE12, 0.1180)]:
      var x = 1.0
      while x < 10.0:
        check abs(relativeError(s, x)) <= bound
        x += 0.001
    # The widest gap in each table, so a mistyped entry moves both.
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
    # Never turn an arithmetic mistake into a plausible part.
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
    # A builder never learns which ladder it got; the four answers differ.
    var picked: seq[float]
    for s in [PreferredSeries(exactSeries), e12, e24, e96]:
      picked.add s(2044.37.ohm).float
    check picked == @[2044.37, 2200.0, 2000.0, 2050.0]

  test "relativeError is signed, so the direction of a rounding is visible":
    check relativeError(seriesE96, 2044.37) > 0.0    # 2050, upwards
    check relativeError(seriesE12, 713.152) < 0.0    # 680, downwards
    check abs(relativeError(seriesE96, 715.0)) < 1.0e-12
