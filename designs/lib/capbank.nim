## Splitting a target bulk capacitance into a real bank of parts.
##
## A ripple equation (`buck.outputCapForRipple`, `buck.inputCapForRipple`)
## computes a farad figure. A board does not buy one capacitor at that
## figure -- it buys several smaller ones in parallel, because a real MLCC
## line tops out well below what a rail's bulk capacitance needs, because
## `N` parts in parallel divide the ESR and ESL `spice/models/capacitor.nim`
## already models per case size, and because spreading the mounting
## inductance across several footprints is the entire reason a bank exists
## rather than one large part. `capBank` is that split, under stated
## constraints (largest case allowed, how many parts).
##
## ## Bias derating decides how big the bank has to be, not how it splits
##
## A Class 2 ceramic loses capacitance to DC bias -- `spice/models/derating`
## already rewrites a capacitor's simulated value downward for exactly this
## reason, and its own doc states the size of the effect: an X5R bank at
## about two thirds of its rating measured 1.23 ohm of worst in-band rail
## impedance where the nominal values said 173 mohm. This module reuses that
## same curve (`spice/models/derating.defaultDerating()`) to size the bank's
## *nominal* (labelled) capacitance so that its *effective* (derated)
## capacitance reaches the target -- one source of truth, so a design-time
## figure and what the simulator actually sees cannot disagree the way
## `buckSheet`'s un-annotated capacitors used to (nothing stated `dielectric`
## or `voltage_rating`, so every one was derated against an *assumed* X7R at
## an *assumed* 2x rating rather than a stated one).
##
## **What splitting into more parts does not do**: the derating curve is
## keyed on the dielectric letter alone, not on case size or capacitance
## density, so cutting one 47 uF part into five 10 uF parts does not change
## the modelled bias loss per part -- `derating.nim`'s own doc already flags
## that real loss depends far more on case size than on the dielectric
## letter, and making the model case-size-aware is a change to that module,
## not this one. What the split buys here is ESR/ESL division and
## buildability; what stating `dielectric`/`voltage_rating` buys is the bias
## correction; the two are orthogonal, and this module does both because a
## bank is the natural place to state a part's rating.
##
## `effectiveTotal` is what the simulator will measure; `nominalTotal` is
## what the label on each part -- and a BoM -- says.

import std/[math, strutils, tables]

import verax/units
import verax/parts
import verax/spice/models/derating

type
  CapBankSpec* = object
    maxPackage*: string
      ## The largest case this bank may use. Default `"0805"` -- a caller
      ## after the highest density states a bigger one; a caller building to
      ## a tight keepout states a smaller one, which (through `minCount`
      ## below) drives the part count up rather than silently exceeding it.
    minCount*: int
      ## At least this many parts, even when one would meet the target --
      ## spreading a bulk capacitance across a minimum number of footprints
      ## is a board-layout decision (parallel paths to the rail, mounting
      ## inductance) this module cannot make on its own, so a caller states
      ## it. Default 1.
    maxCount*: int
      ## A ceiling `capBank` raises against rather than silently exceeding --
      ## the same role `buck.inductorForRipple`'s preconditions play for an
      ## impossible ripple target. Default 16.
    dielectric*: string
      ## What every part in the bank is. Default `"X7R"`, the same default
      ## judgement `parts/policy.defaultCapacitor` makes for a decoupling
      ## part and for the same reason -- density/stability compromise, and
      ## exactly where a wrong guess costs most. State `"C0G"`/`"NP0"` for a
      ## bank that must not lose capacitance to bias at all.
    voltageRating*: Volts
      ## Stated, or `0.V` to derive one from the working voltage and
      ## `ratingFactor` via `parts.standardVoltageRating` -- the same
      ## "state it or derive it, never invent silently without saying so"
      ## split `defaultCapacitor` makes.
    ratingFactor*: float
      ## Multiple of the working voltage to rate a derived voltage at.
      ## Default `ceramicDeratingFactor` (2x) -- see that const's own doc for
      ## why this is a capacitance margin and not a reliability one.
    series*: ESeries
      ## The preferred-value ladder each part's nominal value is rounded up
      ## to -- up, never merely nearest, because `series.nearest` rounds by
      ## ratio and can land below what was asked, which would leave the bank
      ## short of its target. Default `seriesE12`: capacitors are mostly
      ## stocked in it whatever their tolerance (`parts/series.nim`'s own
      ## doc).

  BankPart* = object
    value*: Farads
      ## Nominal -- what the part's label and a BoM line say.
    package*: string
    dielectric*: string
    voltageRating*: Volts

  CapBank* = object
    parts*: seq[BankPart]
      ## All identical: same value, package, dielectric, rating. A bank with
      ## a mixed complement (a bulk part plus a small high-frequency one) is
      ## a different concern than "split one total" and is not this module's
      ## job -- see `designs/lib/lt8640a.nim`'s own small fixed capacitors
      ## (`CB2`, `COUT2`, `CBST`, ...), which stay hand-written.
    target*: Farads
      ## The effective capacitance asked for.
    working*: Volts
    nominalTotal*: Farads
      ## Sum of every part's label value -- what a BoM cost or footprint
      ## count is computed from.
    effectiveTotal*: Farads
      ## `nominalTotal` after bias derating at `working` -- what a simulation
      ## will actually see across the bank, and what should be compared
      ## against `target`.
    biasFraction*: float
      ## Fraction of nominal capacitance the bank keeps at `working` volts,
      ## from `biasFraction` below. 1.0 for a dielectric that does not derate
      ## (C0G/NP0) or that the curve does not carry.
    notes*: seq[string]
      ## What was guessed, stated the way `parts/annotate.choiceNotes` does
      ## for a single-part `Choice` -- a bank invents a rating exactly as
      ## often as a lone capacitor does, and for the same reason.

