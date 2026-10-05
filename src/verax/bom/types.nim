## What a bill of materials is made of, before any catalogue is asked.
##
## Stage 2 of `docs/bom_compiler_plan.md` is collection only, so this module
## holds only what collection produces: the `PartFamily` that decides how a
## part is resolved, and the `BomItem` that carries everything the design
## stated about one physical part. The catalogue-facing types the plan
## sketches beside them (`Candidate`, `Resolution`, `BomResult`, `BomLine`)
## arrive with Stage 3's resolver, the first code that would read them.

import std/math

import ../netlist/types
import ../netlist/annotations
import ../netlist/issue

export Assumption, Issue

type
  PartFamily* = enum
    pfResistor, pfCapacitor, pfInductor, pfFerrite
      ## The parametrically searchable families: a value, a tolerance and a
      ## case code are enough to buy one.
    pfOther
      ## Everything else that is bought. Must state an MPN -- there is no
      ## parametric query for "an op-amp".
    pfNotAPart
      ## A simulation-only element with no physical counterpart: a stimulus
      ## source, a controlled source, a coupling statement. Left off the BOM
      ## by kind (`classify.familyOf`), so a design never has to flag its own
      ## test bench.

  BomItem* = ref object
    ## One physical part. A multi-section package (`netlist/packages`) is one
    ## item, not one per section.
    designators*: seq[string]
      ## The board designator(s) a BOM line prints: the hierarchical path
      ## (`X1.X2.R1`) for a plain part, the `package.ref` (`U10`) for a
      ## packaged one. One entry per item at collection; a roll-up merges
      ## items into lines later.
    members*: seq[string]
      ## The hierarchical path of every component this item was built from --
      ## one for a plain part, every section for a packaged one. What a
      ## message should name when it is about a specific section.
    components*: seq[Component]
      ## The same members, as objects, for `Issue.components`.
    generated*: bool
      ## A member's designator was generated, so it is positional and will
      ## renumber when a part is inserted earlier -- never a lock key.
    kind*: string
    family*: PartFamily
    value*: float
      ## SI base units; `NaN` when not a parametric family, or when `value`
      ## did not parse as a bare magnitude.
    valueText*: string
      ## The raw `value` attr, verbatim -- a model name for a non-passive.
    tolerance*, voltageRating*, powerRating*, currentRating*, isat*: float
      ## `NaN` when neither the part nor a `bom:` default states it.
    dielectric*, package*, footprint*, caseCode*: string
    use*: string
      ## `part_use`, when stated.
    mpn*, manufacturer*: string
      ## As stated on the component. Never filled from `partNumber`.
    partNumber*: string
      ## `Component.partNumber` (or the package definition's) verbatim -- an
      ## MPN, a house number or a free-text label, which is exactly why it is
      ## kept apart from `mpn` (the plan's fact 2). Stage 3 may only *try* it.
    quantity*: int
    doNotPopulate*, excluded*: bool
    assumptions*: seq[Assumption]
      ## Every `bom:` default that filled a gap the part left.
    issues*: seq[Issue]
      ## What collection found wrong with what this part states.

proc isParametric*(f: PartFamily): bool =
  f in {pfResistor, pfCapacitor, pfInductor, pfFerrite}

proc hasValue*(i: BomItem): bool = not i.value.isNaN
