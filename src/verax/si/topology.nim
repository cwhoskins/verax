## `SiNet`: the engine-agnostic graph of one signal-integrity net -- a driver
## (behaviour + die node), receivers, and elements (lumped R/L/C, ideal line
## `(Z0, td)`, lossy line `(RLGC/m, length)`, coupled pair `(Ze, Zo, td_e,
## td_o)`). Data, not a `Netlist`.
##
## **More than one conductor** (stage 8): `driver` is the net the stimulus
## drives (conductor 0). `extraDrivers` are other conductors' drivers, each
## with a `DriveMode`: the complement of the stimulus (a differential
## pair's other leg) or held quiet (a crosstalk victim). Every port names
## its `conductor`; `diffReceivers` pairs two receivers read as one
## differential input.
##
## Built from a **template** (pre-layout, parametric: driver -> series R ->
## trunk with `n` vias -> receivers) for constraint derivation and tests;
## the board builder (from a `RouteTree`) comes after the forward path is
## validated (plan stage 6).
##
## The IBIS package is `die -- R_pkg -- L_pkg -- pin` with `C_pkg` from the
## pin to ground, `C_comp` on the die (a verax convention, recorded as an
## `Assumption`: IBIS 3.2 gives the values, not the topology).
##
## **Pin -> behaviour mapping.** A pin goes through its designator's
## `IbisBinding`. A `[Model Selector]` name needs an explicit choice per
## designator. `POWER`/`GND`/`NC`, an unbound designator, a missing choice or
## an unsupported model all make the net unsupported (`esNotEvaluable`),
## naming the pin -- never a guess.

import std/[tables, strutils, math, algorithm, options]
export options
import ../ibis/types
import ../ibis/behave
import ../ibis/attach
import ../pcb/impedance
import ../pcb/via
import ../touchstone/types as tstypes
import ../netlist/annotations

export behave

type
  SiElemKind* = enum
    sekResistor, sekInductor, sekCapacitor, sekLine, sekLossyLine,
    sekVoltage   ## ideal DC source, `v(a) - v(b) = value`
    sekCoupledLine
      ## Symmetric lossless coupled pair: conductor 1 `a -> b`, conductor 2
      ## `a2 -> b2`.
    sekSParams
      ## A Touchstone 2-port, port 1 at `a`, port 2 at `b`.

  SiElement* = object
    kind*: SiElemKind
    a*, b*: int
      ## Node indices; `0` is ground. A line's two ends, both referenced to
      ## ground.
    label*: string
    value*: float
      ## R ohms, L henries, C farads, source volts.
    z0*, td*: float
      ## Ideal line.
    r*, l*, g*, c*, length*: float
      ## Lossy line, per metre, and its length.
    spec*: LineSpec
      ## The cross-section, when `hasSpec`: a convolution line then uses its
      ## frequency-dependent (causal) RLGC; the ladder always uses `r/l/g/c`.
    hasSpec*: bool
    fRef*: float
      ## Where `r/l/g/c` were taken, Hz (`hasSpec` only).
    a2*, b2*: int
      ## Coupled line: the second conductor's ends.
    zEven*, zOdd*, tdEven*, tdOdd*: float
      ## Coupled line: each mode's impedance (one line, ohms) and delay.
    sparams*: SParams
      ## S-parameter block.

  PackageRlc* = object
    r*, l*, c*: float
    source*: string

  SiPort* = object
    label*: string
      ## `"U1.7"`.
    dieNode*, pinNode*: int
    pkg*: PackageRlc
    conductor*: int
      ## Which conductor (index into `SiNet.conductorNames`; 0 = the driven
      ## net).

  DriveMode* = enum
    dmStimulus    ## the stimulus itself (the primary driver)
    dmInverted    ## its complement: the other leg of a differential pair
    dmQuietLow    ## held low: a crosstalk victim
    dmQuietHigh   ## held high

  SiExtraDriver* = object
    behaviour*: DriverBehaviour
    port*: SiPort
    mode*: DriveMode
    skew*: float
      ## Seconds added to the stimulus delay (`[Diff Pin]` `tdelay`).

  SiSupply* = object
    ## Power-aware: the die's own rails, which every driver hangs from.
    ## `SiNet.supply` is `none` when the rails are ideal.
    vccDie*, gndDie*: int

  DiffReceiver* = object
    ## Two receivers read as one differential input `v(p) - v(n)`.
    label*: string
    p*, n*: int
      ## Indices into `receivers`.
    vdiff*: Option[float]
      ## Differential threshold, volts: switched at `+vdiff`/`-vdiff`;
      ## `none` when nothing states one.
    source*: string
      ## Where `vdiff` came from.

  SiNet* = object
    name*: string
    nodes*: seq[string]
      ## Node names; index 0 is ground.
    elements*: seq[SiElement]
    driver*: DriverBehaviour
    driverPort*: SiPort
    receivers*: seq[ReceiverBehaviour]
    receiverPorts*: seq[SiPort]
    extraDrivers*: seq[SiExtraDriver]
    conductorNames*: seq[string]
      ## Empty: one conductor, the net itself.
    diffReceivers*: seq[DiffReceiver]
    supply*: Option[SiSupply]
    unsupported*: seq[string]
      ## Non-empty: this net cannot be simulated (`esNotEvaluable`); each is
      ## the precise limitation.
    assumptions*: seq[Assumption]
    issues*: seq[Issue]

  PinRef* = object
    designator*, pin*: string

  ResolvedPin* = object
    pin*: PinRef
    ok*: bool
    reason*: string
    model*: IbisModel
    file*: string
    pkg*: PackageRlc