proc capBankSpec*(maxPackage = "0805", minCount = 1, maxCount = 16,
                  dielectric = "X7R", voltageRating = 0.V,
                  ratingFactor = ceramicDeratingFactor,
                  series = seriesE12): CapBankSpec =
  CapBankSpec(maxPackage: maxPackage, minCount: minCount, maxCount: maxCount,
              dielectric: dielectric, voltageRating: voltageRating,
              ratingFactor: ratingFactor, series: series)

proc biasFraction*(dielectric: string, working, rated: Volts): float =
  ## The fraction of nominal capacitance a part of this dielectric keeps at
  ## `working` volts against a `rated` voltage -- read straight off
  ## `spice/models/derating.defaultDerating()`'s own curve, so this module
  ## and the simulator's own bias correction can never disagree about what a
  ## stated dielectric and rating mean. 1.0 (no loss) for Class 1 and for
  ## anything the curve does not carry -- tantalum, film, an unrecognised
  ## name -- since those either genuinely do not bias-derate or this module
  ## has no defensible curve for them and must not invent one.
  if float(rated) <= 0.0: return 1.0
  let d = defaultDerating()
  var curve: seq[(float, float)]
  if not d.byDielectric.hasKey(dielectric):
    # Case-insensitively, the same leniency `derateCapacitor` gives a stated
    # dielectric -- a design authoring "x7r" should get the same curve as
    # "X7R".
    var found = false
    for k in d.byDielectric.keys:
      if k.toUpperAscii == dielectric.toUpperAscii:
        curve = d.byDielectric[k]
        found = true
        break
    if not found: return 1.0
  else:
    curve = d.byDielectric[dielectric]
  deratingFraction(curve, abs(float(working)) / float(rated))

proc roundUpSeries(s: ESeries, x: float): float =
  ## The smallest value of `s` at or above `x`. Distinct from
  ## `series.nearest`, which rounds by ratio and can land below `x` --
  ## exactly what a bank sizing to a target must not do, or the bank would
  ## come in under it.
  if s.mantissas.len == 0 or x.classify notin {fcNormal, fcSubnormal} or x <= 0.0:
    return x
  let decade = pow(10.0, floor(log10(x)))
  let m = x / decade
  for cand in s.mantissas:
    if cand >= m - 1e-9:
      return cand * decade
  # Every mantissa in this decade undershoots `m` (it sits just under 10) --
  # the next decade's first value.
  s.mantissas[0] * decade * 10.0

proc capBank*(target: Farads, working: Volts, spec = capBankSpec()): CapBank =
  ## Splits `target` (the *effective*, post-bias capacitance a rail at
  ## `working` volts needs) into `spec.series`-valued parts no larger than
  ## `spec.maxPackage`, at least `spec.minCount` of them, sharing one
  ## dielectric and voltage rating.
  ##
  ## Raises `ValueError` rather than a bank that silently misses its target:
  ## an unrecognised `maxPackage` (nothing in `parts.ceramicLadder` to size
  ## against), or a target that needs more parts than `spec.maxCount` allows
  ## -- the same treatment `buck.inductorForRipple`'s preconditions give an
  ## impossible ripple target, naming the knob to relax rather than leaving
  ## the reader to work out which one.
  if float(target) <= 0.0:
    raise newException(ValueError,
      "capBank: target capacitance must be positive, got " & $float(target) & " F")

  let rated =
    if float(spec.voltageRating) > 0.0: spec.voltageRating
    else: standardVoltageRating(Volts(abs(float(working)) * spec.ratingFactor))
  let frac = biasFraction(spec.dielectric, working, rated)
  let needNominal = float(target) / frac

  let cMaxOpt = maxCeramicCapacitance(spec.maxPackage, rated)
  if cMaxOpt.isNone:
    raise newException(ValueError,
      "capBank: '" & spec.maxPackage & "' is not a case size this module " &
      "knows (see `parts.ceramicLadder`) -- state a recognised `maxPackage`")

  let cMax = float(cMaxOpt.get)
  var n = max(spec.minCount, int(ceil(needNominal / cMax)))
  var per = 0.0
  while true:
    if n > spec.maxCount:
      raise newException(ValueError,
        "capBank: " & $float(target) & " F at " & $float(working) & " V " &
        "needs more than " & $spec.maxCount & " parts of '" & spec.maxPackage &
        "' or smaller -- raise `maxCount`, allow a bigger `maxPackage`, or " &
        "lower `minCount`")
    per = roundUpSeries(spec.series, needNominal / n.float)
    if per <= cMax: break
    inc n

  let package = smallestCeramicPackage(Farads(per), rated)
  var bank = CapBank(target: target, working: working, biasFraction: frac)
  for i in 0 ..< n:
    bank.parts.add BankPart(value: Farads(per), package: package,
                            dielectric: spec.dielectric, voltageRating: rated)
  bank.nominalTotal = Farads(per * n.float)
  bank.effectiveTotal = Farads(float(bank.nominalTotal) * frac)

  if float(spec.voltageRating) <= 0.0:
    bank.notes.add "voltage_rating assumed " & $float(rated) & " V, " &
      $spec.ratingFactor & "x the " & $float(working) & " V across the bank"
  bank.notes.add $float(target) & " F effective needs " &
    $float(needNominal) & " F nominal at " & spec.dielectric & " on a " &
    $float(rated) & " V part (" & $int(frac * 100.0) &
    "% of nominal remains at bias) -- split across " & $n & " x " &
    $float(per) & " F (" & package & ")"
  bank
