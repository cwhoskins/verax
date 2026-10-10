## Interpreting an IBIS `[Model]` as a *behaviour*: absolute-voltage I/V
## curves, rails, `C_comp` and the switching coefficients `Ku(t)`/`Kd(t)`
## for one corner. Pure math over `ibis/types`; it builds no solver devices
## and reaches no verdicts (that is `si/`). The only other imports are the
## shared `Issue`/`Assumption` record types.
##
## Normative conventions (docs/ibis_simulator_plan.md, decision 2). Clause
## references are to the IBIS 7.2 specification, section 6 ("Buffer
## Modeling"), keyword entries as named:
##
## - **Voltages are absolute**, relative to the model's ground. `[Pullup]`
##   and `[POWER Clamp]` are tabulated as `Vtable = Vcc - Voutput`
##   ("[Pulldown], [Pullup], [GND Clamp], [POWER Clamp]", Other Notes), with
##   Vcc the rail from `[Pullup Reference]`/`[POWER Clamp Reference]`, else
##   `[Voltage Range]`. `[Pulldown]`/`[GND Clamp]` are relative to their
##   reference keyword, else 0 V. `behave` converts every table once; engines
##   never see the IBIS reference convention.
## - **Current sign.** IBIS tabulates current *into* the component (same
##   entry, Description; section 3 rule 11). verax uses the opposite: an
##   `IvCurve` holds current **out of the die into the pad node**, so a
##   driver pulling high is positive. Conversion negates once, here.
## - **Clamps are always on, and the pullup/pulldown tables already have the
##   clamp current subtracted** (same entry, Other Notes: "the [Pullup] and
##   [Pulldown] tables of an IBIS model must represent the difference of the
##   3-stated and the enabled buffer's tables ... This requirement enables
##   the EDA tool to sum the tables, without the danger of double
##   counting"). So the driver equation adds every table exactly once:
##
##   ```
##   I_pad(t) = Ku(t)*I_pu(v) + Kd(t)*I_pd(v) + I_gc(v) + I_pc(v) - C_comp*dv/dt
##   ```
##
##   A non-3-statable buffer may fold the clamps into its pullup/pulldown and
##   leave the clamp tables zero or absent (same note) -- the same sum still
##   holds.
## - **Interpolation** is linear between rows; outside the table the end
##   segment is extended linearly (flat extrapolation would turn a clamp
##   off). Leaving the table by more than a margin is the engine's `Issue`,
##   because only it knows the pad voltage. Interior `NA` rows are skipped
##   (allowed: the first and last rows must be numeric, same entry).
## - **Waveforms** include `C_comp` and exclude the package ("[Rising
##   Waveform], [Falling Waveform]", Usage Rules). Each table's first row is
##   the stimulus reference time, so each is shifted to start at 0.
##   `V_fixture_min/max` give the fixture voltage at the min/max corner.
## - **Fixture networks** (`L_fixture`, `R_dut`, `L_dut`, `C_dut`; IBIS
##   Figure 18: die - L_dut - R_dut - pin, C_dut at the pin, then L_fixture
##   to the fixture node with C_fixture and R_fixture to V_fixture). The
##   spec's text does not say where the table is measured; the dut
##   parasitics exist "if the waveform includes the effects of pin
##   inductance/capacitance", so it is outside the package: **at the DUT
##   pin** by default (`ExtractTolerances.probe`), recorded as an
##   `Assumption`. The linear network is marched from the measured node to
##   the die (trapezoidal fixture side; derivatives of the sampled table on
##   the package side), giving the die voltage and current at each time
##   point, and the same `Ku`/`Kd` solve follows. The reconstruction then
##   **simulates the whole nonlinear fixture** with the extracted
##   coefficients (trapezoidal, as `si/engine`) and its residual decides
##   availability -- the package side differentiates the table twice, so a
##   coarse table shows up there, not as a silently wrong edge.
## - **`[Ramp]`** is the 20 %-80 % time, `C_comp` included, package excluded.
##   The ramp-only fallback assumes linear `Ku + Kd = 1` over `dt / 0.6`.
## - **`[Model Spec]`**: an `NA` min/max column means the typ value ("NA
##   indicating the typical value by default", [Model Spec] Usage Rules), so
##   that fill is the spec's rule, recorded as a substitution but always
##   permitted. Every other absent corner has no substitution policy yet
##   (decision 7), so it makes the behaviour unsupported.

import std/[math, strutils, algorithm]
import ./types
import ../netlist/issue
import ../netlist/annotations

export types, issue, annotations.Assumption, annotations.`$`

