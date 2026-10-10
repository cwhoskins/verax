## The board builder (decision 8): one SI net from a routed board. The net's
## `RouteTree` (rooted at the driver pin) becomes one line element per
## `RouteSection`, characterised by `pcb/tline.specFor` + `pcb/impedance`;
## every via node becomes the `pcb/via` closed-form model; each pin's IBIS
## `[Pin]`/`[Package]` RLC becomes its port.
##
## **Never optimistic.** Each of these makes the net unsupported
## (`esNotEvaluable`), naming the place: a section with no resolved return
## path or a `NaN` Z0, a reference change between sections or across a via,
## a via whose geometry the stack-up cannot place, a copper pour on the
## route, a loop, a pin on the net that is neither the driver nor a declared
## receiver (a passive on an SI net is not modelled yet), and a declared
## receiver the route never reaches.

import std/[tables, sets, strutils, math, algorithm]
import ../pcb/types
import ../pcb/units
import ../pcb/geometry
import ../pcb/graph as pgraph
import ../pcb/trace
import ../pcb/tline
import ../pcb/via
import ../ibis/attach
import ../ibis/types as ibtypes
import ../netlist/graph
import ./topology
import ../netlist/annotations

type
  BoardNetSpec* = object
    net*: string
    driver*: PinRef
    receivers*: seq[PinRef]
    corner*: ibtypes.Corner
    lossy*: bool
      ## Lossy lines per section instead of ideal ones: a ladder at `fKnee`,
      ## or recursive convolution over frequency (`SiOptions.lossyModel`).
    fKnee*: float
    tol*: ExtractTolerances

proc boardNetSpec*(net: string, driver: PinRef, receivers: seq[PinRef],
                   corner = ibtypes.coTyp): BoardNetSpec =
  BoardNetSpec(net: net, driver: driver, receivers: receivers, corner: corner,
               fKnee: 1e9, tol: defaultTolerances())

proc boardPin(pcb: Pcb, p: PinRef): Pin =
  let c = pcb.netlist.findComponent(p.designator)
  if c == nil or not c.pins.hasKey(p.pin): return nil
  c.pins[p.pin]

proc distTo(p: Point, b: Box): float =
  ## Point-to-box distance, nanometres as float.
  let dx = max(0.0, max(b.lo.x.raw.float - p.x.raw.float, p.x.raw.float - b.hi.x.raw.float))
  let dy = max(0.0, max(b.lo.y.raw.float - p.y.raw.float, p.y.raw.float - b.hi.y.raw.float))
  sqrt(dx * dx + dy * dy)

proc sectionDist(p: Point, s: RouteSection): float =
  result = Inf
  for c in s.copper: result = min(result, distTo(p, c.box))

proc orderedSections(e: RouteEdge): seq[RouteSection] =
  ## Sections from `e.a` to `e.b`. A tree edge flipped by `rootedAt` keeps
  ## its sections in extraction order, so order them by which end sits
  ## nearer `e.a`.
  result = e.sections
  if result.len > 1 and sectionDist(e.a.at, result[^1]) < sectionDist(e.a.at, result[0]):
    result.reverse()

proc refName(s: RouteSection): string =
  if s.reference.layer == nil: "" else: s.reference.layer.name

