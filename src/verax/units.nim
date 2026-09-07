## Typed electrical quantities for authoring annotations.
##
## These exist for exactly one reason: `esr = 20.mohm` cannot be misread,
## whereas `esr = "20m"` and `esr = "0.02"` differ by a factor of a thousand
## and look equally plausible. The unit is carried by the *type* at the point
## of authoring, and the value is stored canonically in SI base units.
##
## **Deliberately not a dimensional-analysis system.** There is no unit
## arithmetic, no derived units, no compile-time dimension checking, and no
## way to divide volts by ohms and get amps. Adding that would be a much
## larger design with a much larger surface, and it would buy nothing for the
## job at hand -- which is stopping a literal from being written in the wrong
## decade. If dimensional arithmetic is ever wanted, it belongs in its own
## module rather than growing here.
##
## Distinct from `verax/pcb/units`, which is board *geometry* (`Nm`/`Deg`).
## The two never collide: their type names and their suffixes are disjoint,
## and a module importing both refers to unrelated quantities.

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
    ## Power. Here because a resistor's rating is stated in watts and a
    ## derating check has to compare against one; nothing in the analysis
    ## layer computes power as a *measurement* yet.
  Fraction* = distinct float
    ## A dimensionless ratio, stored as a fraction: `5.pct` is `0.05`.
    ## Used for acceptance bands and part tolerances.
  Degrees* = distinct float
    ## Phase, in degrees. Not an *electrical* quantity like the rest, and
    ## here anyway: `minPhaseMargin` is declared in degrees by the role
    ## registry, and a bare `50.0` in a list of unit literals is precisely
    ## the misread this module exists to remove.
  Decibels* = distinct float
    ## A logarithmic ratio. Stored as the dB figure itself rather than as
    ## the ratio it denotes, because that is what every consumer compares
    ## against -- `gain_max_db` is measured in dB and an assertion stated in
    ## dB must compare to it directly. Converting here would mean converting
    ## back at every use.

  Celsius* = distinct float
    ## Temperature, in degrees Celsius. Celsius rather than kelvin because
    ## every source a board's temperature comes from is in it -- a datasheet's
    ## operating range, an enclosure specification, SPICE's own `.options
    ## temp` -- and converting at the boundary would mean converting back at
    ## every use, the same reasoning that keeps `Decibels` in dB.
    ##
    ## It carries both an *absolute* temperature (`t_ambient_max = 70.degC`)
    ## and a temperature *difference* (`delta_t = 25.degC`, a rise above
    ## ambient), which are not the same quantity: two absolute temperatures
    ## must never be added, and a difference has no zero point. Nothing here
    ## enforces that, because this is deliberately not a dimensional-analysis
    ## system -- the annotation each value is stored under says which it is,
    ## and `netlist/environment` is the one place that adds the two together.

  Quantity* = Volts | Ohms | Farads | Henries | Hertz | Seconds | Amps |
              Watts | Fraction | Degrees | Decibels | Celsius

template defCtor(name: untyped, T: typedesc, scale: float) =
  proc name*(x: SomeNumber): T {.inline.} =
    ## Suffix constructor; the value is scaled to SI base units.
    T(float(x) * scale)

# Voltage
defCtor(V, Volts, 1.0)
defCtor(mV, Volts, 1e-3)
defCtor(uV, Volts, 1e-6)
defCtor(kV, Volts, 1e3)

# Resistance. `Mohm` is capitalised for mega and `mohm` is milli, matching SI
# rather than SPICE -- SPICE is case-insensitive and spells mega `MEG`, which
# is exactly the ambiguity these types exist to remove.
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

# Temperature. Only a Celsius constructor: a kelvin one would look like a
# unit conversion and is not -- `20.K` as a *rise* is 20 degC, while `20.K`
# as an absolute temperature is -253 degC, and one suffix cannot mean both.
defCtor(degC, Celsius, 1.0)

# Dimensionless
defCtor(pct, Fraction, 1e-2)
defCtor(ppm, Fraction, 1e-6)

# Phase and logarithmic ratio. Note Nim reads `dB` and `db` as the same
# identifier -- case after the first character is not significant -- so both
# spellings work and mean this.
defCtor(deg, Degrees, 1.0)
defCtor(dB, Decibels, 1.0)

proc toFloat*(q: Quantity): float {.inline.} =
  ## The value in SI base units -- volts, ohms, farads, henries, hertz,
  ## seconds, amps, or a bare fraction.
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
  else: ""

proc `$`*(q: Quantity): string =
  ## Human-readable, via `verax/eng` -- `20.0 mohm`, `600 pH`, `400 kHz`.
  ## For the canonical *storage* form see `netlist/formats/spice.spiceValue`;
  ## this is display only and must never be written into a deck.
  ##
  ## A `Fraction` renders as a percentage rather than through the SI prefixes:
  ## `5.pct` is stored as 0.05, and "50.0m" is a true but unreadable way to
  ## say "five percent".
  ##
  ## `Celsius` skips the prefixes for the same reason: nothing is ever
  ## measured in millidegrees, and a half-degree rise rendered `500 mdegC`
  ## is the misread this module exists to remove.
  when q is Fraction:
    eng(toFloat(q) * 100.0) & "%"
  elif q is Celsius:
    var t = formatFloat(toFloat(q), ffDecimal, 1)
    if t.endsWith(".0"): t.setLen(t.len - 2)
    t & " degC"
  else:
    eng(toFloat(q), unitOf(q))
