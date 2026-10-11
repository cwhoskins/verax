## Sweeping a source at DC: what a node does as its supply or load moves --
## line/load regulation, dropout, transfer curves.
##
## `analyzeLineSweep` sweeps a source **the design already contains** (a
## regulator's supply, or a divider's input). `analyzeLoadSweep` sweeps a
## constant-current sink **this module injects** -- a test load isn't a
## board part, and a resistor's current would follow the node.
##
## Deliberately not done:
##
## **No capacitor parasitics** (open at DC; no effect). **No source
## impedance**: the invented default would add to the output resistance being
## measured. **No isolation**: a cut rail terminated at nominal would measure
## its own assumption.

import std/[math, strutils, tables]

import ../../netlist/types
import ../../netlist/graph
import ../../netlist/formats/spice as spiceFormat
import ../../spice/transform
import ../../spice/models
import ../../spice/ngspice
import ../../spice/bench
import ../report

export report

const
  KindSimulationFailed* = "dc_sweep_simulation_failed"
  KindNoDropout* = "dc_sweep_no_dropout"
    ## The output never left regulation in the swept range: not a small
    ## dropout -- sweep lower.
  KindDegenerateSweep* = "dc_sweep_degenerate"

type
  DcSweepSpec* = object
    scope*: ScopeChoice
      ## How much of the design is simulated (`spice/region_strategy`).
    fromVal*, toVal*: float
      ## The swept range, in the source's unit (volts or amps).
    step*: float
      ## `0` derives one from `points`.
    points*: int
      ## Points to derive a step from; `0` means 51. Resolution only refines
      ## `dropout_v`.
    nominal*: float
      ## The output percentages reference; `0` takes the least-stressed end
      ## (high line, light load), as datasheets do. Write sweeps from the light
      ## end toward the hard one.
    inputNet*: string
      ## The input node for `dropout_v`; empty uses the sweep axis. Name the
      ## regulator's own input pin net if there's a fuse or filter upstream.
    dropoutBand*: float
      ## How far below `nominal` counts as out of regulation; `0` takes 2%
      ## (the datasheet figure). Recorded as an assumption.
    pinModels*: PinModelDefaults
    flattenHierarchy*: bool
    keepInstances*: seq[string]
    modelUnmodelledParts*: bool

proc defaultDcSweepSpec*(): DcSweepSpec =
  DcSweepSpec(scope: ScopeChoice(strategy: "source_closed", icSinks: true),
              fromVal: 0.0, toVal: 0.0, step: 0.0, points: 0, nominal: 0.0,
              dropoutBand: 0.0, pinModels: defaultPinModels(),
              flattenHierarchy: true, modelUnmodelledParts: true)

const
  defaultPoints = 51
  defaultDropoutBand = 0.02
  loadSinkDesignator = "IDCLOADSWEEP"
    ## The injected sink's designator: long so it can't collide with design
    ## parts and doesn't look placed.

# --- the shared machinery ------------------------------------------------

proc stepOf(spec: DcSweepSpec): float =
  if spec.step > 0.0: return spec.step
  let n = if spec.points > 1: spec.points else: defaultPoints
  abs(spec.toVal - spec.fromVal) / float(n - 1)

proc prepare(nl: Netlist, spec: DcSweepSpec, rep: var AnalysisReport,
             namedParts: varargs[string]): Bench =
  ## The work copy: cloned, flattened, *then* sim-replaced for an operating
  ## point (so nested XSPICE ports use post-flatten names), with unmodelled
  ## parts stood in for.
  result = openBench(nl, "dc sweep", spOperating, spec.flattenHierarchy,
                     spec.keepInstances, namedParts)
  if spec.modelUnmodelledParts:
    result.modelUnmodelled(spec.pinModels)

proc scoped(b: var Bench, spec: DcSweepSpec, rep: var AnalysisReport,
            seedParts, seedNets: openArray[string]) =
  ## After the analysis has found what it drives and reads.
  b.scopeBench(spec.scope, seedParts, seedNets)
  rep.assumptions.add b.assumptions

proc sweepCard(designator: string, spec: DcSweepSpec): string =
  ".dc " & designator & " " & spiceValue(spec.fromVal) & " " &
  spiceValue(spec.toVal) & " " & spiceValue(stepOf(spec))

proc sweepAxis(raw: SimResult): seq[float] =
  ## The swept variable's values: the vector with a `-sweep` marker
  ## (`v(v-sweep)`, `i(i-sweep)`), else variable 0.
  for name, vec in raw.vectors:
    if "-sweep" in name and vec.kind == sdReal: return vec.values
  for name, vec in raw.vectors:
    if vec.kind == sdReal: return vec.values
  @[]

