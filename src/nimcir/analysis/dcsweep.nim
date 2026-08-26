## Sweeping a source at DC: what a node does as its supply or its load moves.
##
## ## The gap this fills
##
## Every other simulation-backed analysis here answers a question at **one**
## bias. `analysis/operating` solves a single `.op`; `analysis/derating` reads
## that same solve back; `analysis/pdn` and `analysis/opamp` linearise about it.
## So the whole family answers "what does this circuit do *there*", and a large
## part of what a datasheet specifies is instead "what does it do as something
## moves" -- line regulation, load regulation, dropout, a comparator's trip
## point, an input offset, a plain transfer curve. Every one of those is a
## source sweep, and there was no capability for one.
##
## ## The two shapes, and why they are two procs
##
## `analyzeLineSweep` sweeps a source **the design already contains**. That is
## the input supply for a regulator, and it is the input *node* for anything
## that is not a regulator at all -- a divider swept from 0 to its rail reports
## its ratio as a measured slope over the whole range, rather than as one node
## voltage at one bias that happens to come out right.
##
## `analyzeLoadSweep` sweeps a current **this module injects**, from the
## measured node to the reference. There is deliberately no part in the design
## for it: a test load is not something anybody solders, and putting one in the
## netlist would put it on the BoM and in the layout. This is the same idiom
## `spice/probes.addImpedanceProbe` uses for an `.ac` sweep -- the stimulus
## belongs to the measurement, not to the board -- and it is what makes
## `z_out_dc` askable of a network that has no load port.
##
## A constant-current sink rather than a resistor, for the reason
## `spice/boundary` states at length: a resistor's current follows the node it
## is hung on, so a "load sweep" against one sweeps the load *and* the drive
## together and reports neither. A sink's current is what the sweep says it is.
##
## ## What is deliberately not done here
##
## **No capacitor parasitics.** At DC a capacitor is an open circuit, so its
## ESR and ESL are in series with nothing and cannot move a number. Expanding
## them would cost three components per capacitor for an identical answer.
##
## **No source impedance.** `spice/models.expandSourceImpedance` exists because
## an ideal source is a dead short at AC; at DC its default 10 mohm is an
## *invented* series resistance, and on a load sweep it would be added to the
## very output resistance being measured. `analysis/operating` leaves sources
## ideal for the same reason, and a design whose supply really does have output
## resistance says so with a resistor.
##
## **No isolation.** A cut rail is terminated at its *nominal* voltage, which
## on a regulation measurement is the answer -- the same trap `runDcVoltage`
## avoids by simulating the design as authored. So does this.

import std/[math, strutils, tables]

import ../netlist/types
import ../netlist/graph
import ../netlist/formats/spice as spiceFormat
import ../spice/transform
import ../spice/flatten
import ../spice/models
import ../spice/ngspice
import ./report

export report

const
  KindSimulationFailed* = "dc_sweep_simulation_failed"
  KindNoDropout* = "dc_sweep_no_dropout"
    ## The output never fell out of regulation anywhere in the swept range.
    ## Reported rather than answered: a dropout voltage that was not reached
    ## is not a small dropout voltage, and the fix is to sweep lower.
  KindDegenerateSweep* = "dc_sweep_degenerate"

type
  DcSweepSpec* = object
    fromVal*, toVal*: float
      ## The swept range, in the source's own unit -- volts for a voltage
      ## source, amps for a current one.
    step*: float
      ## `0` derives one from `points`.
    points*: int
      ## How many points to derive a step from. `0` means 51, which is a
      ## sensible curve and a cheap one: a `.dc` is N operating points, and
      ## every quantity here is read off endpoints or off a threshold
      ## crossing, so resolution buys precision on `dropout_v` and nothing
      ## anywhere else.
    nominal*: float
      ## The output the percentage figures are referenced to. `0` takes it
      ## from the end of the sweep where the circuit is least stressed --
      ## high line for a line sweep, light load for a load sweep -- which is
      ## what a datasheet quotes against. A sweep is therefore written from
      ## the light end towards the hard one.
    inputNet*: string
      ## Which node counts as the input when computing `dropout_v`. Empty
      ## takes the sweep axis itself, which is right when the swept source
      ## drives the part directly and wrong the moment there is a lead
      ## resistance, a fuse or a filter between them -- the differential a
      ## regulator actually has is measured at its own pin.
    dropoutBand*: float
      ## How far below `nominal` the output must fall to count as out of
      ## regulation, as a fraction. `0` takes 2%, which is the figure
      ## datasheets quote dropout at. Declared as an assumption on every run
      ## that uses it, because it is a threshold nobody stated and the answer
      ## moves with it.
    pinModels*: PinModelDefaults
    flattenHierarchy*: bool
    keepInstances*: seq[string]
    modelUnmodelledParts*: bool