proc `$`*(p: PinRef): string = p.designator & "." & p.pin

proc newSiNet*(name: string): SiNet =
  SiNet(name: name, nodes: @["0"])

proc addNode*(n: var SiNet, name: string): int =
  n.nodes.add name
  n.nodes.high

proc addResistor*(n: var SiNet, a, b: int, r: float, label = "") =
  n.elements.add SiElement(kind: sekResistor, a: a, b: b, value: r, label: label)

proc addInductor*(n: var SiNet, a, b: int, l: float, label = "") =
  n.elements.add SiElement(kind: sekInductor, a: a, b: b, value: l, label: label)

proc addCapacitor*(n: var SiNet, a, b: int, c: float, label = "") =
  n.elements.add SiElement(kind: sekCapacitor, a: a, b: b, value: c, label: label)

proc addSource*(n: var SiNet, a, b: int, v: float, label = "") =
  n.elements.add SiElement(kind: sekVoltage, a: a, b: b, value: v, label: label)

proc addLine*(n: var SiNet, a, b: int, z0, td: float, label = "") =
  n.elements.add SiElement(kind: sekLine, a: a, b: b, z0: z0, td: td, label: label)

proc addLossyLine*(n: var SiNet, a, b: int, r, l, g, c, length: float, label = "") =
  n.elements.add SiElement(kind: sekLossyLine, a: a, b: b, r: r, l: l, g: g,
                           c: c, length: length, label: label)

proc addLossyLine*(n: var SiNet, a, b: int, spec: LineSpec, fRef, length: float,
                   label = "") =
  ## A lossy line that keeps its cross-section: `r/l/g/c` at `fRef` for the
  ## ladder, the frequency-dependent RLGC for a convolution line.
  let q = rlgc(spec, fRef)
  n.elements.add SiElement(kind: sekLossyLine, a: a, b: b, r: q.r, l: q.l, g: q.g,
                           c: q.c, length: length, label: label, spec: spec,
                           hasSpec: true, fRef: fRef)

proc addCoupledLine*(n: var SiNet, a1, b1, a2, b2: int, zEven, zOdd, tdEven, tdOdd: float,
                     label = "") =
  n.elements.add SiElement(kind: sekCoupledLine, a: a1, b: b1, a2: a2, b2: b2,
                           zEven: zEven, zOdd: zOdd, tdEven: tdEven, tdOdd: tdOdd,
                           label: label)

