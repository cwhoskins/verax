## Signal integrity of one net, on the native SI engine (`si/`), no ngspice.
## Two questions, one engine:
##
## - **Check** (`analyzeSiNet`): a routed board exists. Every corner the
##   IBIS data supports, both edges and, with a UI, the ISI pattern
##   (`si/sweep`); one `AnalysisReport` per receiver with the **worst**
##   value of each SI quantity and the run that set it.
## - **Derive** (`deriveSiConstraints`): no board yet. A template on a stated
##   stack-up, the same pass criteria, and the routing rules that pass.
##
## IBIS models come from each part's `ibis_file` / `ibis_component` /
## `ibis_model` annotations. Knows nothing of contracts.

import std/[tables, strutils, math, os]
import ../../netlist/types
import ../../netlist/graph
import ../../netlist/formats/spice as spiceFormat
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
import ../../si/sweep
import ../report

export constrain, sweep

const siQuantities* = ["si_overshoot_v", "si_undershoot_v", "si_ringback_margin_v",
                       "si_flight_time", "si_settle_time", "si_threshold_margin_v"]
const siEyeQuantities* = ["si_eye_height_v", "si_eye_width"]
  ## With an eye run (`SiNetRequest.eyeBits`).
const siCrosstalkQuantities* = ["si_crosstalk_v", "si_noise_margin_v"]
  ## Claimed on an `si_net`'s victim; derived pre-layout as a spacing
  ## (`deriveSiConstraints`), not yet measured on a routed board.

type
  SiNetRequest* = object
    net*: string
    driver*: PinRef
    receivers*: seq[PinRef]
    ui*: float
      ## Unit interval, s; positive adds the ISI pattern to the sweep.
    hasVictim*: bool
    victimNet*: string
    victimDriver*, victimRx*: PinRef
      ## A quiet neighbour (held low) for the spacing constraint.
    coupledLength*: float
      ## The parallel run to derive the spacing for, metres; `0` = none.
    eyeBits*: int
      ## With a UI: this many PRBS7 bits folded into an eye; `0` = none.

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
    sweep*: SiSweep
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
  if req.hasVictim:
    for r in [req.victimDriver, req.victimRx]:
      if r.designator notin result: result.add r.designator

proc analyzeSiNet*(pcb: Pcb, nl: Netlist, req: SiNetRequest,
                   corners = [ibtypes.coTyp, ibtypes.coMin, ibtypes.coMax]): SiCheck =
  ## Every supported corner x the sweep's stimuli, worst value per receiver.
  discard pcbgraph.bindLandPins(pcb)   # a board read from a file has no pins
  let setup = ibisSetup(nl, req.designators)
  if setup.problems.len > 0:
    result.status = ssUnsupported
    result.reason = setup.problems.join("; ")
    return
  var runs: seq[SweepCorner]
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
    if c == coTyp:
      result.assumptions.add net.assumptions
      result.issues.add net.issues
    runs.add SweepCorner(corner: c, net: net)
  let sw = sweepNet(runs, sweepStimuli(req.ui, prbsBits = (if req.ui > 0: req.eyeBits else: 0)))
  result.sweep = sw
  result.cornersRun = sw.corners
  result.assumptions.add sw.assumptions
  result.issues.add sw.issues
  result.status = sw.status
  result.reason = sw.reason
  if sw.status != ssOk: return
  for k, rxp in req.receivers:
    var rep = AnalysisReport(name: "si " & req.net & " -> " & $rxp,
                             assumptions: result.assumptions, issues: result.issues)
    for f in signalFigures:
      let w = sw.worst[k][f]
      # A figure undefined at any run is undefined: a worst case over the
      # runs that happened to produce one would be optimistic.
      let v = if w.undefined.len > 0: NaN else: w.value
      rep.add(siQuantities[ord(f)], v, figureUnit[f],
              at = $rxp & (if w.at.len > 0: ", worst at " & w.at else: ""))
      if w.undefined.len > 0:
        rep.issues.add newIssue("si_undefined", sevWarning, siQuantities[ord(f)] & ": " & w.undefined)
    if sw.eyes:
      for (f, q) in [(sfEyeHeight, siEyeQuantities[0]), (sfEyeWidth, siEyeQuantities[1])]:
        let w = sw.worst[k][f]
        rep.add(q, w.value, figureUnit[f],
                at = $rxp & (if w.at.len > 0: ", worst at " & w.at else: ""))
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
  # Spacing to a victim: the same nets as a coupled point-to-point pair,
  # routed exactly the parallel run (crosstalk depends on the coupled
  # length; a route at the length rule's limit would fail on its own
  # flight time whatever the gap).
  if req.hasVictim:
    if req.coupledLength <= 0:
      r.notes.add "a victim is named but no coupled_length: no spacing derived"
    elif req.receivers.len != 1:
      r.notes.add "spacing is derived for a point-to-point net only (this one has " &
        $req.receivers.len & " receivers)"
    else:
      var pts: seq[SiTemplate]
      for k, t in templates:
        let corner = corners[k]
        let vd = resolvePin(setup.bindings, req.victimDriver, setup.selections, corner)
        let vr = resolvePin(setup.bindings, req.victimRx, setup.selections, corner)
        if not vd.ok or not vr.ok:
          if corner == coTyp:
            r.notes.add "no spacing: " & (if vd.ok: vr.reason else: vd.reason)
            pts.setLen 0
            break
          continue
        var pt = t
        var pair = st.line
        pair.geometry = lgEdgeCoupledMicrostrip
        pair.s = st.line.w
        pt.partner = TemplatePartner(role: prVictim, name: req.victimNet,
                                     driver: driverBehaviour(vd.model, corner, file = vd.file),
                                     driverPort: TemplatePort(label: $req.victimDriver, pkg: vd.pkg),
                                     receiver: receiverBehaviour(vr.model, corner, vr.file),
                                     receiverPort: TemplatePort(label: $req.victimRx, pkg: vr.pkg),
                                     coupled: pair)
        pts.add pt
      if pts.len > 0:
        var b = base
        b.length = req.coupledLength
        b.coupledLength = req.coupledLength
        r.spacing = spacingFor(pts, b, 0.05e-3, 2.0e-3, max(grid div 2, 6), c, 0.01e-3)
        r.hasSpacing = true
        r.victimNet = req.victimNet
        r.coupledLength = req.coupledLength
        r.notes.add "spacing derived on routes that are exactly the " &
          formatFloat(req.coupledLength * 1e3, ffDecimal, 1) & " mm parallel run, the " &
          "victim held low, both on the same outer-layer microstrip"
  (true, "", r)

