## Turns a `SimReport` into a renderer-neutral model: one `TestSection` per
## check with its claims, schematic, plots and diagnostics, plus the
## inconclusive/not-run entries that go at the end. `report/html` renders
## it; nothing here writes markup except the SVGs `schematic` and `plot`
## produce.
##
## **Plots show only what a claim names.** A run's plotted vectors are the
## voltages of the claims' subject nets, of every net the evaluator's own
## setup description names (`net 'x'` -- where it injects and reads), and of
## a net a result says it was measured `at`. No match → no plot, said so;
## never "the first few vectors". A claim's limit is drawn on a curve only
## for a quantity that *is* a level on that curve (`overlayQuantities`), in
## the curve's unit, on its own subject's trace -- `ripple_pp` is volts too,
## but a ripple limit drawn on V(t) would mislead.

import std/[algorithm, math, options, sequtils, sets, strutils, tables, times]
import ../eng
import ../netlist/types
import ../contract/design
import ../contract/evaluate
import ../schematic
import ../spice/flatten
import ../spice/provenance
import ../netlist/graph
import ../netlist/kinds
import ../netlist/region
import ./view
import ../spice/backend
import ../readiness
import ../plot
import ./collect

type
  ClaimRow* = object
    id*: string
    quantity*: string
    subjects*: string
    conditions*: string
    expect*: string
      ## The pass criterion as written (`<= 50 mohm`).
    acceptance*: string
      ## The interval it accepts, when that differs in form (`ekNominal`).
    measured*: string
    margin*: string
    reason*: string
    rationale*: string
    severity*: Severity
    status*: EvalStatus
    issues*: seq[Issue]
    evaluator*: string

  Figure* = object
    caption*: string
    svg*: string
      ## Inline SVG (no XML prolog); "" when there is nothing to draw.
    note*: string
      ## Why there is no picture, or what it does not show.

  RunInfo* = object
    index*: int            ## run number within the report, 1-based
    label*, analysis*: string
    setup*: seq[string]
    ok*: bool
    error*: string
    ms*: int
    points*: int
    vectors*: int
    logNotes*: seq[string] ## warning/error lines picked out of the log
    log*, deck*: string
    plot*: Figure
    opValues*: seq[(string, string)]
      ## `.op` results as a table instead of a plot.

  BenchRow* = object
    role*, designator*, nets*, text*: string

  BenchView* = object
    ## What a run's bench declared: the scope, what drove and read it,
    ## what was cut, and which design parts were drawn for their models.
    strategy*, strategyDoc*: string
    rows*: seq[BenchRow]
    dropped*: seq[string]
    detached*: seq[string]
    folded*: seq[string]

  TestSection* = object
    anchor*: string
    number*: int
    title*: string         ## the test: evaluator and claim ids
    circuit*: string       ## the circuit under test
    evaluator*: string
    setup*: string         ## the evaluator's own account of the run
    nets*: seq[string]     ## nets the run injects at or reads
    claims*: seq[ClaimRow]
    status*: EvalStatus    ## worst claim status
    schematic*: Figure
    bench*: BenchView
    runs*: seq[RunInfo]
    assumptions*: seq[string]
    issues*: seq[Issue]    ## de-duplicated across the section's claims
    reusedOp*: bool        ## a cached operating point stood in for a run

  UncheckedEntry* = object
    anchor*: string
    claim*: ClaimRow
    circuit*: string
    section*: string       ## anchor of the test section it belongs to, or ""
    hints*: seq[string]    ## `didYouMean` for an unknown quantity

  ReportModel* = object
    design*: string
    generated*: string
    simulator*: string
    environment*: string
    capabilities*: string
    missing*: string
    total*, passed*, failed*, notEvaluated*, notEvaluable*: int
    exitCode*: int
    exitLabel*: string
    structural*: seq[Issue]
    tests*: seq[TestSection]
      ## Checks that produced at least one verdict: failures first.
    inconclusive*: seq[TestSection]
      ## Checks that ran but produced no verdict at all.
    unchecked*: seq[UncheckedEntry]
    runs*: seq[RunInfo]    ## every run, for the appendix

const
  overlayQuantities* = ["z_max_in_band", "z_min", "z_antiresonance",
    "settled_min", "settled_max", "settled_v", "step_v_min", "step_v_max",
    "final_v", "clip_high", "clip_low", "dc_out_min", "dc_out_max",
    "dc_voltage"]
    ## Quantities whose limit is a level on the subject net's own curve.
  maxSeries = 6
  logNoise = ["note: no compatibility mode selected!",
              "note: simulation executed from .control section"]
    ## Printed by ngspice on every run; exact lines, lower-cased.