type
  IvCurve* = object
    ## Absolute pad voltage (ascending) -> current **out of** the die.
    ## Empty means the table is absent: it contributes nothing.
    v*, i*: seq[float]
    source*: string
      ## Provenance: model, keyword, corner.

  Edge* = enum
    edRising, edFalling

  KSource* = enum
    ksWaveforms   ## solved from the V/T tables
    ksRamp        ## `[Ramp]` fallback, linear, `Ku + Kd = 1`

  KSeries* = object
    ## `Ku`/`Kd` against time since the stimulus, for one edge.
    t*, ku*, kd*: seq[float]
    source*: KSource
    waveformsUsed*: seq[int]
      ## Indices into the model's rising/falling waveform list.
    residualV*, residualI*: float
      ## Worst reconstruction error over every used fixture: volts, amps.
      ## `0` for the ramp fallback (nothing to reconstruct).
    lsResidual*: float
      ## Worst least-squares residual current, amps (more fixtures than
      ## unknowns only).
    conditioning*: float
      ## Smallest normalised conditioning over the time axis (1 = ideal).
    available*: bool
      ## False when the reconstruction residual is past tolerance: the edge
      ## may be inspected but not used for a verdict.
    reason*: string
    provenance*: string

  ExtractTolerances* = object
    kRange*: float
      ## How far outside `[0, 1]` a coefficient may go before a warning.
    residualVFrac*: float
      ## Reconstruction voltage error, as a fraction of the rail span.
    residualIFrac*: float
      ## Reconstruction current error, as a fraction of the largest fixture
      ## current.
    conditioning*: float
      ## Below this the fixtures can't separate pullup from pulldown.
    probe*: WaveformProbe
      ## Where a fixture network's waveform is taken.

  WaveformProbe* = enum
    wpPin       ## the DUT pin: between R_dut/C_dut and L_fixture (default)
    wpFixture   ## the fixture node: after L_fixture, at C_fixture/R_fixture

  Rails* = object
    pullup*, pulldown*, gndClamp*, powerClamp*: float

  Thresholds* = object
    vinh*, vinl*: float
    present*: bool
      ## Both thresholds known (`[Model Spec]` first, else `[Model]`).

  OvershootLimits* = object
    ## `[Model Spec]` static limits, absolute volts.
    high*, low*: float
    hasHigh*, hasLow*: bool

  TimingLoad* = object
    ## The `Vref`/`Rref`/`Cref` load timing is specified into, and `Vmeas`.
    vmeas*, vref*, rref*, cref*: float
    hasVmeas*, hasVref*, hasRref*, hasCref*: bool

  DriverBehaviour* = object
    model*, file*: string
    modelType*: ModelType
    corner*: Corner
    supported*: bool
    reason*: string
      ## Why not, when `supported` is false: the precise limitation.
    rails*: Rails
    pullup*, pulldown*, gndClamp*, powerClamp*: IvCurve
    hasPullup*, hasPulldown*: bool
    cComp*: float
    edges*: array[Edge, KSeries]
    kssoPu*, kssoPd*: IvCurve
      ## Power-aware (`[ISSO PU]`/`[ISSO PD]`): the factor on the pullup
      ## (pulldown) current against `Vtable` = the pullup rail's droop below
      ## nominal (the pulldown rail's rise above it), `Isso(Vtable) /
      ## Isso(0)`. Here `IvCurve.i` holds the factor. Empty: not stated.
    preDriver*: array[Edge, tuple[t, i: seq[float]]]
      ## Current from the power to the ground rail that is not in the I/V
      ## tables, after the start of each edge: `[Composite Current]` minus
      ## the pullup and POWER clamp current the extracted edge draws into
      ## the same fixture. Empty without a `[Composite Current]`.
    timing*: TimingLoad
    thresholds*: Thresholds
    substitutions*: seq[Assumption]
    assumptions*: seq[Assumption]
    issues*: seq[Issue]

  ReceiverBehaviour* = object
    model*, file*: string
    modelType*: ModelType
    corner*: Corner
    supported*: bool
    reason*: string
    rails*: Rails
    gndClamp*, powerClamp*: IvCurve
    cComp*: float
    thresholds*: Thresholds
    overshoot*: OvershootLimits
    substitutions*: seq[Assumption]
    assumptions*: seq[Assumption]
    issues*: seq[Issue]

proc edgeName*(e: Edge): string =
  case e
  of edRising: "rising"
  of edFalling: "falling"

proc defaultTolerances*(): ExtractTolerances =
  ## Starting values (open decision 3): set from the synthetic fixtures,
  ## to be checked against the vendor set.
  ExtractTolerances(kRange: 0.1, residualVFrac: 0.02, residualIFrac: 0.02,
                    conditioning: 1e-3)

# --- curves ------------------------------------------------------------

proc isEmpty*(c: IvCurve): bool {.inline.} = c.v.len == 0

proc eval*(c: IvCurve, v: float): tuple[i, g: float] =
  ## Current and `di/dv` at `v`: linear between rows, end segments extended.
  ## An empty curve is `(0, 0)`; a one-row curve is a constant.
  let n = c.v.len
  if n == 0: return (0.0, 0.0)
  if n == 1: return (c.i[0], 0.0)
  var k: int
  if v <= c.v[0]: k = 0
  elif v >= c.v[^1]: k = n - 2
  else:
    k = upperBound(c.v, v) - 1
    k = clamp(k, 0, n - 2)
  let g = (c.i[k + 1] - c.i[k]) / (c.v[k + 1] - c.v[k])
  (c.i[k] + g * (v - c.v[k]), g)

proc segmentOf*(c: IvCurve, v: float): int =
  ## Which segment `v` falls in (`-1` below, `len - 1` above), for Newton
  ## damping on segment changes.
  if c.v.len < 2: return 0
  if v < c.v[0]: return -1
  if v >= c.v[^1]: return c.v.len - 1
  upperBound(c.v, v) - 1

proc knees*(c: IvCurve): seq[float] = c.v

# --- corner resolution ---------------------------------------------------

type
  CornerData* = object
    ## Every field a simulation needs, at one corner, plus how it got there.
    rails*: Rails
    pullup*, pulldown*, gndClamp*, powerClamp*: IvCurve
    cComp*: float
    thresholds*: Thresholds
    overshoot*: OvershootLimits
    timing*: TimingLoad
    substitutions*: seq[Assumption]
    unsupported*: seq[string]
      ## Each a field with no value at this corner and no permitted
      ## substitution. Non-empty means the corner cannot run.

proc tripletAt(t: Triplet, c: Corner): tuple[ok: bool, v: float] =
  if t.has(c): (true, t.get(c)) else: (false, NaN)

proc anyCorner(t: Triplet): bool = t.has(coTyp) or t.has(coMin) or t.has(coMax)

proc convertTable(tbl: IvTable, c: Corner, vref: float, vccRelative: bool,
                  what: string, cd: var CornerData): IvCurve =
  ## IBIS rows -> absolute, out-of-die curve. Interior `NA` rows are skipped;
  ## a missing first/last row or repeated voltage is unsupported.
  result.source = what & " " & cornerName(c)
  if tbl.len == 0: return
  if not tbl[0].i.has(c) or not tbl[^1].i.has(c):
    cd.unsupported.add what & " has no " & cornerName(c) & " column at its first/last row"
    return IvCurve(source: result.source)
  var pts: seq[tuple[v, i: float]]
  for row in tbl:
    if not row.i.has(c): continue
    let vabs = if vccRelative: vref - row.v else: vref + row.v
    pts.add (vabs, -row.i.get(c))
  pts.sort(proc(a, b: tuple[v, i: float]): int = cmp(a.v, b.v))
  for k in 1 ..< pts.len:
    if pts[k].v == pts[k - 1].v:
      cd.unsupported.add what & " repeats voltage " & $pts[k].v
      return IvCurve(source: result.source)
  for p in pts:
    result.v.add p.v
    result.i.add p.i

