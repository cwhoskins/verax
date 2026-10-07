## `formatMm`/`formatDeg`/`formatAt` against KiCad's literal forms, plus
## negative lengths, sub-micron fractions, and trailing-zero stripping
## (`formatFloat(ffDefault)` keeps them).

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
  # Every decimal place occupied, exposing padding off-by-ones.
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
  # Not folded into [0, 360): KiCad writes -90 and a fold would diff.
  check formatDeg(deg(-90.0)) != "270"
  # A fractional angle proves trailing-zero stripping.
  check formatDeg(deg(12.345)) == "12.345"

test "formatAt omits a zero rotation and Y-flips the position":
  # A zero angle is omitted, as KiCad writes it.
  check formatAt(pt(mm(101.0), mm(0.0)), deg(0.0)) == "101 0"
  # Canonical Y-up -> KiCad Y-down: a positive canonical Y becomes negative.
  check formatAt(pt(mm(10.0), mm(5.0)), deg(0.0)) == "10 -5"
  check formatAt(pt(mm(10.0), mm(-5.0)), deg(0.0)) == "10 5"
  # Rotation passes through verbatim; the caller has already flipped it.
  check formatAt(pt(mm(0.0), mm(0.0)), deg(-90.0)) == "0 0 -90"

test "escapeKicadString is the inverse of the reader's decode and always quotes":
  check escapeKicadString("") == "\"\""
  check escapeKicadString("VCC") == "\"VCC\""
  check escapeKicadString("a\\b") == "\"a\\\\b\""
  check escapeKicadString("say \"hi\"") == "\"say \\\"hi\\\"\""
  check escapeKicadString("line1\nline2") == "\"line1\\nline2\""
