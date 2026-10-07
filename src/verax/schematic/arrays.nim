## Repeated-part grouping: a read-only index built once per layout, after
## the bundle plan and before any symbol is sized.
##
## `buildSubsheetArrays` groups a subcircuit instantiated three or more
## times; `buildComponentArrays` groups repeated raw components. Component
## grouping is **per component, not per motif**: an 8x(R+C) bank draws as
## one `R x8` and one `C x8`, so each part stays individually identifiable.
## Both build `PartArray`s through `classifyGroup` (sub-grouping, port
## classes, chain pairing, display/tag allocation); they differ only in
## candidacy and the all-common decline.
##
## **The collapse floor is three members**, with two exceptions at two (both
## in `addSignatureArrays`): a parallel bank whose shared nets are a
## rail/ground pair, and a group with an `apDistributed` port whose varying
## nets belong to one declared bus or interface (`mergedByBundle` -- e.g. a
## diff pair's per-leg termination). Two same-valued parts wired any other
## way (a divider's `R1`/`R2`) must not merge.
##
## The plan is a pure function of the netlist and bundle plan and never
## mutates; `recoverRouting` never rebuilds it. An empty `ArrayPlan` is the
## byte-identity guarantee: every downstream path is guarded on it.
##
## Precedence with `bundles.nim`: **the bundle wins at the pin, the array
## wins at the box.** An array declines only when a member carries a
## `brCollapsed` bundle (its far endpoint would vanish); over a
## `brNetLabel`/`brScalar` bundle the array collapses and the port is marked
## `bundled`, drawn by the bundle plan.
##
## **Component identity key**:
## `kind \x1f value \x1f partNumber \x1f description \x1f name \x1f <pin names> \x1f <pin kinds>`.
## `value` is in it because the collapsed symbol shows one value; other attrs
## (`package`, `dielectric`, ...) are not, since they don't change the
## drawing. **A component with neither `value` nor `partNumber` is never a
## candidate** -- a blank value asserts nothing about the parts it stands for,
## and unvalued topology fixtures would otherwise collapse into phantom arrays.
##
## **The all-common decline**: a component group must have an
## `apDistributed` port, or be all `apCommon` with every shared net a
## rail/ground (`railCommon` -- a bypass bank). Any other all-common group is
## left to `composites/passive.parallelStackKind`, which shows its members.
##
## **Chain pairing is skipped for a non-box representative**: the
## recirculation arc is drawn on the box interior, which a resistor symbol
## lacks, so a series ladder of raw components degrades to distributed.
##
## **A net distributed at both ends** (`R_i`'s port 2 and `C_i`'s port 1
## both on `mid_i`): two arrays may enumerate members in different orders, so
## per-array `suppressed` writes could suppress every member and the bus
## never routes. `finalizeArrayPlan` therefore derives `suppressed` from the
## final `groupOf`, keeping the first member in `nl.nets` order.
##
## **A distributed port's members must belong to one declared bus or
## interface**, not merely be N distinct nets: `splitKeyOf` reads
## `iface.instance`, then `bus.name`, then the net name, so switches bound to
## `rin[0..3]` and `rout[0..3]` split into two `x4` groups. The same family
## name is what a bundled distributed pin draws once collapsed
## (`ArrayPort.bundleFamily`): the box stands for the bus ("rin"), not the
## representative's own member ("rin_0").