proc specOr(cd: var CornerData, spec: Triplet, fallback: ModelParam,
            c: Corner, name, model: string): tuple[ok: bool, v: float] =
  ## `[Model Spec]` value at `c`; an NA min/max column is typ by the spec's
  ## own rule; otherwise the `[Model]` scalar.
  if spec.has(c): return (true, spec.get(c))
  if spec.has(coTyp):
    cd.substitutions.add note(model,
      "[Model Spec] " & name & " " & cornerName(c) & " is NA; the typ value applies " &
      "(IBIS [Model Spec] usage rule)")
    return (true, spec.get(coTyp))
  if fallback.present: return (true, fallback.value)
  (false, NaN)

proc resolveCorner*(m: IbisModel, c: Corner): CornerData =
  ## Decision 7: walk every field, take it at `c` or record why not. No
  ## substitution between corners is permitted (no policy yet), so an absent
  ## min/max value lands in `unsupported`.
  let who = m.name
  # Rails.
  proc rail(cd: var CornerData, refT: Triplet, fallback: Triplet,
            fallbackZero: bool, name: string): float =
    if anyCorner(refT):
      let (ok, v) = tripletAt(refT, c)
      if not ok: cd.unsupported.add name & " has no " & cornerName(c) & " value"
      return v
    if fallbackZero: return 0.0
    let (ok, v) = tripletAt(fallback, c)
    if not ok: cd.unsupported.add "[Voltage Range] has no " & cornerName(c) & " value (needed for " & name & ")"
    v
  let needsVcc = m.pullup.len > 0 or m.powerClamp.len > 0
  if needsVcc or anyCorner(m.voltageRange):
    result.rails.pullup = rail(result, m.pullupRef, m.voltageRange, false, "[Pullup Reference]")
    result.rails.powerClamp = rail(result, m.powerClampRef, m.voltageRange, false, "[POWER Clamp Reference]")
  result.rails.pulldown = rail(result, m.pulldownRef, m.voltageRange, true, "[Pulldown Reference]")
  result.rails.gndClamp = rail(result, m.gndClampRef, m.voltageRange, true, "[GND Clamp Reference]")
  if result.unsupported.len == 0:
    result.pullup = convertTable(m.pullup, c, result.rails.pullup, true, who & " [Pullup]", result)
    result.pulldown = convertTable(m.pulldown, c, result.rails.pulldown, false, who & " [Pulldown]", result)
    result.gndClamp = convertTable(m.gndClamp, c, result.rails.gndClamp, false, who & " [GND Clamp]", result)
    result.powerClamp = convertTable(m.powerClamp, c, result.rails.powerClamp, true, who & " [POWER Clamp]", result)
  # C_comp.
  if m.cComp.has(c): result.cComp = m.cComp.get(c)
  elif anyCorner(m.cComp): result.unsupported.add "C_comp has no " & cornerName(c) & " value"
  else: result.unsupported.add "no C_comp (C_comp_* split capacitance is not supported)"
  # Thresholds, limits, timing load.
  let (hOk, vinh) = specOr(result, m.modelSpec.vinh, m.vinh, c, "Vinh", who)
  let (lOk, vinl) = specOr(result, m.modelSpec.vinl, m.vinl, c, "Vinl", who)
  result.thresholds = Thresholds(vinh: vinh, vinl: vinl, present: hOk and lOk)
  let none = ModelParam()
  let (shOk, sh) = specOr(result, m.modelSpec.sOvershootHigh, none, c, "S_overshoot_high", who)
  let (slOk, sl) = specOr(result, m.modelSpec.sOvershootLow, none, c, "S_overshoot_low", who)
  result.overshoot = OvershootLimits(high: sh, low: sl, hasHigh: shOk, hasLow: slOk)
  let (vmOk, vm) = specOr(result, m.modelSpec.vmeas, m.vmeas, c, "Vmeas", who)
  let (vrOk, vr) = specOr(result, m.modelSpec.vref, m.vref, c, "Vref", who)
  let (rrOk, rr) = specOr(result, m.modelSpec.rref, m.rref, c, "Rref", who)
  let (crOk, cr) = specOr(result, m.modelSpec.cref, m.cref, c, "Cref", who)
  result.timing = TimingLoad(vmeas: vm, vref: vr, rref: rr, cref: cr,
                             hasVmeas: vmOk, hasVref: vrOk, hasRref: rrOk, hasCref: crOk)

# --- model-type gating ---------------------------------------------------

proc driverKind(m: IbisModel): tuple[ok: bool, pullup, pulldown: bool, why: string] =
  let raw = m.rawType.toLowerAscii
  if raw.startsWith("i/o_open") or raw.startsWith("io_open"):
    return (false, false, false, "Model_type " & m.rawType & " is not supported yet (open decision 1)")
  case m.modelType
  of mtOutput, mtThreeState, mtIO: (true, true, true, "")
  of mtOpenDrain, mtOpenSink: (true, false, true, "")
  of mtInput, mtTerminator:
    (false, false, false, "Model_type " & m.rawType & " cannot drive")
  else:
    (false, false, false, "Model_type " & m.rawType & " is not supported yet (open decision 1)")

proc receiverKind(m: IbisModel): tuple[ok: bool, why: string] =
  let raw = m.rawType.toLowerAscii
  if raw.startsWith("i/o_open") or raw.startsWith("io_open"):
    return (false, "Model_type " & m.rawType & " is not supported yet (open decision 1)")
  case m.modelType
  of mtInput, mtIO: (true, "")
  of mtTerminator:
    for ch in m.raw.children:
      if ch.keyword in ["rgnd", "rpower", "rac", "cac"]:
        return (false, "Terminator [" & ch.rawKeyword & "] is not modelled")
    (true, "")
  of mtOutput, mtThreeState, mtOpenDrain, mtOpenSink:
    (false, "Model_type " & m.rawType & " is not an input")
  else:
    (false, "Model_type " & m.rawType & " is not supported yet (open decision 1)")

# --- switching coefficients -----------------------------------------------

