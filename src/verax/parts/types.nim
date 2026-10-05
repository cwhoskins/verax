## Requesting a part by what it has to *do*, and resolving it to what to buy.
##
## ## The asymmetry this exists for
##
## A parameterized module -- `designs/lib/filters.sallenKeyLP(fc, r, q)` --
## computes that it needs 22.5 nF. It cannot compute what part that is, and
## the reason is not laziness: the choice depends on the rail voltage, the
## temperature range, the space budget and the cost target, none of which the
## module can see. But the board cannot make the choice either, because it
## cannot see which of the module's capacitors is timing-critical and which is
## a bypass -- and that distinction is *decisive*, not cosmetic. A timing
## capacitor must be Class 1 (C0G/NP0), because a Class 2 dielectric loses
## capacitance under DC bias and would move the filter's corner by tens of
## percent; a decoupling capacitor should be Class 2, because that is where
## the capacitance density is.
##
## So: **the module knows the part's function, the board knows the part's
## environment, and neither can choose the part alone.** The module states a
## `Request`; the board supplies a `PartPolicy` that turns it into a `Choice`.
##
## The alternatives were both tried on paper and both fail. Per-component
## builder parameters (`c1Package`, `c1Dielectric`, `c1VoltageRating`, ...)
## multiply out with every part in the module *and* still leave the board
## guessing at function. A pass that annotates the netlist afterwards loses
## the compile-time checking a `spec:` block gives and has to address parts by
## generated name.
##
## ## Why proc-valued
##
## `PartPolicy` holds procs on a data object rather than being a compile-time
## construct, for the same reason `RoleDef` does: a policy built at runtime --
## from a preferred-parts database, say, or from a project's derating rules --
## must register and behave identically to a built-in one. Nothing here is
## privileged.

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
      ## The DC voltage the module expects across it. Zero means "the module
      ## does not know", which is honest and is what a signal-path coupling
      ## capacitor in an unbiased stage actually is.

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
    ## registered annotation, so nothing here is private to this module.
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
      ## What the part is *for* -- `partUseName(r.use)` of whichever request
      ## produced this `Choice` (`"timing"`, `"decoupling"`, ...), matching
      ## `netlist/annotations`' `part_use` key so `applyChoice` can write it
      ## straight through. Added so `Choice` stops erasing the one fact that
      ## decided everything else in it: before this field existed, a `Choice`
      ## carried a capacitor's dielectric and tolerance but not *why* that
      ## dielectric was picked, so a BOM compiler reading a finished netlist
      ## could not tell a timing capacitor from a bypass one -- precisely the
      ## distinction that makes a Class 2 dielectric in a filter move the
      ## corner by tens of percent (`docs/bom_compiler_plan.md`, fact 4).
    notes*: seq[string]
      ## Anything the policy wants said out loud -- carried into the design's
      ## assumptions rather than swallowed.

  PartPolicy* = object
    ## Proc-valued so a runtime-built policy is indistinguishable from a
    ## built-in one. A nil member means "this policy has nothing to say about
    ## that kind of part", and the caller leaves the component unannotated
    ## rather than inventing something.
    capacitor*: proc (r: CapRequest): Choice {.nimcall.}
    resistor*: proc (r: ResRequest): Choice {.nimcall.}
    inductor*: proc (r: IndRequest): Choice {.nimcall.}

proc partUseName*(u: CapUse): string =
  ## `CapUse`/`ResUse`/`IndUse` spelled without their enum prefix, matching
  ## `netlist/annotations`' `part_use` key's `allowed` list exactly --
  ## `$CapUse` would print `"cuTiming"`, which is a Nim identifier and not a
  ## value that key accepts. One proc per enum rather than one generic
  ## `$`-style overload, because the three enums are otherwise unrelated
  ## types and a shared name here is only correct because the three
  ## `case` bodies happen to agree on style, not because they share a type.
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
  ## `iuPower` maps to the same `"power"` string `ResUse.ruPower` does --
  ## deliberate, not a collision: `part_use`'s allowed list is the *union* of
  ## what the three enums mean, spelled once, and "power" reads the same
  ## whether the part carries current as a resistor or as an inductor.
  case u
  of iuFilter: "filter"
  of iuPower: "power"

proc isClass1*(dielectric: string): bool =
  ## Class 1 ceramics (C0G, NP0) are paraelectric: their capacitance does not
  ## depend on applied voltage. Every other ceramic class does, which is the
  ## whole reason `dielectric` is a registered key rather than a BoM note.
  let d = dielectric.toUpperAscii
  d == "C0G" or d == "NP0"

proc isCeramic*(dielectric: string): bool =
  let d = dielectric.toUpperAscii
  d in ["C0G", "NP0", "X7R", "X5R", "X6S", "X7S", "Y5V", "Z5U"]