proc addSParams*(n: var SiNet, a, b: int, sp: SParams, label = "") =
  n.elements.add SiElement(kind: sekSParams, a: a, b: b, sparams: sp, label: label)

proc conductorCount*(n: SiNet): int = max(1, n.conductorNames.len)

proc conductorMode*(n: SiNet, conductor: int): DriveMode =
  ## How a conductor is driven (`dmStimulus` for conductor 0, or a
  ## conductor without a driver of its own).
  for d in n.extraDrivers:
    if d.port.conductor == conductor: return d.mode
  dmStimulus

# --- pins -------------------------------------------------------------------

proc packageFor*(comp: IbisComponent, pinName: string, c: Corner): tuple[ok: bool, rlc: PackageRlc, why: string] =
  ## Per-pin `[Pin]` columns override `[Package]` (IBIS [Package] Other
  ## Notes). Per-pin values are single values: they apply at every corner.
  let pe = comp.pin(pinName)
  var rlc = PackageRlc(source: comp.name & " pin " & pinName)
  proc pick(present: bool, pinV: float, pkg: Triplet, name: string,
            dst: var float): string =
    if present: dst = pinV; return ""
    if pkg.has(c): dst = pkg.get(c); return ""
    name & " has no " & cornerName(c) & " value for pin " & pinName
  var whys: seq[string]
  for w in [pick(prR in pe.present, pe.rPin, comp.pkg.rPkg, "R_pkg", rlc.r),
            pick(prL in pe.present, pe.lPin, comp.pkg.lPkg, "L_pkg", rlc.l),
            pick(prC in pe.present, pe.cPin, comp.pkg.cPkg, "C_pkg", rlc.c)]:
    if w.len > 0: whys.add w
  if whys.len > 0: return (false, rlc, whys.join("; "))
  (true, rlc, "")

proc resolvePin*(bindings: openArray[IbisBinding], p: PinRef,
                 selections: Table[string, string] = initTable[string, string](),
                 corner = coTyp): ResolvedPin =
  ## Which `[Model]` drives/receives on `p`. `selections` maps a designator
  ## to its `[Model Selector]` choice.
  result.pin = p
  var found = -1
  for i, b in bindings:
    if b.designator == p.designator: found = i
  if found < 0:
    result.reason = $p & ": no IBIS binding for " & p.designator
    return
  let b = bindings[found]
  result.file = b.file.fileName
  let comp = b.file.component(b.componentName)
  let ip = b.ibisPin(p.pin)
  var pe: PinEntry
  try:
    pe = comp.pin(ip)
  except IbisError:
    result.reason = $p & ": IBIS [Component] " & comp.name & " has no pin " & p.pin &
      " (by pin name or signal_name)"
    return
  if pe.model.toUpperAscii in ["POWER", "GND", "NC"]:
    result.reason = $p & " is " & pe.model & " in IBIS, not a buffer"
    return
  var modelName = pe.model
  if not b.file.hasModel(modelName):
    var sel = -1
    for i, s in b.file.modelSelectors:
      if cmpIgnoreCase(s.name, modelName) == 0: sel = i
    if sel < 0:
      result.reason = $p & ": [Pin] model '" & modelName & "' is neither a [Model] nor a [Model Selector]"
      return
    if not selections.hasKey(p.designator):
      result.reason = $p & ": [Model Selector] '" & modelName &
        "' needs a choice for " & p.designator
      return
    let choice = selections[p.designator]
    var okChoice = false
    for ch in b.file.modelSelectors[sel].choices:
      if cmpIgnoreCase(ch.model, choice) == 0: okChoice = true
    if not okChoice:
      result.reason = $p & ": '" & choice & "' is not a choice of [Model Selector] '" & modelName & "'"
      return
    modelName = choice
  if not b.file.hasModel(modelName):
    result.reason = $p & ": no [Model] named '" & modelName & "'"
    return
  result.model = b.file.model(modelName)
  let (okPkg, rlc, why) = packageFor(comp, ip, corner)
  if not okPkg:
    result.reason = $p & ": " & why
    return
  result.pkg = rlc
  result.ok = true

