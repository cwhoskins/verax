import std/unittest

import verax/touchstone/parse
import verax/touchstone/types

test "the option line's tokens are order-independent":
  let a = parseOptionLine("# GHZ S RI R 50")
  let b = parseOptionLine("# R 50 RI S GHZ")
  check a.freqUnit == b.freqUnit
  check a.param == b.param
  check a.format == b.format
  check a.z0 == b.z0
  check a.freqUnit == fuGHz
  check a.param == ptS
  check a.format == dfRI
  check a.z0 == 50.0

test "an omitted token takes the spec's documented default":
  # GHz and S/MA/R 50 are the spec defaults, so `# S RI` is ordinary.
  let opt = parseOptionLine("# S RI")
  check opt.freqUnit == fuGHz
  check opt.z0 == 50.0

test "case is not significant on option-line tokens":
  let opt = parseOptionLine("# mhz s db r 75")
  check opt.freqUnit == fuMHz
  check opt.format == dfDB
  check opt.z0 == 75.0

test "a line not starting with '#' is not an option line":
  expect(TouchstoneError):
    discard parseOptionLine("GHZ S RI R 50")

test "an unrecognised option-line token raises, unlike IBIS's degrade-and-keep":
  # Every option token governs how the rows are read; none can be skipped.
  expect(TouchstoneError):
    discard parseOptionLine("# THZ S RI R 50")

test "'R' with no following number raises rather than silently keeping 50":
  expect(TouchstoneError):
    discard parseOptionLine("# GHZ S RI R")
  expect(TouchstoneError):
    discard parseOptionLine("# GHZ S RI R notanumber")

test "freqScale converts each unit to a multiplier on hertz":
  check freqScale(fuHz) == 1.0
  check freqScale(fuKHz) == 1e3
  check freqScale(fuMHz) == 1e6
  check freqScale(fuGHz) == 1e9

# --- parseTouchstoneNumber ----------------------------------------------

test "parseTouchstoneNumber accepts plain decimal and scientific literals":
  var v: float
  check parseTouchstoneNumber("1.5", v)
  check v == 1.5
  check parseTouchstoneNumber("-3.25", v)
  check v == -3.25
  check parseTouchstoneNumber("2.5e9", v)
  check v == 2.5e9
  check parseTouchstoneNumber("1E-3", v)
  check v == 1e-3

test "parseTouchstoneNumber refuses anything with trailing junk":
  # Touchstone rows carry no metric prefixes (scaling is on the option
  # line), so refuse outright.
  var v: float
  check not parseTouchstoneNumber("1.5k", v)
  check not parseTouchstoneNumber("1.5MHz", v)
  check not parseTouchstoneNumber("abc", v)
  check not parseTouchstoneNumber("", v)
  check not parseTouchstoneNumber("1,5", v)

test "parseTouchstoneNumber leaves value untouched on refusal":
  var v = 42.0
  check not parseTouchstoneNumber("garbage", v)
  check v == 42.0
