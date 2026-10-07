## Signal integrity of one net, on the native SI engine (`si/`), no ngspice.
## Two questions, one engine:
##
## - **Check** (`analyzeSiNet`): a routed board exists. Every corner the
##   IBIS data supports, both edges; one `AnalysisReport` per receiver with
##   the **worst** value of each SI quantity and the corner/edge that set it.
## - **Derive** (`deriveSiConstraints`): no board yet. A template on a stated
##   stack-up, the same pass criteria, and the routing rules that pass.
##
## IBIS models come from each part's `ibis_file` / `ibis_component` /
## `ibis_model` annotations. Knows nothing of contracts.

import std/[tables, strutils, math, os]
import ../../netlist/types
import ../../netlist/graph
import ../../ibis/reader
import ../../ibis/types as ibtypes
import ../../ibis/attach
import ../../pcb/types as pcbtypes
import ../../pcb/graph as pcbgraph
import ../../pcb/impedance
import ../../pcb/via
import ../../si/simulate
import ../../si/measure
import ../../si/board
import ../../si/constrain
import ../report

export constrain

const siQuantities* = ["si_overshoot_v", "si_undershoot_v", "si_ringback_margin_v",
                       "si_flight_time", "si_settle_time", "si_threshold_margin_v"]

type
  SiNetRequest* = object
    net*: string
    driver*: PinRef
    receivers*: seq[PinRef]

  IbisSetup* = object
    bindings*: seq[IbisBinding]
    selections*: Table[string, string]
    problems*: seq[string]

  SiCheck* = object
    status*: SiStatus
    reason*: string
    reports*: seq[AnalysisReport]
      ## One per receiver, in request order (named by the receiver pin).
    cornersRun*: seq[ibtypes.Corner]
    assumptions*: seq[Assumption]
    issues*: seq[Issue]

proc pinRef*(name: string): PinRef =
  ## `"U1.7"` -> designator `U1`, pin `7` (the last dot splits, so a
  ## hierarchical `X1.U1.7` keeps its path in the designator).
  let k = name.rfind('.')
  if k <= 0: PinRef(designator: name, pin: "")
  else: PinRef(designator: name[0 ..< k], pin: name[k + 1 .. ^1])

var ibisCache: Table[string, IbisFile]

proc ibisSetup*(nl: Netlist, designators: openArray[string]): IbisSetup =
  ## Read and bind each part's IBIS file. A missing annotation or an
  ## unreadable file is a named problem, never skipped.
  for des in designators:
    let c = nl.findComponent(des)
    if c == nil:
      result.problems.add "no part " & des & " in the design"
      continue
    let path = c.attrs.getOrDefault("ibis_file")
    if path.len == 0:
      result.problems.add des & " has no `ibis_file` annotation"
      continue
    var f: IbisFile
    try:
      let key = absolutePath(path)
      if not ibisCache.hasKey(key): ibisCache[key] = readIbisFile(path)
      f = ibisCache[key]
    except IbisError as e:
      result.problems.add des & ": " & e.msg
      continue
    try:
      result.bindings.add bindIbis(nl, des, f, c.attrs.getOrDefault("ibis_component"))
    except IbisError as e:
      result.problems.add des & ": " & e.msg
      continue
    let sel = c.attrs.getOrDefault("ibis_model")
    if sel.len > 0: result.selections[des] = sel

proc designators(req: SiNetRequest): seq[string] =
  result.add req.driver.designator
  for r in req.receivers:
    if r.designator notin result: result.add r.designator

type Worst = object
  value: float
  at: string
  undefined: string   ## why it is `NaN`, when it is

proc track(w: var Worst, x: float, higherIsWorse: bool, at: string) =
  if x.isNaN: return
  if w.value.isNaN or (higherIsWorse and x > w.value) or (not higherIsWorse and x < w.value):
    w.value = x
    w.at = at