type
  ArrayOrigin = enum
    aoSubsheet     ## a subcircuit instantiated three or more times
    aoComponent    ## a raw component repeated, sharing the identity key

  ArrayPortClass = enum
    apCommon       ## every member binds the identical `Net` object
    apDistributed  ## N distinct non-nil `Net` objects, one per member
    apChained      ## paired: out(i) == in(i+1), complete through every member
    apIrregular    ## anything else: repeats, gaps, a nil binding

  ArrayPort = object
    name: string               ## instance pin name == child port key
    cls: ArrayPortClass
    dir: PortDirection         ## folded member direction (chained: in/out)
    nets: seq[string]          ## member order; "" for an unbound member
    bundled: bool              ## nets belong to a bus/interface bundle
                               ## (reporting only; see `mergedByBundle`)
    mergedByBundle: bool       ## apDistributed only: the bundle draws this
                               ## port -- it merges a pin here (`brCollapsed`,
                               ## or a `LabelGroup` with >= 2 members), or
                               ## merges one anywhere (`mixedMergeBundle`).
                               ## A `bundled` port merged nowhere on its bundle
                               ## is routed by the array, reusing the bundle's
                               ## occupancy tag so every side agrees on one wire.
    display: string            ## scene/occupancy tag; "" for apCommon. For a
                               ## bundled, non-merged port, the bundle's own
                               ## `Bundle.display`
    tag: string                ## drawn text: "" / "cs[1:3]" / "3*9"
    open: bool                 ## apIrregular: some member's net is nil
    distinctNets: int          ## apIrregular: distinct non-nil net count
    partner: int               ## apChained: index of the paired port; -1
    isOut: bool                ## apChained: this half is the OUT side
    head, tail: string         ## apChained: the two escaping nets
    links: seq[string]         ## apChained OUT half: N-1 link nets, chain order
    chainKey: string           ## apChained OUT half: member walk order, so
                               ## parallel chains share one drawn arc
    chainLead: int             ## apChained OUT half: port whose arc this chain
                               ## draws under (== self for the lead); -1 otherwise
    railCommon: bool           ## apCommon only: shared net is ground/rail, so
                               ## `pmBusBar` is suppressed (the glyph already
                               ## says "shared rail"; tick and bars would collide)
    bundleFamily: string       ## apDistributed + bundled only: the bus/interface
                               ## name behind this port (`splitKeyOf`) -- "rin",
                               ## not "rin_0". `arrayPinFor` labels a merged port
                               ## with it, since the box stands for every member.

  PartArray = object
    key: string                ## "<subNetlist.name|kind>\x1f<...>\x1f<sub>"; the
                               ## first field is `arrayReport`'s `source`
    origin: ArrayOrigin
    members: seq[string]       ## designators, graph insertion order
    rep: string                ## members[0] -- the one drawn box/symbol
    label: string              ## "X1..X8"
    ports: seq[ArrayPort]      ## one per port/pin, declaration order

  ArrayPlan = object
    arrays: seq[PartArray]
    byRep: Table[string, int]              ## representative designator -> array
    hidden: HashSet[string]                ## the N-1 designators prepare drops
    portOfPin: Table[string, tuple[a, p: int]]  ## pinKey(rep, pin) -> port
    suppressed: HashSet[string]            ## nets that never route (chain links;
                                           ## distributed members after the first)
    groupOf: Table[string, tuple[a, p: int]]  ## distributed member net -> port
    extraPins: Table[string, seq[tuple[desig, pin: string, outward: bool]]]
                                           ## chain head/tail re-homed onto the
                                           ## representative; `outward` marks the
                                           ## tail (the array's real output), since
                                           ## a positional instance pin is always
                                           ## `ptUnknown`
    arrayNets: HashSet[string]             ## what finish skips in the net-name
                                           ## pass (drawn group members + tags)

proc isOpenBind(x: Net): bool {.inline.} =
  ## An unbound pin or an explicit no-connect (`nc_<inst>_<port>`): the
  ## member leaves the port open.
  x == nil or x.attrs.getOrDefault("iface.nc") == "1"

proc netNameOf(x: Net): string {.inline.} =
  (if x != nil and not isOpenBind(x): x.name else: "")

proc splitKeyOf(x: Net): string {.inline.} =
  ## The value `subGroupsOf` partitions on: `iface.instance`, else `bus.name`,
  ## else the net name. Distinct members of one bus must count as the same
  ## family, or a port bound to `rin[0..3]` on some members and `rout[0..3]`
  ## on others never splits. `iface.instance` comes first (as in
  ## `bundles.nim`) because `bus.name` alone is the bare signal name, shared
  ## across every instance of an interface.
  if x == nil: ""
  else:
    let inst = x.attrs.getOrDefault("iface.instance", "")
    if inst.len > 0: inst
    else: x.attrs.getOrDefault("bus.name", x.name)