type
  DiffPartner* = object
    ## A pin's `[Diff Pin]` row, read from its side.
    ok*: bool
    reason*: string
    other*: PinRef
      ## The other leg.
    inverting*: bool
      ## `other` is the row's `inv_pin` (so the queried pin is the
      ## non-inverting one).
    vdiff*: Option[float]
    tdelay*: float
      ## The inverting leg's delay after the non-inverting one, at the
      ## corner (`0` when not stated).
    source*: string

proc diffPartner*(bindings: openArray[IbisBinding], p: PinRef, corner = coTyp): DiffPartner =
  ## The other leg of `p`'s differential pair, from its component's `[Diff
  ## Pin]`. Not a pair (no row) is a named reason, never a guess.
  for b in bindings:
    if b.designator != p.designator: continue
    let comp = b.file.component(b.componentName)
    let ip = b.ibisPin(p.pin)
    for dp in comp.diffPins:
      if dp.pin != ip and dp.invPin != ip: continue
      let noninv = dp.pin == ip
      result = DiffPartner(ok: true, inverting: noninv,
                           other: PinRef(designator: p.designator,
                                         pin: b.netlistPin(if noninv: dp.invPin else: dp.pin)),
                           source: comp.name & " [Diff Pin] " & dp.pin & "/" & dp.invPin)
      if dp.vdiff.present:
        result.vdiff = some(dp.vdiff.value)
      let td = case corner
               of coTyp: dp.tdelayTyp
               of coMin: (if dp.tdelayMin.present: dp.tdelayMin else: dp.tdelayTyp)
               of coMax: (if dp.tdelayMax.present: dp.tdelayMax else: dp.tdelayTyp)
      if td.present: result.tdelay = td.value
      return
    result.reason = $p & ": IBIS [Component] " & comp.name & " has no [Diff Pin] row for pin " & p.pin
    return
  result.reason = $p & ": no IBIS binding for " & p.designator

# --- ports -----------------------------------------------------------------

proc addPort(n: var SiNet, label: string, pkg: PackageRlc, pin = -1,
             conductor = 0): SiPort =
  ## die -- R_pkg -- L_pkg -- pin, C_pkg at the pin. `pin` reuses an
  ## existing board node as the pin.
  result = SiPort(label: label, pkg: pkg, conductor: conductor)
  result.dieNode = n.addNode(label & ":die")
  let mid = n.addNode(label & ":pkg")
  result.pinNode = if pin >= 0: pin else: n.addNode(label & ":pin")
  n.addResistor(result.dieNode, mid, pkg.r, label & " R_pkg")
  n.addInductor(mid, result.pinNode, pkg.l, label & " L_pkg")
  if pkg.c > 0: n.addCapacitor(result.pinNode, 0, pkg.c, label & " C_pkg")

proc setDriver*(n: var SiNet, label: string, d: DriverBehaviour, pkg: PackageRlc) =
  n.driver = d
  n.driverPort = n.addPort(label, pkg)
  if not d.supported: n.unsupported.add label & ": " & d.reason
  n.issues.add d.issues
  n.assumptions.add d.assumptions
  n.assumptions.add d.substitutions

proc addExtraDriver*(n: var SiNet, label: string, d: DriverBehaviour, pkg: PackageRlc,
                     conductor: int, mode: DriveMode, skew = 0.0, pin = -1): int =
  ## Another conductor's driver; returns its pin node (`pin` if given).
  let p = n.addPort(label, pkg, pin, conductor)
  n.extraDrivers.add SiExtraDriver(behaviour: d, port: p, mode: mode, skew: skew)
  if not d.supported: n.unsupported.add label & ": " & d.reason
  n.issues.add d.issues
  n.assumptions.add d.substitutions
  p.pinNode

