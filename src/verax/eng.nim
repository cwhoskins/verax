## Engineering-notation formatting for human-readable output.
##
## Every quantity this library reports is physical and spans many decades --
## milliohms to kilohms, hertz to gigahertz, nanohenries to microfarads -- and
## a reader has to judge it at a glance against a datasheet figure written the
## same way. `1.591549e+07 Hz` does not support that; `15.9 MHz` does.
##
## This is strictly for *presentation*: report text, issue messages, assumption
## lines. A device value written into a SPICE deck must go through
## `netlist/formats/spice.spiceValue` instead, which never emits a trailing
## letter that SPICE would read as a unit multiplier -- `15.9M` in a deck means
## 15.9 milli, not 15.9 mega.
##
## It lives at the package root because both `verax/spice` (isolation and
## model assumptions) and `verax/analysis` (reports) need it, and `analysis`
## already depends on `spice`, so it cannot live in either.

import std/[math, strutils]

const
  siPrefixes = ["y", "z", "a", "f", "p", "n", "u", "m", "",
                "k", "M", "G", "T", "P", "E"]
  siZero = 8  ## index of the empty prefix
  noPrefixUnits = ["dB", "dBm", "dBc", "dBi", "degC"]
    ## Units an SI prefix would misread, not merely fail to help. A gain or a
    ## noise figure is a logarithmic *ratio*, and "milli-dB" is not a smaller
    ## dB the way a milliohm is a smaller ohm -- there is no such thing as a
    ## thousandth of a ratio-in-decibels, and rendering one invents a unit
    ## nobody uses. This was a live defect, not a hypothetical one:
    ## `eng(0.5, "dB")` rendered `"500 mdB"` before this list existed, because
    ## the loop below treats every unit string alike. `degC` joins for the
    ## same reason `units.Celsius`'s own `$` already special-cases it -- a
    ## half-degree rise printed `500 mdegC` is the identical misread -- kept
    ## here too because `eng` is called directly with a bare `"degC"` string
    ## from callers that never go through a `Celsius` value.
    ##
    ## Matched against the literal string, not through `units.unitOf`: `eng`
    ## takes a bare `(float, string)` pair and must stay quantity-agnostic --
    ## teaching it about `verax/units` would invert the dependency direction
    ## `units.nim` already has on this module.

proc eng*(x: float, unit = "", sig = 3): string =
  ## `sig` significant figures plus an SI prefix, e.g. `eng(0.0201, "ohm")`
  ## gives `20.1 mohm` and `eng(6e-10, "H")` gives `600 pH`. A unit in
  ## `noPrefixUnits` skips prefixing entirely and is rendered as a bare
  ## decimal instead, for the reason given there.
  ##
  ## The space goes between the mantissa and the *prefix*, not between the
  ## prefix and the unit, because the prefix belongs to the unit: `600 pH`,
  ## never `600p H`. `NaN` renders as `n/a` -- which is what a measurement
  ## that never occurred in the swept range should read as, rather than a
  ## number.
  let suffix = if unit.len > 0: " " & unit else: ""
  if x.isNaN: return "n/a"
  if x == Inf: return "inf" & suffix
  if x == -Inf: return "-inf" & suffix
  if x == 0.0: return "0" & suffix

  var idx = siZero
  var v = x
  let skipPrefix = unit in noPrefixUnits
  if not skipPrefix:
    while abs(v) >= 1000.0 and idx < siPrefixes.high:
      v /= 1000.0
      inc idx
    while abs(v) < 1.0 and idx > 0:
      v *= 1000.0
      dec idx

  var mantissa: string
  if skipPrefix:
    # `v` is unscaled here and may sit anywhere below 1 -- the intDigits
    # table below assumes a prefix already normalised it into [1, 1000) and
    # would otherwise round a small ratio straight to "0". Pick the decimal
    # count from `v`'s own order of magnitude instead, then trim the
    # trailing zeros that gives back for a value that needed fewer of them
    # (3 significant figures of 0.5 is "0.500", and "0.5" is what a reader
    # of a gain or a noise figure expects).
    let mag = int(floor(log10(abs(v))))
    mantissa = formatFloat(v, ffDecimal, max(sig - 1 - mag, 0))
    while mantissa.contains('.') and mantissa.endsWith("0"):
      mantissa.setLen(mantissa.len - 1)
  else:
    let intDigits = if abs(v) >= 100.0: 3 elif abs(v) >= 10.0: 2 else: 1
    mantissa = formatFloat(v, ffDecimal, max(sig - intDigits, 0))
  if mantissa.endsWith("."): mantissa.setLen(mantissa.len - 1)
  if unit.len == 0: mantissa & siPrefixes[idx]
  else: mantissa & " " & siPrefixes[idx] & unit
