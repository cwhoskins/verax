## Repeated-subsheet grouping: a read-only index built once per layout, after
## the bundle plan and before any symbol is sized.
##
## When one subcircuit is instantiated three or more times in a netlist,
## drawing each instance as its own fallback box gives the reader no help
## seeing that they are one sheet built N times, and no help telling a net
## shared across every instance from one that differs per instance. This unit
## groups such instances so the collapse (`state.prepare` drops the N-1
## non-representative members) and its scene decoration can happen.
##
## The plan is a pure function of the netlist and the bundle plan. It reads
## `Component.subNetlist` identity and the instance pins' parent nets
## (`Pin.net`); it never mutates. `recoverRouting`'s candidate part moves never
## rebuild it. A zero-value `ArrayPlan` (no subsheet has >= 3 instances) is the
## whole byte-identity guarantee: every downstream code path is guarded on a
## non-empty plan.
##
## Precedence with `bundles.nim`: **the bundle wins at the pin, the array wins
## at the box.** An array declines to collapse only when a member carries a
## `brCollapsed` bundle (whose far endpoint would vanish); a `brNetLabel` /
## `brScalar` bundle degrades cleanly over hidden members, so the array still
## collapses and that port is marked `bundled` -- classified for the report but
## drawn entirely by the bundle plan.

type
  ArrayPortClass = enum
    apCommon       ## every member binds the identical `Net` object
    apDistributed  ## N distinct non-nil `Net` objects, one per member
    apChained      ## paired with another port: out(i) == in(i+1), a linear
                   ## and complete chain through every member
    apIrregular    ## anything else: repeats, gaps, a nil binding

  ArrayPort = object
    name: string               ## the instance pin name == child port key,
                               ## identical on every member by construction
    cls: ArrayPortClass
    dir: PortDirection         ## folded member direction (chained: in/out)
    nets: seq[string]          ## member order; "" for an unbound member
    bundled: bool              ## a bundle owns this port's drawing
    display: string            ## scene/occupancy tag; "" for apCommon and
                               ## for a bundled port
    tag: string                ## drawn text: "" / "cs[1:3]" / "3*9"
    open: bool                 ## apIrregular: some member's net is nil
    distinctNets: int          ## apIrregular: distinct non-nil net count
    partner: int               ## apChained: index of the paired port; -1
    isOut: bool                ## apChained: this half is the OUT side
    head, tail: string         ## apChained: the two escaping nets
    links: seq[string]         ## apChained OUT half: N-1 link nets, chain order
    chainKey: string           ## apChained OUT half: the member walk order,
                               ## so parallel chains (a strapped SPI bus) share
                               ## one drawn arc
    chainLead: int             ## apChained OUT half: the port index whose arc
                               ## this chain draws under (== self for the
                               ## lead); -1 otherwise

  SubsheetArray = object
    key: string                ## "<subNetlist.name>\x1f<pin-key join>\x1f<sub>"
    members: seq[string]       ## designators, graph insertion order
    rep: string                ## members[0] -- the one drawn box
    label: string              ## "X1..X8"
    ports: seq[ArrayPort]      ## one per subsheet port, pin order

  ArrayPlan = object
    arrays: seq[SubsheetArray]
    byRep: Table[string, int]              ## representative designator -> array
    hidden: HashSet[string]                ## the N-1 designators prepare drops
    portOfPin: Table[string, tuple[a, p: int]]  ## pinKey(rep, pin) -> port
    suppressed: HashSet[string]            ## nets that must not route at all
                                           ## (chain links; distributed members
                                           ## after the first)
    groupOf: Table[string, tuple[a, p: int]]  ## distributed member net -> port
    extraPins: Table[string, seq[tuple[desig, pin: string]]]  ## chain head/tail
                                           ## re-homed onto the representative
    arrayNets: HashSet[string]             ## what finish skips in the net-name
                                           ## pass (drawn group members + tags)