# --- small helpers ------------------------------------------------------

proc anchorize(s: string): string =
  for ch in s.toLowerAscii:
    result.add (if ch in {'a'..'z', '0'..'9'}: ch else: '-')

proc worst(statuses: openArray[EvalStatus]): EvalStatus =
  ## fail > not evaluable > not evaluated > pass.
  result = esPass
  for s in statuses:
    case s
    of esFail: return esFail
    of esNotEvaluable: result = esNotEvaluable
    of esNotEvaluated:
      if result == esPass: result = esNotEvaluated
    of esPass: discard

proc stripProlog(svg: string): string =
  ## Inline SVG in HTML must not carry an XML declaration.
  result = svg
  if result.startsWith("<?xml"):
    let i = result.find("?>")
    if i >= 0: result = result[i + 2 .. ^1].strip(trailing = false)

proc circuitOf*(d: Design, a: Assertion): string =
  ## The role instance that made the claim, with its bindings; else the
  ## claim's subjects.
  let inst = originRole(d, a)
  if inst.isSome:
    var parts: seq[string]
    for k, v in inst.get.bindings: parts.add k & " = " & $v
    result = inst.get.role & " '" & inst.get.name & "'"
    if parts.len > 0: result &= " (" & parts.join(", ") & ")"
  else:
    var subj: seq[string]
    for s in a.subjects: subj.add $s
    result = if subj.len > 0: subj.join(", ") else: "design"

proc claimRow*(r: AssertionResult): ClaimRow =
  let a = r.assertion
  result.id = claimLabel(a)
  result.quantity = a.quantity
  var subj: seq[string]
  for s in a.subjects: subj.add $s
  result.subjects = subj.join(", ")
  result.conditions = conditionText(a)
  result.expect = if a.expect.kind == ekPredicate: "predicate"
                  else: `$`(a.expect, a.unit)
  result.acceptance = acceptance(a)
  result.status = r.status
  result.severity = a.severity
  result.rationale = a.rationale
  result.reason = r.reason
  result.issues = r.issues
  result.evaluator = r.evaluator
  case r.status
  of esPass, esFail:
    if a.expect.kind in {ekRelative, ekPredicate}:
      result.measured = r.reason
    else:
      result.measured = eng(r.value, r.unit)
      let at = r.reason.find(" at ")
      if at >= 0: result.measured &= r.reason[at .. ^1]
      let m = marginOf(r)
      if m.isSome: result.margin = marginText(r, m.get)
  of esNotEvaluated, esNotEvaluable:
    result.measured = "not measured"

proc netsNamedIn(text: string): seq[string] =
  ## `net 'x'` mentions in an evaluator's prose: where it drives and reads.
  var i = text.find("net '")
  while i >= 0:
    let start = i + 5
    let stop = text.find('\'', start)
    if stop < 0: break
    let name = text[start ..< stop]
    if name.len > 0 and name notin result: result.add name
    i = text.find("net '", stop + 1)

proc atNet(reason: string): string =
  ## The net in a result's ` at net 'x'` / ` at x` clause, if any.
  let i = reason.find(" at ")
  if i < 0: return ""
  let tail = reason[i + 4 .. ^1]
  let named = netsNamedIn(tail)
  if named.len > 0: return named[0]
  tail.split({' ', ',', ';', ')'})[0]

proc logNotes(log: string): seq[string] =
  ## The log lines worth reading: warnings, errors, convergence aids. The
  ## two notes ngspice prints on every run are dropped.
  for line in log.splitLines:
    let l = line.strip
    let low = l.toLowerAscii
    if l.len == 0 or low in logNoise: continue
    for key in ["warning", "error", "note:", "timestep too small", "gmin",
                "source stepping", "singular"]:
      if key in low:
        result.add l
        break

# --- plotting a run -----------------------------------------------------

proc vectorFor(res: SimResult, net: string): string =
  ## `v(net)`, matched case-insensitively; else the one vector whose
  ## hierarchical name ends in `.net`. Ambiguous or absent → "".
  let want = "v(" & net.toLowerAscii & ")"
  if res.vectors.hasKey(want): return want
  var hits: seq[string]
  for k in res.vectors.keys:
    if k.startsWith("v(") and k.endsWith("." & net.toLowerAscii & ")"):
      hits.add k
  if hits.len == 1: hits[0] else: ""