proc addReceiver*(n: var SiNet, label: string, r: ReceiverBehaviour,
                  pkg: PackageRlc, pin = -1, conductor = 0): int =
  ## Returns the receiver's pin node (`pin` if given).
  n.receivers.add r
  let p = n.addPort(label, pkg, pin, conductor)
  n.receiverPorts.add p
  if not r.supported: n.unsupported.add label & ": " & r.reason
  n.issues.add r.issues
  n.assumptions.add r.substitutions
  p.pinNode

proc packageAssumption*(): Assumption =
  note("IBIS package", "modelled as die - R_pkg - L_pkg - pin with C_pkg at the pin")

# --- templates -------------------------------------------------------------

type
  LineSection* = object
    ## A trace on one layer, characterised.
    z0*, tdPerM*: float
    lossy*: bool
    r*, l*, g*, c*: float
      ## Per metre, at the knee frequency (lossy only).
    spec*: LineSpec
    hasSpec*: bool
      ## The cross-section is kept (from `lineSection`), so a convolution
      ## line can use its frequency dependence.
    fKnee*: float
    layer*, reference*: string

  TemplateTopology* = enum
    ttPointToPoint, ttDaisyChain, ttStar

  TemplatePort* = object
    label*: string
    pkg*: PackageRlc

  PartnerRole* = enum
    prNone
    prVictim     ## a quiet neighbour: crosstalk at its ends
    prDiffPair   ## the complementary leg: the net is a differential pair

  TemplatePartner* = object
    ## A second conductor beside the template's trunk (point-to-point only).
    ## It copies the trunk's termination; over the coupled section the two
    ## are a coupled pair of `coupled`'s cross-section (gap `s`, or
    ## `TemplateParams.spacing`), elsewhere each is `SiTemplate.line`.
    role*: PartnerRole
    name*: string
      ## The partner net's name.
    quietHigh*: bool
      ## A victim held high (else low).
    driver*: DriverBehaviour
    driverPort*: TemplatePort
    receiver*: ReceiverBehaviour
    receiverPort*: TemplatePort
    coupled*: LineSpec
      ## An edge-coupled geometry.
    skew*: float
      ## The partner driver's delay after the stimulus (`[Diff Pin]`
      ## `tdelay`), seconds.
    vdiff*: Option[float]
    vdiffSource*: string

  SiTemplate* = object
    ## A parametric net. The free parameters are `TemplateParams`.
    name*: string
    driver*: DriverBehaviour
    driverPort*: TemplatePort
    receivers*: seq[ReceiverBehaviour]
    receiverPorts*: seq[TemplatePort]
    topology*: TemplateTopology
    line*: LineSection
    via*: ViaModel
      ## Used when `viaCount > 0`.
    hasVia*: bool
    partner*: TemplatePartner
    channel*: SParams
      ## A Touchstone 2-port (connector, cable, backplane) between the
      ## trunk and the receiver, when `hasChannel` (point-to-point).
    hasChannel*: bool
    channelName*: string

  TemplateParams* = object
    length*: float
      ## Trunk length, metres (star: the shared trunk).
    viaCount*: int
    seriesR*: float
      ## Source termination at the driver pin, ohms; `0` = none.
    stubLength*: float
      ## Daisy-chain stub per receiver, or star branch length, metres.
    parallelR*: float
      ## Far-end termination to `parallelV` at the last receiver; `0` = none.
    parallelV*: float
    viaStub*: float
      ## The via's bottom stub, metres, when `hasViaStub` (a backdrill or
      ## stub-removal question); otherwise the via model's own.
    hasViaStub*: bool
    spacing*: float
      ## Edge-to-edge gap to the partner, metres, when `hasSpacing`;
      ## otherwise the partner cross-section's own `s`.
    hasSpacing*: bool
    coupledLength*: float
      ## How much of the trunk runs beside a victim, from the driver end,
      ## metres (a differential pair is coupled throughout).
    diffR*: float
      ## Differential pair: a termination across the receiver pins, ohms;
      ## `0` = none.
    legMismatch*: float
      ## Differential pair: extra length on the partner leg (an uncoupled
      ## run before its receiver), metres -- intra-pair skew.