proc slopeAt(ts, vs: seq[float], t: float): float =
  ## `dv/dt` of a piecewise-linear table: the segment slope, or at a knot the
  ## mean of the two adjacent slopes (one at an end).
  let n = ts.len
  if n < 2: return 0.0
  if t <= ts[0]: return (vs[1] - vs[0]) / (ts[1] - ts[0])
  if t >= ts[^1]: return (vs[^1] - vs[^2]) / (ts[^1] - ts[^2])
  let k = upperBound(ts, t) - 1        # ts[k] <= t < ts[k+1]
  let s = (vs[k + 1] - vs[k]) / (ts[k + 1] - ts[k])
  if t == ts[k] and k > 0:
    let sPrev = (vs[k] - vs[k - 1]) / (ts[k] - ts[k - 1])
    return 0.5 * (s + sPrev)
  s

proc valueAt(ts, vs: seq[float], t: float): float =
  if t <= ts[0]: return vs[0]
  if t >= ts[^1]: return vs[^1]
  let k = upperBound(ts, t) - 1
  vs[k] + (vs[k + 1] - vs[k]) * (t - ts[k]) / (ts[k + 1] - ts[k])

type
  UsableWave = object
    index: int
    t, v: seq[float]
    rf, vf, cf: float
    lf, rdut, ldut, cdut: float
    network: bool
      ## Any of `L_fixture`/`R_dut`/`L_dut`/`C_dut`: the measured node is
      ## not the die.

proc usableWaveforms(ws: seq[Waveform], c: Corner, label: string,
                     issues: var seq[Issue]): seq[UsableWave] =
  ## Every fixture IBIS defines (Figure 18); a malformed table is reported,
  ## not dropped silently and not simplified.
  for k, w in ws:
    let tag = label & " #" & $(k + 1)
    var bad: seq[string]
    for (x, name) in [(w.lFixture, "L_fixture"), (w.rDut, "R_dut"), (w.lDut, "L_dut"),
                      (w.cDut, "C_dut"), (w.cFixture, "C_fixture")]:
      if x < 0.0: bad.add name
    if bad.len > 0:
      issues.add newIssue("ibis_waveform_unsupported", sevWarning,
        tag & " has a negative " & bad.join(", ") & "; not used")
      continue
    if w.rFixture <= 0.0:
      issues.add newIssue("ibis_waveform_unsupported", sevWarning,
        tag & " has no positive R_fixture; not used")
      continue
    if not w.vFixture.has(c):
      issues.add newIssue("ibis_waveform_unsupported", sevWarning,
        tag & " has no V_fixture at " & cornerName(c) & "; not used")
      continue
    var u = UsableWave(index: k, rf: w.rFixture, vf: w.vFixture.get(c), cf: w.cFixture,
                       lf: w.lFixture, rdut: w.rDut, ldut: w.lDut, cdut: w.cDut)
    u.network = u.lf != 0.0 or u.rdut != 0.0 or u.ldut != 0.0 or u.cdut != 0.0
    var ok = true
    for p in w.points:
      if not p.v.has(c): continue
      if u.t.len > 0 and p.t <= u.t[^1]:
        issues.add newIssue("ibis_waveform_unsupported", sevWarning,
          tag & " time column is not strictly increasing at " & $p.t & "; not used")
        ok = false
        break
      u.t.add p.t
      u.v.add p.v.get(c)
    if not ok: continue
    if u.t.len < 2 or not w.points[0].v.has(c) or not w.points[^1].v.has(c):
      issues.add newIssue("ibis_waveform_unsupported", sevWarning,
        tag & " has no " & cornerName(c) & " column (first/last rows); not used")
      continue
    let t0 = u.t[0]
    for x in u.t.mitems: x -= t0
    result.add u

type
  FixtureSeries = object
    ## One network fixture on the extraction axis: every node and branch.
    vd, iL, vp, iFix, vf: seq[float]
      ## Die, die -> pin current, pin, pin -> fixture current, fixture node.

proc fixtureSeries(w: UsableWave, ts: seq[float], probe: WaveformProbe): FixtureSeries =
  ## March the linear network from the measured node to the die. The
  ## fixture side (L_fixture into C_fixture || R_fixture) is integrated
  ## trapezoidally when the table is taken at the pin; the package side
  ## (C_dut, R_dut, L_dut) is the table's derivatives.
  let n = ts.len
  var r = FixtureSeries(vd: newSeq[float](n), iL: newSeq[float](n), vp: newSeq[float](n),
                        iFix: newSeq[float](n), vf: newSeq[float](n))
  case probe
  of wpFixture:
    for k in 0 ..< n:
      r.vf[k] = valueAt(w.t, w.v, ts[k])
      r.iFix[k] = (r.vf[k] - w.vf) / w.rf + w.cf * slopeAt(w.t, w.v, ts[k])
    for k in 0 ..< n: r.vp[k] = r.vf[k] + w.lf * slopeAt(ts, r.iFix, ts[k])
  of wpPin:
    for k in 0 ..< n: r.vp[k] = valueAt(w.t, w.v, ts[k])
    if w.lf == 0.0:
      for k in 0 ..< n:
        r.vf[k] = r.vp[k]
        r.iFix[k] = (r.vf[k] - w.vf) / w.rf + w.cf * slopeAt(w.t, w.v, ts[k])
    else:
      # DC at the first point, then trapezoidal: L_fixture
      # `vp - vf = (2L/h)(iFix - iF0) - vL0`, fixture node
      # `iFix = (2C/h)(vf - vf0) - iC0 + (vf - Vf)/Rf`.
      r.vf[0] = r.vp[0]
      r.iFix[0] = (r.vf[0] - w.vf) / w.rf
      var vL = 0.0
      var iC = 0.0
      for k in 1 ..< n:
        let h = ts[k] - ts[k - 1]
        let gL = 2.0 * w.lf / h
        let gC = 2.0 * w.cf / h
        let num = r.iFix[k - 1] + (r.vp[k] + vL) / gL + gC * r.vf[k - 1] + iC + w.vf / w.rf
        r.vf[k] = num / (gC + 1.0 / w.rf + 1.0 / gL)
        r.iFix[k] = r.iFix[k - 1] + (r.vp[k] - r.vf[k] + vL) / gL
        vL = r.vp[k] - r.vf[k]
        iC = gC * (r.vf[k] - r.vf[k - 1]) - iC
  for k in 0 ..< n: r.iL[k] = r.iFix[k] + w.cdut * slopeAt(ts, r.vp, ts[k])
  for k in 0 ..< n: r.vd[k] = r.vp[k] + w.rdut * r.iL[k] + w.ldut * slopeAt(ts, r.iL, ts[k])
  r