proc scaleName(res: SimResult): string =
  for k in res.vectors.keys: return k

proc isOhm(u: string): bool = u.toLowerAscii in ["ohm", "ohms", "Ω"]

proc limitsFor(a: Assertion, unit: string): seq[Limit] =
  if a.expect.kind in {ekRelative, ekPredicate}: return
  let (lo, hi) = bounds(a.expect)
  var band = (false, 0.0, 0.0)
  if a.condition.hasKey("f_from") and a.condition.hasKey("f_to"):
    try:
      band = (true, parseFloat(a.condition["f_from"]),
              parseFloat(a.condition["f_to"]))
    except ValueError: discard
  proc mk(kind: LimitKind, v: float, word: string): Limit =
    Limit(kind: kind, value: v, label: claimLabel(a) & " " & word & " " &
          eng(v, unit), banded: band[0], xFrom: band[1], xTo: band[2])
  if lo.classify notin {fcInf, fcNegInf, fcNan}: result.add mk(lkMin, lo, "min")
  if hi.classify notin {fcInf, fcNegInf, fcNan}: result.add mk(lkMax, hi, "max")

proc runFigure(run: RunRecord, nets: seq[string], claims: seq[AssertionResult],
               subjectNets: HashSet[string]): Figure =
  let res = run.result
  if res.vectors.len == 0:
    result.note = "no data: the run did not complete"
    return
  var picked: seq[(string, string)]   # (net, vector)
  var missing: seq[string]
  for n in nets:
    let v = vectorFor(res, n)
    if v.len == 0: missing.add n
    elif not picked.anyIt(it[1] == v):
      picked.add (n, v)
  if picked.len > maxSeries:
    result.note = $(picked.len - maxSeries) & " more net(s) not drawn. "
    picked.setLen maxSeries
  if missing.len > 0:
    result.note &= "No vector in this run for: " & missing.join(", ") & ". "
  if picked.len == 0:
    result.note &= "Nothing the claims name was saved in this run, so " &
                   "nothing is plotted."
    return

  # Claims whose limit belongs on one of these curves.
  var overlays: seq[(AssertionResult, string)]   # (claim, its net)
  for r in claims:
    if r.assertion.quantity notin overlayQuantities: continue
    for s in r.assertion.subjects:
      if s.kind == skNet:
        for p in picked:
          if p[0].toLowerAscii == s.name.toLowerAscii: overlays.add (r, p[0])

  let scale = scaleName(res)
  let n0 = res.vectors[scale].len
  if n0 <= 1:
    result.note &= "single-point analysis; values are tabulated"
    return

  case res.dataKind
  of sdComplex:
    let f = freq(res)
    var ohmClaims: seq[(AssertionResult, string)]
    for o in overlays:
      if isOhm(o[0].assertion.unit) or isOhm(o[0].unit): ohmClaims.add o
    let asOhm = ohmClaims.len > 0
    var magP = Plot(title: run.label,
      xAxis: axis("frequency", "Hz", scLog),
      yAxis: (if asOhm: axis("|V| = |Z| (1 A injected)", "ohm", scLog)
              else: axis("magnitude", "dB")))
    var phP = Plot(xAxis: magP.xAxis, yAxis: axis("phase", "°"), height: 190)
    for i, p in picked:
      let name = "V(" & p[0] & ")"
      magP.series.add Series(name: name, x: f,
        y: (if asOhm: mag(res, p[1]) else: db(res, p[1])), slot: i)
      phP.series.add Series(name: name, x: f, y: phaseDeg(res, p[1]), slot: i)
    for (r, _) in ohmClaims:
      for l in limitsFor(r.assertion, "ohm"): magP.limits.add l
    var atSeen: seq[float]
    for r in claims:
      # A claim judged at one frequency: show where.
      let fq = r.assertion.condition.getOrDefault("at_f")
      if fq.len == 0: continue
      try:
        let x = parseFloat(fq)
        if x notin atSeen:
          atSeen.add x
          magP.vlines.add VLine(x: x, label: "at " & eng(x, "Hz"))
      except ValueError: discard
    for r in claims:
      # A measured frequency is a position on this axis.
      if r.status in {esPass, esFail} and r.unit == "Hz":
        magP.vlines.add VLine(x: r.value, label: claimLabel(r.assertion) &
                              " " & eng(r.value, "Hz"))
    result.svg = stackSvg([magP, phP])
    result.caption = "AC sweep (" & run.analysis.strip & ")"
  of sdReal:
    let x = res[scale]
    let isTime = scale == "time"
    # `.dc V1 8 20 0.1` sweeps V1; ngspice names the scale `v(v-sweep)`.
    let toks = run.analysis.splitWhitespace
    let xLabel = if isTime: "time"
                 elif toks.len > 1: toks[1] & " (swept)"
                 else: "swept " & scale
    let xUnit = if isTime: "s"
                elif toks.len > 1 and toks[1].toLowerAscii.startsWith("i"): "A"
                else: "V"
    var p = Plot(title: run.label, xAxis: axis(xLabel, xUnit),
                 yAxis: axis("voltage", "V"))
    for i, pk in picked:
      p.series.add Series(name: "V(" & pk[0] & ")", x: x, y: res[pk[1]], slot: i)
    for (r, _) in overlays:
      if r.assertion.unit == "V" or r.unit == "V":
        for l in limitsFor(r.assertion, "V"): p.limits.add l
    result.svg = plotSvg(p)
    result.caption = (if isTime: "Transient (" else: "DC sweep (") &
                     run.analysis.strip & ")"