# --- shared build context (both passes) ------------------------------------

type
  ArrayBuildCtx = object
    usedDisplays: HashSet[string]
      ## Display tags already taken by a bundle or an earlier array of either
      ## origin, so the two passes never allocate the same one.
    mixedMergeBundle: HashSet[int]
      ## `brNetLabel` bundles with at least one merged `LabelGroup`. Every
      ## port on such a bundle is bundle-owned (`mergedByBundle`), even where
      ## its own representative merges nothing: a bundle drawn partly as
      ## merged tags has no single tag left for a bus tree to reuse.

proc initArrayBuildCtx(nl: Netlist, bundles: BundlePlan,
                       base = ArrayPlan()): ArrayBuildCtx =
  for bi, b in bundles.bundles:
    result.usedDisplays.incl b.display
    if b.role == brNetLabel:
      for lg in b.labelGroups:
        if lg.merged:
          result.mixedMergeBundle.incl bi
          break
  for a in base.arrays:
    for ap in a.ports:
      if ap.display.len > 0: result.usedDisplays.incl ap.display

proc survivesCollapsedBundles(bundles: BundlePlan, alreadyHidden: HashSet[string],
                              candidateHidden: seq[string]): bool =
  ## Declines only if hiding sub-group `g`'s members leaves some
  ## `brCollapsed` bundle with fewer than two placeable entities (its far end
  ## would vanish). Evaluated per sub-group, so a bundle that keeps two
  ## entities does not veto it.
  var hidden = alreadyHidden
  for d in candidateHidden: hidden.incl d
  for b in bundles.bundles:
    if b.role != brCollapsed: continue
    var touchesHidden = false
    for d in b.parts:
      if d in hidden: touchesHidden = true
    if not touchesHidden: continue
    var survivors = 0
    for d in b.parts:
      if d notin hidden: inc survivors
    if survivors < 2: return false
  true

proc uniqueDisplay(ctx: var ArrayBuildCtx, nl: Netlist, natural: string): string =
  # `used` is passed explicitly: a nested proc may not capture a `var`
  # parameter of its enclosing proc.
  proc free(s: string, used: HashSet[string]): bool =
    not nl.nets.hasKey(s) and s notin used
  var cand = natural
  if not free(cand, ctx.usedDisplays):
    cand = natural & "_arr"
    var i = 2
    while not free(cand, ctx.usedDisplays):
      cand = natural & "_arr_" & $i
      inc i
  ctx.usedDisplays.incl cand
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
  ## `_out`/`out` or `_in`/`in` port-name suffix: the chain-pairing
  ## tiebreaker when child pin kinds don't distinguish the halves.
  let s = portName.toLowerAscii()
  if s.endsWith("_out") or s == "out" or s.endsWith("outp") or s.endsWith("_o"):
    pdOutput
  elif s.endsWith("_in") or s == "in" or s.endsWith("_i"):
    pdInput
  else: pdUnspecified

proc hierDir(c: Component, portName: string): PortDirection =
  ## The subsheet port's authored direction, folded from the child's pin
  ## kinds on the port net (positional instance pins are `ptUnknown`).
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