proc buildFromBoard*(pcb: Pcb, spec: BoardNetSpec, bindings: openArray[IbisBinding],
                     selections = initTable[string, string]()): SiNet =
  result = newSiNet(spec.net)
  result.assumptions.add packageAssumption()
  result.assumptions.add note("net " & spec.net,
    "board lines are closed-form quasi-static (pcb/impedance); vias closed-form (pcb/via)")
  if not pcb.netlist.nets.hasKey(spec.net):
    result.unsupported.add "the board has no net '" & spec.net & "'"
    return
  let net = pcb.netlist.nets[spec.net]
  # Behaviours.
  let dr = resolvePin(bindings, spec.driver, selections, spec.corner)
  if not dr.ok:
    result.unsupported.add dr.reason
    return
  var rxs: seq[ResolvedPin]
  for r in spec.receivers:
    let rp = resolvePin(bindings, r, selections, spec.corner)
    if not rp.ok:
      result.unsupported.add rp.reason
      return
    rxs.add rp
  let drvPin = boardPin(pcb, spec.driver)
  if drvPin == nil:
    result.unsupported.add "the board has no pin " & $spec.driver
    return
  let tree = traceTree(pcb, net, drvPin)
  result.issues.add tree.issues
  if tree.root == nil:
    result.unsupported.add "net '" & spec.net & "' has no route from " & $spec.driver
    return
  if tree.extra.len > 0:
    result.unsupported.add "net '" & spec.net & "' route has a loop (" & $tree.extra.len &
      " closing edge(s)); loops are not modelled"
    return
  result.setDriver($spec.driver, driverBehaviour(dr.model, spec.corner, spec.tol, dr.file), dr.pkg)
  # Receivers by board pin.
  var rxIndex = initTable[uint, int]()
  for k, r in spec.receivers:
    let bp = boardPin(pcb, r)
    if bp == nil:
      result.unsupported.add "the board has no pin " & $r
      return
    rxIndex[cast[uint](bp)] = k
  var reached = initHashSet[int]()
  # Walk the tree from the root.
  var children = initTable[uint, seq[RouteEdge]]()
  for e in tree.edges:
    children.mgetOrPut(cast[uint](e.a), @[]).add e
  let t = defaultTlineSpec()
  type Work = tuple[rn: RouteNode, node: int, arriving: RouteSection, hasArriving: bool]
  var stack: seq[Work] = @[(tree.root, result.driverPort.pinNode, RouteSection(), false)]
  var seg = 0
  while stack.len > 0:
    let (rn, node, arriving, hasArr) = stack.pop()
    # The node itself.
    case rn.kind
    of rnPour:
      result.unsupported.add "net '" & spec.net & "' runs into a copper pour; pours are not modelled"
      return
    of rnPin:
      if rn.pin != nil and rn != tree.root:
        let key = cast[uint](rn.pin)
        if not rxIndex.hasKey(key):
          let who = (if rn.pin.component != nil: rn.pin.component.designator & "." else: "") & rn.pin.name
          result.unsupported.add "pin " & who & " is on net '" & spec.net &
            "' but is neither the driver nor a declared receiver (passives on an SI net are not modelled)"
          return
        let k = rxIndex[key]
        reached.incl k
        let b = receiverBehaviour(rxs[k].model, spec.corner, rxs[k].file)
        discard result.addReceiver($spec.receivers[k], b, rxs[k].pkg, node)
    else: discard
    for e in children.getOrDefault(cast[uint](rn)):
      var cur = node
      var prevRef = if hasArr: refName(arriving) else: ""
      var havePrev = hasArr
      # A via between the arriving section and this edge's first.
      let secs = orderedSections(e)
      if rn.kind == rnVia and rn.hole != nil and hasArr and secs.len > 0:
        let exitSec = secs[0]
        let (g, notes, vissues) = viaGeometryFor(pcb, rn.hole, arriving.layer, exitSec.layer,
                                                 refName(arriving), refName(exitSec))
        result.assumptions.add notes
        result.issues.add vissues
        if g.barrelLength.isNaN or g.padDia.isNaN:
          result.unsupported.add "via at the " & arriving.layer.name & " -> " &
            exitSec.layer.name & " transition: geometry unknown (" &
            (if vissues.len > 0: vissues[0].message else: "no pad") & ")"
          return
        let vm = viaModel(g)
        if vm.referenceChange:
          result.issues.add vm.issues
          result.unsupported.add vm.issues[0].message
          return
        result.assumptions.add vm.assumptions
        let o = result.addNode("via" & $seg & ":out")
        if vm.usedC > 0:
          result.addCapacitor(cur, 0, vm.usedC / 2, "via C/2")
          result.addCapacitor(o, 0, vm.usedC / 2, "via C/2")
        result.addInductor(cur, o, vm.usedL, "via L")
        if vm.stubTop > 0:
          let s = result.addNode("via" & $seg & ":stub_top")
          result.addLine(cur, s, vm.stubZ0, vm.stubTdPerM * vm.stubTop, "via top stub")
        if vm.stubBottom > 0:
          let s = result.addNode("via" & $seg & ":stub_bottom")
          result.addLine(o, s, vm.stubZ0, vm.stubTdPerM * vm.stubBottom, "via bottom stub")
        cur = o
        prevRef = refName(exitSec)
        havePrev = true
      var last = RouteSection()
      for s in secs:
        if s.reference.layer == nil:
          result.unsupported.add "section on " & (if s.layer != nil: s.layer.name else: "?") &
            " of net '" & spec.net & "' has no resolved return path"
          return
        if s.reference.coverage < 0.9 or s.reference.gaps.len > 0:
          result.unsupported.add "section on " & s.layer.name & " of net '" & spec.net &
            "': return plane " & s.reference.layer.name & " covers only " &
            formatFloat(s.reference.coverage * 100, ffDecimal, 1) & " % of it (gaps are not modelled)"
          return
        if havePrev and refName(s) != prevRef:
          result.unsupported.add "net '" & spec.net & "' changes reference from '" & prevRef &
            "' to '" & refName(s) & "'; the return transition is not modelled"
          return
        let ls = specFor(pcb, s, t)
        let z = z0(ls)
        let tdpm = delayPerMetre(ls)
        if z.isNaN or tdpm.isNaN:
          result.unsupported.add "section on " & s.layer.name & " has no computable Z0"
          return
        inc seg
        let nn = result.addNode("sec" & $seg)
        if spec.lossy:
          result.addLossyLine(cur, nn, ls, spec.fKnee, s.length, s.layer.name & " section")
        else:
          result.addLine(cur, nn, z, tdpm * s.length, s.layer.name & " section")
        cur = nn
        prevRef = refName(s)
        havePrev = true
        last = s
      stack.add (e.b, cur, last, last.layer != nil)
  for k, r in spec.receivers:
    if k notin reached:
      result.unsupported.add "receiver " & $r & " is not reached by net '" & spec.net & "' route"
  # Every other pin with copper on this net must be on the route.
  var onTree = initHashSet[uint]()
  for rn in tree.nodes:
    if rn.pin != nil: onTree.incl cast[uint](rn.pin)
  for p in net.pins:
    if cast[uint](p) in onTree or p.component == nil: continue
    let pl = pgraph.placementOf(pcb, p.component)
    if pl == nil or not pl.lands.hasKey(p.name): continue
    if cast[uint](p) in rxIndex or p == drvPin:
      continue   # already reported as unreached above
    result.unsupported.add "pin " & p.component.designator & "." & p.name & " on net '" &
      spec.net & "' is not reached by its copper (unrouted)"
