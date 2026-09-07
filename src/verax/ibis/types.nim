## The typed IBIS model: what a silicon vendor's `.ibs` file says a buffer
## does, transcribed into Nim types.
##
## This is a *transcription*, not an interpretation. The reader
## (`verax/ibis/reader`) fills these structures from the file and checks
## almost nothing beyond "the file is well-formed"; deciding whether an I/V
## curve is *usable* -- turning it into a behavioural device, or a timing
## budget -- is a separate job that belongs to whichever consumer knows what
## the number is for, exactly as `verax/netlist/annotations` accessors never
## invent a stand-in.
##
## Two decisions worth stating, because both looked wrong at first glance:
##
## - **Every quantity is a bare `float` in SI base units, not a
##   `verax/units` type.** IBIS states volts, ohms, farads, henries, amps
##   and seconds through one `typ/min/max` column grammar. A single generic
##   `Triplet` cannot carry six quantity types, and a distinct triplet type
##   per quantity buys a reader nothing -- its job is faithful transcription,
##   not dimensional analysis. `verax/spice/backend.SimVector` makes the
##   same call for the same reason.
## - **`Triplet` records *presence* per corner.** A missing `min` corner and
##   a `min` of `0.0` are different claims about a part, and IBIS `NA`
##   appears anywhere a number may. `get` raises on an absent corner rather
##   than returning `0.0`, mirroring `SimResult.[]` raising instead of
##   letting a `FieldDefect` escape.
##
## Deliberately not modelled: `[External Model]`/`[External Circuit]` (SPICE,
## VHDL-AMS, Verilog-AMS and IBIS-ISS references to other files), `[Node
## Declarations]`, algorithmic AMS models, and the IBIS 5+ `[Begin Board
## Description]` / EBD / ICM package families. Every such keyword still
## survives verbatim in `IbisFile.sections`; nothing here throws it away.

import std/strutils

type
  IbisError* = object of CatchableError
    ## Raised by the reader on malformed input, and by `get` when a `Triplet`
    ## corner that was `NA` (or never stated) is read. `msg` carries
    ## file-line context wherever the reader can supply it.

  Corner* = enum
    ## The three columns of an IBIS `typ min max` group. `coTyp` is always
    ## present in a legal file; `coMin`/`coMax` may be `NA`.
    coTyp, coMin, coMax

  Triplet* = object
    ## One `typ/min/max` column group. `present[c]` is false where the file
    ## wrote `NA` or omitted the column entirely -- see the module note on
    ## why absence is not zero.
    present*: array[Corner, bool]
    value*: array[Corner, float]

  IvPoint* = object
    ## One row of an I/V table: a voltage and the current drawn at it,
    ## across corners.
    v*: float
    i*: Triplet

  IvTable* = seq[IvPoint]
    ## `[Pulldown]`, `[Pullup]`, `[GND_Clamp]`, `[POWER_Clamp]`. Voltages are
    ## referenced per the IBIS convention for each table (pullup and
    ## POWER_clamp are relative to the rail); the reader does not rebase them.

  VtPoint* = object
    ## One row of a `[Rising Waveform]` / `[Falling Waveform]` table.
    t*: float
    v*: Triplet

  Waveform* = object
    ## A `[Rising Waveform]` or `[Falling Waveform]` block: the fixture it
    ## was measured into, then the time/voltage samples.
    rFixture*: float
    vFixture*: Triplet
    cFixture*, lFixture*, rDut*, lDut*, cDut*: float
    points*: seq[VtPoint]

  RampSpec* = object
    ## `[Ramp]`: the 20%-80% dV/dt of each edge, plus the load it was
    ## measured into (`R_load`, default 50 ohm per spec).
    dvR*, dtR*, dvF*, dtF*: Triplet
    rLoad*: float
    rLoadPresent*: bool

  ModelType* = enum
    ## The `Model_type` subparameter. `mtOther` covers a spelling this
    ## version does not know; `IbisModel.rawType` keeps the original so it is
    ## still identifiable.
    mtInput, mtOutput, mtIO, mtThreeState, mtOpenDrain, mtOpenSink,
    mtOpenSource, mtInputEcl, mtOutputEcl, mtIoEcl, mtThreeStateEcl,
    mtTerminator, mtSeries, mtSeriesSwitch, mtOther

  ModelParam* = object
    ## A single-valued `[Model]` subparameter (`Vinl`, `Vinh`, `Vmeas`,
    ## `Cref`, `Rref`, `Vref`, ...). `present` distinguishes "stated as 0"
    ## from "not stated".
    present*: bool
    value*: float

  IbisModel* = object
    ## One `[Model]` ... `[End Model]` block.
    name*: string
    modelType*: ModelType
    rawType*: string
    polarity*, enable*: string
    vinl*, vinh*, vmeas*, cref*, rref*, vref*: ModelParam
    cComp*: Triplet
    temperatureRange*, voltageRange*: Triplet
    pullupRef*, pulldownRef*, gndClampRef*, powerClampRef*: Triplet
    pulldown*, pullup*, gndClamp*, powerClamp*: IvTable
    ramp*: RampSpec
    risingWaveforms*, fallingWaveforms*: seq[Waveform]
    raw*: IbisSection
      ## The whole block as lexed, so a subparameter this version does not
      ## model is still reachable.

  PinRlc* = enum
    ## Which of the optional per-pin package columns a `[Pin]` row carried.
    prR, prL, prC

  PinEntry* = object
    ## One row of the `[Pin]` table. `model` may be a real `[Model]` name or
    ## one of the reserved `POWER` / `GND` / `NC`. Per spec the per-pin
    ## `R_pin`/`L_pin`/`C_pin` are **single values, not triplets**.
    name*, signal*, model*: string
    rPin*, lPin*, cPin*: float
    present*: set[PinRlc]

  DiffPin* = object
    ## One row of `[Diff Pin]`: the two pin names, the inversion, and the
    ## optional tdelay triplet.
    pin*, invPin*: string
    vdiff*: ModelParam
    tdelayTyp*, tdelayMin*, tdelayMax*: ModelParam

  Package* = object
    ## `[Package]`: the default lumped package parasitics. Unlike the per-pin
    ## columns these **are** triplets.
    rPkg*, lPkg*, cPkg*: Triplet

  IbisComponent* = object
    ## One `[Component]` ... (next `[Component]` or `[End]`) block.
    name*, manufacturer*, packageName*: string
    siLocation*, timingLocation*: string
    pkg*: Package
    pins*: seq[PinEntry]
    diffPins*: seq[DiffPin]
    raw*: IbisSection

  ModelSelector* = object
    ## `[Model Selector]`: a name that stands for a choice between several
    ## `[Model]`s, each with a human-readable description.
    name*: string
    choices*: seq[tuple[model, description: string]]

  IbisLine* = tuple[n: int, text: string]
    ## A content line with its 1-based source line number, so the reader can
    ## put `line 412:` in an error about a malformed table row.

  IbisSection* = object
    ## One keyword block as lexed by `verax/ibis/parse`, kept whether or not
    ## the typed layer above models it. Declared here rather than in `parse`
    ## so `IbisModel`/`IbisComponent` can hold one without a circular import
    ## -- the same reason `SpatialIndex` storage sits in `verax/pcb/types`.
    keyword*: string
      ## Canonical form: lowercased, spaces and underscores unified to single
      ## underscores. `[GND Clamp]` and `[GND_Clamp]` both canonicalise to
      ## `gnd_clamp` -- IBIS keywords are case-insensitive and treat space and
      ## underscore as the same character.
    rawKeyword*: string
      ## Exactly as written between the brackets.
    line*: int
      ## 1-based line number of the keyword line in the source.
    args*: string
      ## Remainder of the keyword line after the `]`.
    body*: seq[IbisLine]
      ## Content lines belonging to this keyword: comments stripped, trailing
      ## whitespace trimmed, blank lines dropped, each with its source line
      ## number. IBIS has no line-continuation character -- a row is one line
      ## however long.
    children*: seq[IbisSection]
      ## Sub-keywords, for `[Model]` / `[Model Selector]` / `[Component]`.

  IbisFile* = object
    ## A parsed `.ibs` file.
    ibisVersion*: string
    fileName*, fileRev*, date*, source*, notes*, disclaimer*, copyright*: string
    components*: seq[IbisComponent]
    models*: seq[IbisModel]
    modelSelectors*: seq[ModelSelector]
    sections*: seq[IbisSection]
      ## Every top-level keyword in file order, modelled or not.