proc subGroupsOf(n: int, portNames: seq[string], binding: seq[seq[Net]]):
    seq[seq[int]] =
  ## Splits member indices by every *splitting* port -- one whose
  ## `splitKeyOf` values partition the members into 2+ groups of size >= 2
  ## with none open -- before classification, so nine memories on three
  ## buses draw as three `x3` boxes. A singleton differing from everyone is
  ## the irregular signal, not a sub-array boundary.
  var subOf = newSeq[int](n)
  var nsub = 1
  for pi in 0 ..< portNames.len:
    var counts = initTable[string, int]()
    var anyNil = false
    for mi in 0 ..< n:
      let nm = netNameOf(binding[pi][mi])
      if nm.len == 0: anyNil = true
      else:
        let k = splitKeyOf(binding[pi][mi])
        counts[k] = counts.getOrDefault(k, 0) + 1
    if anyNil or counts.len < 2 or counts.len >= n: continue
    var evenGroups = true
    for _, cnt in counts:
      if cnt < 2: evenGroups = false
    if not evenGroups: continue
    var refined = initTable[string, int]()
    var newSub = newSeq[int](n)
    var nn = 0
    for mi in 0 ..< n:
      let k = $subOf[mi] & "\x1f" & splitKeyOf(binding[pi][mi])
      if k notin refined:
        refined[k] = nn
        inc nn
      newSub[mi] = refined[k]
    subOf = newSub
    nsub = nn

  result = newSeq[seq[int]](nsub)
  for mi in 0 ..< n: result[subOf[mi]].add mi

proc classifyGroup(ctx: var ArrayBuildCtx, nl: Netlist, sig: string, gi: int,
                   members: seq[string], g: seq[int], portNames: seq[string],
                   binding: seq[seq[Net]], bundles: BundlePlan,
                   rep0: Component, origin: ArrayOrigin,
                   allowChain: bool): PartArray =
  ## Builds one `PartArray` for sub-group `g`: per-port classification,
  ## chain pairing (if `allowChain`), display/tag allocation. Shared by both
  ## passes; registration (`registerArray`) is separate so a caller can veto
  ## a group first.
  var sub = PartArray(key: sig & "\x1f" & $gi, origin: origin)
  for mi in g: sub.members.add members[mi]
  sub.rep = sub.members[0]
  sub.label = sub.members[0] & ".." & sub.members[^1]
  let repC = nl.components[sub.rep]

  # Per-port classification over this sub-group.
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
    for x in objs:
      if bundles.ofNet.hasKey(x.name):
        ap.bundled = true
        # `subGroupsOf` already split on disagreeing families, so the first
        # bound member is a valid witness.
        if ap.bundleFamily.len == 0: ap.bundleFamily = splitKeyOf(x)
    # Bundle-owned if the bundle claims this representative pin
    # (`bundles.byPin`) or merges a pin anywhere (`mixedMergeBundle` -- a bus
    # merged on one carrier but not another has no single tag left to reuse).
    # A `bundled` port merged nowhere is drawn and routed by the array.
    ap.mergedByBundle = bundles.byPin.hasKey(pinKey(repC, pn)) or
      (ap.nets.len > 0 and bundles.byNet.hasKey(ap.nets[0]) and
       bundles.byNet[ap.nets[0]] in ctx.mixedMergeBundle)
    var allSame = objs.len == g.len
    for x in objs:
      if x != objs[0]: allSame = false
    var distinctSet = initHashSet[string]()
    for nm in ap.nets:
      if nm.len > 0: distinctSet.incl nm
    if allSame:
      ap.cls = apCommon
      ap.railCommon = rail
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

  # Chain pairing over non-bundled distributed candidates, first success
  # wins. Skipped for a non-box representative (no interior for the arc).
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
    true

  if allowChain:
    for a in 0 ..< sub.ports.len:
      if sub.ports[a].cls != apDistributed or sub.ports[a].bundled: continue
      if sub.ports[a].dir == pdInput: continue     # a is the OUT candidate
      for b in 0 ..< sub.ports.len:
        if b == a: continue
        if sub.ports[b].cls != apDistributed or sub.ports[b].bundled: continue
        if sub.ports[b].dir == pdOutput: continue   # b is the IN candidate
        if tryChain(a, b): break

  # Parallel chains (a strapped SPI bus) draw as one arc: the first OUT half
  # of each `chainKey` group leads, the rest point at it.
  var chainLead = initTable[string, int]()
  for pi in 0 ..< sub.ports.len:
    if sub.ports[pi].cls != apChained or not sub.ports[pi].isOut: continue
    let k = sub.ports[pi].chainKey
    if k notin chainLead: chainLead[k] = pi
    sub.ports[pi].chainLead = chainLead[k]

  # Displays, tags.
  for pi in 0 ..< sub.ports.len:
    case sub.ports[pi].cls
    of apDistributed:
      if sub.ports[pi].mergedByBundle: continue
      if sub.ports[pi].bundled:
        # Not merged anywhere: the array routes this port, reusing the
        # bundle's own occupancy tag so its route, the bundle's port pennant,
        # and any other array distributing the same bus agree on one wire.
        let bi = bundles.byNet.getOrDefault(sub.ports[pi].nets[0], -1)
        if bi >= 0: sub.ports[pi].display = bundles.bundles[bi].display
      if sub.ports[pi].display.len == 0:
        sub.ports[pi].display = uniqueDisplay(ctx, nl, sub.ports[pi].name)
      # This tag is the only label the pin gets (`finish.nim` skips
      # `arrayNets`), so a bundled port uses the bundle's disambiguated
      # `display` -- two buses whose source pins are both named "RF" must not
      # both read "RF[1:4]". An unbundled port keeps the pin-name tag.
      let tagName = if sub.ports[pi].bundled: sub.ports[pi].display
                    else: sub.ports[pi].name
      sub.ports[pi].tag = tagName & "[1:" & $g.len & "]"
    of apChained:
      if sub.ports[pi].isOut:
        sub.ports[pi].dir = pdOutput
        if sub.ports[pi].chainLead == pi:      # the arc's lead only
          sub.ports[pi].display = uniqueDisplay(ctx, nl, sub.ports[pi].name & "_chain")
      else:
        sub.ports[pi].dir = pdInput
    else: discard
  # Non-lead parallel chains borrow the lead's display.
  for pi in 0 ..< sub.ports.len:
    if sub.ports[pi].cls == apChained and sub.ports[pi].isOut and
       sub.ports[pi].chainLead != pi:
      sub.ports[pi].display = sub.ports[sub.ports[pi].chainLead].display

  sub