proc solveScalar(f: proc(v: float): tuple[r, d: float], x0, lo, hi: float): float =
  ## Root of a decreasing-ish scalar function: Newton, bisection fallback.
  var x = x0
  for _ in 0 ..< 60:
    let (r, d) = f(x)
    if abs(r) < 1e-15: return x
    if d == 0.0: break
    let nx = x - r / d
    if abs(nx - x) < 1e-12 * max(1.0, abs(x)): return nx
    if nx < lo or nx > hi: break
    x = nx
  var a = lo
  var b = hi
  var fa = f(a).r
  for _ in 0 ..< 200:
    let m = 0.5 * (a + b)
    let fm = f(m).r
    if (fm > 0) == (fa > 0):
      a = m; fa = fm
    else:
      b = m
    if b - a < 1e-13: break
  0.5 * (a + b)

proc bufferCurrent*(cd: CornerData, ku, kd, v: float): tuple[i, g: float] =
  ## Out-of-die buffer current excluding `C_comp`: every table once.
  let pu = cd.pullup.eval(v)
  let pd = cd.pulldown.eval(v)
  let gc = cd.gndClamp.eval(v)
  let pc = cd.powerClamp.eval(v)
  (ku * pu.i + kd * pd.i + gc.i + pc.i, ku * pu.g + kd * pd.g + gc.g + pc.g)

proc rampSeries(m: IbisModel, edge: Edge, c: Corner, hasPu, hasPd: bool,
                why: string): KSeries =
  let dt = if edge == edRising: m.ramp.dtR else: m.ramp.dtF
  result.source = ksRamp
  if not dt.has(c) or dt.get(c) <= 0.0:
    result.available = false
    result.reason = "no usable waveforms (" & why & ") and no [Ramp] " &
      (if edge == edRising: "dV/dt_r" else: "dV/dt_f") & " at " & cornerName(c)
    return
  let tFull = dt.get(c) / 0.6
  let up0 = if edge == edRising: 0.0 else: 1.0
  result.t = @[0.0, tFull]
  for up in [up0, 1.0 - up0]:
    result.ku.add (if hasPu: up else: 0.0)
    result.kd.add (if hasPd: 1.0 - up else: 0.0)
  result.available = true
  result.conditioning = 1.0
  result.provenance = m.name & " [Ramp] " & edgeName(edge) & " " & cornerName(c) & " (dt / 0.6, linear)"

proc solve4(a: var array[4, array[4, float]], b: var array[4, float]): array[4, float] =
  ## Gaussian elimination with partial pivoting (a fixture's linear part).
  for col in 0 ..< 4:
    var p = col
    for r in col + 1 ..< 4:
      if abs(a[r][col]) > abs(a[p][col]): p = r
    swap(a[p], a[col])
    swap(b[p], b[col])
    for r in col + 1 ..< 4:
      let f = a[r][col] / a[col][col]
      for q in col ..< 4: a[r][q] -= f * a[col][q]
      b[r] -= f * b[col]
  for r in countdown(3, 0):
    var s = b[r]
    for q in r + 1 ..< 4: s -= a[r][q] * result[q]
    result[r] = s / a[r][r]

proc reconstructNetwork(cd: CornerData, ser: KSeries, w: UsableWave, ts: seq[float],
                        meas: FixtureSeries, probe: WaveformProbe): tuple[dv, di: float] =
  ## Simulate the whole fixture (buffer with the extracted `Ku`/`Kd`,
  ## C_comp, R_dut + L_dut, C_dut, L_fixture, C_fixture, R_fixture to
  ## V_fixture) trapezoidally from the table's first (DC) point, and return
  ## the worst error at the measured node and in the fixture current.
  var vd = meas.vd[0]
  var iL = meas.iL[0]
  var vp = meas.vp[0]
  var iFix = meas.iFix[0]
  var vf = meas.vf[0]
  var iCc, iCd, iCf, vLd, vLf: float   # DC: capacitors open, inductors short
  let span = max(abs(cd.rails.pullup - cd.rails.pulldown), 1e-3)
  let lo = min(cd.rails.pulldown, cd.rails.gndClamp) - 2.0 * span
  let hi = max(cd.rails.pullup, cd.rails.powerClamp) + 2.0 * span
  for k in 1 ..< ts.len:
    let h = ts[k] - ts[k - 1]
    let ku = valueAt(ser.t, ser.ku, ts[k])
    let kd = valueAt(ser.t, ser.kd, ts[k])
    let gCc = 2.0 * cd.cComp / h
    let gLd = 2.0 * w.ldut / h
    let gCd = 2.0 * w.cdut / h
    let gLf = 2.0 * w.lf / h
    let gCf = 2.0 * w.cf / h
    # Given the die voltage the rest is linear: x = (iL, vp, iFix, vf).
    proc linear(vdie: float): array[4, float] =
      var a: array[4, array[4, float]]
      var b: array[4, float]
      a[0] = [-(w.rdut + gLd), -1.0, 0.0, 0.0]
      b[0] = -vdie - gLd * iL - vLd
      a[1] = [1.0, -gCd, -1.0, 0.0]
      b[1] = -(gCd * vp + iCd)
      a[2] = [0.0, 1.0, -gLf, -1.0]
      b[2] = -gLf * iFix - vLf
      a[3] = [0.0, 0.0, 1.0, -(gCf + 1.0 / w.rf)]
      b[3] = -(gCf * vf + iCf) - w.vf / w.rf
      solve4(a, b)
    let x0 = linear(0.0)
    let x1 = linear(1.0)
    let beta = x1[0] - x0[0]
    let vdPrev = vd
    let iCcPrev = iCc
    let vdn = solveScalar(proc(v: float): tuple[r, d: float] =
      let b = bufferCurrent(cd, ku, kd, v)
      let ic = gCc * (v - vdPrev) - iCcPrev
      (b.i - ic - (x0[0] + beta * v), b.g - gCc - beta), vd, lo, hi)
    var x: array[4, float]
    for q in 0 ..< 4: x[q] = x0[q] + (x1[q] - x0[q]) * vdn
    iCc = gCc * (vdn - vd) - iCc
    iCd = gCd * (x[1] - vp) - iCd
    iCf = gCf * (x[3] - vf) - iCf
    vLd = vdn - x[1] - w.rdut * x[0]
    vLf = x[1] - x[3]
    vd = vdn
    iL = x[0]
    vp = x[1]
    iFix = x[2]
    vf = x[3]
    let vm = if probe == wpPin: vp else: vf
    let vt = if probe == wpPin: meas.vp[k] else: meas.vf[k]
    result.dv = max(result.dv, abs(vm - vt))
    result.di = max(result.di, abs(iFix - meas.iFix[k]))

