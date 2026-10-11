## A default `PartPolicy`. **Guess where the guess is forced, refuse where
## it's a choice**:
##
##   * A *timing* capacitor gets C0G -- forced by physics (Class 2 drifts
##     with bias and temperature).
##   * A *decoupling* capacitor gets X7R -- a judgement, so defaulted *and*
##     noted every time.
##   * Voltage rating is derived from the working voltage by a stated
##     derating factor (no catalogue here); a real parts list should
##     override it.
##
## Nothing is privileged; a project may replace it wholesale.

import std/math

import ../units
import ./types

const
  ceramicDeratingFactor* = 2.0
    ## Rate a ceramic at twice its working voltage (the usual 50% rule) --
    ## really a *capacitance* margin, since DC-bias loss grows steeply above
    ## it.
  electrolyticDeratingFactor* = 1.5
  filmDeratingFactor* = 2.0

proc ceramicLadder*(voltage = none(Volts)): seq[(string, float)] =
  ## Case size -> the largest capacitance it plausibly holds at this voltage
  ## tier, 0402 up to 1206; read both ways by `smallestCeramicPackage` and
  ## `maxCeramicCapacitance` so they agree. Voltage-aware (higher ratings
  ## need bigger cases). Typical X7R density, not one vendor's line.
  ## An unknown voltage (`none`) reads as the most permissive tier.
  let v = if voltage.isSome: abs(float(voltage.get)) else: 0.0
  if v <= 16.0:
    @[("0402", 100e-9), ("0603", 1e-6), ("0805", 10e-6), ("1206", 47e-6)]
  elif v <= 25.0:
    @[("0402", 10e-9), ("0603", 100e-9), ("0805", 2.2e-6), ("1206", 10e-6)]
  elif v <= 50.0:
    @[("0402", 1e-9), ("0603", 10e-9), ("0805", 1e-6), ("1206", 4.7e-6)]
  else:
    @[("0402", 100e-12), ("0603", 1e-9), ("0805", 100e-9), ("1206", 1e-6)]

proc smallestCeramicPackage*(c: Farads, voltage = none(Volts)): string =
  ## The smallest standard MLCC case (up to 1206) plausibly holding this
  ## capacitance at this rating. Coarse: enough for some ESR/ESL; boards that
  ## care should state one.
  let f = float(c)
  let ladder = ceramicLadder(voltage)
  for (pkg, maxCap) in ladder:
    if f <= maxCap: return pkg
  ladder[^1][0]  # nothing here is bigger than 1206 -- that is as far as this goes

proc maxCeramicCapacitance*(package: string,
                            voltage = none(Volts)): Option[Farads] =
  ## The inverse of `smallestCeramicPackage`: the largest part in this case
  ## at this voltage tier. `none` for an unknown case name, rather than a
  ## guess.
  for (pkg, maxCap) in ceramicLadder(voltage):
    if pkg == package: return some(Farads(maxCap))
  none(Farads)

# A known voltage, the common case, without wrapping it.
proc ceramicLadder*(voltage: Volts): seq[(string, float)] =
  ceramicLadder(some(voltage))
proc smallestCeramicPackage*(c: Farads, voltage: Volts): string =
  smallestCeramicPackage(c, some(voltage))
proc maxCeramicCapacitance*(package: string, voltage: Volts): Option[Farads] =
  maxCeramicCapacitance(package, some(voltage))

proc standardVoltageRating*(want: Volts): Volts =
  ## The next standard MLCC voltage rating at or above `want` (not an
  ## unbuyable 8.6 V).
  let w = abs(float(want))
  for std in [4.0, 6.3, 10.0, 16.0, 25.0, 35.0, 50.0, 63.0, 100.0]:
    if std >= w: return Volts(std)
  Volts(w)

proc defaultCapacitor*(r: CapRequest): Choice =
  result.use = partUseName(r.use)
  case r.use
  of cuTiming, cuCoupling:
    # Forced: Class 2 would move what this capacitor sets.
    result.dielectric = "C0G"
    result.tolerance = some(5.pct)
    if float(r.value) > 100e-9:
      result.notes.add "a C0G part above 100 nF is large and expensive; " &
        "if this is a coupling capacitor rather than a timing one, a film " &
        "part is the usual answer -- state `dielectric` to override"
      result.dielectric = "film"
  of cuDecoupling:
    result.dielectric = "X7R"
    result.tolerance = some(10.pct)
    result.notes.add "X7R assumed for a decoupling part: it is the usual " &
      "density/stability compromise, and it is also where a wrong guess " &
      "costs most -- a Class 2 bank at two thirds of its rating measured " &
      "1.23 ohm of rail impedance where its nominal values said 173 mohm"
  of cuBulk:
    result.dielectric = "tantalum"
    result.tolerance = some(20.pct)

  # A derived rating. An unknown working voltage gets none; don't invent one.
  if r.working.isSome:
    let factor =
      if isCeramic(result.dielectric): ceramicDeratingFactor
      elif result.dielectric == "electrolytic": electrolyticDeratingFactor
      else: filmDeratingFactor
    result.voltageRating = some(standardVoltageRating(
      Volts(abs(float(r.working.get)) * factor)))

  # Package last, once the rating is known. Tantalum/film aren't ceramic
  # cases; others are looked up by capacitance and rating.
  result.package =
    case result.dielectric
    of "tantalum": "tantalum"
    of "film": "film"
    else: smallestCeramicPackage(r.value, result.voltageRating)

proc defaultResistor*(r: ResRequest): Choice =
  result.package = "0402"
  result.use = partUseName(r.use)
  case r.use
  of ruPrecision: result.tolerance = some(1.pct)
  of ruGeneral:   result.tolerance = some(5.pct)
  of ruPower:
    result.tolerance = some(5.pct)
    result.package = "1206"
  if r.dissipating.isSome:
    # Twice the dissipation, then the nearest standard chip rating above it.
    let want = float(r.dissipating.get) * 2.0
    var chosen = 0.0
    for std in [0.063, 0.1, 0.125, 0.25, 0.5, 1.0, 2.0]:
      if std >= want:
        chosen = std
        break
    result.powerRating = some(Watts(if chosen > 0.0: chosen else: want))

proc defaultInductor*(r: IndRequest): Choice =
  result.package = "inductor"
  result.tolerance = some(20.pct)
  result.use = partUseName(r.use)
  if r.carrying.isSome:
    # Saturation headroom over the stated *peak*: near saturation inductance
    # drops, ripple grows, and the error compounds.
    result.isat = some(Amps(float(r.carrying.get) * 1.5))
    result.currentRating = some(Amps(float(r.carrying.get) * 1.25))

proc defaultPolicy*(): PartPolicy =
  ## The policy a builder gets when its caller says nothing.
  PartPolicy(capacitor: defaultCapacitor,
             resistor: defaultResistor,
             inductor: defaultInductor)
