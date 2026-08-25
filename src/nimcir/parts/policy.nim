## A default `PartPolicy`, and the rule about what it may and may not guess.
##
## The line it draws is the one `spice/models` already draws for stand-in
## values: **guess where the guess is forced, refuse where it is a choice.**
##
##   * A *timing* capacitor gets C0G. That is not a preference -- a Class 2
##     dielectric loses capacitance under DC bias and with temperature, and a
##     filter built from one has a corner that moves. Physics decides it, so
##     defaulting it is safe.
##   * A *decoupling* capacitor gets X7R, and this one is a genuine judgement:
##     it is the density/stability compromise almost every board makes, and it
##     is also exactly where getting it wrong cost a factor of seven in
##     measured rail impedance. So it is defaulted *and* noted, every time.
##   * Voltage rating is derived from the working voltage by a stated
##     derating factor rather than picked from a catalogue, because this
##     module has no catalogue. A policy backed by a real preferred-parts list
##     should override it.
##
## Nothing here is privileged: `defaultPolicy()` builds an ordinary
## `PartPolicy` out of ordinary procs, and a project replacing it wholesale
## gets identical treatment.

import std/math

import ../units
import ./types

const
  ceramicDeratingFactor* = 2.0
    ## Rate a ceramic at twice its working voltage. The common industry rule
    ## is 50% for Class 2 ceramics, and it is not really a reliability margin:
    ## it is a *capacitance* margin, because the DC-bias loss at 50% of rating
    ## is already large and gets steeply worse above it.
  electrolyticDeratingFactor* = 1.5
  filmDeratingFactor* = 2.0

proc smallestCeramicPackage(c: Farads): string =
  ## The smallest case size that plausibly holds this capacitance. Coarse on
  ## purpose -- it exists so a module's capacitor gets *some* package and
  ## therefore some ESR/ESL rather than the global fallback, and any board
  ## that cares should state one.
  let f = float(c)
  if f <= 100e-12: "0402"
  elif f <= 10e-9: "0402"
  elif f <= 220e-9: "0402"
  elif f <= 2.2e-6: "0603"
  elif f <= 22e-6: "0805"
  else: "1210"

proc defaultCapacitor*(r: CapRequest): Choice =
  result.package = smallestCeramicPackage(r.value)
  case r.use
  of cuTiming, cuCoupling:
    # Forced, not chosen. A Class 2 part here moves the thing the capacitor
    # was put there to set.
    result.dielectric = "C0G"
    result.tolerance = 5.pct
    if float(r.value) > 100e-9:
      result.notes.add "a C0G part above 100 nF is large and expensive; " &
        "if this is a coupling capacitor rather than a timing one, a film " &
        "part is the usual answer -- state `dielectric` to override"
      result.dielectric = "film"
      result.package = "film"
  of cuDecoupling:
    result.dielectric = "X7R"
    result.tolerance = 10.pct
    result.notes.add "X7R assumed for a decoupling part: it is the usual " &
      "density/stability compromise, and it is also where a wrong guess " &
      "costs most -- a Class 2 bank at two thirds of its rating measured " &
      "1.23 ohm of rail impedance where its nominal values said 173 mohm"
  of cuBulk:
    result.dielectric = "tantalum"
    result.package = "tantalum"
    result.tolerance = 20.pct

  # A rating, derived rather than looked up. Zero working voltage means the
  # module genuinely does not know -- a coupling capacitor in an unbiased
  # stage -- and inventing a rating for it would be inventing the circuit.
  if float(r.working) > 0.0:
    let factor =
      if isCeramic(result.dielectric): ceramicDeratingFactor
      elif result.dielectric == "electrolytic": electrolyticDeratingFactor
      else: filmDeratingFactor
    # Round up to a standard-ish rating rather than emitting 8.6 V.
    let want = abs(float(r.working)) * factor
    var chosen = 0.0
    for std in [4.0, 6.3, 10.0, 16.0, 25.0, 35.0, 50.0, 63.0, 100.0]:
      if std >= want:
        chosen = std
        break
    result.voltageRating = Volts(if chosen > 0.0: chosen else: want)

proc defaultResistor*(r: ResRequest): Choice =
  result.package = "0402"
  case r.use
  of ruPrecision: result.tolerance = 1.pct
  of ruGeneral:   result.tolerance = 5.pct
  of ruPower:
    result.tolerance = 5.pct
    result.package = "1206"
  if float(r.dissipating) > 0.0:
    # Twice the dissipation, then the nearest standard chip rating above it.
    let want = float(r.dissipating) * 2.0
    var chosen = 0.0
    for std in [0.063, 0.1, 0.125, 0.25, 0.5, 1.0, 2.0]:
      if std >= want:
        chosen = std
        break
    result.powerRating = Watts(if chosen > 0.0: chosen else: want)

proc defaultInductor*(r: IndRequest): Choice =
  result.package = "inductor"
  result.tolerance = 20.pct
  if float(r.carrying) > 0.0:
    # Saturation current with headroom over the *peak* the caller stated. An
    # inductor run near saturation has less inductance than its label, so the
    # ripple current is larger than designed, which pushes it further into
    # saturation -- the error compounds rather than averaging out.
    result.isat = Amps(float(r.carrying) * 1.5)
    result.currentRating = Amps(float(r.carrying) * 1.25)

proc defaultPolicy*(): PartPolicy =
  ## The policy a builder gets when its caller says nothing.
  PartPolicy(capacitor: defaultCapacitor,
             resistor: defaultResistor,
             inductor: defaultInductor)