proc isOpenBind(x: Net): bool {.inline.} =
  ## An instance pin that binds nothing, or an explicit no-connect
  ## (`instantiateByPortOpen`'s `nc_<inst>_<port>` net) -- both read as "this
  ## member leaves the port open" for array classification.
  x == nil or x.attrs.getOrDefault("iface.nc") == "1"

proc netNameOf(x: Net): string {.inline.} =
  (if x != nil and not isOpenBind(x): x.name else: "")

proc arrayPlan(nl: Netlist, bundles: BundlePlan): ArrayPlan =
  ## One pass over `nl.components` in insertion order. Returns a zero-value
  ## plan the moment no subsheet has three or more instances.
  var plan: ArrayPlan

  # 1. Signature grouping. `graph.instantiate` creates one pin per child port
  #    in declaration order, so instances of one template share this key and
  #    two different templates with a colliding `.SUBCKT` name do not.
  var sigOrder: seq[string]
  var sigMembers = initTable[string, seq[string]]()
  for _, c in nl.components:
    if c.subNetlist == nil or c.subNetlist.name.len == 0: continue
    var keys: seq[string]
    var clean = true
    for pn, p in c.pins:
      if p.hierNet == nil:
        clean = false
        break
      keys.add pn
    if not clean or keys.len == 0: continue
    let sig = c.subNetlist.name & "\x1f" & keys.join("\x1f")
    if sig notin sigMembers:
      sigOrder.add sig
      sigMembers[sig] = @[]
    sigMembers[sig].add c.designator

  var anyBig = false
  for s in sigOrder:
    if sigMembers[s].len >= 3: anyBig = true
  if not anyBig: return

  # A `brCollapsed` bundle is a point-to-point wire between exactly two
  # entities; hiding one deletes its far end. That is the only decline.
  var inCollapsedBundle = initHashSet[string]()
  for b in bundles.bundles:
    if b.role == brCollapsed:
      for d in b.parts: inCollapsedBundle.incl d

  var usedDisplays = initHashSet[string]()
  for b in bundles.bundles: usedDisplays.incl b.display
  proc uniqueDisplay(natural: string): string =
    proc free(s: string): bool = not nl.nets.hasKey(s) and s notin usedDisplays
    var cand = natural
    if not free(cand):
      cand = natural & "_arr"
      var i = 2
      while not free(cand):
        cand = natural & "_arr_" & $i
        inc i
    usedDisplays.incl cand
    cand

  proc foldDir(objs: seq[Net]): PortDirection =
    var seen: set[PortDirection]
    for x in objs:
      let d = portDirection(x)
      if d != pdUnspecified: seen.incl d
    if card(seen) == 1:
      for d in seen: return d
      pdUnspecified
    elif card(seen) == 0: pdUnspecified
    else: pdBidir

  proc nameDir(portName: string): PortDirection =
    ## The author's most explicit direction cue: a `_out`/`out` or `_in`/`in`
    ## suffix on the port name. Used as the chain-pairing tiebreaker when the
    ## child pin kinds do not distinguish the two halves -- a pass-through
    ## strap (`sclk_in`/`sclk_out` on one internal net) is exactly that case.
    let s = portName.toLowerAscii()
    if s.endsWith("_out") or s == "out" or s.endsWith("outp") or s.endsWith("_o"):
      pdOutput
    elif s.endsWith("_in") or s == "in" or s.endsWith("_i"):
      pdInput
    else: pdUnspecified

  proc hierDir(c: Component, portName: string): PortDirection =
    ## The subsheet port's *authored* direction: fold the pin kinds inside the
    ## child on the matching port net. Positional instances leave the instance
    ## pin `ptUnknown`, so this is the only reliable signal for chain pairing.
    if portName notin c.pins or c.pins[portName].hierNet == nil:
      return pdUnspecified
    var sawIn, sawOut, sawIo = false
    for hp in c.pins[portName].hierNet.pins:
      case hp.kind
      of ptOutput: sawOut = true
      of ptInput: sawIn = true
      of ptInOut: sawIo = true
      else: discard
    if sawIo or (sawIn and sawOut): pdBidir
    elif sawOut: pdOutput
    elif sawIn: pdInput
    else: pdUnspecified

  for sig in sigOrder:
    let members = sigMembers[sig]
    let n = members.len
    if n < 3: continue
    block signatureBody:
      for d in members:
        if d in inCollapsedBundle: break signatureBody

      let rep0 = nl.components[members[0]]
      var portNames: seq[string]
      for pn, _ in rep0.pins: portNames.add pn

      # binding[portIdx][memberIdx] -> the parent Net that member binds
      var binding = newSeq[seq[Net]](portNames.len)
      for pi, pn in portNames:
        binding[pi] = newSeq[Net](n)
        for mi, d in members:
          binding[pi][mi] = nl.components[d].pins[pn].net

      # 4. Sub-grouping: split members by every *splitting* port -- one whose
      #    nets partition the members into 2+ groups each of size >= 2, with no
      #    member left open. A singleton group is a member that differs from
      #    everyone: the irregular signal, not a sub-array boundary, so a port
      #    that produces one is left to classification instead.
      var subOf = newSeq[int](n)
      var nsub = 1
      for pi in 0 ..< portNames.len:
        var counts = initTable[string, int]()
        var anyNil = false
        for mi in 0 ..< n:
          let nm = netNameOf(binding[pi][mi])
          if nm.len == 0: anyNil = true
          else: counts[nm] = counts.getOrDefault(nm, 0) + 1
        if anyNil or counts.len < 2 or counts.len >= n: continue
        var evenGroups = true
        for _, cnt in counts:
          if cnt < 2: evenGroups = false
        if not evenGroups: continue
        var refined = initTable[string, int]()
        var newSub = newSeq[int](n)
        var nn = 0
        for mi in 0 ..< n:
          let k = $subOf[mi] & "\x1f" & netNameOf(binding[pi][mi])
          if k notin refined:
            refined[k] = nn
            inc nn
          newSub[mi] = refined[k]
        subOf = newSub
        nsub = nn

      var groups = newSeq[seq[int]](nsub)
      for mi in 0 ..< n: groups[subOf[mi]].add mi

      for gi, g in groups:
        if g.len < 3: continue
        var sub = SubsheetArray(key: sig & "\x1f" & $gi)
        for mi in g: sub.members.add members[mi]
        sub.rep = sub.members[0]
        sub.label = sub.members[0] & ".." & sub.members[^1]

        # 5. Per-port classification over this sub-group.
        for pi, pn in portNames:
          var ap = ArrayPort(name: pn, partner: -1)
          var objs: seq[Net]
          var anyNil = false
          for mi in g:
            let x = binding[pi][mi]
            ap.nets.add netNameOf(x)
            if isOpenBind(x): anyNil = true
            else: objs.add x
          var rail = false
          for x in objs:
            if isGroundHere(x) or isRailHere(x): rail = true
          for nm in ap.nets:
            if nm.len > 0 and bundles.ofNet.hasKey(nm): ap.bundled = true
          var allSame = objs.len == g.len
          for x in objs:
            if x != objs[0]: allSame = false
          var distinctSet = initHashSet[string]()
          for nm in ap.nets:
            if nm.len > 0: distinctSet.incl nm
          if allSame:
            ap.cls = apCommon
          elif rail:
            ap.cls = apIrregular
            ap.distinctNets = distinctSet.len
            ap.open = anyNil
          elif distinctSet.len == g.len and not anyNil:
            ap.cls = apDistributed
          else:
            ap.cls = apIrregular
            ap.distinctNets = distinctSet.len
            ap.open = anyNil
          let nd = nameDir(pn)
          ap.dir =
            if nd != pdUnspecified: nd
            elif hierDir(rep0, pn) != pdUnspecified: hierDir(rep0, pn)
            else: foldDir(objs)
          sub.ports.add ap

        # 6. Chain pairing over non-bundled distributed candidates, first
        #    success wins.
        proc tryChain(a, b: int): bool =
          let na = sub.ports[a].nets   # OUT nets, sub-group order
          let nb = sub.ports[b].nets   # IN nets
          if na.len != g.len or nb.len != g.len: return false
          var producer = initTable[string, int]()
          var consumer = initTable[string, int]()
          for i in 0 ..< g.len:
            if na[i].len == 0 or nb[i].len == 0: return false
            if na[i] in producer or nb[i] in consumer: return false
            producer[na[i]] = i
            consumer[nb[i]] = i
          var head = -1
          for i in 0 ..< g.len:
            if nb[i] notin producer:
              if head >= 0: return false
              head = i
          if head < 0: return false
          var visited = initHashSet[int]()
          var cur = head
          var links: seq[string]
          var walk: seq[string]
          for step in 0 ..< g.len:
            if cur in visited: return false
            visited.incl cur
            walk.add members[g[cur]]
            if step == g.len - 1: break
            let outNet = na[cur]
            if outNet notin consumer: return false
            links.add outNet
            cur = consumer[outNet]
          if visited.card != g.len: return false
          let tailNet = na[cur]
          if tailNet in consumer: return false
          let headNet = nb[head]
          if headNet == tailNet or headNet in links or tailNet in links:
            return false
          for lnk in links:
            let net = nl.nets.getOrDefault(lnk, nil)
            if net == nil or net.pins.len != 2: return false
            for p in net.pins:
              if p.component == nil or
                 p.component.designator notin sub.members: return false
          sub.ports[a].cls = apChained
          sub.ports[b].cls = apChained
          sub.ports[a].isOut = true
          sub.ports[a].partner = b
          sub.ports[b].partner = a
          sub.ports[a].links = links
          sub.ports[a].chainKey = walk.join("\x1f")
          sub.ports[a].chainLead = a
          sub.ports[a].head = headNet
          sub.ports[a].tail = tailNet
          sub.ports[b].head = headNet
          sub.ports[b].tail = tailNet
          return true

        for a in 0 ..< sub.ports.len:
          if sub.ports[a].cls != apDistributed or sub.ports[a].bundled: continue
          if sub.ports[a].dir == pdInput: continue     # a is the OUT candidate
          for b in 0 ..< sub.ports.len:
            if b == a: continue
            if sub.ports[b].cls != apDistributed or sub.ports[b].bundled: continue
            if sub.ports[b].dir == pdOutput: continue   # b is the IN candidate
            if tryChain(a, b): break

        # Parallel chains (a pass-through-strapped SPI bus: sclk, cs and data
        # all walking the same members in the same order) draw as ONE arc, so
        # the box does not sprout three near-identical loops. The first OUT
        # half of each `chainKey` group leads; the rest point at it.
        var chainLead = initTable[string, int]()
        for pi in 0 ..< sub.ports.len:
          if sub.ports[pi].cls != apChained or not sub.ports[pi].isOut: continue
          let k = sub.ports[pi].chainKey
          if k notin chainLead: chainLead[k] = pi
          sub.ports[pi].chainLead = chainLead[k]

        # 7. Displays, tags, and the bridges.
        for pi in 0 ..< sub.ports.len:
          case sub.ports[pi].cls
          of apDistributed:
            if sub.ports[pi].bundled: continue
            sub.ports[pi].display = uniqueDisplay(sub.ports[pi].name)
            sub.ports[pi].tag = sub.ports[pi].name & "[1:" & $g.len & "]"
          of apChained:
            if sub.ports[pi].isOut:
              sub.ports[pi].dir = pdOutput
              if sub.ports[pi].chainLead == pi:      # the arc's lead only
                sub.ports[pi].display =
                  uniqueDisplay(sub.ports[pi].name & "_chain")
            else:
              sub.ports[pi].dir = pdInput
          else: discard
        # Non-lead parallel chains borrow the lead's display.
        for pi in 0 ..< sub.ports.len:
          if sub.ports[pi].cls == apChained and sub.ports[pi].isOut and
             sub.ports[pi].chainLead != pi:
            sub.ports[pi].display = sub.ports[sub.ports[pi].chainLead].display

        let arrIdx = plan.arrays.len
        plan.byRep[sub.rep] = arrIdx
        for mi in 1 ..< sub.members.len: plan.hidden.incl sub.members[mi]
        let repC = nl.components[sub.rep]
        for pi in 0 ..< sub.ports.len:
          let ap = sub.ports[pi]
          plan.portOfPin[pinKey(repC, ap.name)] = (arrIdx, pi)
          case ap.cls
          of apDistributed:
            if ap.bundled: continue
            for k, nm in ap.nets:
              if nm.len == 0: continue
              plan.groupOf[nm] = (arrIdx, pi)
              plan.arrayNets.incl nm
              if k > 0: plan.suppressed.incl nm
            plan.arrayNets.incl ap.display
          of apChained:
            if ap.isOut:
              for lnk in ap.links:
                plan.suppressed.incl lnk
                plan.arrayNets.incl lnk
              plan.arrayNets.incl ap.display
              plan.extraPins.mgetOrPut(ap.head, @[]).add (sub.rep,
                sub.ports[ap.partner].name)
              plan.extraPins.mgetOrPut(ap.tail, @[]).add (sub.rep, ap.name)
          else: discard

        plan.arrays.add sub

  # 9. Totality: every distinct net named by a hidden member's pin must be
  #    accounted for -- suppressed, drawn by a group, still on the
  #    representative's own pin (common / irregular / chain head-tail), or on
  #    an irregular port. A net every pin of which is on a hidden member and
  #    is in none of these would vanish with no marker.
  var repNets = initHashSet[string]()
  var irregularNets = initHashSet[string]()
  for a in plan.arrays:
    let repC = nl.components[a.rep]
    for _, p in repC.pins:
      if p.net != nil: repNets.incl p.net.name
    for ap in a.ports:
      if ap.cls == apIrregular:
        for nm in ap.nets:
          if nm.len > 0: irregularNets.incl nm
      if ap.cls == apChained:
        if ap.head.len > 0: repNets.incl ap.head
        if ap.tail.len > 0: repNets.incl ap.tail
  for a in plan.arrays:
    for mi in 1 ..< a.members.len:
      for _, p in nl.components[a.members[mi]].pins:
        if p.net == nil or isOpenBind(p.net): continue
        let nm = p.net.name
        doAssert nm in plan.suppressed or plan.groupOf.hasKey(nm) or
                 nm in repNets or nm in irregularNets or bundles.ofNet.hasKey(nm),
          "schematic arrays: net \"" & nm & "\" on hidden member " &
          a.members[mi] & " is in no port class"

  result = plan

