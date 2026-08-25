import std/[math, unittest]

import nimcir/units

test "suffixes scale to SI base units":
  check toFloat(3.3.V) == 3.3
  check abs(toFloat(20.mohm) - 0.02) < 1e-15
  check abs(toFloat(600.pH) - 600e-12) < 1e-24
  check toFloat(400.kHz) == 400_000.0
  check abs(toFloat(100.nF) - 100e-9) < 1e-20
  check abs(toFloat(5.pct) - 0.05) < 1e-15
  check abs(toFloat(10.ppm) - 10e-6) < 1e-15

test "integer and float literals both work":
  check toFloat(100.nF) == toFloat(100.0.nF)
  check toFloat(1.kohm) == 1000.0

test "milli and mega are distinguished by case, unlike SPICE":
  # This is the whole reason the types exist: in a SPICE deck `1M` is milli
  # and mega is spelled `MEG`, so a bare "20m" is ambiguous to a reader and
  # a factor of 1e6 away from `Mohm`.
  check toFloat(20.mohm) == 0.02
  check toFloat(20.Mohm) == 20_000_000.0

test "unitOf reports the SI base symbol the registry uses":
  check unitOf(1.V) == "V"
  check unitOf(1.ohm) == "ohm"
  check unitOf(1.F) == "F"
  check unitOf(1.H) == "H"
  check unitOf(1.Hz) == "Hz"
  check unitOf(1.s) == "s"
  check unitOf(1.A) == "A"
  check unitOf(1.pct) == ""      # dimensionless

test "display uses engineering notation, and a fraction reads as a percent":
  check $(20.mohm) == "20.0 mohm"
  check $(600.pH) == "600 pH"
  check $(400.kHz) == "400 kHz"
  check $(3.3.V) == "3.30 V"
  # 0.05 rendered through SI prefixes is "50.0m", which is true and useless.
  check $(5.pct) == "5.00%"

test "quantities of different dimensions are distinct types":
  # Not a dimensional-analysis system, but the types are at least disjoint,
  # which is what lets the annotation registry reject `esr = 20.nF`.
  check not compiles((let x: Ohms = 20.nF))
  check not compiles(toFloat(20.mohm) + 1.V)
  check not compiles(20.mohm + 20.mohm)   # no arithmetic on quantities

# --- phase and logarithmic ratio ---------------------------------------

test "deg and dB are literals, so a role parameter need not be a bare float":
  # The roles declare minPhaseMargin in degrees and maxPeaking in dB, and a
  # bare number in a list of unit literals is exactly the misread this
  # module exists to remove.
  check toFloat(50.deg) == 50.0
  check toFloat(3.dB) == 3.0
  check unitOf(50.deg) == "deg"
  check unitOf(3.dB) == "dB"

test "dB and db are the same literal, because Nim reads them as one identifier":
  check toFloat(6.dB) == toFloat(6.db)

test "a dB literal stores the dB figure, not the ratio it denotes":
  # Every consumer compares against a measurement already in dB --
  # `gain_max_db` is dB -- so converting here would mean converting back at
  # each use.
  check toFloat(20.dB) == 20.0

test "negative phase and gain are ordinary values":
  check toFloat(-45.deg) == -45.0
  check toFloat(-3.dB) == -3.0