# --- differential pairs -------------------------------------------------------

type
  DiffPairRequest* = object
    p*, n*: string
      ## The two nets.
    driver*, rx*: PinRef
      ## The P leg's driver and receiver; the N leg's come from `[Diff Pin]`.
    zDiff*: float
      ## Target differential impedance, ohms (sets the template's gap).
    skewMax*: float
      ## The role's intra-pair skew budget, seconds; `NaN` = none.
    ui*: float

proc diffTermination(nl: Netlist, p, n: string): float =
  ## A resistor straight across the pair (its value), or `0`.
  var r = 0.0
  for _, c in nl.components:
    if c.kind != "resistor" or c.pins.len != 2: continue
    var nets: seq[string]
    for _, pin in c.pins:
      if pin.net != nil: nets.add pin.net.name
    if nets.len == 2 and ((nets[0] == p and nets[1] == n) or (nets[0] == n and nets[1] == p)):
      var v: float
      if parseSpiceMagnitude(c.attrs.getOrDefault("value"), v): r = v
  r

proc pairGap(line: LineSpec, zDiff: float): tuple[spec: LineSpec, z: float] =
  ## The edge-coupled microstrip on `line`'s dielectric, gap equal to width
  ## (a common pair rule), whose `2 Zo` is `zDiff`: width in 0.03 .. 3 mm.
  var spec = line
  spec.geometry = lgEdgeCoupledMicrostrip
  var lo = 0.03e-3
  var hi = 3e-3
  for _ in 0 ..< 60:
    spec.w = 0.5 * (lo + hi)
    spec.s = spec.w
    if 2 * coupledModes(spec).zOdd > zDiff: lo = spec.w else: hi = spec.w
  spec.w = 0.5 * (lo + hi)
  spec.s = spec.w
  (spec, 2 * coupledModes(spec).zOdd)