proc templateParams*(length: float, viaCount = 0, seriesR = 0.0,
                     stubLength = 0.0, parallelR = 0.0, parallelV = 0.0,
                     viaStub = NaN, spacing = NaN, coupledLength = 0.0,
                     diffR = 0.0, legMismatch = 0.0): TemplateParams =
  ## Constructor; a `NaN` `viaStub` keeps the via model's stub, a `NaN`
  ## `spacing` the partner cross-section's gap.
  TemplateParams(length: length, viaCount: viaCount, seriesR: seriesR,
                 stubLength: stubLength, parallelR: parallelR,
                 parallelV: parallelV, viaStub: viaStub,
                 hasViaStub: not viaStub.isNaN, spacing: spacing,
                 hasSpacing: not spacing.isNaN, coupledLength: coupledLength,
                 diffR: diffR, legMismatch: legMismatch)

proc withSpacing*(p: TemplateParams, s: float): TemplateParams =
  result = p
  result.spacing = s
  result.hasSpacing = true

proc lineSection*(spec: LineSpec, lossy = false, fKnee = 1e9,
                  layer = "", reference = ""): LineSection =
  ## Characterise a cross-section with `pcb/impedance` (closed form).
  result = LineSection(z0: z0(spec), tdPerM: delayPerMetre(spec), lossy: lossy,
                       layer: layer, reference: reference)
  if lossy:
    let q = rlgc(spec, fKnee)
    result.r = q.r; result.l = q.l; result.g = q.g; result.c = q.c
    result.spec = spec
    result.hasSpec = true
    result.fKnee = fKnee

proc idealLine*(z0, tdPerM: float): LineSection =
  LineSection(z0: z0, tdPerM: tdPerM)

proc addRun(n: var SiNet, a: int, s: LineSection, length: float, label: string): int =
  ## A line from `a` of `length`; returns the far node (`a` itself if 0).
  if length <= 0.0: return a
  let b = n.addNode(label)
  if s.lossy and s.hasSpec:
    n.addLossyLine(a, b, s.spec, s.fKnee, length, label)
  elif s.lossy:
    n.addLossyLine(a, b, s.r, s.l, s.g, s.c, length, label)
  else:
    n.addLine(a, b, s.z0, s.tdPerM * length, label)
  b

proc addVia(n: var SiNet, a: int, v: ViaModel, label: string): int =
  ## pi: C/2 -- L -- C/2, with open stubs at the shallow and deep ends.
  let b = n.addNode(label & ":out")
  if v.usedC > 0:
    n.addCapacitor(a, 0, v.usedC / 2, label & " C/2")
    n.addCapacitor(b, 0, v.usedC / 2, label & " C/2")
  n.addInductor(a, b, v.usedL, label & " L")
  if v.stubTop > 0:
    let o = n.addNode(label & ":stub_top")
    n.addLine(a, o, v.stubZ0, v.stubTdPerM * v.stubTop, label & " top stub")
  if v.stubBottom > 0:
    let o = n.addNode(label & ":stub_bottom")
    n.addLine(b, o, v.stubZ0, v.stubTdPerM * v.stubBottom, label & " bottom stub")
  b

const SpeedOfLightSi = 299_792_458.0

