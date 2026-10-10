## The typed IBIS model: a vendor `.ibs` file transcribed into Nim types.
## A *transcription*, not an interpretation: deciding whether a curve is
## usable belongs to the consumer.
##
## - **Quantities are bare SI `float`s**, not `verax/units` types: one
##   `typ/min/max` grammar carries six quantity types.
## - **`Triplet` records presence per corner**: `NA` and `0.0` differ, and
##   `get` raises on an absent corner.
##
## Power-aware keywords transcribed: `[ISSO PU]`, `[ISSO PD]`,
## `[Composite Current]`. Not modelled: `[External Model]`/`[External Circuit]`, `[Node
## Declarations]`, AMS models, EBD/ICM package families. Every keyword
## still survives verbatim in `IbisFile.sections`.

import std/strutils

type
  IbisError* = object of CatchableError
    ## Raised on malformed input, or when an absent `Triplet` corner is read.
    ## `msg` carries file-line context where available.

  Corner* = enum
    ## The `typ min max` columns; `coTyp` is always present, `coMin`/`coMax`
    ## may be `NA`.
    coTyp, coMin, coMax

  Triplet* = object
    ## One `typ/min/max` group; `present[c]` is false for `NA` or omitted.
    present*: array[Corner, bool]
    value*: array[Corner, float]

  IvPoint* = object
    ## One row of an I/V table: a voltage and the current drawn at it,
    ## across corners.
    v*: float
    i*: Triplet

  IvTable* = seq[IvPoint]
    ## `[Pulldown]`, `[Pullup]`, `[GND_Clamp]`, `[POWER_Clamp]`. Voltages keep
    ## each table's IBIS reference (pullup/POWER_clamp relative to the rail).

  VtPoint* = object
    ## One row of a `[Rising Waveform]` / `[Falling Waveform]` table.
    t*: float
    v*: Triplet

  Waveform* = object
    ## A `[Rising Waveform]`/`[Falling Waveform]` block: fixture, then
    ## samples.
    rFixture*: float
    vFixture*: Triplet
      ## `V_fixture` is the typ column; `V_fixture_min`/`V_fixture_max` fill
      ## the min/max corners.
    cFixture*, lFixture*, rDut*, lDut*, cDut*: float
    points*: seq[VtPoint]
    composite*: seq[VtPoint]
      ## `[Composite Current]` under this table: amps into the [Pullup
      ## Reference] terminal (IBIS: positive into the component) against
      ## the same time axis and fixture. Empty if absent.

  RampSpec* = object
    ## `[Ramp]`: 20%-80% dV/dt per edge, plus its load (`R_load`, default
    ## 50 ohm).
    dvR*, dtR*, dvF*, dtF*: Triplet
    rLoad*: float
    rLoadPresent*: bool

  ModelSpec* = object
    ## `[Model Spec]`: per-corner receiver/timing figures that override the
    ## `[Model]` scalars. Every field is a `Triplet`, absent unless stated.
    present*: bool
      ## The keyword appeared at all.
    vinh*, vinl*: Triplet
    vinhPlus*, vinhMinus*, vinlPlus*, vinlMinus*: Triplet
      ## Hysteresis thresholds.
    sOvershootHigh*, sOvershootLow*: Triplet
      ## Static overshoot limits, **absolute volts** (not relative to a rail).
    dOvershootHigh*, dOvershootLow*, dOvershootTime*: Triplet
      ## Dynamic overshoot limits (absolute volts) and the time they may last.
    pulseHigh*, pulseLow*, pulseTime*: Triplet
    vmeas*, vref*, cref*, rref*: Triplet

  ReceiverThresholds* = object
    ## `[Receiver Thresholds]`: single values, not triplets. `Vinh_ac` and
    ## friends are **offsets from `Vth`** as IBIS states them, kept as written.
    present*: bool
    vth*, vthMin*, vthMax*: ModelParam
    vinhAc*, vinhDc*, vinlAc*, vinlDc*: ModelParam
    thresholdSensitivity*: ModelParam
    referenceSupply*: string
    vcrossLow*, vcrossHigh*: ModelParam
    vdiffAc*, vdiffDc*: ModelParam
    tslewAc*, tdiffslewAc*: ModelParam

  ModelType* = enum
    ## `Model_type`. `mtOther` covers unknown spellings; `rawType` keeps the
    ## original.
    mtInput, mtOutput, mtIO, mtThreeState, mtOpenDrain, mtOpenSink,
    mtOpenSource, mtInputEcl, mtOutputEcl, mtIoEcl, mtThreeStateEcl,
    mtTerminator, mtSeries, mtSeriesSwitch, mtOther

  ModelParam* = object
    ## A single-valued `[Model]` subparameter (`Vinl`, `Vref`, ...);
    ## `present` distinguishes 0 from unstated.
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
    issoPu*, issoPd*: IvTable
      ## `[ISSO PU]`/`[ISSO PD]`: effective pullup/pulldown current against
      ## the reference rail's deviation (`Vtable`; pullup as `Vcc - V`).
      ## Empty if absent.
    ramp*: RampSpec
    risingWaveforms*, fallingWaveforms*: seq[Waveform]
    modelSpec*: ModelSpec
    receiverThresholds*: ReceiverThresholds
    raw*: IbisSection
      ## The whole block as lexed, so unmodelled subparameters stay reachable.

  PinRlc* = enum
    ## Which of the optional per-pin package columns a `[Pin]` row carried.
    prR, prL, prC

  PinEntry* = object
    ## One `[Pin]` row. `model` is a `[Model]` name or `POWER`/`GND`/`NC`.
    ## Per-pin R/L/C are **single values, not triplets**.
    name*, signal*, model*: string
    rPin*, lPin*, cPin*: float
    present*: set[PinRlc]

  DiffPin* = object
    ## One `[Diff Pin]` row: pins, inversion, optional tdelay.
    pin*, invPin*: string
    vdiff*: ModelParam
    tdelayTyp*, tdelayMin*, tdelayMax*: ModelParam

  Package* = object
    ## `[Package]` default parasitics (these **are** triplets).
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
    ## `[Model Selector]`: a name choosing between `[Model]`s.
    name*: string
    choices*: seq[tuple[model, description: string]]

  IbisLine* = tuple[n: int, text: string]
    ## A content line with its 1-based source line, for error messages.

  IbisSection* = object
    ## One keyword block as lexed, modelled or not. Declared here so model
    ## types can hold one without a circular import.
    keyword*: string
      ## Canonical: lowercased, spaces/underscores unified (`[GND Clamp]` ==
      ## `gnd_clamp`), as IBIS treats them.
    rawKeyword*: string
      ## Exactly as written between the brackets.
    line*: int
      ## 1-based line number of the keyword line in the source.
    args*: string
      ## Remainder of the keyword line after the `]`.
    body*: seq[IbisLine]
      ## Content lines: comments stripped, trimmed, blanks dropped, with
      ## line numbers. IBIS has no line continuation.
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