proc switchingCoefficients*(m: IbisModel, edge: Edge, c: Corner,
                            cd: CornerData, hasPu, hasPd: bool,
                            tol = defaultTolerances(),
                            issues: var seq[Issue],
                            assumptions: var seq[Assumption]): KSeries =
  ## Decision 3. With at least as many usable fixtures as unknowns, solve
  ## the full driver equation per time point (least squares beyond that);
  ## else fall back to `[Ramp]`. The reconstruction residual decides
  ## `available`.
  let label = m.name & (if edge == edRising: " [Rising Waveform]" else: " [Falling Waveform]")
  let ws = if edge == edRising: m.risingWaveforms else: m.fallingWaveforms
  let nUnk = ord(hasPu) + ord(hasPd)
  var waves = usableWaveforms(ws, c, label, issues)

  template fallback(why: string): KSeries =
    var r = rampSeries(m, edge, c, hasPu, hasPd, why)
    if r.available:
      assumptions.add note(m.name,
        edgeName(edge) & " edge from [Ramp] only (" & why & "): linear Ku + Kd = 1 " &
        "over the 20-80 % time / 0.6 -- less accurate than V/T tables")
    r

  if nUnk == 0: return fallback("no pullup or pulldown")
  if waves.len < max(nUnk, 2) and not (nUnk == 1 and waves.len >= 1):
    return fallback($waves.len & " usable waveform(s), need " & $max(nUnk, 2))

  # Common axis: union of knots within the overlap.
  var tEnd = Inf
  for w in waves: tEnd = min(tEnd, w.t[^1])
  if tEnd <= 0.0:
    issues.add newIssue("ibis_waveform_unsupported", sevWarning,
      label & ": waveform time ranges do not overlap")
    return fallback("time ranges do not overlap")
  var axis: seq[float]
  for w in waves:
    for t in w.t:
      if t <= tEnd: axis.add t
  axis.add tEnd
  axis.sort()
  var ts: seq[float]
  for t in axis:
    if ts.len == 0 or t - ts[^1] > 1e-6 * tEnd: ts.add t

  # A fixture network: the die's voltage and current from the table.
  var series = newSeq[FixtureSeries](waves.len)
  var networks: seq[string]
  for j in 0 ..< waves.len:
    if waves[j].network:
      series[j] = fixtureSeries(waves[j], ts, tol.probe)
      networks.add "#" & $(waves[j].index + 1)
  if networks.len > 0:
    assumptions.add note(m.name, label & " " & networks.join(",") & " " & cornerName(c) &
      ": fixture network (L_fixture/R_dut/L_dut/C_dut) solved back to the die; the table " &
      "is taken to be measured at the " &
      (if tol.probe == wpPin: "DUT pin (IBIS Figure 18 does not say; outside the package)"
       else: "fixture node (after L_fixture)"))

  # Column scales, for scale-free conditioning.
  var colMax = [0.0, 0.0]
  type Row = tuple[a: array[2, float], rhs: float]
  var rowsAt = newSeq[seq[Row]](ts.len)
  for k, t in ts:
    for j in 0 ..< waves.len:
      template w: untyped = waves[j]
      var v, dv, iOut: float
      if w.network:
        v = series[j].vd[k]
        dv = slopeAt(ts, series[j].vd, t)
        iOut = series[j].iL[k] + cd.cComp * dv
      else:
        v = valueAt(w.t, w.v, t)
        dv = slopeAt(w.t, w.v, t)
        iOut = (v - w.vf) / w.rf + (w.cf + cd.cComp) * dv
      var a: array[2, float]
      var q = 0
      if hasPu: a[q] = cd.pullup.eval(v).i; inc q
      if hasPd: a[q] = cd.pulldown.eval(v).i; inc q
      let rhs = iOut - cd.gndClamp.eval(v).i - cd.powerClamp.eval(v).i
      for q in 0 ..< nUnk: colMax[q] = max(colMax[q], abs(a[q]))
      rowsAt[k].add (a, rhs)

  result.source = ksWaveforms
  result.conditioning = 1.0
  for w in waves: result.waveformsUsed.add w.index
  for k, t in ts:
    let rows = rowsAt[k]
    var x: array[2, float]
    if nUnk == 1:
      var num, den: float
      for r in rows:
        num += r.a[0] * r.rhs
        den += r.a[0] * r.a[0]
      let cond = if colMax[0] > 0: sqrt(den / rows.len.float) / colMax[0] else: 0.0
      result.conditioning = min(result.conditioning, cond)
      if cond < tol.conditioning:
        issues.add newIssue("ibis_waveform_ill_conditioned", sevWarning,
          label & ": at t = " & $t & " s no fixture draws current through the " &
          "buffer; coefficient not identifiable")
        return fallback("ill-conditioned fixtures")
      x[0] = num / den
    else:
      # Normal equations on column-scaled A.
      var s00, s01, s11, b0, b1: float
      let c0 = if colMax[0] > 0: colMax[0] else: 1.0
      let c1 = if colMax[1] > 0: colMax[1] else: 1.0
      for r in rows:
        let a0 = r.a[0] / c0
        let a1 = r.a[1] / c1
        s00 += a0 * a0; s01 += a0 * a1; s11 += a1 * a1
        b0 += a0 * r.rhs; b1 += a1 * r.rhs
      let tr = s00 + s11
      let det = s00 * s11 - s01 * s01
      let disc = sqrt(max(0.0, tr * tr / 4 - det))
      let lmax = tr / 2 + disc
      let lmin = tr / 2 - disc
      let cond = if lmax > 0: sqrt(max(lmin, 0.0) / lmax) else: 0.0
      result.conditioning = min(result.conditioning, cond)
      if cond < tol.conditioning:
        issues.add newIssue("ibis_waveform_ill_conditioned", sevWarning,
          label & ": at t = " & $t & " s the fixtures are too similar to " &
          "separate pullup from pulldown (conditioning " & $cond & "); pair rejected")
        return fallback("ill-conditioned fixtures")
      x[0] = (s11 * b0 - s01 * b1) / det / c0
      x[1] = (s00 * b1 - s01 * b0) / det / c1
    if rows.len > nUnk:
      for r in rows:
        var fit = 0.0
        for q in 0 ..< nUnk: fit += r.a[q] * x[q]
        result.lsResidual = max(result.lsResidual, abs(fit - r.rhs))
    result.t.add t
    let jd = if hasPu: 1 else: 0
    result.ku.add (if hasPu: x[0] else: 0.0)
    result.kd.add (if hasPd: x[jd] else: 0.0)

  # Out-of-range coefficients: warn, never clamp.
  var worst = 0.0
  for s in [result.ku, result.kd]:
    for k in s: worst = max(worst, max(-k, k - 1.0))
  if worst > tol.kRange:
    issues.add newIssue("ibis_coefficient_out_of_range", sevWarning,
      label & ": Ku/Kd leave [0, 1] by " & formatFloat(worst, ffDecimal, 3) &
      " -- the waveforms and the I/V tables disagree")

  # Reconstruction: re-drive every used fixture and compare.
  let span = max(abs(cd.rails.pullup - cd.rails.pulldown), 1e-3)
  var iMax = 0.0
  for w in waves:
    for k, t in w.t:
      iMax = max(iMax, abs((w.v[k] - w.vf) / w.rf + w.cf * slopeAt(w.t, w.v, t)))
  for j in 0 ..< waves.len:
    if waves[j].network:
      for x in series[j].iFix: iMax = max(iMax, abs(x))
  iMax = max(iMax, 1e-9)
  let ser = result
  for jw in 0 ..< waves.len:
    let w = waves[jw]
    if w.network:
      let (dv, di) = reconstructNetwork(cd, ser, w, ts, series[jw], tol.probe)
      result.residualV = max(result.residualV, dv)
      result.residualI = max(result.residualI, di)
      continue
    let ctot = w.cf + cd.cComp
    let lo = min(cd.rails.pulldown, cd.rails.gndClamp) - 2.0 * span
    let hi = max(cd.rails.pullup, cd.rails.powerClamp) + 2.0 * span
    proc kAt(t: float): tuple[ku, kd: float] =
      (valueAt(ser.t, ser.ku, t), valueAt(ser.t, ser.kd, t))
    var vrec = newSeq[float](ts.len)
    vrec[0] = valueAt(w.t, w.v, ts[0])
    if ctot == 0.0:
      for k, t in ts:
        let (ku, kd) = kAt(t)
        vrec[k] = solveScalar(proc(v: float): tuple[r, d: float] =
          let b = bufferCurrent(cd, ku, kd, v)
          (b.i - (v - w.vf) / w.rf, b.g - 1.0 / w.rf), vrec[max(k - 1, 0)], lo, hi)
    else:
      for k in 1 ..< ts.len:
        let h = ts[k] - ts[k - 1]
        let (ku0, kd0) = kAt(ts[k - 1])
        let (ku1, kd1) = kAt(ts[k])
        let vp = vrec[k - 1]
        let f0 = bufferCurrent(cd, ku0, kd0, vp).i - (vp - w.vf) / w.rf
        # Trapezoidal: C (v - vp) / h = (f0 + f1) / 2
        vrec[k] = solveScalar(proc(v: float): tuple[r, d: float] =
          let b = bufferCurrent(cd, ku1, kd1, v)
          let f1 = b.i - (v - w.vf) / w.rf
          (0.5 * (f0 + f1) - ctot * (v - vp) / h, 0.5 * (b.g - 1.0 / w.rf) - ctot / h),
          vp, lo, hi)
    for k, t in ts:
      let vt = valueAt(w.t, w.v, t)
      result.residualV = max(result.residualV, abs(vrec[k] - vt))
      let dvr = slopeAt(ts, vrec, t)
      let itab = (vt - w.vf) / w.rf + w.cf * slopeAt(w.t, w.v, t)
      let irec = (vrec[k] - w.vf) / w.rf + w.cf * dvr
      result.residualI = max(result.residualI, abs(irec - itab))
  result.available = result.residualV <= tol.residualVFrac * span and
                     result.residualI <= tol.residualIFrac * iMax
  var used: seq[string]
  for i in result.waveformsUsed: used.add "#" & $(i + 1)
  result.provenance = label & " " & used.join(",") & " " & cornerName(c)
  if not result.available:
    result.reason = label & " " & cornerName(c) & ": reconstruction residual " &
      formatFloat(result.residualV * 1e3, ffDecimal, 2) & " mV / " &
      formatFloat(result.residualI * 1e3, ffDecimal, 3) & " mA is past tolerance (" &
      formatFloat(tol.residualVFrac * span * 1e3, ffDecimal, 2) & " mV / " &
      formatFloat(tol.residualIFrac * iMax * 1e3, ffDecimal, 3) & " mA); edge unavailable for verdicts"
    issues.add newIssue("ibis_reconstruction_residual", sevWarning, result.reason)