proc registerArray(nl: Netlist, plan: var ArrayPlan, sub: PartArray) =
  ## Wires a built `PartArray` into the plan (`byRep`/`hidden`/`portOfPin`,
  ## `groupOf`/`arrayNets`, chain `suppressed`/`extraPins`). Shared by both
  ## passes. Distributed members are **not** suppressed here -- that needs
  ## the final `groupOf` (`finalizeArrayPlan`). Chain links are internal to
  ## one array, so they are suppressed immediately.
  let arrIdx = plan.arrays.len
  plan.byRep[sub.rep] = arrIdx
  for mi in 1 ..< sub.members.len: plan.hidden.incl sub.members[mi]
  let repC = nl.components[sub.rep]
  for pi in 0 ..< sub.ports.len:
    let ap = sub.ports[pi]
    plan.portOfPin[pinKey(repC, ap.name)] = (arrIdx, pi)
    case ap.cls
    of apDistributed:
      if ap.mergedByBundle: continue
      for nm in ap.nets:
        if nm.len == 0: continue
        plan.groupOf[nm] = (arrIdx, pi)
        plan.arrayNets.incl nm
      plan.arrayNets.incl ap.display
    of apChained:
      if ap.isOut:
        for lnk in ap.links:
          plan.suppressed.incl lnk
          plan.arrayNets.incl lnk
        plan.arrayNets.incl ap.display
        plan.extraPins.mgetOrPut(ap.head, @[]).add (sub.rep,
          sub.ports[ap.partner].name, false)
        plan.extraPins.mgetOrPut(ap.tail, @[]).add (sub.rep, ap.name, true)
    else: discard
  plan.arrays.add sub

