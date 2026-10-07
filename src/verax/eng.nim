## Engineering-notation formatting for human-readable output: `15.9 MHz`,
## not `1.591549e+07 Hz`. **Presentation only** -- deck values go through
## `netlist/formats/spice.spiceValue` (`15.9M` in a deck is milli). At the
## package root because `spice` and `analysis` both need it.

import std/[math, strutils]

const
  siPrefixes = ["y", "z", "a", "f", "p", "n", "u", "m", "",
                "k", "M", "G", "T", "P", "E"]
  siZero = 8  ## index of the empty prefix
  noPrefixUnits = ["dB", "dBm", "dBc", "dBi", "degC"]
    ## Units an SI prefix would misread: "milli-dB" isn't a unit, so
    ## `eng(0.5, "dB")` must not give `"500 mdB"`; likewise `degC`. Matched
    ## as literal strings, since `eng` stays quantity-agnostic (`units`
    ## depends on this module, not the reverse).

proc eng*(x: float, unit = "", sig = 3): string =
  ## `sig` significant figures plus an SI prefix (`eng(0.0201, "ohm")` ->
  ## `20.1 mohm`). Units in `noPrefixUnits` render as bare decimals. The
  ## space precedes the prefix (`600 pH`). `NaN` renders as `n/a`.
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
    # Unscaled `v` may be anywhere below 1, so choose decimals from its own
    # magnitude, then trim trailing zeros ("0.5", not "0.500").
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