proc analyzeSiNet*(pcb: Pcb, nl: Netlist, req: SiNetRequest,
                   corners = [ibtypes.coTyp, ibtypes.coMin, ibtypes.coMax]): SiCheck =
  ## Every supported corner, both edges, worst value per receiver.
  discard pcbgraph.bindLandPins(pcb)   # a board read from a file has no pins
  let setup = ibisSetup(nl, req.designators)
  if setup.problems.len > 0:
    result.status = ssUnsupported
    result.reason = setup.problems.join("; ")
    return
  var worst = newSeq[array[6, Worst]](req.receivers.len)
  for k in 0 ..< worst.len:
    for q in 0 .. 5: worst[k][q] = Worst(value: NaN)
  for c in corners:
    let spec = boardNetSpec(req.net, req.driver, req.receivers, c)
    let net = buildFromBoard(pcb, spec, setup.bindings, setup.selections)
    if net.unsupported.len > 0:
      if c == coTyp:
        result.status = ssUnsupported
        result.reason = net.unsupported.join("; ")
        result.issues.add net.issues
        return
      result.assumptions.add note("net " & req.net,
        cornerName(c) & " corner not run: " & net.unsupported.join("; "))
      continue
    result.cornersRun.add c
    if c == coTyp:
      result.assumptions.add net.assumptions
      result.issues.add net.issues
    for e in Edge:
      let stim = edgeStimulus(e, 0.5e-9)
      let r = simulate(net, stim)
      result.issues.add r.issues
      case r.status
      of ssUnsupported:
        result.status = ssUnsupported
        result.reason = cornerName(c) & " " & edgeName(e) & ": " & r.reason
        return
      of ssSolverFailed:
        result.status = ssSolverFailed
        result.reason = cornerName(c) & " " & edgeName(e) & ": " & r.reason
        return
      of ssOk: discard
      let (tRef, why, tnote) = timingReference(net.driver, stim)
      if why.len == 0: result.assumptions.add tnote
      for k in 0 ..< req.receivers.len:
        let rx = net.receivers[k]
        let m = measure(r, k, net.driver, rx.thresholds, rx.overshoot, tRef)
        let at = cornerName(c) & " " & edgeName(e)
        worst[k][0].track(m.overshoot, true, at)
        worst[k][1].track(m.undershoot, true, at)
        if m.ringbackMargin.isNaN:
          worst[k][2].undefined = $req.receivers[k] & " never reaches its far threshold (" & at & ")"
        worst[k][2].track(m.ringbackMargin, false, at)
        if tRef.isNaN:
          worst[k][3].undefined = why
        else:
          worst[k][3].track((if m.flightTimeMax.isNaN: Inf else: m.flightTimeMax), true, at)
        worst[k][4].track((if m.settleTime.isNaN: Inf else: m.settleTime), true, at)
        worst[k][5].track(m.thresholdMargin, false, at)
  result.status = ssOk
  let units = ["V", "V", "V", "s", "s", "V"]
  for k, rxp in req.receivers:
    var rep = AnalysisReport(name: "si " & req.net & " -> " & $rxp,
                             assumptions: result.assumptions, issues: result.issues)
    for q in 0 .. 5:
      var w = worst[k][q]
      # A figure undefined at any run is undefined: a worst case over the
      # runs that happened to produce one would be optimistic.
      let v = if w.undefined.len > 0: NaN else: w.value
      rep.add(siQuantities[q], v, units[q],
              at = $rxp & (if w.at.len > 0: ", worst at " & w.at else: ""))
      if w.undefined.len > 0:
        rep.issues.add newIssue("si_undefined", sevWarning, siQuantities[q] & ": " & w.undefined)
    result.reports.add rep

# --- constraint derivation --------------------------------------------------

type
  StackupChoice* = object
    ## The cross-section a template assumes before any board exists.
    layers*: int
    line*: LineSpec
    via*: ViaGeometry
    notes*: seq[Assumption]

proc defaultStackup*(layers = 4, z0Target = 50.0): StackupChoice =
  ## A typical FR4 build: outer microstrip 0.2 mm over the first plane,
  ## 1.6 mm board, 0.3 mm drill / 0.6 mm pad / 1.0 mm antipad vias, trace
  ## width solved for `z0Target`. Every figure is an `Assumption`.
  result.layers = layers
  var spec = LineSpec(geometry: lgMicrostrip, t: 35e-6, h1: 0.2e-3, er: 4.3,
                      tand: 0.02, rho: 1.72e-8)
  var lo = 0.02e-3
  var hi = 3e-3
  for _ in 0 ..< 80:
    let mid = 0.5 * (lo + hi)
    spec.w = mid
    if z0(spec) > z0Target: lo = mid else: hi = mid
  spec.w = 0.5 * (lo + hi)
  result.line = spec
  let pitch = 1.6e-3 / (layers - 1).float
  result.via = ViaGeometry(drillDia: 0.3e-3, padDia: 0.6e-3, antipadDia: 1.0e-3,
                           barrelLength: 1.6e-3, er: 4.3, entryDepth: 0.0,
                           exitDepth: pitch * (layers - 2).float,
                           backdrillResidual: -1.0, entryRef: "plane", exitRef: "plane")
  result.notes.add note("stack-up", $layers & "-layer FR4 (er 4.3), 1.6 mm, outer " &
    "microstrip 0.2 mm over the first plane, width " &
    formatFloat(spec.w * 1e3, ffDecimal, 3) & " mm for " & $z0Target & " ohm -- " &
    "no board exists yet")
  result.notes.add note("via", "0.3 mm drill, 0.6 mm pad, 1.0 mm antipad, top to " &
    "the second-to-last layer (one barrel span), same reference both sides")

