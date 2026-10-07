## The Touchstone *lexer*: `.sNp` text into the option line and data rows.
## Separate from `reader` so numeric-token parsing is testable without
## building `SParams`.
##
## **The option line gets no benefit of the doubt**: `# GHZ S RI R 50` fixes
## frequency scale, parameter, numeric layout and reference impedance for
## every row, so an unrecognised token raises `TouchstoneError` rather than
## risk misreading the whole file.

import std/[parseutils, strutils]
import ./types

type
  FrequencyUnit* = enum
    fuHz, fuKHz, fuMHz, fuGHz

  ParamType* = enum
    ptS, ptY, ptZ, ptH, ptG
      ## Y/Z/H/G files are recognised (so a non-S file fails clearly), but
      ## only `ptS` is consumed.

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
  ## Parses one numeric token: a plain decimal or scientific literal only
  ## (no prefixes -- scaling is on the option line). Refuses rather than
  ## guesses; `value` is untouched on failure.
  let s = text.strip()
  if s.len == 0: return false
  var f: float
  let n = parseutils.parseFloat(s, f)
  if n == 0 or n != s.len: return false
  value = f
  true

proc parseOptionLine*(line: string): OptionLine =
  ## Parses an option line (`# GHZ S RI R 50`): order-independent tokens.
  ## Omitted tokens take the spec defaults (GHz, S, MA, R 50). Unknown tokens
  ## raise.
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
  # Any token may be omitted, taking the spec's defaults; `# S RI` is
  # ordinary.