# --- plain-data bridges (consumed by state.prepare / symbols / routing) -----

proc arrayLabelFor(plan: ArrayPlan, c: Component): string {.inline.} =
  ## The drawn box label for `c` ("X1..X8"), or "" for every non-representative.
  if plan.byRep.hasKey(c.designator): plan.arrays[plan.byRep[c.designator]].label
  else: ""

proc arrayLanesFor(plan: ArrayPlan, c: Component):
    tuple[names: seq[string], side: seq[int]] =
  ## Reserved for a future need. The chain arc anchors directly on the box
  ## edge beside its own IN/OUT pins now -- a dashed annotation, exempt from
  ## the routed-wire separation invariants -- so no lane is drawn and the box
  ## keeps its historical size.
  discard

proc arrayTitleWidth(plan: ArrayPlan, c: Component): float {.inline.} =
  ## The width `boxSlots` must reserve at the box top for "X1..X8" at the left
  ## and the "xN" badge at the right. 0.0 for every other part -- the one
  ## default that keeps the historical sizing bit-for-bit.
  if not plan.byRep.hasKey(c.designator): return 0.0
  let a = plan.arrays[plan.byRep[c.designator]]
  float(a.label.len + 4 + ($a.members.len).len) * 7.2 + 24.0

proc arrayPinFor(plan: ArrayPlan, c: Component, pinName: string):
    tuple[found: bool, mark: PinMark, tag, net: string,
          members: seq[BundleMember]] =
  ## Scene decoration for one representative pin. `net` is the name the drawn
  ## pin carries: the head/tail net for the two halves of a chain, the group
  ## `display` for a distributed pin, "" (unchanged) otherwise. `members` is
  ## one entry per array member, `name` the member *designator* and `net` its
  ## binding on this port.
  if not plan.portOfPin.hasKey(pinKey(c, pinName)): return
  let (ai, pi) = plan.portOfPin[pinKey(c, pinName)]
  let a = plan.arrays[ai]
  let ap = a.ports[pi]
  result.found = true
  for k, d in a.members:
    result.members.add BundleMember(name: d, net: ap.nets[k])
  case ap.cls
  of apCommon:
    if not ap.bundled: result.mark = pmBusBar
  of apDistributed:
    if not ap.bundled:
      result.mark = pmBusSlash
      result.tag = ap.tag
      result.net = ap.display
  of apChained:
    result.net = (if ap.isOut: ap.tail else: ap.head)
  of apIrregular:
    if not ap.bundled:
      result.mark = pmForkCap
      var nOpen = 0
      for nm in ap.nets:
        if nm.len == 0: inc nOpen
      result.tag = $ap.distinctNets & "*" & $a.members.len &
        (if nOpen > 0: " open" else: "")

