## Requesting a part by what it must *do*, and resolving it to what to buy.
##
## A parameterized module (a filter builder) knows it needs 22.5 nF and what
## the part is *for* -- a timing cap must be C0G (Class 2 loses capacitance
## under bias and moves the corner); a decoupling cap should be Class 2 --
## but not the rail voltage, temperature range or space budget. The board
## knows those but not each part's function. So the module states a
## `Request` and the board's `PartPolicy` turns it into a `Choice`.
##
## `PartPolicy` is proc-valued so runtime-built policies (a parts database,
## project derating rules) behave identically to built-ins.

import std/strutils

import ../units

type
  CapUse* = enum
    ## What a capacitor is *for*, which is what decides its dielectric.
    cuTiming        ## sets a frequency or a time constant; must not drift
    cuCoupling      ## passes signal, blocks DC; drift shifts a corner
    cuDecoupling    ## holds a rail up at frequency; density beats accuracy
    cuBulk          ## charge reservoir; density beats everything

  ResUse* = enum
    ruPrecision     ## sets a ratio or a gain; tolerance matters
    ruGeneral       ## pull-up, series, damping
    ruPower         ## carries current; dissipation matters

  IndUse* = enum
    iuFilter        ## sets a corner
    iuPower         ## carries the converter's ripple current

  CapRequest* = object
    ## What a module knows about a capacitor it needs.
    value*: Farads
    use*: CapUse
    working*: Volts
      ## The DC voltage the module expects across it; zero means unknown
      ## (e.g. a coupling cap in an unbiased stage).

  ResRequest* = object
    value*: Ohms
    use*: ResUse
    dissipating*: Watts

  IndRequest* = object
    value*: Henries
    use*: IndUse
    carrying*: Amps

  Choice* = object
    ## What the board decided. Every field lands on the component as a
    ## registered annotation.
    package*: string
    dielectric*: string
    voltageRating*: Volts
    currentRating*: Amps
    isat*: Amps
    powerRating*: Watts
    tolerance*: Fraction
    esr*: Ohms
    esl*: Henries
    partNumber*: string
    use*: string
      ## What the part is *for* (`partUseName`), matching the `part_use`
      ## annotation, so a finished netlist still records why a dielectric
      ## was chosen.
    notes*: seq[string]
      ## Anything the policy wants said, carried into the design's
      ## assumptions.

  PartPolicy* = object
    ## Proc-valued. A nil member means the policy says nothing about that
    ## kind of part, and the component is left unannotated.
    capacitor*: proc (r: CapRequest): Choice {.nimcall.}
    resistor*: proc (r: ResRequest): Choice {.nimcall.}
    inductor*: proc (r: IndRequest): Choice {.nimcall.}

proc partUseName*(u: CapUse): string =
  ## The enum value without its prefix, matching `part_use`'s `allowed`
  ## list (`$CapUse` would give `"cuTiming"`).
  case u
  of cuTiming: "timing"
  of cuCoupling: "coupling"
  of cuDecoupling: "decoupling"
  of cuBulk: "bulk"

proc partUseName*(u: ResUse): string =
  case u
  of ruPrecision: "precision"
  of ruGeneral: "general"
  of ruPower: "power"

proc partUseName*(u: IndUse): string =
  ## `iuPower` maps to `"power"` like `ruPower`, deliberately: `part_use`'s
  ## list is the union of the three enums.
  case u
  of iuFilter: "filter"
  of iuPower: "power"

proc isClass1*(dielectric: string): bool =
  ## Class 1 ceramics (C0G, NP0) don't lose capacitance under voltage; every
  ## other class does.
  let d = dielectric.toUpperAscii
  d == "C0G" or d == "NP0"

proc isCeramic*(dielectric: string): bool =
  let d = dielectric.toUpperAscii
  d in ["C0G", "NP0", "X7R", "X5R", "X6S", "X7S", "Y5V", "Z5U"]