type SweptCurve = object
  ## One `.dc` run, read back.
  x*, v*: seq[float]
  ok*: bool

proc runSweep(b: var Bench, designator, measureNet: string,
              spec: DcSweepSpec, rep: var AnalysisReport): SweptCurve =
  let work = b.netlist
  b.probe(measureNet, "V(" & measureNet & ") across the sweep")
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
    rep.raw = b.run(sweepCard(designator, spec),
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
  ## The output's raw envelope over the sweep, reported first by both
  ## sweeps.
  let (lo, hi) = envelope(c)
  rep.add "dc_out_min", lo, "V"
  rep.add "dc_out_max", hi, "V"
  rep.add "dc_out_delta", hi - lo, "V"

proc referenceOf(spec: DcSweepSpec, c: SweptCurve, what, whichEnd: string,
                 v: float, rep: var AnalysisReport): float =
  ## The output percentages reference: stated, else the least-stressed end
  ## (high line for a line sweep, light load for a load sweep). The same end
  ## for both would reference a line figure to zero supply.
  if spec.nominal != 0.0: return spec.nominal
  rep.assumptions.add note(
    what & " is referenced to " & eng(v, "V") & ", the output at the " &
    whichEnd & " of the sweep, because no nominal was stated")
  v

# --- a voltage source the design already has -----------------------------

proc analyzeLineSweep*(nl: Netlist, source, measureNet: string,
                       spec = defaultDcSweepSpec()): AnalysisReport =
  ## Sweeps `source` and reports `measureNet`: `dc_out_min`, `dc_out_max`,
  ## `dc_out_delta` (V); `dc_transfer` (V/V); `line_reg_pct` (%),
  ## `line_reg_pct_per_v` (%/V); `dropout_v` (V).
  ##
  ## `dc_transfer` and `line_reg_pct` are one number asked two ways: a
  ## divider wants the slope, a regulator a small percentage.
  ##
  ## **`dropout_v` is `NaN` (with an issue) when regulation never broke**:
  ## the range didn't go low enough. Ideal regulator models always report
  ## this.
  result.name = "dc line sweep"

  var b = prepare(nl, spec, result, source)
  let found = findComponent(b.work, source)
  if found == nil:
    raise newException(NetlistError,
      "no such component: " & source & " -- a line sweep needs the source it " &
      "is to sweep, named as it appears in the design")
  let seedPart = if b.work.components.hasKey(found.designator): found.designator
                 else: ""
  b.scoped(spec, result, [seedPart], [measureNet, spec.inputNet])
  let work = b.netlist
  let src = findComponent(work, source)
  let designator = spiceFormat.deckDesignator(src)
  if designator.len == 0 or designator[0].toUpperAscii != 'V':
    raise newException(NetlistError,
      source & " is a '" & src.kind & "', which reaches the deck as '" &
      designator & "'. A line sweep sweeps a *voltage* source; to sweep a " &
      "load current, use analyzeLoadSweep, which injects its own sink rather " &
      "than needing one in the design.")

  b.stimulus(src, source & " swept " & eng(spec.fromVal, "V") & " to " &
             eng(spec.toVal, "V"))
  let c = runSweep(b, designator, measureNet, spec, result)
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
  # Walked down from the top of the sweep. The differential uses the named
  # input node, if any (dropout is across the part).
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
  ## Injects a constant-current sink at `measureNet` and sweeps it:
  ## `dc_out_min`, `dc_out_max`, `dc_out_delta` (V); `load_reg_pct` (%);
  ## `z_out_dc` (ohm) -- the Thevenin resistance driving the node (e.g. a
  ## divider's legs in parallel). Start at the specified load, usually zero.
  result.name = "dc load sweep"

  var b = prepare(nl, spec, result)
  b.scoped(spec, result, [], [measureNet])
  let work = b.netlist
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

  # `+` on the measured node: a positive value pulls current out of it.
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

  b.load(sink, "load swept " & eng(spec.fromVal, "A") & " to " &
         eng(spec.toVal, "A") & " out of '" & measureNet & "'")
  let c = runSweep(b, spiceFormat.deckDesignator(sink), measureNet, spec,
                   result)
  if not c.ok: return

  addEnvelope(result, c)
  let (lo, hi) = envelope(c)
  let nom = referenceOf(spec, c, "load regulation", "light-load end",
                        c.v[0], result)
  if abs(nom) > 0.0:
    result.add "load_reg_pct", 100.0 * (hi - lo) / abs(nom), "%"
  # Endpoint slope, not envelope height: a non-monotonic node has no single
  # output resistance.
  let di = c.x[^1] - c.x[0]
  result.add "z_out_dc", abs((c.v[^1] - c.v[0]) / di), "ohm"
