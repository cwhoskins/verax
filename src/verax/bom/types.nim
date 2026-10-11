## What a bill of materials is made of: `PartFamily` and `BomItem` (from
## collection), `Candidate` (from a catalogue), and `Resolution`s rolled up
## into `BomLine`s in a `BomResult` (from the resolver).

import std/[math, options, strutils, tables]

import ../netlist/types
import ../netlist/annotations
import ../netlist/issue
import ../stated as statedmod

export Assumption, Issue, options, statedmod

type
  PartFamily* = enum
    pfResistor, pfCapacitor, pfInductor, pfFerrite
      ## Parametrically searchable: value, tolerance and case code suffice.
    pfOther
      ## Everything else bought; needs an MPN.
    pfNotAPart
      ## Simulation-only (stimulus, controlled source, coupling); left off by
      ## kind (`classify.familyOf`).

  BomItem* = ref object
    ## One physical part; a multi-section package is one item.
    designators*: seq[string]
      ## Designators a line prints: the hierarchical path (`X1.X2.R1`), or
      ## `package.ref` (`U10`) for a packaged part.
    members*: seq[string]
      ## Hierarchical path of every component in this item (every section of
      ## a package), for messages about a specific section.
    components*: seq[Component]
      ## The same members, as objects, for `Issue.components`.
    generated*: bool
      ## A member's designator was generated (positional) -- never a lock
      ## key.
    kind*: string
    family*: PartFamily
    value*: Option[float]
      ## SI base units; `none` when not parametric or `value` didn't parse.
    valueText*: string
      ## The raw `value` attr (a model name for a non-passive).
    tolerance*, voltageRating*, powerRating*, currentRating*, isat*: Stated[float]
      ## With where each came from: the part's own annotation keeps its
      ## provenance (authored, or derived by a `parts` policy), a `bom:`
      ## default is `annDefaulted`. Unstated when neither says.
    dielectric*, package*, footprint*, caseCode*: string
    use*: string
      ## `part_use`, when stated.
    mpn*, manufacturer*: string
      ## As stated on the component. Never filled from `partNumber`.
    description*: string
      ## The `description` annotation, printed when no catalogue describes
      ## the part; never ordered by.
    partNumber*: string
      ## `Component.partNumber` (or the package definition's) verbatim -- an
      ## MPN, house number or label, so kept apart from `mpn`.
    quantity*: int
    doNotPopulate*, excluded*: bool
    assumptions*: seq[Assumption]
      ## Every `bom:` default that filled a gap the part left.
    issues*: seq[Issue]
      ## What collection found wrong with what this part states.

  Availability* = object
    stock*: Option[int]
      ## Units on hand; `none` when unknown (never triggers low stock).
    moq*: Option[int]
      ## Minimum order quantity; `none` when the source does not say.
    lifecycle*: string
      ## `"active"`, `"nrnd"`, `"obsolete"`, or `""` when unknown.

  Candidate* = ref object
    ## One orderable part from a `CatalogSource`. Unstated numbers are
    ## `none`, so an unknown rating never passes a minimum.
    mpn*, manufacturer*: string
    family*: PartFamily
      ## `pfResistor`..`pfFerrite` or `pfOther`; never `pfNotAPart`.
    description*, datasheet*: string
    package*: string
    caseCode*: string
      ## Imperial chip case code or `""` (found by MPN only).
    value*, tolerance*: Option[float]
      ## SI base units, and a fraction (0.01 is 1 %).
    voltageRating*, powerRating*, currentRating*: Option[float]
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
      ## `nil` when nothing resolved (a stated MPN no source knows still
      ## prints as stated).
    alternates*: seq[Candidate]
      ## The next-ranked candidates of a parametric search, best first.
    candidates*: int
      ## Distinct orderable parts meeting the requirement; `0` if no search
      ## ran.
    locked*: bool
      ## A prior result's `LockEntry` decided this.
    signature*: string
      ## The lockfile key: the requirement, never the designator; `""` for
      ## MPN-bought items.
    issues*: seq[Issue]
      ## The item's own findings from collection, then the resolver's.

  LockEntry* = object
    ## One decision a previous run made, keyed on `signature`.
    signature*, mpn*, manufacturer*: string
    designators*: seq[string]
      ## For a human reading the lockfile only; never matched on.

  BomLine* = ref object
    ## One orderable line: items resolving to the same part (DNP separately).
    ## Field names follow `pcb/bom.BomLine` without importing it.
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
      ## Whole-BOM or whole-line findings (`bom_low_stock`); per-item ones are
      ## on each `Resolution`.
    attrs*: OrderedTable[string, string]

proc isParametric*(f: PartFamily): bool =
  f in {pfResistor, pfCapacitor, pfInductor, pfFerrite}

proc hasValue*(i: BomItem): bool = i.value.isSome

proc asOption*(s: Stated[float]): Option[float] =
  ## A requirement as a query sees it: present or not, provenance dropped.
  if s.has: some(s.value) else: none(float)

proc effectiveMpn*(i: BomItem): string =
  ## The MPN ordered by when nothing resolved: `mpn`, else `partNumber` (the
  ## resolver warns on that fallback).
  if i.mpn.len > 0: i.mpn else: i.partNumber.strip

proc unknownAvailability*(): Availability =
  ## Every field unknown -- also what `Availability()` is.
  Availability()

proc copyCandidate*(c: Candidate): Candidate =
  ## A caller-owned copy, so callers can never edit the catalogue.
  if c == nil: return nil
  result = Candidate()
  result[] = c[]