proc addSignatureArrays(ctx: var ArrayBuildCtx, nl: Netlist,
                        plan: var ArrayPlan, bundles: BundlePlan, sig: string,
                        members: seq[string], portNames: seq[string],
                        binding: seq[seq[Net]], rep0: Component,
                        origin: ArrayOrigin, allowChain: bool) =
  ## Sub-groups one signature's members, classifies each sub-group of >= 3
  ## (>= 2 under the floors below) and registers those that survive
  ## `survivesCollapsedBundles` and, for component groups only, the
  ## all-common decline (a repeated subcircuit is a design decision, not an
  ## inferred motif).
  for gi, g in subGroupsOf(members.len, portNames, binding):
    if g.len < 2: continue
    var hidden: seq[string]
    for i in 1 ..< g.len: hidden.add members[g[i]]
    if not survivesCollapsedBundles(bundles, plan.hidden, hidden): continue
    let sub = classifyGroup(ctx, nl, sig, gi, members, g, portNames, binding,
                            bundles, rep0, origin, allowChain)
    if origin == aoComponent:
      var anyDistributed = false
      var anyMergedDistributed = false
      var allCommonRail = sub.ports.len > 0
      for ap in sub.ports:
        if ap.cls == apDistributed:
          anyDistributed = true
          if ap.mergedByBundle: anyMergedDistributed = true
        if ap.cls != apCommon or not ap.railCommon: allCommonRail = false
      # Two-member floors. Bypass bank: every port `apCommon` and
      # `railCommon` -- members genuinely share a rail/ground pair. Declared
      # pair: an `apDistributed` port that is `mergedByBundle`, i.e. its nets
      # belong to one declared bus/interface (a diff pair's per-leg
      # termination); one such port vouches for the pairing. Anything else
      # keeps the three-member floor so two coincidentally equal parts don't
      # merge.
      if allCommonRail or (g.len == 2 and anyMergedDistributed): discard
      elif g.len < 3 or not anyDistributed: continue
    elif g.len < 3: continue
    registerArray(nl, plan, sub)

proc finalizeArrayPlan(nl: Netlist, bundles: BundlePlan, plan: var ArrayPlan) =
  ## Derives `suppressed` for every distributed group from the final
  ## `groupOf`, then asserts totality. Call exactly **once**, after every
  ## builder has run: `suppressed` only grows, so a second finalize could
  ## keep a stale decision once `groupOf` is reassigned.
  var bucketFirst = initTable[tuple[a, p: int], string]()
  for name, _ in nl.nets:
    if plan.groupOf.hasKey(name):
      let key = plan.groupOf[name]
      if key notin bucketFirst: bucketFirst[key] = name
  for name, key in plan.groupOf:
    if bucketFirst[key] != name: plan.suppressed.incl name

  # Totality: every net on a hidden member's pin must be suppressed, drawn
  # by a group, on the representative's pin, or on an irregular port --
  # otherwise it vanishes with no marker.
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

proc buildSubsheetArrays(nl: Netlist, bundles: BundlePlan, plan: var ArrayPlan) =
  ## Repeated-**subsheet** groups, added to `plan` in place (no-op if no
  ## subsheet has three instances). The caller runs `finalizeArrayPlan`
  ## once after all builders.
  var ctx = initArrayBuildCtx(nl, bundles, plan)

  # Signature grouping. `graph.instantiate` creates one pin per child port in
  # declaration order, so instances of one template share this key and two
  # different templates with a colliding `.SUBCKT` name do not.
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

  for sig in sigOrder:
    let members = sigMembers[sig]
    if members.len < 3: continue
    block signatureBody:
      let rep0 = nl.components[members[0]]
      var portNames: seq[string]
      for pn, _ in rep0.pins: portNames.add pn

      # binding[portIdx][memberIdx] -> the parent Net that member binds
      var binding = newSeq[seq[Net]](portNames.len)
      for pi, pn in portNames:
        binding[pi] = newSeq[Net](members.len)
        for mi, d in members:
          binding[pi][mi] = nl.components[d].pins[pn].net

      addSignatureArrays(ctx, nl, plan, bundles, sig, members, portNames,
                         binding, rep0, aoSubsheet, allowChain = true)

