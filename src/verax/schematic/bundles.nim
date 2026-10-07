## Bus- and interface-aware grouping: a read-only index built once per
## layout, before any symbol is sized. Groups members of a lowered bus or
## interface so a whole SPI link can draw as one thick wire between merged
## pins.
##
## Reads **net attrs only, never pin attrs**: `promotePortDirections` copies
## `iface.*` onto instance pins, so reading pins would drag an `iface.nc`
## open net into the bundle it was left out of.
##
## `findBus`/`findInterface`/`interfacesOf` are forbidden here: they rescan,
## `findInterface` needs a registered def, and `busOf` *writes*
## `bus.index`. Layout stays read-only and reads `attrs` directly.
##
## The plan is a pure function of netlist topology; `recoverRouting` never
## rebuilds it. A zero-value `BundlePlan` is the byte-identity guarantee for a
## bus-free netlist.

type
  BundleTag = enum
    btBus, btInterface

  BundleRole = enum
    brScalar     ## fails collapse: ordinary wires, membership colour only
    brCollapsed  ## two or more endpoint entities, uniform: one merged pin per
                 ## entity, one thick bus tree between them
    brNetLabel   ## fails collapse **and** is published or spans 3+ entities:
                 ## grouped net-label tags, no wires (one merged tag per box
                 ## carrying >= 2 members, a bare tag elsewhere)

  LabelGroup = object
    ## One endpoint's share of a `brNetLabel` bundle. A box carrying >= 2
    ## members gets one merged pin and tag; one member keeps its bare label.
    ## In `memberPins` desig-first-seen order (`bundleReport`, `laneOf` rely
    ## on it).
    desig: string
    pins: seq[tuple[pin, net: string]]  ## owned member pins, memberPins order
    members: seq[BundleMember]          ## this group's subset, member order
    merged: bool                        ## >= 2 owned members AND a box carrier
    text: string                        ## "spi1" / "spi1(cs0)"; "" when unmerged

  Bundle = object
    key: string              ## "iface:spi" / "bus:spi1_cs" -- index identity
    display: string          ## scene net identity ("spi"), distinct from
                             ## every `nl.nets` key
    pinName: string          ## net-based fallback text ("en[7:0]", "spi[3]");
                             ## the drawn merged pin name is `pinNameFor`
    portText: string         ## drawn port pennant text over the published
                             ## members only; "" when none. Separate from
                             ## `pinName` because a `brNetLabel` bundle may
                             ## publish a subset.
    tag: BundleTag
    role: BundleRole
    dir: PortDirection       ## the folded member direction
    members: seq[string]     ## member net names, in `nl.nets` order
    parts: seq[string]       ## component-entity designators, sorted
    ported: bool             ## the sheet boundary is one of the entities
    portNames: seq[string]   ## the merged `nl.ports` keys, declared order
    memberPins: seq[tuple[desig, pin, net: string]]
      ## every owned physical pin of every member net, member then pin order:
      ## routing endpoints and net-label pins
    sceneMembers: seq[BundleMember]
      ## the drawn (signal name, scalar net) pairs, one per member, carried by
      ## a merged `SchematicPin`/`SchematicPort`
    portSceneMembers: seq[BundleMember]
      ## `sceneMembers` restricted to the published subset (equal for a
      ## `brCollapsed` bundle, which requires uniform ported-ness)
    labelGroups: seq[LabelGroup]
      ## `brNetLabel` only: one entry per component entity.

  BundlePlan = object
    bundles: seq[Bundle]
    ofNet: Table[string, BundleTag]
      ## every membership net -> kind, for colour, whatever the role
      ## (including discarded candidates)
    byNet: Table[string, int]
      ## member net -> bundle index, real bundles only
    byPin: Table[string, int]
      ## `pinKey(c, pin)` -> bundle index: collapsed bundles and merged
      ## `LabelGroup`s
    byPort: Table[string, int]
      ## `nl.ports` key -> bundle index, for collapsed or published
      ## `brNetLabel` bundles (`brScalar` is never published)
    bundled: HashSet[string]
      ## designators carrying a collapsed bundle or a merged net-label group

proc wireKindFor(plan: BundlePlan, netName: string): WireKind {.inline.} =
  ## Membership colour for a signal wire: purple for an interface, blue for
  ## a bus, else `wkSignal`. Colour is membership; thickness
  ## (`members.len > 1`) says it collapses nets.
  if not plan.ofNet.hasKey(netName): return wkSignal
  if plan.ofNet[netName] == btInterface: wkInterface else: wkBus

