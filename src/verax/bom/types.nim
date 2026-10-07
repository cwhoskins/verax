## What a bill of materials is made of, before any catalogue is asked.
##
## What collection produces -- the `PartFamily` that decides how a part is
## resolved, and the `BomItem` that carries everything the design stated
## about one physical part -- and what a catalogue answers with: a
## `Candidate`, one orderable part -- and what the resolver makes of the two:
## a `Resolution` per item, rolled up into `BomLine`s in a `BomResult`.

import std/[math, strutils, tables]

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
    description*: string
      ## The `description` annotation: what the part is, in words. Printed
      ## on its BOM line when no catalogue describes it; never ordered by.
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

  Availability* = object
    stock*: int
      ## Units on hand; `-1` when the source does not say. Unknown is not
      ## zero: a low-stock finding is skipped for an unknown, never raised.
    moq*: int
      ## Minimum order quantity; `-1` when the source does not say.
    lifecycle*: string
      ## `"active"`, `"nrnd"`, `"obsolete"`, or `""` when unknown.

  Candidate* = ref object
    ## One orderable part, as a `bom/source.CatalogSource` reports it.
    ## Every float a source can leave unstated is `NaN` when unstated, the
    ## same rule as `BomItem` -- an unknown rating must never pass a minimum.
    mpn*, manufacturer*: string
    family*: PartFamily
      ## `pfResistor`..`pfFerrite` or `pfOther`; never `pfNotAPart`.
    description*, datasheet*: string
    package*: string
    caseCode*: string
      ## Imperial chip case code (`classify.standardCaseCodes`), or `""` --
      ## a part with none is found by MPN, never by a parametric search.
    value*, tolerance*: float
      ## SI base units, and a fraction (0.01 is 1 %).
    voltageRating*, powerRating*, currentRating*: float
    dielectric*: string
    avail*: Availability
    source*: string
      ## The name of the `CatalogSource` that produced this.
    attrs*: OrderedTable[string, string]
      ## Free-form extras: a house part number (`ipn`), notes.

  Resolution* = ref object
    ## What the resolver decided for one `BomItem`.
    item*: BomItem
    chosen*: Candidate
      ## `nil` when nothing resolved -- including a stated MPN no source
      ## knows, which the BOM line still carries as stated.
    alternates*: seq[Candidate]
      ## The next-ranked candidates of a parametric search, best first.
    candidates*: int
      ## How many distinct orderable parts met the requirement; `0` when no
      ## search ran.
    locked*: bool
      ## A prior result's `LockEntry` decided this.
    signature*: string
      ## The lockfile key for a parametric item -- its requirement, never
      ## its designator; `""` for anything bought by MPN.
    issues*: seq[Issue]
      ## The item's own findings from collection, then the resolver's.

  LockEntry* = object
    ## One decision a previous run made, keyed on `signature`.
    signature*, mpn*, manufacturer*: string
    designators*: seq[string]
      ## For a human reading the lockfile only; never matched on.

  BomLine* = ref object
    ## One orderable line: every populated (or every DNP) item resolving to
    ## the same part. Field names follow `pcb/bom.BomLine`, without importing
    ## it, so a reconciliation would be a field copy.
    key*: string
    designators*: seq[string]
    quantity*: int
    value*: string
    footprint*: string
    partNumber*: string
    manufacturer*: string
    mpn*: string
    description*: string
    doNotPopulate*: bool
    resolutions*: seq[Resolution]
    attrs*: OrderedTable[string, string]

  BomResult* = ref object
    resolutions*: seq[Resolution]
      ## One per item, excluded ones included, in collection order.
    lines*: seq[BomLine]
      ## Excluded items are on no line; DNP items are, on their own.
    issues*: seq[Issue]
      ## Findings about the whole BOM or a whole line (`bom_low_stock`);
      ## per-item findings are on each `Resolution`.
    attrs*: OrderedTable[string, string]

proc isParametric*(f: PartFamily): bool =
  f in {pfResistor, pfCapacitor, pfInductor, pfFerrite}

proc hasValue*(i: BomItem): bool = not i.value.isNaN

proc effectiveMpn*(i: BomItem): string =
  ## The MPN the BOM orders by when no catalogue resolved the part: the
  ## stated `mpn`, else `partNumber` -- which may be a free-text label, so
  ## the resolver warns whenever it falls back to it unverified.
  if i.mpn.len > 0: i.mpn else: i.partNumber.strip

proc unknownAvailability*(): Availability =
  Availability(stock: -1, moq: -1, lifecycle: "")

proc copyCandidate*(c: Candidate): Candidate =
  ## A caller-owned copy. A source hands these out rather than its stored
  ## refs, so a caller folding stock into one can never edit the catalogue.
  if c == nil: return nil
  result = Candidate()
  result[] = c[]