proc coupledAssumption*(m: CoupledModes, spec: LineSpec): Assumption =
  note("coupled section", "lossless, quasi-static even/odd modes (" &
    (if spec.geometry == lgEdgeCoupledStripline: "Cohn, scaled to the IPC-2141 single line"
     else: "Kirschning-Jansen") & "): Ze " & formatFloat(m.zEven, ffDecimal, 2) &
    " ohm, Zo " & formatFloat(m.zOdd, ffDecimal, 2) & " ohm, eps_e " &
    formatFloat(m.epsEven, ffDecimal, 3) & ", eps_o " & formatFloat(m.epsOdd, ffDecimal, 3))

proc buildPair(t: SiTemplate, p: TemplateParams, n: var SiNet) =
  ## Point-to-point trunk and its partner, coupled over the first
  ## `coupledLength` (a differential pair: all of it).
  let pt = t.partner
  if t.topology != ttPointToPoint:
    n.unsupported.add "a coupled partner needs a point-to-point template"
    return
  if p.viaCount > 0:
    n.unsupported.add "vias on a coupled pair are not modelled"
    return
  if pt.coupled.geometry notin {lgEdgeCoupledMicrostrip, lgEdgeCoupledStripline}:
    n.unsupported.add "partner cross-section is not an edge-coupled geometry"
    return
  n.conductorNames = @[t.name, pt.name]
  let lc = if pt.role == prDiffPair: p.length else: clamp(p.coupledLength, 0.0, p.length)
  var a1 = n.driverPort.pinNode
  var a2 = n.addExtraDriver(pt.driverPort.label, pt.driver, pt.driverPort.pkg, 1,
                            (case pt.role
                             of prDiffPair: dmInverted
                             else: (if pt.quietHigh: dmQuietHigh else: dmQuietLow)),
                            pt.skew)
  if p.seriesR > 0:
    let r1 = n.addNode("rs")
    n.addResistor(a1, r1, p.seriesR, "series R")
    let r2 = n.addNode(pt.name & ":rs")
    n.addResistor(a2, r2, p.seriesR, pt.name & " series R")
    a1 = r1
    a2 = r2
  if lc > 0:
    var spec = pt.coupled
    if p.hasSpacing: spec.s = p.spacing
    let m = coupledModes(spec)
    let b1 = n.addNode("coupled")
    let b2 = n.addNode(pt.name & ":coupled")
    n.addCoupledLine(a1, b1, a2, b2, m.zEven, m.zOdd,
                     lc * sqrt(m.epsEven) / SpeedOfLightSi,
                     lc * sqrt(m.epsOdd) / SpeedOfLightSi, "coupled section")
    n.assumptions.add coupledAssumption(m, spec)
    if not m.inRange:
      n.issues.add newIssue("si_coupled_range", sevWarning,
        "coupled cross-section (w/h " & formatFloat(spec.w / spec.h1, ffDecimal, 2) &
        ", s/h " & formatFloat(spec.s / spec.h1, ffDecimal, 2) &
        ") is outside the closed form's validated range; extrapolated")
    a1 = b1
    a2 = b2
  a1 = n.addRun(a1, t.line, p.length - lc, "trunk")
  a2 = n.addRun(a2, t.line, p.length - lc + max(p.legMismatch, 0.0), pt.name & ":trunk")
  discard n.addReceiver(t.receiverPorts[0].label, t.receivers[0], t.receiverPorts[0].pkg, a1)
  discard n.addReceiver(pt.receiverPort.label, pt.receiver, pt.receiverPort.pkg, a2, 1)
  if pt.role == prDiffPair and p.diffR > 0:
    n.addResistor(n.receiverPorts[0].pinNode, n.receiverPorts[1].pinNode, p.diffR,
                  "differential termination")
  if pt.role == prDiffPair:
    n.diffReceivers.add DiffReceiver(label: t.receiverPorts[0].label & "/" & pt.receiverPort.label,
                                     p: 0, n: 1, vdiff: pt.vdiff,
                                     source: pt.vdiffSource)
  if p.parallelR > 0:
    for (pin, tag) in [(n.receiverPorts[0].pinNode, ""), (n.receiverPorts[1].pinNode, pt.name & ":")]:
      let vt = n.addNode(tag & "vtt")
      n.addResistor(pin, vt, p.parallelR, tag & "parallel termination")
      n.addSource(vt, 0, p.parallelV, tag & "termination supply")