proc defaultDcSweepSpec*(): DcSweepSpec =
  DcSweepSpec(fromVal: 0.0, toVal: 0.0, step: 0.0, points: 0, nominal: 0.0,
              dropoutBand: 0.0, pinModels: defaultPinModels(),
              flattenHierarchy: true, modelUnmodelledParts: true)

const
  defaultPoints = 51
  defaultDropoutBand = 0.02
  loadSinkDesignator = "IDCLOADSWEEP"
    ## The injected sink's designator. Long and unlovely on purpose: it has to
    ## survive `checkDeckDesignators` beside whatever the design already
    ## contains, and a part that exists only inside one analysis's work copy
    ## should not look like one somebody placed.

# --- the shared machinery ------------------------------------------------

proc stepOf(spec: DcSweepSpec): float =
  if spec.step > 0.0: return spec.step
  let n = if spec.points > 1: spec.points else: defaultPoints
  abs(spec.toVal - spec.fromVal) / float(n - 1)

proc prepare(nl: Netlist, spec: DcSweepSpec, rep: var AnalysisReport,
             namedParts: varargs[string]): Netlist =
  ## The work copy every sweep here runs on: materialized for an operating
  ## point (a `.dc` *is* a series of them), flattened, and with every part
  ## carrying no model stood in for.
  var cloneNets: OrderedTable[string, Net]
  result = materializeSimNetlist(nl, cloneNets, purpose = spOperating)
  discard flattenForSim(result, spec.flattenHierarchy, spec.keepInstances,
                        namedParts)
  if spec.modelUnmodelledParts:
    rep.assumptions.add expandPinModels(result, spec.pinModels)

proc sweepCard(designator: string, spec: DcSweepSpec): string =
  ".dc " & designator & " " & spiceValue(spec.fromVal) & " " &
  spiceValue(spec.toVal) & " " & spiceValue(stepOf(spec))

proc sweepAxis(raw: SimResult): seq[float] =
  ## The swept variable's own values.
  ##
  ## ngspice names this vector after what is being swept -- `v(v-sweep)` for a
  ## voltage source, `i(i-sweep)` for a current one -- and writes it as
  ## variable 0. Matched by the `-sweep` marker rather than by either exact
  ## name, and falling back to variable 0, so a swept temperature or
  ## resistance reads here too without this module having to enumerate what
  ## ngspice may one day sweep.
  for name, vec in raw.vectors:
    if "-sweep" in name and vec.kind == sdReal: return vec.values
  for name, vec in raw.vectors:
    if vec.kind == sdReal: return vec.values
  @[]

type SweptCurve = object
  ## One `.dc` run, read back.
  x*, v*: seq[float]
  ok*: bool

proc runSweep(work: Netlist, designator, measureNet: string,
              spec: DcSweepSpec, rep: var AnalysisReport): SweptCurve =
  let measured = findNet(work, measureNet)
  if measured == nil:
    raise newException(NetlistError, "no such net: " & measureNet & " (dc sweep)")
  if not (spec.toVal > spec.fromVal):
    raise newException(NetlistError,
      "a dc sweep needs a range to sweep: from " & eng(spec.fromVal) &
      " to " & eng(spec.toVal) & " is not one. Every quantity a sweep " &
      "produces is a difference across it, so a zero-width sweep has no " &
      "answer rather than a trivial one.")

  try:
    rep.raw = run(work, sweepCard(designator, spec),
                  label = "dc:" & measureNet)
  except SpiceSimError as e:
    rep.issues.add newIssue(KindSimulationFailed, sevWarning,
      "ngspice could not run the dc sweep of " & designator & ": " & e.msg)
    return

  result.x = sweepAxis(rep.raw)
  try:
    result.v = rep.raw["v(" & measured.name & ")"]
  except CatchableError:
    rep.issues.add newIssue(KindSimulationFailed, sevWarning,
      "the dc sweep produced no voltage for net '" & measureNet & "'")
    return
  if result.x.len < 2 or result.v.len != result.x.len:
    rep.issues.add newIssue(KindDegenerateSweep, sevWarning,
      "the dc sweep of " & designator & " returned " & $result.x.len &
      " point(s) -- too few for any difference across the range to mean " &
      "anything")
    return
  result.ok = true

proc envelope(c: SweptCurve): tuple[lo, hi: float] =
  result = (c.v[0], c.v[0])
  for y in c.v:
    if y < result.lo: result.lo = y
    if y > result.hi: result.hi = y