# --- behaviours ------------------------------------------------------------

proc kssoCurve(tbl: IvTable, c: Corner, label: string, issues: var seq[Issue]): IvCurve =
  ## `Isso(Vtable) / Isso(0)` at corner `c` (an absent corner: typ).
  var vs, isv: seq[float]
  for p in tbl:
    let cc = if p.i.has(c): c else: coTyp
    if p.i.has(cc):
      vs.add p.v
      isv.add p.i.get(cc)
  if vs.len < 2: return
  var i0 = NaN
  for k in 0 ..< vs.len - 1:
    if vs[k] <= 0.0 and vs[k + 1] >= 0.0:
      i0 = isv[k] + (isv[k + 1] - isv[k]) * (0.0 - vs[k]) / (vs[k + 1] - vs[k])
  if i0.isNaN or abs(i0) < 1e-12:
    issues.add newIssue("ibis_isso_unusable", sevWarning,
      label & " has no non-zero current at Vtable = 0; not applied")
    return
  result.source = label & " " & cornerName(c)
  for k in 0 ..< vs.len:
    result.v.add vs[k]
    result.i.add isv[k] / i0

proc preDriverCurrent(m: IbisModel, edge: Edge, c: Corner, cd: CornerData,
                      k: KSeries): tuple[t, i: seq[float]] =
  ## `[Composite Current]` of the first plain R/V/C fixture that has one,
  ## minus the pullup and POWER clamp current the extracted edge draws
  ## through the power terminal into that fixture (the table's own pad
  ## voltage).
  if k.t.len == 0: return
  let ws = if edge == edRising: m.risingWaveforms else: m.fallingWaveforms
  for w in ws:
    if w.composite.len < 2 or w.points.len < 2: continue
    if w.lFixture != 0 or w.rDut != 0 or w.lDut != 0 or w.cDut != 0: continue
    if not w.points[0].v.has(c) or not w.composite[0].v.has(c): continue
    let t0 = w.points[0].t
    var tv, vv: seq[float]
    for p in w.points:
      if p.v.has(c):
        tv.add p.t - t0
        vv.add p.v.get(c)
    for p in w.composite:
      if not p.v.has(c): continue
      let t = p.t - t0
      let v = valueAt(tv, vv, t)
      let ku = valueAt(k.t, k.ku, t)
      let rail = ku * cd.pullup.eval(v).i + cd.powerClamp.eval(v).i
      result.t.add t
      result.i.add p.v.get(c) - rail
    return