proc build*(t: SiTemplate, p: TemplateParams): SiNet =
  ## One instance of the template.
  result = newSiNet(t.name)
  result.setDriver(t.driverPort.label, t.driver, t.driverPort.pkg)
  result.assumptions.add packageAssumption()
  if t.topology == ttPointToPoint and t.receivers.len != 1:
    result.unsupported.add "point-to-point template needs exactly one receiver"
    return
  if t.receivers.len == 0:
    result.unsupported.add "no receivers"
    return
  if t.hasChannel and (t.topology != ttPointToPoint or t.channel.nPorts != 2):
    result.unsupported.add "an S-parameter channel needs a point-to-point template and a 2-port file"
    return
  if t.partner.role != prNone:
    t.buildPair(p, result)
    return
  if p.viaCount > 0:
    if not t.hasVia:
      result.unsupported.add "template has no via geometry but viaCount = " & $p.viaCount
      return
    if t.via.referenceChange:
      result.unsupported.add "via changes return reference (not modelled)"
      result.issues.add t.via.issues
      return
    result.assumptions.add t.via.assumptions
  var node = result.driverPort.pinNode
  if p.seriesR > 0:
    let n2 = result.addNode("rs")
    result.addResistor(node, n2, p.seriesR, "series R")
    node = n2
  # Events along the trunk: vias and (daisy chain) taps, by position.
  type Ev = tuple[pos: float, isVia: bool, rx: int]
  var evs: seq[Ev]
  for i in 1 .. p.viaCount:
    evs.add (p.length * i.float / (p.viaCount + 1).float, true, -1)
  case t.topology
  of ttPointToPoint, ttStar:
    evs.add (p.length, false, -1)
  of ttDaisyChain:
    let nrx = t.receivers.len
    for k in 0 ..< nrx:
      evs.add (p.length * (k + 1).float / nrx.float, false, k)
  evs.sort(proc(a, b: Ev): int =
    result = cmp(a.pos, b.pos)
    if result == 0: result = cmp(ord(b.isVia), ord(a.isVia)))
  var pos = 0.0
  var seg = 0
  var vi = 0
  for ev in evs:
    node = result.addRun(node, t.line, ev.pos - pos, "trunk" & $seg)
    inc seg
    pos = ev.pos
    if ev.isVia:
      inc vi
      var v = t.via
      if p.hasViaStub: v.stubBottom = p.viaStub
      node = result.addVia(node, v, "via" & $vi)
    elif ev.rx >= 0:
      let tap = node
      let end2 = result.addRun(tap, t.line, p.stubLength, "stub" & $ev.rx)
      discard result.addReceiver(t.receiverPorts[ev.rx].label, t.receivers[ev.rx],
                                 t.receiverPorts[ev.rx].pkg, end2)
  case t.topology
  of ttPointToPoint:
    if t.hasChannel:
      let o = result.addNode("channel:out")
      result.addSParams(node, o, t.channel, (if t.channelName.len > 0: t.channelName else: "channel"))
      node = o
    discard result.addReceiver(t.receiverPorts[0].label, t.receivers[0],
                               t.receiverPorts[0].pkg, node)
  of ttStar:
    for k in 0 ..< t.receivers.len:
      let e = result.addRun(node, t.line, p.stubLength, "branch" & $k)
      discard result.addReceiver(t.receiverPorts[k].label, t.receivers[k],
                                 t.receiverPorts[k].pkg, e)
  of ttDaisyChain: discard
  if p.parallelR > 0:
    let last = result.receiverPorts[^1].pinNode
    let vt = result.addNode("vtt")
    result.addResistor(last, vt, p.parallelR, "parallel termination")
    result.addSource(vt, 0, p.parallelV, "termination supply")