proc opTable(res: SimResult, nets: seq[string]): seq[(string, string)] =
  ## Named nets first, then every other node voltage (capped).
  var seen = initHashSet[string]()
  for n in nets:
    let v = vectorFor(res, n)
    if v.len > 0 and res[v].len > 0:
      result.add ("V(" & n & ")", eng(res[v][0], "V"))
      seen.incl v
  var rest: seq[string]
  for k in res.vectors.keys:
    if k.startsWith("v(") and k notin seen: rest.add k
  rest.sort()
  for k in rest:
    if result.len >= 40: break
    if res[k].len > 0: result.add (k.toUpperAscii[0 .. 0] & k[1 .. ^1],
                                   eng(res[k][0], "V"))

# --- schematic ----------------------------------------------------------

const
  probeColour* = highlightColour
    ## Where a test reads.
  stimulusColour* = "#3a7bd5"
    ## Where a test drives (or loads).

type LayoutCache* = Table[string, Schematic]
  ## Layouts by view content (`view.viewKey`): many tests draw the same
  ## circuit, and layout dominates report time, so each distinct picture is
  ## laid out once; highlighting is applied per test at render time.

proc flatDesign(nl: Netlist): Netlist =
  ## A flattened clone, named as simulations name things. Unflattenable ->
  ## the design as is.
  var globals: OrderedTable[string, Net]
  result = clone(nl, globals)
  try: discard flatten(result)
  except CatchableError: result = nl

proc claimSeeds(d: Design, claims: seq[AssertionResult]):
    tuple[nets, parts: seq[string]] =
  ## What each claim was read from, as flattened names: its `scope` when an
  ## evaluator gave one, else its subjects.
  for r in claims:
    let subjects = if r.scope.len > 0: r.scope else: r.assertion.subjects
    let resolve = r.scope.len == 0
    for s in subjects:
      case s.kind
      of skNet:
        let n = if resolve: findNet(d.netlist, s.name) else: nil
        let name = if n != nil: flatName(n) else: s.name
        if name notin result.nets: result.nets.add name
      of skComponent:
        let c = if resolve: findComponent(d.netlist, s.name) else: nil
        let name = if c != nil: flatName(c) else: s.name
        if name notin result.parts: result.parts.add name
      of skPin:
        let p = findPin(d.netlist, s.name)
        if p != nil:
          let part = flatName(p.component)
          if part notin result.parts: result.parts.add part
          if p.net != nil and flatName(p.net) notin result.nets:
            result.nets.add flatName(p.net)
      of skClass, skDesign: discard

proc roleSignalNets(d: Design, claims: seq[AssertionResult]): seq[string] =
  ## The signal nets bound by the roles behind `claims`, flattened -- drawn
  ## for context (an SDA claim's picture also shows SCL). Rails and ground
  ## are left out: they touch everything.
  for r in claims:
    let inst = originRole(d, r.assertion)
    if inst.isNone: continue
    for _, subj in inst.get.bindings:
      if subj.kind != skNet: continue
      let n = findNet(d.netlist, subj.name)
      if n == nil or n.kind notin {ntSignal, ntUnknown}: continue
      let f = flatName(n)
      if f notin result: result.add f