proc deriveDiffConstraints*(nl: Netlist, req: DiffPairRequest, c: Criteria,
                            st = defaultStackup(), maxLength = 0.3, grid = 11,
                            tolerance = 0.5e-3): tuple[ok: bool, why: string, report: ConstraintReport] =
  ## The routing rules for a differential pair before layout: the max
  ## length of the coupled pair, and the max length mismatch between its
  ## legs (KiCad `skew`) -- simulated with the role's criteria, and from the
  ## role's skew budget over the single line's delay, whichever is tighter.
  let setup = ibisSetup(nl, [req.driver.designator, req.rx.designator])
  if setup.problems.len > 0:
    return (false, setup.problems.join("; "), ConstraintReport())
  let (pair, zd) = pairGap(st.line, req.zDiff)
  var templates: seq[SiTemplate]
  var corners: seq[ibtypes.Corner]
  let rxTerm = diffTermination(nl, req.p, req.n)
  for corner in [ibtypes.coTyp, ibtypes.coMin, ibtypes.coMax]:
    let dP = resolvePin(setup.bindings, req.driver, setup.selections, corner)
    let rP = resolvePin(setup.bindings, req.rx, setup.selections, corner)
    let dPair = diffPartner(setup.bindings, req.driver, corner)
    let rPair = diffPartner(setup.bindings, req.rx, corner)
    var why = ""
    if not dP.ok: why = dP.reason
    elif not rP.ok: why = rP.reason
    elif not dPair.ok: why = dPair.reason
    elif not rPair.ok: why = rPair.reason
    var dN, rN: ResolvedPin
    if why.len == 0:
      dN = resolvePin(setup.bindings, dPair.other, setup.selections, corner)
      rN = resolvePin(setup.bindings, rPair.other, setup.selections, corner)
      if not dN.ok: why = dN.reason
      elif not rN.ok: why = rN.reason
    if why.len > 0:
      if corner == coTyp: return (false, why, ConstraintReport())
      continue
    # Vdiff: the receiver's [Diff Pin], else its [Receiver Thresholds].
    var vdiff = NaN
    var vsrc = ""
    if rPair.hasVdiff:
      vdiff = rPair.vdiff
      vsrc = rPair.source
    else:
      let rt = rP.model.receiverThresholds
      if rt.vdiffDc.present:
        vdiff = rt.vdiffDc.value
        vsrc = rP.model.name & " [Receiver Thresholds] Vdiff_dc"
      elif rt.vdiffAc.present:
        vdiff = rt.vdiffAc.value
        vsrc = rP.model.name & " [Receiver Thresholds] Vdiff_ac"
    var single = pair
    single.geometry = lgMicrostrip
    let line = lineSection(single, lossy = false, layer = "outer", reference = "plane")
    var t = SiTemplate(name: req.p & "/" & req.n & " differential pair",
                       driver: driverBehaviour(dP.model, corner, file = dP.file),
                       driverPort: TemplatePort(label: $req.driver, pkg: dP.pkg),
                       topology: ttPointToPoint, line: line)
    t.receivers.add receiverBehaviour(rP.model, corner, rP.file)
    t.receiverPorts.add TemplatePort(label: $req.rx, pkg: rP.pkg)
    t.partner = TemplatePartner(role: prDiffPair, name: req.n,
                                driver: driverBehaviour(dN.model, corner, file = dN.file),
                                driverPort: TemplatePort(label: $dPair.other, pkg: dN.pkg),
                                receiver: receiverBehaviour(rN.model, corner, rN.file),
                                receiverPort: TemplatePort(label: $rPair.other, pkg: rN.pkg),
                                coupled: pair,
                                skew: (if dPair.inverting: dPair.tdelay else: -dPair.tdelay),
                                vdiff: vdiff, hasVdiff: not vdiff.isNaN, vdiffSource: vsrc)
    templates.add t
    corners.add corner
  var base = templateParams(0.0, diffR = rxTerm)
  var r = ConstraintReport(net: req.p, identity: identity(templates[0], corners, base, c),
                           hasLength: true, bestSeriesR: NaN, pairNet: req.n)
  for a in st.notes: r.identity.assumptions.add $a
  r.identity.assumptions.add "pair: edge-coupled microstrip, width = gap = " &
    formatFloat(pair.s * 1e3, ffDecimal, 3) & " mm for Zdiff " & formatFloat(zd, ffDecimal, 1) &
    " ohm (target " & formatFloat(req.zDiff, ffDecimal, 1) & ")"
  r.identity.assumptions.add (if rxTerm > 0: "differential termination " &
    formatFloat(rxTerm, ffDecimal, 1) & " ohm across the pair (from the netlist)"
    else: "no differential termination found across the pair")
  r.length = sweep(templates, base, spLength, 0.0, maxLength, grid, c, tolerance)
  let tr = templates[0].driver.edges[edRising].riseTime
  r.criticalLength = criticalLength(tr, templates[0].line.tdPerM)
  # Mismatch at the longest length that passes (or 50 mm).
  var sb = base
  sb.length = (let m = r.length.maxFromStart; if m.isNaN: 0.05 else: min(m, maxLength))
  r.skew = sweep(templates, sb, spLegMismatch, 0.0, 0.05, grid, c, 0.2e-3)
  r.hasSkew = true
  if not req.skewMax.isNaN:
    let fromBudget = req.skewMax / templates[0].line.tdPerM
    r.notes.add "skew budget " & formatFloat(req.skewMax * 1e12, ffDecimal, 1) &
      " ps over " & formatFloat(templates[0].line.tdPerM * 1e9, ffDecimal, 3) &
      " ns/m is " & formatFloat(fromBudget * 1e3, ffDecimal, 3) & " mm of mismatch"
    let m = r.skew.maxFromStart
    if m.isNaN or fromBudget < m:
      r.skew.passing = @[(0.0, fromBudget)]
      r.skew.binding = "the role's skew_intra_max"
  (true, "", r)