proc addEnvelope(rep: var AnalysisReport, c: SweptCurve) =
  ## The raw window of the output over the sweep. Reported by both sweeps and
  ## before anything derived from it, because it is the one set of numbers
  ## that means the same thing whatever was swept.
  let (lo, hi) = envelope(c)
  rep.add "dc_out_min", lo, "V"
  rep.add "dc_out_max", hi, "V"
  rep.add "dc_out_delta", hi - lo, "V"

proc referenceOf(spec: DcSweepSpec, c: SweptCurve, what, whichEnd: string,
                 v: float, rep: var AnalysisReport): float =
  ## The output a percentage figure is quoted against.
  ##
  ## Stated wins. Otherwise it comes from the end of the sweep where the part
  ## is *least* stressed, and which end that is differs by what is being
  ## swept: line regulation is quoted against the output at high line, where
  ## there is most headroom, and load regulation against the output at light
  ## load. Taking the same end for both would reference a line figure to
  ## whatever the circuit does with no supply, which on anything that starts
  ## from zero is zero -- and a percentage of zero is not a small number, it
  ## is no number at all.
  if spec.nominal != 0.0: return spec.nominal
  rep.assumptions.add note(
    what & " is referenced to " & eng(v, "V") & ", the output at the " &
    whichEnd & " of the sweep, because no nominal was stated")
  v

# --- a voltage source the design already has -----------------------------

proc analyzeLineSweep*(nl: Netlist, source, measureNet: string,
                       spec = defaultDcSweepSpec()): AnalysisReport =
  ## Sweeps `source` and reports what `measureNet` does.
  ##
  ## Measurements: `dc_out_min`, `dc_out_max`, `dc_out_delta` (V);
  ## `dc_transfer` (V/V, the slope end to end); `line_reg_pct` (%) and
  ## `line_reg_pct_per_v` (%/V); and `dropout_v` (V).
  ##
  ## **`dc_transfer` and `line_reg_pct` are the same number asked two ways,**
  ## and both are kept because the two circuits that want them are opposites.
  ## A regulator's specification is that the output does *not* follow the
  ## input, so it is quoted as a percentage of the output and wants to be
  ## small. A divider's specification is that the output follows the input
  ## exactly, by a stated ratio, so it is quoted as a slope and wants to be
  ## right. One quantity would force one of those two to be phrased as the
  ## other's failure.
  ##
  ## **`dropout_v` is `NaN` when the output never left regulation**, with an
  ## issue saying so. That is not the same as a small dropout voltage: it
  ## means the swept range never went low enough to find one, and a claim
  ## resting on it must decline rather than pass. It is also what an ideal
  ## regulator *model* reports, which is the honest answer -- an error
  ## amplifier driving an ideal source holds its target from an input below
  ## it, and no sweep will find a dropout the model does not have.
  result.name = "dc line sweep"

  let work = prepare(nl, spec, result, source)
  let src = findComponent(work, source)
  if src == nil:
    raise newException(NetlistError,
      "no such component: " & source & " -- a line sweep needs the source it " &
      "is to sweep, named as it appears in the design")
  let designator = spiceFormat.deckDesignator(src)
  if designator.len == 0 or designator[0].toUpperAscii != 'V':
    raise newException(NetlistError,
      source & " is a '" & src.kind & "', which reaches the deck as '" &
      designator & "'. A line sweep sweeps a *voltage* source; to sweep a " &
      "load current, use analyzeLoadSweep, which injects its own sink rather " &
      "than needing one in the design.")

  let c = runSweep(work, designator, measureNet, spec, result)
  if not c.ok: return

  addEnvelope(result, c)
  let span = c.x[^1] - c.x[0]
  result.add "dc_transfer", (c.v[^1] - c.v[0]) / span, ""

  let (lo, hi) = envelope(c)
  let nom = referenceOf(spec, c, "line regulation", "high-line end",
                        c.v[^1], result)
  if abs(nom) > 0.0:
    let pct = 100.0 * (hi - lo) / abs(nom)
    result.add "line_reg_pct", pct, "%"
    result.add "line_reg_pct_per_v", pct / abs(span), "%/V"

  # --- dropout ---------------------------------------------------------
  #
  # Walked from the top of the sweep -- the most headroom -- downwards, so
  # "the last point still in regulation" is well defined even for a curve
  # that wanders. The differential is taken at the input *node* when one was
  # named, because a regulator's dropout is the difference across the part
  # and not the difference from whatever is upstream of its lead resistance.
  let band = if spec.dropoutBand > 0.0: spec.dropoutBand else: defaultDropoutBand
  var vin = c.x
  if spec.inputNet.len > 0:
    let inNet = findNet(work, spec.inputNet)
    if inNet == nil:
      raise newException(NetlistError,
        "no such net: " & spec.inputNet & " (dc sweep input node)")
    try:
      vin = result.raw["v(" & inNet.name & ")"]
    except CatchableError:
      vin = c.x
  if vin.len != c.v.len: vin = c.x

  let regulated = if spec.nominal != 0.0: spec.nominal else: c.v[^1]
  let floorV = regulated * (1.0 - band)
  var dropout = NaN
  var fellOut = false
  for i in countdown(c.v.high, 0):
    if c.v[i] < floorV:
      fellOut = true
      break
    dropout = vin[i] - c.v[i]
  result.add "dropout_v", (if fellOut: dropout else: NaN), "V"
  if fellOut:
    result.assumptions.add note(
      "dropout is taken where the output falls " & eng(band * 100.0) &
      "% below " & eng(regulated, "V") & ", which is a threshold this " &
      "analysis chose rather than one the design stated")
  else:
    result.issues.add newIssue(KindNoDropout, sevInfo,
      "'" & measureNet & "' stayed within " & eng(band * 100.0) & "% of " &
      eng(regulated, "V") & " over the whole sweep, so no dropout voltage " &
      "was reached and none is reported. Either sweep " & source &
      " lower, or the part standing in for the regulator has no dropout in " &
      "it to find -- an error amplifier driving an ideal source holds its " &
      "target from an input below it.",
      net = nl.nets.getOrDefault(measureNet))

