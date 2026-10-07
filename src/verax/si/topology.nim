## `SiNet`: the engine-agnostic graph of one signal-integrity net -- a driver
## (behaviour + die node), receivers, and elements (lumped R/L/C, ideal line
## `(Z0, td)`, lossy line `(RLGC/m, length)`). Data, not a `Netlist`.
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

import std/[tables, strutils, math, algorithm]
import ../ibis/types
import ../ibis/behave
import ../ibis/attach
import ../pcb/impedance
import ../pcb/via
import ../netlist/annotations

export behave

type
  SiElemKind* = enum
    sekResistor, sekInductor, sekCapacitor, sekLine, sekLossyLine,
    sekVoltage   ## ideal DC source, `v(a) - v(b) = value`

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

  PackageRlc* = object
    r*, l*, c*: float
    source*: string

  SiPort* = object
    label*: string
      ## `"U1.7"`.
    dieNode*, pinNode*: int
    pkg*: PackageRlc

  SiNet* = object
    name*: string
    nodes*: seq[string]
      ## Node names; index 0 is ground.
    elements*: seq[SiElement]
    driver*: DriverBehaviour
    driverPort*: SiPort
    receivers*: seq[ReceiverBehaviour]
    receiverPorts*: seq[SiPort]
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
  var pe: PinEntry
  try:
    pe = comp.pin(p.pin)
  except IbisError:
    result.reason = $p & ": IBIS [Component] " & comp.name & " has no pin " & p.pin
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
  let (okPkg, rlc, why) = packageFor(comp, p.pin, corner)
  if not okPkg:
    result.reason = $p & ": " & why
    return
  result.pkg = rlc
  result.ok = true

# --- ports -----------------------------------------------------------------

proc addPort(n: var SiNet, label: string, pkg: PackageRlc, pin = -1): SiPort =
  ## die -- R_pkg -- L_pkg -- pin, C_pkg at the pin. `pin` reuses an
  ## existing board node as the pin.
  result = SiPort(label: label, pkg: pkg)
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

proc addReceiver*(n: var SiNet, label: string, r: ReceiverBehaviour,
                  pkg: PackageRlc, pin = -1): int =
  ## Returns the receiver's pin node (`pin` if given).
  n.receivers.add r
  let p = n.addPort(label, pkg, pin)
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
    layer*, reference*: string

  TemplateTopology* = enum
    ttPointToPoint, ttDaisyChain, ttStar

  TemplatePort* = object
    label*: string
    pkg*: PackageRlc

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

proc templateParams*(length: float, viaCount = 0, seriesR = 0.0,
                     stubLength = 0.0, parallelR = 0.0, parallelV = 0.0,
                     viaStub = NaN): TemplateParams =
  ## Constructor; a `NaN` `viaStub` keeps the via model's stub.
  TemplateParams(length: length, viaCount: viaCount, seriesR: seriesR,
                 stubLength: stubLength, parallelR: parallelR,
                 parallelV: parallelV, viaStub: viaStub,
                 hasViaStub: not viaStub.isNaN)

proc lineSection*(spec: LineSpec, lossy = false, fKnee = 1e9,
                  layer = "", reference = ""): LineSection =
  ## Characterise a cross-section with `pcb/impedance` (closed form).
  result = LineSection(z0: z0(spec), tdPerM: delayPerMetre(spec), lossy: lossy,
                       layer: layer, reference: reference)
  if lossy:
    let q = rlgc(spec, fKnee)
    result.r = q.r; result.l = q.l; result.g = q.g; result.c = q.c

proc idealLine*(z0, tdPerM: float): LineSection =
  LineSection(z0: z0, tdPerM: tdPerM)

proc addRun(n: var SiNet, a: int, s: LineSection, length: float, label: string): int =
  ## A line from `a` of `length`; returns the far node (`a` itself if 0).
  if length <= 0.0: return a
  let b = n.addNode(label)
  if s.lossy:
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
