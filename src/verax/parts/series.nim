## Preferred values: the numbers a resistor or a capacitor is actually sold in.
##
## An equation returns 713.152 ohm and nothing sells that. What is stocked is a
## **preferred series** -- a geometric ladder of values per decade, sized so
## that parts at a given tolerance cover the whole range with roughly even
## proportional spacing and without excessive overlap. E24 is the 5% ladder,
## E96 the 1% one; E12 is what capacitors are mostly stocked in whatever their
## tolerance.
##
## ## Rounding is a decision, so it is asked for rather than assumed
##
## Nothing here is applied by default anywhere in this library, and that is
## the position `designs/lib/filters.nim` states: a builder that quietly
## rounds hands back the number you asked for while building something else.
## `PreferredSeries` is the hook a caller passes *in*, and the caller's
## obligation is to recompute what the circuit then does from the values it
## will actually have -- `designs/lib/adjreg.nim` is the worked example, where
## the output voltage is recomputed from the rounded divider rather than
## reported back as the voltage that was requested.
##
## ## Why the tables are written out and not computed
##
## The obvious implementation is `10^(n/24)` rounded to two significant
## figures, and it is wrong. The standard series deviate from the geometric
## ideal through the middle of the decade, by historical accident that is now
## simply what is manufactured:
##
##     n:        10     11     12     13     14     15     16
##     ideal:   2.61   2.87   3.16   3.47   3.83   4.22   4.64
##     E24:     2.7    3.0    3.3    3.6    3.9    4.3    4.7
##
## Seven of E24's twenty-four values are not what the formula gives. Computing
## them would produce a plausible ladder of numbers that cannot be bought,
## which is the one failure mode this module exists to prevent. E96 does come
## out of the formula cleanly, and is written out anyway -- a table that is
## sometimes the standard and sometimes a derivation of it is worse than one
## that is always the standard.
##
## ## Nearest, in the logarithmic sense
##
## The ladder is geometric, so the error that matters is proportional: 2050
## against a wanted 2044 is a 0.27% error whether it happens at 2 kohm or at
## 2 Mohm, and picking by absolute difference would bias every choice
## downwards. `nearest` compares `abs(ln(candidate/wanted))`, and includes the
## next decade's first value as a candidate, since for a mantissa just under
## 10 the nearest preferred value is 10 and not the top of the table.
##
## ## What this does not know
##
## A series says which values *exist*, not which are stocked, in what
## tolerance, in what package, or at what price. Every E96 value is a real 1%
## part; not every one of them is a real 1% part in an 0402 at your
## distributor. That is a preferred-parts database's job -- and the reason
## `PreferredSeries` is a proc value rather than an enum is so that one can be
## substituted here without anything else changing, exactly as `PartPolicy` is.

import std/math

import ../units

type
  ESeries* = object
    ## One preferred-value ladder.
    name*: string
    mantissas*: seq[float]
      ## One decade's values, each in `[1, 10)` and strictly increasing. The
      ## ladder repeats by powers of ten, which is what makes one decade
      ## enough to describe all of it.
    tolerance*: Fraction
      ## The part tolerance the series was spaced for. It is **not** the
      ## tolerance of a part you buy at one of these values -- E24 values are
      ## routinely stocked at 1% -- but it is what says whether rounding to
      ## this ladder is even coherent: rounding to E12 a value whose ratio has
      ## to hold to 1% is a decision to miss.

  PreferredSeries* = proc (r: Ohms): Ohms {.nimcall.}
    ## Rounds a computed resistance to a value that can be bought. Proc-valued
    ## for the same reason `PartPolicy` is: a project with its own stock list
    ## substitutes one and behaves identically, and a builder taking one as a
    ## parameter never has to know which it was given.