proc deriveSiConstraints*(nl: Netlist, req: SiNetRequest, c: Criteria,
                          st = defaultStackup(), maxLength = 0.3, grid = 13,
                          tolerance = 0.5e-3): tuple[ok: bool, why: string, report: ConstraintReport] =
  ## The routing rules for one net before layout: max length (with the
  ## passing set, binding failure and rule of thumb), max length by via
  ## count, series termination, and the stub verdict for each transition.
  let setup = ibisSetup(nl, req.designators)
  if setup.problems.len > 0:
    return (false, setup.problems.join("; "), ConstraintReport())
  var templates: seq[SiTemplate]
  var corners: seq[ibtypes.Corner]
  let line = lineSection(st.line, lossy = false, layer = "outer", reference = "plane")
  let vm = viaModel(st.via)
  for corner in [ibtypes.coTyp, ibtypes.coMin, ibtypes.coMax]:
    let d = resolvePin(setup.bindings, req.driver, setup.selections, corner)
    if not d.ok:
      if corner == coTyp: return (false, d.reason, ConstraintReport())
      continue
    var t = SiTemplate(name: req.net & " " & (if req.receivers.len == 1: "point-to-point" else: "daisy chain"),
                       driver: driverBehaviour(d.model, corner, file = d.file),
                       driverPort: TemplatePort(label: $req.driver, pkg: d.pkg),
                       topology: (if req.receivers.len == 1: ttPointToPoint else: ttDaisyChain),
                       line: line, via: vm, hasVia: true)
    var okAll = t.driver.supported
    var why = t.driver.reason
    for r in req.receivers:
      let rp = resolvePin(setup.bindings, r, setup.selections, corner)
      if not rp.ok:
        okAll = false
        why = rp.reason
        break
      let rb = receiverBehaviour(rp.model, corner, rp.file)
      if not rb.supported:
        okAll = false
        why = rb.reason
        break
      t.receivers.add rb
      t.receiverPorts.add TemplatePort(label: $r, pkg: rp.pkg)
    if not okAll:
      if corner == coTyp: return (false, why, ConstraintReport())
      continue
    templates.add t
    corners.add corner
  let base = templateParams(0.0)
  var r = ConstraintReport(net: req.net, identity: identity(templates[0], corners, base, c),
                           hasLength: true, bestSeriesR: NaN)
  for a in st.notes: r.identity.assumptions.add $a
  r.length = sweep(templates, base, spLength, 0.0, maxLength, grid, c, tolerance)
  let tr = templates[0].driver.edges[edRising].riseTime
  r.criticalLength = criticalLength(tr, line.tdPerM)
  r.vias = viaTable(templates, base, [0, 1, 2, 3], 0.0, maxLength, max(grid div 2, 5), c, tolerance * 2)
  let tt = terminationTable(templates, base, [0.0, 22.0, 33.0, 47.0], 0.0, maxLength,
                            max(grid div 2, 5), c, tolerance * 2)
  r.termination = tt.rows
  r.bestSeriesR = tt.best
  # Stub per layer transition: top -> each inner/bottom layer.
  var transitions: seq[tuple[name: string, stub: float]]
  let pitch = st.via.barrelLength / (st.layers - 1).float
  for k in 1 ..< st.layers:
    transitions.add ("L1-L" & $(k + 1), st.via.barrelLength - pitch * k.float)
  var vb = base
  vb.viaCount = 1
  vb.length = min(0.05, maxLength)
  r.stubs = stubRemoval(templates, vb, transitions, 7, c, tolerance)
  for (n, s) in transitions:
    if s > 0: r.stubResonances.add (n, stubResonance(s, vm.stubTdPerM))
  (true, "", r)