proc arrayRouteFor(plan: ArrayPlan, netName: string):
    tuple[skip: bool, group: bool, tag: string, members: seq[string],
          first: bool] =
  ## The routing decision for one `nl.nets` entry. `skip` for a suppressed net
  ## (a chain link, a distributed member after the first). `group` marks a
  ## distributed member net that routes as the one drawn bus; `first` is true
  ## only for the member that actually routes.
  if netName in plan.suppressed:
    return (skip: true, group: false, tag: "", members: @[], first: false)
  if plan.groupOf.hasKey(netName):
    let (ai, pi) = plan.groupOf[netName]
    let ap = plan.arrays[ai].ports[pi]
    var mem: seq[string]
    for nm in ap.nets:
      if nm.len > 0: mem.add nm
    return (skip: false, group: true, tag: ap.display, members: mem,
            first: netName == mem[0])
  (skip: false, group: false, tag: "", members: @[], first: false)

# --- public reporter -------------------------------------------------------

proc arrayReport*(nl: Netlist): seq[tuple[subsheet, label, rep: string,
                                    count: int, members, ports: seq[string]]] =
  ## Every collapsed subsheet array, so "does `sclk_out` chain?" is a one-line
  ## unit test instead of an inference from geometry. A netlist with fewer than
  ## three instances of any one subsheet yields an empty report. Builds the
  ## bundle plan itself, so the report is exactly what `prepare` computes.
  ##
  ## Each `ports` entry renders as `"<port>=<class>[<detail>]"`:
  ##   "vdd=common"                  "vdd=common(bundled)"
  ##   "wp=distributed[1:6]"         "sclk=common(bundled)"
  ##   "sclk_out=chained(out,x7)"    "sclk_in=chained(in)"
  ##   "trig=irregular(3*6)"         "nc=irregular(2*6,open=4)"
  let bundles = bundlePlan(nl)
  let plan = arrayPlan(nl, bundles)
  for a in plan.arrays:
    var ports: seq[string]
    for ap in a.ports:
      let suffix = if ap.bundled: "(bundled)" else: ""
      case ap.cls
      of apCommon:
        ports.add ap.name & "=common" & suffix
      of apDistributed:
        ports.add ap.name & "=distributed[1:" & $a.members.len & "]" & suffix
      of apChained:
        if ap.isOut:
          ports.add ap.name & "=chained(out,x" & $ap.links.len & ")"
        else:
          ports.add ap.name & "=chained(in)"
      of apIrregular:
        var nOpen = 0
        for nm in ap.nets:
          if nm.len == 0: inc nOpen
        let detail = $ap.distinctNets & "*" & $a.members.len &
          (if nOpen > 0: ",open=" & $nOpen else: "")
        ports.add ap.name & "=irregular(" & detail & ")" & suffix
    let subName = a.key.split("\x1f")[0]
    result.add (subsheet: subName, label: a.label, rep: a.rep,
                count: a.members.len, members: a.members, ports: ports)