proc cornerName*(c: Corner): string =
  ## `typ`/`min`/`max`, for messages (`$` keeps the enum spelling).
  case c
  of coTyp: "typ"
  of coMin: "min"
  of coMax: "max"

proc newTriplet*(): Triplet = Triplet()
  ## An all-absent triplet, `NA` on every corner until filled.

proc has*(t: Triplet, c: Corner): bool {.inline.} =
  t.present[c]

proc get*(t: Triplet, c: Corner): float =
  ## The value at one corner; raises `IbisError` if absent (check `has`).
  if not t.present[c]:
    raise newException(IbisError, "IBIS triplet has no " & $c & " corner")
  t.value[c]

proc set*(t: var Triplet, c: Corner, v: float) {.inline.} =
  t.present[c] = true
  t.value[c] = v

proc component*(f: IbisFile, name: string): IbisComponent =
  ## The named `[Component]` (case-insensitive); raises if absent.
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
  ## The `[Model]` a component pin uses. Raises if the component or pin is
  ## absent, or the pin's model is `POWER`/`GND`/`NC`.
  let pe = f.component(componentName).pin(pinName)
  if pe.model in ["POWER", "GND", "NC", "NC "]:
    raise newException(IbisError,
      "pin '" & pinName & "' is " & pe.model & ", not a buffer model")
  f.model(pe.model)