proc newTriplet*(): Triplet = Triplet()
  ## An all-absent triplet. A freshly constructed one reads as `NA` on every
  ## corner until the parser fills it.

proc has*(t: Triplet, c: Corner): bool {.inline.} =
  t.present[c]

proc get*(t: Triplet, c: Corner): float =
  ## The value at one corner. Raises `IbisError` if that corner was `NA` or
  ## never stated -- callers that can tolerate absence check `has` first.
  if not t.present[c]:
    raise newException(IbisError, "IBIS triplet has no " & $c & " corner")
  t.value[c]

proc set*(t: var Triplet, c: Corner, v: float) {.inline.} =
  t.present[c] = true
  t.value[c] = v

proc component*(f: IbisFile, name: string): IbisComponent =
  ## The `[Component]` of the given name (case-insensitive, as IBIS matches).
  ## Raises `IbisError` if absent.
  for c in f.components:
    if cmpIgnoreCase(c.name, name) == 0: return c
  raise newException(IbisError, "no [Component] named '" & name & "' in IBIS file")

proc model*(f: IbisFile, name: string): IbisModel =
  ## The `[Model]` of the given name. Raises `IbisError` if absent.
  for m in f.models:
    if cmpIgnoreCase(m.name, name) == 0: return m
  raise newException(IbisError, "no [Model] named '" & name & "' in IBIS file")

proc hasModel*(f: IbisFile, name: string): bool =
  for m in f.models:
    if cmpIgnoreCase(m.name, name) == 0: return true

proc pin*(c: IbisComponent, name: string): PinEntry =
  ## The `[Pin]` row for a pin name. Raises `IbisError` if absent.
  for p in c.pins:
    if p.name == name: return p
  raise newException(IbisError,
    "component '" & c.name & "' has no pin '" & name & "'")

proc modelFor*(f: IbisFile, componentName, pinName: string): IbisModel =
  ## The `[Model]` a given component pin uses. Raises `IbisError` if the
  ## component or pin is absent, or if the pin's model is a reserved name
  ## (`POWER`/`GND`/`NC`) rather than a real model.
  let pe = f.component(componentName).pin(pinName)
  if pe.model in ["POWER", "GND", "NC", "NC "]:
    raise newException(IbisError,
      "pin '" & pinName & "' is " & pe.model & ", not a buffer model")
  f.model(pe.model)