proc driverBehaviour*(m: IbisModel, c = coTyp, tol = defaultTolerances(),
                      file = ""): DriverBehaviour =
  ## Everything an engine needs to drive from `m` at corner `c`. Never
  ## raises on model content: an unusable model comes back `supported =
  ## false` with the reason.
  result = DriverBehaviour(model: m.name, file: file, modelType: m.modelType,
                           corner: c, supported: true)
  let (ok, hasPu, hasPd, why) = driverKind(m)
  if not ok:
    result.supported = false
    result.reason = m.name & ": " & why
    return
  result.hasPullup = hasPu
  result.hasPulldown = hasPd
  let cd = resolveCorner(m, c)
  result.substitutions = cd.substitutions
  if hasPu and m.pullup.len == 0:
    result.supported = false
    result.reason = m.name & ": Model_type " & m.rawType & " has no [Pullup] table"
    return
  if hasPd and m.pulldown.len == 0:
    result.supported = false
    result.reason = m.name & ": Model_type " & m.rawType & " has no [Pulldown] table"
    return
  if cd.unsupported.len > 0:
    result.supported = false
    result.reason = m.name & " at " & cornerName(c) & ": " & cd.unsupported.join("; ")
    return
  result.rails = cd.rails
  result.pullup = cd.pullup
  result.pulldown = cd.pulldown
  result.gndClamp = cd.gndClamp
  result.powerClamp = cd.powerClamp
  result.cComp = cd.cComp
  result.timing = cd.timing
  result.thresholds = cd.thresholds
  for e in Edge:
    result.edges[e] = switchingCoefficients(m, e, c, cd, hasPu, hasPd, tol,
                                            result.issues, result.assumptions)
  result.kssoPu = kssoCurve(m.issoPu, c, m.name & " [ISSO PU]", result.issues)
  result.kssoPd = kssoCurve(m.issoPd, c, m.name & " [ISSO PD]", result.issues)
  for e in Edge:
    if result.edges[e].available and result.edges[e].source == ksWaveforms:
      result.preDriver[e] = preDriverCurrent(m, e, c, cd, result.edges[e])

proc receiverBehaviour*(m: IbisModel, c = coTyp, file = ""): ReceiverBehaviour =
  ## Clamps + `C_comp` + thresholds at corner `c`.
  result = ReceiverBehaviour(model: m.name, file: file, modelType: m.modelType,
                             corner: c, supported: true)
  let (ok, why) = receiverKind(m)
  if not ok:
    result.supported = false
    result.reason = m.name & ": " & why
    return
  let cd = resolveCorner(m, c)
  result.substitutions = cd.substitutions
  if cd.unsupported.len > 0:
    result.supported = false
    result.reason = m.name & " at " & cornerName(c) & ": " & cd.unsupported.join("; ")
    return
  result.rails = cd.rails
  result.gndClamp = cd.gndClamp
  result.powerClamp = cd.powerClamp
  result.cComp = cd.cComp
  result.thresholds = cd.thresholds
  result.overshoot = cd.overshoot

proc receiverCurrent*(r: ReceiverBehaviour, v: float): tuple[i, g: float] =
  ## Out-of-die clamp current (no `C_comp`). A receiver has no stimulus, so
  ## this is the whole of its static behaviour.
  let gc = r.gndClamp.eval(v)
  let pc = r.powerClamp.eval(v)
  (gc.i + pc.i, gc.g + pc.g)

proc bufferCurrent*(d: DriverBehaviour, ku, kd, v: float): tuple[i, g: float] =
  ## Out-of-die driver current excluding `C_comp`: every table once.
  let pu = d.pullup.eval(v)
  let pd = d.pulldown.eval(v)
  let gc = d.gndClamp.eval(v)
  let pc = d.powerClamp.eval(v)
  (ku * pu.i + kd * pd.i + gc.i + pc.i, ku * pu.g + kd * pd.g + gc.g + pc.g)

proc riseTime*(k: KSeries): float =
  ## The 10-90 % duration of the coefficient transition: the fastest edge
  ## the engine's time step must resolve.
  let s = if abs(k.ku[^1] - k.ku[0]) >= abs(k.kd[^1] - k.kd[0]): k.ku else: k.kd
  let a = s[0]
  let b = s[^1]
  if a == b or k.t.len < 2: return k.t[^1] - k.t[0]
  proc cross(level: float): float =
    for i in 0 ..< s.len - 1:
      let lo = min(s[i], s[i + 1])
      let hi = max(s[i], s[i + 1])
      if level >= lo and level <= hi and s[i] != s[i + 1]:
        return k.t[i] + (level - s[i]) / (s[i + 1] - s[i]) * (k.t[i + 1] - k.t[i])
    NaN
  let t10 = cross(a + 0.1 * (b - a))
  let t90 = cross(a + 0.9 * (b - a))
  if t10.isNaN or t90.isNaN: return k.t[^1] - k.t[0]
  max(t90 - t10, 0.0)