const
  seriesE12* = ESeries(name: "E12", tolerance: Fraction(0.10), mantissas: @[
    1.0, 1.2, 1.5, 1.8, 2.2, 2.7, 3.3, 3.9, 4.7, 5.6, 6.8, 8.2])

  seriesE24* = ESeries(name: "E24", tolerance: Fraction(0.05), mantissas: @[
    1.0, 1.1, 1.2, 1.3, 1.5, 1.6, 1.8, 2.0, 2.2, 2.4, 2.7, 3.0,
    3.3, 3.6, 3.9, 4.3, 4.7, 5.1, 5.6, 6.2, 6.8, 7.5, 8.2, 9.1])

  seriesE96* = ESeries(name: "E96", tolerance: Fraction(0.01), mantissas: @[
    1.00, 1.02, 1.05, 1.07, 1.10, 1.13, 1.15, 1.18, 1.21, 1.24, 1.27, 1.30,
    1.33, 1.37, 1.40, 1.43, 1.47, 1.50, 1.54, 1.58, 1.62, 1.65, 1.69, 1.74,
    1.78, 1.82, 1.87, 1.91, 1.96, 2.00, 2.05, 2.10, 2.15, 2.21, 2.26, 2.32,
    2.37, 2.43, 2.49, 2.55, 2.61, 2.67, 2.74, 2.80, 2.87, 2.94, 3.01, 3.09,
    3.16, 3.24, 3.32, 3.40, 3.48, 3.57, 3.65, 3.74, 3.83, 3.92, 4.02, 4.12,
    4.22, 4.32, 4.42, 4.53, 4.64, 4.75, 4.87, 4.99, 5.11, 5.23, 5.36, 5.49,
    5.62, 5.76, 5.90, 6.04, 6.19, 6.34, 6.49, 6.65, 6.81, 6.98, 7.15, 7.32,
    7.50, 7.68, 7.87, 8.06, 8.25, 8.45, 8.66, 8.87, 9.09, 9.31, 9.53, 9.76])

proc nearest*(s: ESeries, x: float): float =
  ## The nearest value of `s` to `x`, nearest meaning smallest ratio.
  ##
  ## A value that is not a positive, finite magnitude comes back unchanged.
  ## There is no preferred value near zero or near infinity, and inventing one
  ## would turn a caller's arithmetic mistake into a plausible component.
  if s.mantissas.len == 0: return x
  if x.classify notin {fcNormal, fcSubnormal} or x <= 0.0: return x

  let decade = pow(10.0, floor(log10(x)))
  let m = x / decade
  var best = s.mantissas[0]
  var bestErr = Inf
  # The next decade's first value is 10 in this decade's terms, and for a
  # mantissa just under it that is the nearest preferred value: 9.9 is 1.0%
  # below 10.0 and 1.4% above E96's 9.76.
  for cand in s.mantissas & @[10.0]:
    let err = abs(ln(cand / m))
    if err < bestErr:
      bestErr = err
      best = cand
  best * decade

proc nearest*[T: Quantity](s: ESeries, v: T): T =
  ## As above, for any `verax/units` quantity. A ladder is a ladder: the same
  ## E12 values that are resistors in ohms are capacitors in farads.
  T(nearest(s, float(v)))

proc relativeError*(s: ESeries, x: float): float =
  ## How far `nearest(s, x)` lands from `x`, as a fraction of `x`. Signed, so
  ## the direction is visible -- which matters wherever a rounding has to be
  ## traded against a tolerance stack rather than merely reported.
  if x == 0.0: return 0.0
  (nearest(s, x) - x) / x

proc exactSeries*(r: Ohms): Ohms {.nimcall.} =
  ## The default a builder should carry: no rounding at all.
  r

proc e12*(r: Ohms): Ohms {.nimcall.} = nearest(seriesE12, r)
proc e24*(r: Ohms): Ohms {.nimcall.} = nearest(seriesE24, r)
proc e96*(r: Ohms): Ohms {.nimcall.} = nearest(seriesE96, r)
  ## The three ladders as `PreferredSeries` procs, which is the form a builder
  ## takes. Anything else -- a stock list, a series with values struck out, a
  ## rounder that prefers a pair it already has on the board -- is an ordinary
  ## proc of the same shape.