proc viewFigure(cache: var LayoutCache, v: View, probe, stim: HashSet[string],
                what: string): Figure =
  if v.netlist == nil or v.parts.len == 0:
    result.note = what & ": nothing to draw" &
      (if v.missing.len > 0: " (no net " & v.missing.join(", ") & " in it)"
       else: "") & "."
    return
  var caption = what & ": " & $v.parts.len & " of " & $v.total & " parts, " &
    (if v.hops == 0: "those on the nets where the test drives and reads"
     else: "within " & $v.hops & " net" & (if v.hops == 1: "" else: "s") &
           " of where the test drives and reads")
  if v.truncated > 0:
    caption &= " (" & $v.truncated & " more within reach not drawn)"
  caption &= ". Orange: read; blue: driven."
  if v.trimmed.len > 0:
    caption &= " Only the pins on the drawn nets are shown for " &
      v.trimmed.join(", ") & "."
  result.caption = caption
  let key = viewKey(v)
  try:
    if key notin cache:
      var opts = archiveLayoutOptions()
      # Each drawn net as itself: SDA and SCL, not one `bus`.
      opts.stages.excl {lsBundles, lsArrays, lsPartArrays}
      cache[key] = layout(v.netlist, opts)
    result.svg = stripProlog(renderSvg(cache[key],
      [(nets: probe, colour: probeColour), (nets: stim, colour: stimulusColour)]))
  except CatchableError as e:
    result.note = "schematic could not be drawn: " & e.msg

proc benchOf(run: RunRecord, v: View): BenchView =
  let b = run.bench
  result.strategy = b.strategy
  result.strategyDoc = b.strategyDoc
  for it in b.items:
    result.rows.add BenchRow(role: $it.role, designator: it.designator,
                             nets: it.nets.join(", "), text: it.text)
  if run.netlist != nil:
    for d, c in run.netlist.components:
      if benchRole(c) == $brTermination:
        result.rows.add BenchRow(role: $brTermination, designator: d,
                                 text: benchNote(c))
  result.dropped = b.dropped
  result.detached = b.detached
  for f in v.folded:
    result.folded.add f.part & ": " & f.elements.join(", ")

# --- assembling ---------------------------------------------------------

proc buildSection(r: SimReport, c: Check, number: int,
                  runNo: var int, allRuns: var seq[RunInfo],
                  cache: var LayoutCache, flat: var Netlist): TestSection =
  let d = r.design
  result.number = number
  result.evaluator = c.evaluator
  result.setup = c.setup
  var ids: seq[string]
  for res in c.results:
    result.claims.add claimRow(res)
    ids.add claimLabel(res.assertion)
  var statuses: seq[EvalStatus]
  for cl in result.claims: statuses.add cl.status
  result.status = worst(statuses)
  result.title = c.evaluator & ": " & ids.join(", ")
  result.anchor = "test-" & $number & "-" & anchorize(c.evaluator)
  var circuits: seq[string]
  for res in c.results:
    let ct = circuitOf(d, res.assertion)
    if ct notin circuits: circuits.add ct
  result.circuit = circuits.join("; ")
  result.assumptions = foldAssumptions(c.assumptions)
  var seenIssue = initHashSet[string]()
  for res in c.results:
    for i in res.issues:
      if i.message in seenIssue: continue
      seenIssue.incl i.message
      result.issues.add i

  # Nets: subjects first, then what the setup prose names, then `at` nets.
  var subjectNets = initHashSet[string]()
  var nets: seq[string]
  for res in c.results:
    for s in res.assertion.subjects:
      if s.kind == skNet and s.name notin nets:
        nets.add s.name
        subjectNets.incl s.name
  for n in netsNamedIn(c.setup):
    if n notin nets: nets.add n
  for res in c.results:
    let n = atNet(res.reason)
    if n.len > 0 and n notin nets and netsNamedIn(res.reason).len > 0:
      nets.add n
  result.nets = nets

  let runs = runsOf(r, c)
  if runs.len == 0 and c.needs * {capSpiceOp, capSpiceDc, capSpiceAc,
                                   capSpiceTran} != {}:
    result.reusedOp = true
  for run in runs:
    inc runNo
    var info = RunInfo(index: runNo, label: run.label, analysis: run.analysis,
                       setup: run.setup, ok: run.ok, error: run.error,
                       ms: run.ms, log: run.log, deck: run.deck,
                       logNotes: logNotes(run.log),
                       vectors: run.result.vectors.len)
    if run.result.vectors.len > 0:
      for v in run.result.vectors.values:
        info.points = v.len
        break
    if run.ok:
      if info.points == 1:
        info.opValues = opTable(run.result, nets)
      else:
        info.plot = runFigure(run, nets, c.results, subjectNets)
    else:
      info.plot.note = "run failed: " & run.error
    result.runs.add info
    allRuns.add info

  # The picture: a view of what was simulated (the first run with a
  # netlist), grown from where the bench drove and read; a check that ran
  # nothing gets a view of the flattened design around what it read.
  if flat == nil: flat = flatDesign(r.netlist)
  let (seedNets0, seedParts0) = claimSeeds(d, c.results)
  let context = roleSignalNets(d, c.results)
  var probe, stim = initHashSet[string]()
  var drawn = false
  for run in runs:
    if run.netlist == nil: continue
    var seedNets, seedParts: seq[string]
    # Blue where a stimulus or load attaches, unless that net is itself a
    # declared probe; orange for probes, the focus and the claim's nets.
    var probed = initHashSet[string]()
    for it in run.bench.items:
      if it.role == brProbe:
        for n in it.nets: probed.incl n
    for it in run.bench.items:
      if it.designator.len > 0 and it.role != brProbe:
        seedParts.add it.designator
      for n in it.nets:
        let nn = findNet(run.netlist, n)
        if nn == nil or isGround(nn) or n == "0": continue
        if it.role in {brStimulus, brLoad} and n notin probed: stim.incl n
        seedNets.add n
    for n in run.bench.focus & seedNets0 & nets:
      seedNets.add n
      if n notin stim: probe.incl n
    for n in probed: probe.incl n
    for n in context: seedNets.add n
    for p in seedParts0: seedParts.add p
    let v = buildView(run.netlist, seedNets, seedParts, flat)
    result.schematic = viewFigure(cache, v, probe, stim,
                                  "Simulated circuit (" & run.label & ")")
    result.bench = benchOf(run, v)
    drawn = true
    break
  if not drawn:
    var seedNets = seedNets0
    for n in seedNets0: probe.incl n
    for n in context:
      if n notin seedNets: seedNets.add n
    let v = buildView(flat, seedNets, seedParts0, flat)
    result.schematic = viewFigure(cache, v, probe, stim,
      "The design, flattened (no simulation ran)")
    for f in v.folded:
      result.bench.folded.add f.part & ": " & f.elements.join(", ")