proc pinNameFor(b: Bundle, desig: string): string
  ## Forward-declared for `routing.nim`, which is spliced in after this file.

proc laneOf(plan: BundlePlan, bi: int, desig: string):
    tuple[name: string, members: seq[BundleMember]] =
  ## The one source of a merged lane's text and members, so box sizing
  ## (`bundleGroupsFor`) and the drawn pin never disagree. A collapsed
  ## bundle's name comes from `pinNameFor`.
  let b = plan.bundles[bi]
  if b.role == brNetLabel:
    for lg in b.labelGroups:
      if lg.desig == desig and lg.merged: return (lg.text, lg.members)
  (pinNameFor(b, desig), b.sceneMembers)

proc bundleGroupsFor(plan: BundlePlan, c: Component):
    tuple[groupOf, groupSide: seq[int], groupNames: seq[string]] =
  ## The per-pin partition `boxSlots` needs for `c`: `groupOf[i]` a local
  ## group id or `-1`. `groupSide` follows the folded direction (input left,
  ## output right, like the port pennant). Empty when `c` carries no bundle.
  if c.designator notin plan.bundled: return
  var localOf = initTable[int, int]()
  for pinName, _ in c.pins:
    let bi = plan.byPin.getOrDefault(pinKey(c, pinName), -1)
    if bi < 0:
      result.groupOf.add -1
      continue
    if bi notin localOf:
      localOf[bi] = result.groupNames.len
      result.groupNames.add laneOf(plan, bi, c.designator).name
      result.groupSide.add (case plan.bundles[bi].dir
        of pdInput, pdUnspecified: 0
        of pdOutput, pdBidir: 1)
    result.groupOf.add localOf[bi]

proc bundleEntities(nl: Netlist, members: seq[Net]):
    tuple[parts: seq[string], ported, uniform: bool] =
  ## `uniform` is the collapse precondition: every member touches the same
  ## entity set. Ported-ness is tested by `Net` identity, never name.
  var first: seq[string]
  var firstPorted = false
  var firstSet = false
  for n in members:
    var here: seq[string]
    for p in n.pins:
      if p.component != nil and p.component.netlist == nl and
         p.component.designator notin here:
        here.add p.component.designator
    here.sort()
    var portedHere = false
    for _, portNet in nl.ports:
      if portNet == n: portedHere = true
    if not firstSet:
      first = here
      firstPorted = portedHere
      firstSet = true
    elif here != first or portedHere != firstPorted:
      return (first, firstPorted, false)
  (first, firstPorted, true)

proc collapsible(parts: seq[string], ported: bool): bool {.inline.} =
  ## The collapse precondition, with `uniform`: two or more endpoint entities
  ## (a component, or the sheet boundary). No upper cap.
  parts.len + (if ported: 1 else: 0) >= 2

proc bundleUnionEntities(nl: Netlist, members: seq[Net]):
    tuple[parts: seq[string], ported: bool] =
  ## Every component entity any member touches, plus whether any member is
  ## published -- for net-label degradation, which concerns the union.
  var parts: seq[string]
  var ported = false
  for n in members:
    for p in n.pins:
      if p.component != nil and p.component.netlist == nl and
         p.component.designator notin parts:
        parts.add p.component.designator
    for _, portNet in nl.ports:
      if portNet == n: ported = true
  parts.sort()
  (parts, ported)

proc sigOf(n: Net): string =
  ## A member's signal: `iface.signal`, else `bus.name` (never
  ## `iface.instance`).
  let s = n.attrs.getOrDefault("iface.signal")
  if s.len > 0: s else: n.attrs.getOrDefault("bus.name")

proc busIndexRangeText(display: string, sortedIndices: seq[int]): string =
  ## `hi:lo` notation over sorted, distinct `bus.index` values: `en[7:0]`,
  ## or `en[7:5,2]` for a partial set. Read from attrs, never `findBus`.
  if sortedIndices.len == 0: return display
  var runs: seq[string]
  var i = sortedIndices.len - 1
  while i >= 0:
    var j = i
    while j > 0 and sortedIndices[j - 1] == sortedIndices[j] - 1: dec j
    if sortedIndices[j] == sortedIndices[i]: runs.add $sortedIndices[i]
    else: runs.add $sortedIndices[i] & ":" & $sortedIndices[j]
    i = j - 1
  display & "[" & runs.join(",") & "]"

proc dimsRangeText(display: string, dims: seq[int]): string =
  ## Multi-dimensional notation, `a[7:0][1:0]` for `dims = [8, 2]`. Only when
  ## every cell is present; otherwise the flat form.
  result = display
  for d in dims: result &= "[" & $(d - 1) & ":0]"

