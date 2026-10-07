import std/[math, unittest]

import verax/units
import verax/eng

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
  # In SPICE `1M` is milli and mega is `MEG`, so a bare "20m" is ambiguous.
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
  # "50.0m" would be true and useless.
  check $(5.pct) == "5.00%"

test "quantities of different dimensions are distinct types":
  # Disjoint types let the annotation registry reject `esr = 20.nF`.
  check not compiles((let x: Ohms = 20.nF))
  check not compiles(toFloat(20.mohm) + 1.V)
  check not compiles(20.mohm + 20.mohm)   # no arithmetic on quantities

# --- phase and logarithmic ratio ---------------------------------------

test "deg and dB are literals, so a role parameter need not be a bare float":
  # Role parameters take unit literals, not bare floats.
  check toFloat(50.deg) == 50.0
  check toFloat(3.dB) == 3.0
  check unitOf(50.deg) == "deg"
  check unitOf(3.dB) == "dB"

test "dB and db are the same literal, because Nim reads them as one identifier":
  check toFloat(6.dB) == toFloat(6.db)

test "a dB literal stores the dB figure, not the ratio it denotes":
  # Consumers compare against measurements already in dB.
  check toFloat(20.dB) == 20.0

test "negative phase and gain are ordinary values":
  check toFloat(-45.deg) == -45.0
  check toFloat(-3.dB) == -3.0

# --- eng() must not SI-prefix a logarithmic unit -----------------------

test "eng() renders dB as a bare decimal, not SI-prefixed":
  # eng() must not SI-prefix dB: 0.5 dB is not "500 mdB".
  check eng(0.5, "dB") == "0.5 dB"
  # Nor "2 mdB".
  check eng(0.002, "dB") == "0.002 dB"

test "NoiseDensity still SI-prefixes, since a spectral density genuinely has decades":
  check $(4.1.nVrtHz) == "4.10 nV/rtHz"

# --- absolute power and carrier-relative ratios ------------------------

test "DBm and DBc round-trip and report their own unit strings":
  check toFloat(10.dBm) == 10.0
  check toFloat(-6.dBc) == -6.0
  check unitOf(10.dBm) == "dBm"
  check unitOf((-6).dBc) == "dBc"

test "DBm and DBc render as bare decimals through eng(), same as Decibels":
  check $(0.5.dBm) == "0.5 dBm"
  check $((-6.0).dBc) == "-6 dBc"

test "DBm, DBc and Decibels are distinct types, so a dBm cannot be mistaken for a dB gain":
  check not compiles((let x: Decibels = 10.dBm))
  check not compiles((let x: DBm = 10.dB))
  check not compiles((let x: DBc = 10.dBm))

test "NoiseDensity suffix constructors scale to volts per root-hertz":
  check toFloat(1.VrtHz) == 1.0
  check abs(toFloat(4.1.nVrtHz) - 4.1e-9) < 1e-18
  check unitOf(1.VrtHz) == "V/rtHz"