proc buildComponentArrays(nl: Netlist, bundles: BundlePlan, plan: var ArrayPlan) =
  ## Repeated **raw component** groups, added to the same unfinalized `plan`
  ## (or a zero-value one). The caller finalizes.
  var ctx = initArrayBuildCtx(nl, bundles, plan)

  var sigOrder: seq[string]
  var sigMembers = initTable[string, seq[string]]()
  for _, c in nl.components:
    if c.subNetlist != nil: continue          # the subsheet pass owns those
    if isPackaged(c): continue                # a section already has "U10A"
    let value = c.attrs.getOrDefault("value", "")
    # A part with no `value`, `partNumber` or `description` is never a
    # candidate: a blank label asserts nothing about the parts it stands for,
    # and unvalued topology fixtures would collapse into phantom arrays.
    let desc = c.attrs.getOrDefault("description", "")
    if value.len == 0 and c.partNumber.len == 0 and desc.len == 0: continue
    var keys, kinds: seq[string]
    for pn, p in c.pins:
      keys.add pn
      kinds.add $p.kind
    if keys.len == 0: continue
    let sig = c.kind & "\x1f" & value & "\x1f" &
              c.partNumber & "\x1f" & desc & "\x1f" & c.name & "\x1f" &
              keys.join("\x1f") &
              "\x1f" & kinds.join("\x1f")
    if sig notin sigMembers:
      sigOrder.add sig
      sigMembers[sig] = @[]
    sigMembers[sig].add c.designator

  for sig in sigOrder:
    let members = sigMembers[sig]
    if members.len < 2: continue
    block signatureBody:
      let rep0 = nl.components[members[0]]
      var portNames: seq[string]
      for pn, _ in rep0.pins: portNames.add pn

      var binding = newSeq[seq[Net]](portNames.len)
      for pi, pn in portNames:
        binding[pi] = newSeq[Net](members.len)
        for mi, d in members:
          binding[pi][mi] = nl.components[d].pins[pn].net

      # A two-terminal symbol has no interior for a recirculation arc; a box
      # keeps the chain treatment.
      let allowChain = symbolFor(rep0).isBox
      addSignatureArrays(ctx, nl, plan, bundles, sig, members, portNames,
                         binding, rep0, aoComponent, allowChain)

# --- plain-data bridges (consumed by state.prepare / symbols / routing) -----

proc arrayLabelFor(plan: ArrayPlan, c: Component): string {.inline.} =
  ## The drawn box/symbol label for `c` ("X1..X8"), or "" for every
  ## non-representative.
  if plan.byRep.hasKey(c.designator): plan.arrays[plan.byRep[c.designator]].label
  else: ""

proc arrayLanesFor(plan: ArrayPlan, c: Component):
    tuple[names: seq[string], side: seq[int]] =
  ## Reserved. The chain arc anchors on the box edge beside its pins, so no
  ## lane is drawn.
  discard

proc arrayTitleWidth(plan: ArrayPlan, c: Component): float {.inline.} =
  ## Width `boxSlots` reserves at the box top for "X1..X8" and the "xN"
  ## badge; 0.0 for every other part, so sizing is otherwise unchanged.
  if not plan.byRep.hasKey(c.designator): return 0.0
  let a = plan.arrays[plan.byRep[c.designator]]
  float(a.label.len + 4 + ($a.members.len).len) * 7.2 + 24.0

proc arrayPinFor(plan: ArrayPlan, c: Component, pinName: string):
    tuple[found: bool, mark: PinMark, tag, net: string,
          members: seq[BundleMember]] =
  ## Scene decoration for one representative pin. `net` is the drawn name:
  ## head/tail for a chain, the group `display` for a distributed pin, the
  ## bus family for a bundled one, "" otherwise. `members` has one entry per
  ## member (designator, binding on this port).
  if not plan.portOfPin.hasKey(pinKey(c, pinName)): return
  let (ai, pi) = plan.portOfPin[pinKey(c, pinName)]
  let a = plan.arrays[ai]
  let ap = a.ports[pi]
  result.found = true
  for k, d in a.members:
    result.members.add BundleMember(name: d, net: ap.nets[k])
  case ap.cls
  of apCommon:
    # A ground/rail pin already draws a glyph the tick would collide with.
    if not ap.bundled and not ap.railCommon: result.mark = pmBusBar
  of apDistributed:
    if not ap.mergedByBundle:
      # Not merged anywhere: the array routes this port (`display` is the
      # bundle's own tag, so it agrees with the bundle's pennant).
      result.mark = pmBusSlash
      result.tag = ap.tag
      result.net = ap.display
    else:
      # The bundle draws the mark, but the pin's `net` is the bus family
      # ("rin"), not the representative's own member ("rin_0").
      result.net = ap.bundleFamily
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