proc busPortText(display: string, tag: BundleTag, members: seq[Net]): string =
  ## The merged port pennant text (`portText`), about net/bus identity. Also
  ## `pinNameFor`'s fallback. An interface uses a count (`spi[3]`); a bus a
  ## `bus.index` range; a complete multi-dim bus the multi-axis form.
  if members.len == 0: return ""
  if tag == btInterface: return display & "[" & $members.len & "]"
  let dimsStr = members[0].attrs.getOrDefault("bus.dims")
  if dimsStr.len > 0:
    var uniform = true
    for n in members:
      if n.attrs.getOrDefault("bus.dims") != dimsStr: uniform = false
    if uniform:
      var dims: seq[int]
      var total = 1
      for tok in dimsStr.split(','):
        let d = parseInt(tok)
        dims.add d
        total *= d
      if members.len == total: return dimsRangeText(display, dims)
  var indices: seq[int]
  for n in members:
    try: indices.add parseInt(n.attrs.getOrDefault("bus.index", "0"))
    except ValueError: discard
  indices.sort()
  busIndexRangeText(display, indices)

proc splitPinFamily(name: string): tuple[prefix: string, idx: int, ok: bool] =
  ## Splits a trailing index off a pin name: `"RF1"` -> `("RF", 1, true)`;
  ## `"GND"` or an all-digit name -> `("", 0, false)`.
  var i = name.len
  while i > 0 and name[i - 1] in {'0' .. '9'}: dec i
  if i == name.len or i == 0: return ("", 0, false)
  (name[0 ..< i], parseInt(name[i .. ^1]), true)

proc pinNameFor(b: Bundle, desig: string): string =
  ## The merged pin's text on `desig`'s box, named from the component's own
  ## pins (the net name is already on the wire): one name, or a
  ## `busIndexRangeText` range (`"RF[4:1]"`) when all share a prefix with
  ## distinct indices, else `b.pinName` (e.g. an interface's
  ## `sclk`/`mosi`/`miso`).
  var names: seq[string]
  for mp in b.memberPins:
    if mp.desig == desig: names.add mp.pin
  if names.len == 0: return b.pinName
  if names.len == 1: return names[0]
  if b.tag == btInterface: return b.pinName
  let (p0, i0, ok0) = splitPinFamily(names[0])
  if not ok0: return b.pinName
  var indices = @[i0]
  for k in 1 ..< names.len:
    let (p, idx, ok) = splitPinFamily(names[k])
    if not ok or p != p0: return b.pinName
    indices.add idx
  indices.sort()
  busIndexRangeText(p0, indices)

proc groupText(b: Bundle, owned, allMembers: seq[Net]): string =
  ## The tag on a merged net-label pin. `owned` is this component's subset,
  ## `allMembers` the bundle's. "Full" is computed from the bundle's members,
  ## never `bus.width` (which `busOf` rewrites).
  ##
  ## Cases: whole interface -> `spi1`; a slice -> `spi1(cs0)`; a tap ->
  ## `spi1(sclk, mosi)`; CS only -> `spi1(cs)`; bits 0 and 3 of `dq` ->
  ## `dq(0, 3)`; all 8 -> `dq`.
  let base = b.display
  var sigOrder: seq[string]
  var total = initCountTable[string]()
  for n in allMembers:
    let s = sigOf(n)
    if s notin sigOrder: sigOrder.add s
    total.inc s
  var carried = initTable[string, seq[Net]]()
  for n in owned: carried.mgetOrPut(sigOf(n), @[]).add n
  let allSigs = carried.len == sigOrder.len
  var parts: seq[string]
  for s in sigOrder:
    if s notin carried: continue
    if allSigs and carried[s].len == total[s]: continue      # full + complete
    if carried[s].len == total[s]: parts.add s                # this signal full
    elif b.tag == btBus:
      for n in carried[s]: parts.add n.attrs.getOrDefault("bus.index", "0")
    else:
      for n in carried[s]: parts.add s & n.attrs.getOrDefault("bus.index", "0")
  if parts.len == 0: base else: base & "(" & parts.join(", ") & ")"

