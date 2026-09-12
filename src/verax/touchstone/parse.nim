## The Touchstone *lexer*: splitting `.sNp` text into the option line and
## data rows, with no knowledge yet of what a row's numbers represent.
##
## Kept separate from `verax/touchstone/reader` for a narrower reason than
## `verax/ibis/parse` gives for the same split. IBIS separates its lexer so
## an unmodelled *keyword* can still round-trip in `IbisFile.sections` --
## nothing here reads unrecognised content back out, since a Touchstone file
## has no equivalent of "a block this version does not model": every line
## after the option line is a data row of a shape the option line already
## fixed. The split survives anyway because parsing a numeric token
## (`parseTouchstoneNumber`) and deciding what an *option-line* token means
## are genuinely different jobs, and testing the former without dragging in
## `SParams` construction is worth keeping easy.
##
## **The option line gets no benefit of the doubt.** `[Comment Char]` in
## IBIS redefines one piece of syntax and everything else keeps its
## documented meaning regardless, so an unmodelled keyword elsewhere in the
## file is still safe to skip. A Touchstone option line has no such
## independence: `# GHZ S RI R 50` fixes the frequency scale, which parameter
## is tabulated, which of two wildly different numeric layouts every
## following row uses, and the reference impedance every derived quantity
## divides by. An option-line token this reader does not recognise means it
## cannot say what any subsequent row *is*, so it raises `TouchstoneError`
## rather than guessing a default and silently misreading the whole file --
## unlike IBIS's degrade-and-keep, there is no safe "keep it and move on"
## here.

import std/[parseutils, strutils]
import ./types

type
  FrequencyUnit* = enum
    fuHz, fuKHz, fuMHz, fuGHz

  ParamType* = enum
    ptS, ptY, ptZ, ptH, ptG
      ## Touchstone also allows Y/Z/H/G parameter files; this reader parses
      ## the option line for all five (so a non-S file fails with a clear
      ## "not S-parameters" rather than a confusing table-shape mismatch)
      ## but only `reader.nim`'s `SParams` consumes `ptS`.

  DataFormat* = enum
    dfRI  ## real, imaginary
    dfMA  ## magnitude, angle in degrees
    dfDB  ## dB-magnitude, angle in degrees

  OptionLine* = object
    freqUnit*: FrequencyUnit
    param*: ParamType
    format*: DataFormat
    z0*: float

proc freqScale*(u: FrequencyUnit): float =
  ## Multiplier to Hz.
  case u
  of fuHz: 1.0
  of fuKHz: 1e3
  of fuMHz: 1e6
  of fuGHz: 1e9

proc parseTouchstoneNumber*(text: string, value: var float): bool =
  ## Parses one Touchstone numeric token: a plain decimal or scientific
  ## literal, nothing else. On success sets `value` and returns `true`; on
  ## anything it will not vouch for, `value` is left untouched and `false`
  ## is returned.
  ##
  ## Shaped like `ibis/parse.parseIbisNumber` and
  ## `netlist/formats/spice.parseSpiceMagnitude`: a `bool` + `var` out-param
  ## that **refuses rather than guesses**. Touchstone data rows carry no
  ## metric-prefix suffixes at all (frequency scaling is stated once, on the
  ## option line, not per row), so unlike those two this proc has no prefix
  ## table to consult -- anything left over after the numeric literal is
  ## refused outright rather than partially accepted.
  let s = text.strip()
  if s.len == 0: return false
  var f: float
  let n = parseutils.parseFloat(s, f)
  if n == 0 or n != s.len: return false
  value = f
  true

proc parseOptionLine*(line: string): OptionLine =
  ## Parses a Touchstone option line (`# GHZ S RI R 50`): order-independent
  ## tokens for frequency unit, parameter type, data format and reference
  ## impedance. Defaults match the spec's when a token is omitted (GHz files
  ## must state their unit, but `R 50` may be entirely absent, meaning
  ## 50 ohm). Raises `TouchstoneError` on a token this reader does not
  ## recognise -- see the module doc for why that is the right failure mode
  ## here and not a degrade-and-keep.
  result = OptionLine(freqUnit: fuGHz, param: ptS, format: dfMA, z0: 50.0)
  let toks = line.strip().splitWhitespace()
  if toks.len == 0 or toks[0] != "#":
    raise newException(TouchstoneError,
      "option line does not start with '#': " & line.escape())
  var i = 1
  while i < toks.len:
    let tok = toks[i].toUpperAscii()
    case tok
    of "HZ": result.freqUnit = fuHz
    of "KHZ": result.freqUnit = fuKHz
    of "MHZ": result.freqUnit = fuMHz
    of "GHZ": result.freqUnit = fuGHz
    of "S": result.param = ptS
    of "Y": result.param = ptY
    of "Z": result.param = ptZ
    of "H": result.param = ptH
    of "G": result.param = ptG
    of "RI": result.format = dfRI
    of "MA": result.format = dfMA
    of "DB": result.format = dfDB
    of "R":
      inc i
      if i >= toks.len:
        raise newException(TouchstoneError,
          "option line: 'R' with no reference impedance: " & line.escape())
      var z: float
      if not parseTouchstoneNumber(toks[i], z):
        raise newException(TouchstoneError,
          "option line: 'R' value is not a number: " & toks[i].escape())
      result.z0 = z
    else:
      raise newException(TouchstoneError,
        "option line: unrecognised token '" & toks[i] &
        "' -- every option-line token fixes how the rows that follow are " &
        "read, so an unmodelled one cannot be safely skipped: " &
        line.escape())
    inc i
  # Touchstone permits any or all of these tokens to be omitted, taking the
  # documented default silently -- `GHZ` is the file format's historical
  # universal default for frequency and `MA`/`S`/`R 50` are the spec's
  # stated defaults for the rest, so an option line as short as `# S RI` is
  # ordinary and not a warning-worthy omission.