proc arrayBundleLabelFor(plan: ArrayPlan, c: Component, pinName: string): string =
  ## Net-label text for a bundled distributed representative's pin: the bus
  ## family name, since the box stands for every member. The bundle pass
  ## never sees the collapsed scene and would draw "rin_0". "" elsewhere.
  if not plan.portOfPin.hasKey(pinKey(c, pinName)): return ""
  let (ai, pi) = plan.portOfPin[pinKey(c, pinName)]
  let ap = plan.arrays[ai].ports[pi]
  if ap.cls == apDistributed and ap.mergedByBundle: ap.bundleFamily else: ""

proc arrayOwnsDistributedPin(plan: ArrayPlan, c: Component, pinName: string): bool =
  ## True when the array routes this pin's port as a real wire under the
  ## bundle's occupancy tag, so the net-label pass must not also tag it.
  if not plan.portOfPin.hasKey(pinKey(c, pinName)): return false
  let (ai, pi) = plan.portOfPin[pinKey(c, pinName)]
  let ap = plan.arrays[ai].ports[pi]
  ap.cls == apDistributed and not ap.mergedByBundle

proc arrayRouteFor(plan: ArrayPlan, netName: string):
    tuple[skip: bool, group: bool, tag: string, members: seq[string],
          first: bool] =
  ## The routing decision for one `nl.nets` entry: `skip` a suppressed net;
  ## `group` for the one surviving distributed member, which routes as the
  ## bus. `first` is always true here -- `finalizeArrayPlan` suppressed every
  ## other member, and its pick need not match the port's `nets[0]`.
  if netName in plan.suppressed:
    return (skip: true, group: false, tag: "", members: @[], first: false)
  if plan.groupOf.hasKey(netName):
    let (ai, pi) = plan.groupOf[netName]
    let ap = plan.arrays[ai].ports[pi]
    var mem: seq[string]
    for nm in ap.nets:
      if nm.len > 0: mem.add nm
    return (skip: false, group: true, tag: ap.display, members: mem, first: true)
  (skip: false, group: false, tag: "", members: @[], first: false)

# --- public reporter -------------------------------------------------------

proc arrayReport*(nl: Netlist): seq[tuple[source, label, rep: string,
                                    count: int, members, ports: seq[string],
                                    origin: string]] =
  ## Every collapsed array, subsheet or component, for unit tests. Builds the
  ## bundle plan itself, so it matches `prepare` with `lsArrays` and
  ## `lsPartArrays` on. `source` is the subckt name or component `kind` (the
  ## first `\x1f` field of `PartArray.key`); `origin` is "subsheet" or
  ## "component".
  ##
  ## Each `ports` entry renders as `"<port>=<class>[<detail>]"`:
  ##   "vdd=common"                  "vdd=common(bundled)"
  ##   "wp=distributed[1:6]"         "sclk=common(bundled)"
  ##   "sclk_out=chained(out,x7)"    "sclk_in=chained(in)"
  ##   "trig=irregular(3*6)"         "nc=irregular(2*6,open=4)"
  let bundles = bundlePlan(nl)
  var plan: ArrayPlan
  buildSubsheetArrays(nl, bundles, plan)
  buildComponentArrays(nl, bundles, plan)
  finalizeArrayPlan(nl, bundles, plan)
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
    let source = a.key.split("\x1f")[0]
    result.add (source: source, label: a.label, rep: a.rep,
                count: a.members.len, members: a.members, ports: ports,
                origin: (case a.origin
                        of aoSubsheet: "subsheet"
                        of aoComponent: "component"))