proc bundlePlan(nl: Netlist): BundlePlan =
  ## One pass over `nl.nets` in order; a zero-value plan if no net carries
  ## `iface.instance` or `bus.name`.
  var plan: BundlePlan
  var order: seq[string]
  var tagOf = initTable[string, BundleTag]()
  var netsOf = initTable[string, seq[Net]]()
  var membership = false
  for _, n in nl.nets:
    let inst = n.attrs.getOrDefault("iface.instance")
    var key = ""
    var tag = btBus
    if inst.len > 0:
      key = "iface:" & inst
      tag = btInterface
    elif n.attrs.getOrDefault("bus.name").len > 0:
      key = "bus:" & n.attrs.getOrDefault("bus.name")
      tag = btBus
    if key.len == 0: continue
    membership = true
    plan.ofNet[n.name] = (if tag == btInterface: btInterface else: btBus)
    if key notin netsOf:
      order.add key
      tagOf[key] = tag
      netsOf[key] = @[]
    netsOf[key].add n
  if not membership: return

  var boxOf = initTable[string, bool]()
  for _, c in nl.components:
    boxOf[c.designator] = symbolFor(c).isBox

  proc memberLabel(n: Net): string =
    ## A member's signal-level name: the interface signal (with index when
    ## wide), or the bare net name. Contains no `[`, so can't collide with a
    ## pin name.
    let sig = n.attrs.getOrDefault("iface.signal")
    if sig.len == 0: return n.name
    let w = n.attrs.getOrDefault("bus.width", "1")
    if w != "1": sig & "_" & n.attrs.getOrDefault("bus.index", "0") else: sig

  proc naturalName(key: string, tag: BundleTag): string =
    if tag == btInterface: key["iface:".len .. ^1]
    else: key["bus:".len .. ^1]

  var usedDisplays = initHashSet[string]()
  proc uniqueDisplay(natural: string, tag: BundleTag): string =
    ## Scene entities key on `display`, so it must not collide with a net
    ## name or another bundle's display.
    proc free(s: string): bool = not nl.nets.hasKey(s) and s notin usedDisplays
    var cand = natural
    if not free(cand):
      cand = natural & (if tag == btInterface: "_iface" else: "_bus")
      var i = 2
      while not free(cand):
        cand = natural & (if tag == btInterface: "_iface" else: "_bus") & "_" & $i
        inc i
    usedDisplays.incl cand
    cand

  proc foldDir(members: seq[Net]): PortDirection =
    var seen: set[PortDirection]
    for n in members:
      let d = portDirection(n)
      if d != pdUnspecified: seen.incl d
    if card(seen) == 0: pdUnspecified
    elif card(seen) == 1:
      for d in seen: return d
      pdUnspecified
    else: pdBidir

  proc anyRailOrGround(members: seq[Net]): bool =
    for n in members:
      if isGroundHere(n) or isRailHere(n): return true
    false

  proc anyNonBoxCarrier(parts: seq[string]): bool =
    for d in parts:
      if not boxOf.getOrDefault(d, true): return true
    false

  proc addBundle(key: string, tag: BundleTag, members: seq[Net],
                 role: BundleRole, ent: tuple[parts: seq[string], ported: bool]) =
    var b = Bundle(key: key, tag: tag, role: role, dir: foldDir(members),
                   parts: ent.parts, ported: ent.ported)
    for n in members: b.members.add n.name
    b.display = uniqueDisplay(naturalName(key, tag), tag)
    b.pinName = busPortText(b.display, tag, members)
    var portedIdx = newSeq[bool](members.len)
    for portName, pn in nl.ports:
      for i, n in members:
        if pn == n:
          if portName notin b.portNames: b.portNames.add portName
          portedIdx[i] = true
    var portedMembers: seq[Net]
    for i, n in members:
      if portedIdx[i]: portedMembers.add n
    b.portText = busPortText(b.display, tag, portedMembers)
    for i, n in members:
      let m = BundleMember(name: memberLabel(n), net: n.name)
      b.sceneMembers.add m
      if portedIdx[i]: b.portSceneMembers.add m
      for p in n.pins:
        if p.component != nil and p.component.netlist == nl:
          b.memberPins.add (p.component.designator, p.name, n.name)

    if role == brNetLabel:
      var netByName = initTable[string, Net]()
      for n in members: netByName[n.name] = n
      var order: seq[string]
      var pinsBy = initTable[string, seq[tuple[pin, net: string]]]()
      for mp in b.memberPins:
        if mp.desig notin pinsBy:
          order.add mp.desig
          pinsBy[mp.desig] = @[]
        pinsBy[mp.desig].add (mp.pin, mp.net)
      for d in order:
        var lg = LabelGroup(desig: d, pins: pinsBy[d])
        var owned: seq[Net]
        for n in members:                       # member order, distinct
          for pr in pinsBy[d]:
            if pr.net == n.name:
              owned.add n
              lg.members.add BundleMember(name: memberLabel(n), net: n.name)
              break
        lg.merged = owned.len >= 2 and boxOf.getOrDefault(d, true)
        if lg.merged: lg.text = groupText(b, owned, members)
        b.labelGroups.add lg

    let idx = plan.bundles.len
    plan.bundles.add b
    for n in members:
      plan.byNet[n.name] = idx
    if role == brCollapsed:
      for mp in b.memberPins:
        plan.byPin[pinKey(nl.components[mp.desig], mp.pin)] = idx
      for d in b.parts: plan.bundled.incl d
    elif role == brNetLabel:
      # Merged groups only; an unmerged carrier keeps its bare per-pin tag.
      for lg in b.labelGroups:
        if not lg.merged: continue
        plan.bundled.incl lg.desig
        for pr in lg.pins:
          plan.byPin[pinKey(nl.components[lg.desig], pr.pin)] = idx
    # `byPort` covers both roles: a collapsed bundle's ends, and a
    # `brNetLabel` bundle's sheet endpoints (one pennant). `brScalar` is
    # never published.
    if role in {brCollapsed, brNetLabel}:
      for pn in b.portNames:
        plan.byPort[pn] = idx

  proc disposeBus(key: string, members: seq[Net]) =
    ## A `btBus` candidate: collapse if eligible; else net-label if ported or
    ## spanning 3+ component entities (the shared-bus convention); else scalar
    ## recolour; under two members, discard (colour still applies).
    if members.len < 2 or anyRailOrGround(members): return
    let ent = bundleEntities(nl, members)
    let union = bundleUnionEntities(nl, members)
    if not anyNonBoxCarrier(union.parts) and ent.uniform and
       collapsible(ent.parts, ent.ported):
      addBundle(key, btBus, members, brCollapsed,
                (parts: ent.parts, ported: ent.ported))
    elif union.ported or union.parts.len >= 3:
      addBundle(key, btBus, members, brNetLabel, union)
    else:
      addBundle(key, btBus, members, brScalar, union)

  for key in order:
    let tag = tagOf[key]
    let members = netsOf[key]
    if tag == btBus:
      disposeBus(key, members)
      continue

    # An interface candidate.
    if members.len >= 2 and not anyRailOrGround(members):
      let ent = bundleEntities(nl, members)
      let union = bundleUnionEntities(nl, members)
      if not anyNonBoxCarrier(union.parts) and ent.uniform and
         collapsible(ent.parts, ent.ported):
        addBundle(key, btInterface, members, brCollapsed,
                  (parts: ent.parts, ported: ent.ported))
        continue
      # A published or 3+-entity interface that fails collapse becomes one
      # net-label bundle over all members; the per-`bus.name` retry is
      # skipped, so no collapsed sub-bus.
      if union.ported or union.parts.len >= 3:
        addBundle(key, btInterface, members, brNetLabel, union)
        continue

    # Retry by `bus.name`, each sub-bus with >= 2 members as `btBus`. Only
    # the < 3-entity, unpublished, non-uniform leftover gets here, where a
    # narrower sub-bus may still be uniform.
    var subOrder: seq[string]
    var subNets = initTable[string, seq[Net]]()
    for n in members:
      let bn = n.attrs.getOrDefault("bus.name")
      if bn.len == 0: continue
      let sk = "bus:" & bn
      if sk notin subNets:
        subOrder.add sk
        subNets[sk] = @[]
      subNets[sk].add n
    for sk in subOrder:
      disposeBus(sk, subNets[sk])

    # An unpublished < 3-entity interface keeps only its `ofNet` colour, so
    # point-to-point sub-buses stay free to collapse.

  result = plan

# --- public reporter -------------------------------------------------------

proc bundleReport*(nl: Netlist): seq[tuple[display, kind, role: string,
                                     members, entities, labels: seq[string],
                                     port: string]] =
  ## Every grouped bundle, for unit tests. `labels` renders each
  ## `brNetLabel` group's tag (`"U1=spi1"`, `"R1="` when unmerged), empty for
  ## other roles. `port` is the pennant text, "" when unpublished.
  let plan = bundlePlan(nl)
  for b in plan.bundles:
    var labels: seq[string]
    for lg in b.labelGroups: labels.add lg.desig & "=" & lg.text
    result.add (display: b.display,
                kind: (if b.tag == btInterface: "interface" else: "bus"),
                role: (case b.role
                       of brScalar: "scalar"
                       of brCollapsed: "collapsed"
                       of brNetLabel: "netlabel"),
                members: b.members,
                entities: b.parts,
                labels: labels,
                port: b.portText)