proc buildModel*(r: SimReport): ReportModel =
  let rd = r.readiness
  result.design = rd.design
  result.generated = r.generated.format("yyyy-MM-dd HH:mm:ss zzz")
  result.simulator = if rd.simulator.len > 0: rd.simulator else: "none"
  if rd.environment.stated:
    result.environment = $rd.environment &
      (if rd.hottest.len > 0: "; hottest " & rd.hottest else: "")
  result.capabilities = capList(rd.requested * rd.available)
  if rd.missing.len > 0: result.missing = capList(rd.missing)
  result.total = rd.results.len
  result.passed = count(rd.results, esPass)
  result.failed = count(rd.results, esFail)
  result.notEvaluated = count(rd.results, esNotEvaluated)
  result.notEvaluable = count(rd.results, esNotEvaluable)
  result.exitCode = exitCode(rd)
  result.exitLabel = exitLabel(result.exitCode)
  result.structural = rd.structural

  var runNo = 0
  var sections: seq[TestSection]
  var cache: LayoutCache
  var flat: Netlist
  for i, c in rd.checks:
    sections.add buildSection(r, c, i + 1, runNo, result.runs, cache, flat)

  var withVerdict, without: seq[TestSection]
  for s in sections:
    var any = false
    for cl in s.claims:
      if cl.status in {esPass, esFail}: any = true
    if any: withVerdict.add s else: without.add s
  # Failures first; plan order otherwise (stable sort).
  withVerdict.sort(proc (a, b: TestSection): int =
    cmp(ord(a.status != esFail), ord(b.status != esFail)))
  result.tests = withVerdict
  result.inconclusive = without

  # Unchecked claims inside tests that otherwise produced verdicts link back.
  var n = 0
  for s in withVerdict:
    for cl in s.claims:
      if cl.status in {esNotEvaluated, esNotEvaluable}:
        inc n
        result.unchecked.add UncheckedEntry(anchor: "unchecked-" & $n,
          claim: cl, section: s.anchor, circuit: s.circuit)
  for res in rd.rejected:
    inc n
    var e = UncheckedEntry(anchor: "unchecked-" & $n, claim: claimRow(res),
                           circuit: circuitOf(r.design, res.assertion))
    if res.status == esNotEvaluable:
      e.hints = didYouMean(res.assertion.quantity)
      if res.assertion.quantity in e.hints: e.hints = @[]
    result.unchecked.add e
