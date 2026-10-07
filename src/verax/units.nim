## Typed electrical quantities for authoring annotations: `esr = 20.mohm`
## can't be misread the way `"20m"` vs `"0.02"` can. Values are stored in SI
## base units.
##
## **Not a dimensional-analysis system**: no unit arithmetic or derived
## units. If that's ever wanted, it belongs in its own module.
##
## Distinct from `verax/pcb/units` (board geometry, `Nm`/`Deg`); names and
## suffixes don't collide.

import std/strutils
import ./eng

type
  Volts* = distinct float
  Ohms* = distinct float
  Farads* = distinct float
  Henries* = distinct float
  Hertz* = distinct float
  Seconds* = distinct float
  Amps* = distinct float
  Watts* = distinct float
    ## Power, for resistor ratings and derating checks.
  Fraction* = distinct float
    ## A dimensionless fraction: `5.pct` is `0.05`. For bands and tolerances.
  Degrees* = distinct float
    ## Phase in degrees (e.g. `minPhaseMargin`), so it isn't a bare number.
  Decibels* = distinct float
    ## Stores the dB figure, not the ratio, since measurements are in dB.

  Celsius* = distinct float
    ## Temperature in degC (every source uses it). Carries both absolute
    ## temperatures (`t_ambient_max`) and differences (`delta_t`); the key
    ## says which, and only `netlist/environment` adds them.

  DBm* = distinct float
    ## Absolute power, dB relative to 1 mW. Distinct from `Decibels` so
    ## `unitsAgree` can tell a level (dBm) from a gain (dB): adding dB to dBm
    ## is valid, dBm to dBm isn't. Conversions live in `touchstone/types`.
  DBc* = distinct float
    ## Power relative to a carrier ("-60 dBc"), whose reference moves with
    ## the carrier. No annotation uses it yet.
  NoiseDensity* = distinct float
    ## Voltage noise density, V/rtHz. No current-noise constructor until
    ## something produces one.

  Quantity* = Volts | Ohms | Farads | Henries | Hertz | Seconds | Amps |
              Watts | Fraction | Degrees | Decibels | Celsius |
              DBm | DBc | NoiseDensity

template defCtor(name: untyped, T: typedesc, scale: float) =
  proc name*(x: SomeNumber): T {.inline.} =
    ## Suffix constructor; the value is scaled to SI base units.
    T(float(x) * scale)

# Voltage
defCtor(V, Volts, 1.0)
defCtor(mV, Volts, 1e-3)
defCtor(uV, Volts, 1e-6)
defCtor(kV, Volts, 1e3)

# Resistance. `Mohm` is mega and `mohm` milli (SI), unlike case-insensitive
# SPICE's `MEG`.
defCtor(ohm, Ohms, 1.0)
defCtor(uohm, Ohms, 1e-6)
defCtor(mohm, Ohms, 1e-3)
defCtor(kohm, Ohms, 1e3)
defCtor(Mohm, Ohms, 1e6)
defCtor(Gohm, Ohms, 1e9)

# Capacitance
defCtor(F, Farads, 1.0)
defCtor(mF, Farads, 1e-3)
defCtor(uF, Farads, 1e-6)
defCtor(nF, Farads, 1e-9)
defCtor(pF, Farads, 1e-12)

# Inductance
defCtor(H, Henries, 1.0)
defCtor(mH, Henries, 1e-3)
defCtor(uH, Henries, 1e-6)
defCtor(nH, Henries, 1e-9)
defCtor(pH, Henries, 1e-12)

# Frequency
defCtor(Hz, Hertz, 1.0)
defCtor(kHz, Hertz, 1e3)
defCtor(MHz, Hertz, 1e6)
defCtor(GHz, Hertz, 1e9)

# Time
defCtor(s, Seconds, 1.0)
defCtor(ms, Seconds, 1e-3)
defCtor(us, Seconds, 1e-6)
defCtor(ns, Seconds, 1e-9)
defCtor(ps, Seconds, 1e-12)

# Current
defCtor(A, Amps, 1.0)
defCtor(mA, Amps, 1e-3)
defCtor(uA, Amps, 1e-6)
defCtor(nA, Amps, 1e-9)

defCtor(W, Watts, 1.0)
defCtor(mW, Watts, 1e-3)
defCtor(kW, Watts, 1e3)

# Temperature: Celsius only. `20.K` would be ambiguous between a rise
# (20 degC) and an absolute (-253 degC).
defCtor(degC, Celsius, 1.0)

# Dimensionless
defCtor(pct, Fraction, 1e-2)
defCtor(ppm, Fraction, 1e-6)

# Phase and logarithmic ratio. Nim treats `dB` and `db` as one identifier.
defCtor(deg, Degrees, 1.0)
defCtor(dB, Decibels, 1.0)

# Absolute and carrier-relative power. `DBm` (type) and `dBm` (constructor)
# differ in their case-significant first character.
defCtor(dBm, DBm, 1.0)
defCtor(dBc, DBc, 1.0)

# Noise density. `nVrtHz` is the datasheet decade.
defCtor(VrtHz, NoiseDensity, 1.0)
defCtor(nVrtHz, NoiseDensity, 1e-9)

proc toFloat*(q: Quantity): float {.inline.} =
  ## The value in SI base units.
  float(q)

proc unitOf*(q: Quantity): string =
  ## The SI base unit symbol, matching the `unit` strings the annotation
  ## registry declares. `Fraction` has none.
  when q is Volts: "V"
  elif q is Ohms: "ohm"
  elif q is Farads: "F"
  elif q is Henries: "H"
  elif q is Hertz: "Hz"
  elif q is Seconds: "s"
  elif q is Amps: "A"
  elif q is Watts: "W"
  elif q is Degrees: "deg"
  elif q is Decibels: "dB"
  elif q is Celsius: "degC"
  elif q is DBm: "dBm"
  elif q is DBc: "dBc"
  elif q is NoiseDensity: "V/rtHz"
  else: ""

proc `$`*(q: Quantity): string =
  ## Human-readable via `verax/eng` (`20.0 mohm`, `400 kHz`) -- display only,
  ## never for a deck (use `spice.spiceValue`). `Fraction` renders as a
  ## percentage and `Celsius` without prefixes.
  when q is Fraction:
    eng(toFloat(q) * 100.0) & "%"
  elif q is Celsius:
    var t = formatFloat(toFloat(q), ffDecimal, 1)
    if t.endsWith(".0"): t.setLen(t.len - 2)
    t & " degC"
  else:
    eng(toFloat(q), unitOf(q))
