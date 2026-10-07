## Preferred values: the numbers resistors and capacitors are sold in (E12,
## E24 for 5%, E96 for 1%).
##
## **Rounding is asked for, never applied by default**: a builder that
## quietly rounds builds something other than what you asked for. A caller
## passing a `PreferredSeries` must recompute the circuit from the values it
## will actually have.
##
## **Tables are written out, not computed**: E24 deviates from `10^(n/24)`
## through mid-decade (2.7, 3.0, 3.3 ... not 2.61, 2.87, 3.16), and the
## formula would give unbuyable values. E96 is written out too, for
## consistency.
##
## **Nearest is logarithmic**: `abs(ln(candidate/wanted))`, including the
## next decade's first value.
##
## A series says which values exist, not which are stocked; a
## preferred-parts database can be substituted since `PreferredSeries` is a
## proc.

import std/math

import ../units

type
  ESeries* = object
    ## One preferred-value ladder.
    name*: string
    mantissas*: seq[float]
      ## One decade's values in `[1, 10)`, strictly increasing.
    tolerance*: Fraction
      ## The tolerance the series was spaced for -- not a bought part's
      ## (E24 values are stocked at 1%), but whether rounding is coherent.

  PreferredSeries* = proc (r: Ohms): Ohms {.nimcall.}
    ## Rounds a computed resistance to a buyable value. Proc-valued so a
    ## project's own stock list can be substituted.

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
  ## The nearest value of `s` to `x` by ratio. A non-positive or non-finite
  ## value comes back unchanged.
  if s.mantissas.len == 0: return x
  if x.classify notin {fcNormal, fcSubnormal} or x <= 0.0: return x

  let decade = pow(10.0, floor(log10(x)))
  let m = x / decade
  var best = s.mantissas[0]
  var bestErr = Inf
  # The next decade's 10.0 can be nearest (9.9 is closer to 10.0 than to
  # 9.76).
  for cand in s.mantissas & @[10.0]:
    let err = abs(ln(cand / m))
    if err < bestErr:
      bestErr = err
      best = cand
  best * decade

proc nearest*[T: Quantity](s: ESeries, v: T): T =
  ## As above, for any `verax/units` quantity.
  T(nearest(s, float(v)))

proc relativeError*(s: ESeries, x: float): float =
  ## Signed fractional error of `nearest(s, x)` from `x`.
  if x == 0.0: return 0.0
  (nearest(s, x) - x) / x

proc exactSeries*(r: Ohms): Ohms {.nimcall.} =
  ## The default a builder should carry: no rounding at all.
  r

proc e12*(r: Ohms): Ohms {.nimcall.} = nearest(seriesE12, r)
proc e24*(r: Ohms): Ohms {.nimcall.} = nearest(seriesE24, r)
proc e96*(r: Ohms): Ohms {.nimcall.} = nearest(seriesE96, r)
  ## The ladders as `PreferredSeries` procs; anything else of the same shape
  ## works too.
