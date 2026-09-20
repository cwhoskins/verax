## `formatMm`/`formatDeg`/`formatAt` against every distinct literal the plan's
## own corpus survey found (see `kicadfmt.nim`'s module doc for the counts),
## plus the boundary cases a survey of "what's actually in 18 files" cannot
## guarantee it caught: negative lengths, sub-micron fractions, and the
## angle-normalisation trap `std/strutils.formatFloat(ffDefault, ...)` falls
## into (it keeps trailing zeros -- verified, see the module doc).

import std/unittest

import verax/pcb/formats/kicadfmt
import verax/pcb/units
import verax/pcb/geometry

test "formatMm reproduces every distinct length literal the plan measured":
  check formatMm(mm(0.0)) == "0"
  check formatMm(mm(90.0)) == "90"
  check formatMm(mm(2.5)) == "2.5"
  check formatMm(mm(141.605)) == "141.605"
  check formatMm(nm(1)) == "0.000001"          # finest KiCad-representable step
  check formatMm(mm(-90.0)) == "-90"
  check formatMm(mm(-2.5)) == "-2.5"
  check formatMm(mm(0.01)) == "0.01"
  check formatMm(mm(100.0)) == "100"
  # A value with every one of the six decimal places occupied, none of them
  # trailing zero -- the case that would expose an off-by-one in the padding.
  check formatMm(nm(123456)) == "0.123456"
  check "-0" != formatMm(nm(0))

test "formatDeg reproduces every distinct angle literal the plan measured, signed":
  check formatDeg(deg(180.0)) == "180"
  check formatDeg(deg(90.0)) == "90"
  check formatDeg(deg(-90.0)) == "-90"
  check formatDeg(deg(-135.0)) == "-135"
  check formatDeg(deg(-45.0)) == "-45"
  check formatDeg(deg(45.0)) == "45"
  check formatDeg(deg(135.0)) == "135"
  check formatDeg(deg(0.0)) == "0"
  # Not folded into [0, 360) -- 768 of the corpus's angle literals are
  # exactly this shape and a fold would turn every one into a diff.
  check formatDeg(deg(-90.0)) != "270"
  # A genuinely fractional angle, to prove trailing-zero stripping (the
  # documented reason `ffDefault` was rejected: `formatFloat(90.0, ffDefault,
  # 10)` yields `"90.00000000"`, not `"90"`).
  check formatDeg(deg(12.345)) == "12.345"

test "formatAt omits a zero rotation and Y-flips the position":
  # 1307 of 4152 `(at)` nodes in the corpus omit the angle field entirely
  # because it is zero -- not because KiCad ever writes `(at x y 0)`.
  check formatAt(pt(mm(101.0), mm(0.0)), deg(0.0)) == "101 0"
  # Canonical Y-up -> KiCad Y-down: a positive canonical Y becomes negative.
  check formatAt(pt(mm(10.0), mm(5.0)), deg(0.0)) == "10 -5"
  check formatAt(pt(mm(10.0), mm(-5.0)), deg(0.0)) == "10 5"
  # Rotation is passed through verbatim -- the caller is documented to have
  # already flipped its sign before calling this.
  check formatAt(pt(mm(0.0), mm(0.0)), deg(-90.0)) == "0 0 -90"

test "escapeKicadString is the inverse of the reader's decode and always quotes":
  check escapeKicadString("") == "\"\""
  check escapeKicadString("VCC") == "\"VCC\""
  check escapeKicadString("a\\b") == "\"a\\\\b\""
  check escapeKicadString("say \"hi\"") == "\"say \\\"hi\\\"\""
  check escapeKicadString("line1\nline2") == "\"line1\\nline2\""