# --- a load current this module injects ----------------------------------

proc analyzeLoadSweep*(nl: Netlist, measureNet: string,
                       spec = defaultDcSweepSpec()): AnalysisReport =
  ## Injects a constant-current sink at `measureNet` and sweeps it.
  ##
  ## Measurements: `dc_out_min`, `dc_out_max`, `dc_out_delta` (V);
  ## `load_reg_pct` (%); and `z_out_dc` (ohm), the DC output resistance seen
  ## at that node.
  ##
  ## `z_out_dc` is the useful one, and it is useful well beyond a regulator:
  ## it is the Thevenin resistance of whatever drives the node, which for a
  ## divider is the two legs in parallel and is therefore a direct measurement
  ## of a number the design equations computed and nothing in the netlist
  ## states.
  ##
  ## The sweep should start at the load the rail is *specified* at -- usually
  ## zero -- because the percentage figure is referenced to the output there.
  result.name = "dc load sweep"

  let work = prepare(nl, spec, result)
  let measured = findNet(work, measureNet)
  if measured == nil:
    raise newException(NetlistError,
      "no such net: " & measureNet & " (dc load sweep)")
  let gnd = findNet(work, "0")
  if gnd == nil:
    raise newException(NetlistError,
      "no ground node '0' to sink a load current into on '" & measureNet &
      "'. A load sweep needs a reference for the current it pulls.")
  if work.components.hasKey(loadSinkDesignator):
    raise newException(NetlistError,
      "the design already contains '" & loadSinkDesignator &
      "', which is the designator a load sweep injects its own sink under")

  # `+` on the measured node and `-` on the reference: SPICE runs positive
  # current from `+` through the source to `-`, so a positive sweep value
  # pulls current *out* of the node, which is what a load does.
  let sink = addComponent(work, newComponent(loadSinkDesignator,
                                             kind = "current_source"))
  discard connect(sink, "+", measured, ptPassive)
  discard connect(sink, "-", gnd, ptPassive)
  sink.attrs["value"] = "DC " & spiceValue(spec.fromVal)
  result.assumptions.add note(loadSinkDesignator,
    "a constant-current sink swept from " & eng(spec.fromVal, "A") & " to " &
    eng(spec.toVal, "A") & ", injected at net '" & measureNet &
    "' by the analysis. It is not in the design: a test load is not a part " &
    "anybody solders, and a resistor would sweep the drive along with the load")

  let c = runSweep(work, spiceFormat.deckDesignator(sink), measureNet, spec,
                   result)
  if not c.ok: return

  addEnvelope(result, c)
  let (lo, hi) = envelope(c)
  let nom = referenceOf(spec, c, "load regulation", "light-load end",
                        c.v[0], result)
  if abs(nom) > 0.0:
    result.add "load_reg_pct", 100.0 * (hi - lo) / abs(nom), "%"
  # Signed division then absolute value, rather than the envelope's height
  # over the range: a node whose voltage is not monotonic in load current has
  # no single output resistance, and taking the endpoints is the definition
  # that says so by coming out smaller than the envelope would.
  let di = c.x[^1] - c.x[0]
  result.add "z_out_dc", abs((c.v[^1] - c.v[0]) / di), "ohm"
