## Bus- and interface-aware grouping: a read-only index built once per layout,
## before any symbol is sized.
##
## `netlist/interfaces.nim` lowers every bus and declared interface to scalar
## nets and records membership only in `Net.attrs` (`bus.name`/`bus.index`/
## `bus.width`, `iface.instance`/`iface.def`/`iface.signal`/`iface.shared`/
## `iface.dir`/`iface.nc`). This unit reads those attrs -- **the net attrs, and
## never a pin attr** -- and groups the members so a whole SPI link can draw as
## one thick coloured wire between one merged pin per end instead of N pennants
## and N thin wires.
##
## Why net attrs only, never pin attrs: `promotePortDirections`
## (`interfaces.nim`) copies every `iface.*` key onto instance *pins*, so an
## `iface.nc` open net (`nc_X1_spi_miso`) -- which carries no `iface.instance`
## on the *net* -- would be dragged into the bundle it was explicitly left out
## of if we read pin attrs. Reading the net's own attrs keeps a no-connect out
## by construction: it is simply not a member, the rest still collapse.
##
## Why `findBus`/`findInterface`/`interfacesOf` are forbidden here: they rescan
## every net; `findInterface` raises unless the `InterfaceDef` was registered
## in this process; and `busOf` -- which `addInterfaceRecovery` calls --
## *writes* `bus.index` from table order. Layout must stay read-only, so this
## reads `attrs` directly, the pattern `analysis/io_check.nim` and
## `contract/design.nim` already use.
##
## The plan is a pure function of netlist topology. `recoverRouting`'s
## candidate part moves never rebuild it: which nets group, and how, depends
## only on `attrs`, `nl.ports` identity and the pin graph, none of which a
## placement move touches. A zero-value `BundlePlan` (no net carries
## `iface.instance` or `bus.name`) is the whole byte-identity guarantee for a
## bus-free netlist: every new code path downstream is guarded on a non-empty
## plan.

type
  BundleTag = enum
    btBus, btInterface

  BundleRole = enum
    brScalar     ## fails collapse, non-ported, < 3 component entities: ordinary
                 ## wires, membership colour only
    brCollapsed  ## exactly two endpoint entities, uniform: one merged pin per
                 ## end, one thick wire between them
    brNetLabel   ## fails collapse **and** (published or spanning 3+ component
                 ## entities): grouped net-label tags, no wires -- one merged
                 ## tag per box endpoint carrying >= 2 members, a bare member
                 ## tag elsewhere

  LabelGroup = object
    ## One endpoint's share of a `brNetLabel` bundle: the member pins on one
    ## component, and how their tags merge. A *box* component carrying >= 2
    ## members gets ONE merged pin with one tag (`text`); a component carrying
    ## a single member keeps the bare member label. Populated in
    ## `b.memberPins` desig-first-seen order, which `bundleReport.labels` and
    ## `laneOf`'s linear scan both rely on.
    desig: string
    pins: seq[tuple[pin, net: string]]  ## owned member pins, memberPins order
    members: seq[BundleMember]          ## this group's subset, member order
    merged: bool                        ## >= 2 owned members AND a box carrier
    text: string                        ## "spi1" / "spi1(cs0)"; "" when unmerged

  Bundle = object
    key: string              ## "iface:spi" / "bus:spi1_cs" -- index identity
    display: string          ## the scene net identity ("spi"), guaranteed
                             ## distinct from every `nl.nets` key
    pinName: string          ## the drawn merged pin/port name: "spi[3]"
    tag: BundleTag
    role: BundleRole
    dir: PortDirection       ## the folded member direction
    members: seq[string]     ## member net names, in `nl.nets` order
    parts: seq[string]       ## component-entity designators, sorted
    ported: bool             ## the sheet boundary is one of the entities
    portNames: seq[string]   ## the merged `nl.ports` keys, declared order
    memberPins: seq[tuple[desig, pin, net: string]]
      ## every owned physical pin of every member net, in member then pin
      ## order -- the routing endpoints and the net-label pins
    sceneMembers: seq[BundleMember]
      ## the drawn (signal name, scalar net) pairs -- one per member net, in
      ## member order. This is what a merged `SchematicPin`/`SchematicPort`
      ## carries and what `runFULL.html` expands.
    labelGroups: seq[LabelGroup]
      ## `brNetLabel` only; empty otherwise. One entry per component entity,
      ## in `memberPins` desig-first-seen order.

  BundlePlan = object
    bundles: seq[Bundle]
    ofNet: Table[string, BundleTag]
      ## every membership net -> its kind, for colour. Covers a net whatever
      ## its bundle's role, and a discarded (<2-member) candidate's nets too.
    byNet: Table[string, int]
      ## member net -> bundle index. Only nets that belong to a real Bundle.
    byPin: Table[string, int]
      ## `pinKey(c, pin)` -> bundle index. Collapsed bundles, and the merged
      ## `LabelGroup`s of a `brNetLabel` bundle.
    byPort: Table[string, int]
      ## `nl.ports` key -> bundle index, collapsed bundles only
    bundled: HashSet[string]
      ## designators carrying a collapsed bundle or a merged net-label group

proc wireKindFor(plan: BundlePlan, netName: string): WireKind {.inline.} =
  ## The membership colour for a signal wire on `netName`: purple for an
  ## interface member, blue for a bus member, `wkSignal` otherwise. Colour is
  ## membership and applies to *every* wire whether or not anything collapsed;
  ## thickness (`SchematicWire.members.len > 1`) is what says a wire collapses
  ## more than one net. A zero-value plan colours nothing.
  if not plan.ofNet.hasKey(netName): return wkSignal
  if plan.ofNet[netName] == btInterface: wkInterface else: wkBus

proc laneOf(plan: BundlePlan, bi: int, desig: string):
    tuple[name: string, members: seq[BundleMember]] =
  ## The one source of a merged lane's drawn string and member list, so
  ## `bundleGroupsFor` (box sizing) and `routing.nim`'s part loop (the merged
  ## `SchematicPin`) never disagree -- `boxSlots` sizing `innerW` for
  ## `spi1(cs0)` while `svg` prints `spi1[5]` is the bug this prevents. A
  ## linear scan: `labelGroups.len` is the entity count, no table to keep in
  ## sync. Collapsed bundles are returned unchanged.
  let b = plan.bundles[bi]
  if b.role == brNetLabel:
    for lg in b.labelGroups:
      if lg.desig == desig and lg.merged: return (lg.text, lg.members)
  (b.pinName, b.sceneMembers)

proc bundleGroupsFor(plan: BundlePlan, c: Component):
    tuple[groupOf, groupSide: seq[int], groupNames: seq[string]] =
  ## The per-pin partition `boxSlots` needs for `c` when it carries one or
  ## more collapsed bundles, or the merged group of a net-label bundle:
  ## `groupOf[i]` a local group id for a member pin, `-1` for an ordinary
  ## pin. `groupSide` is derived from the folded member direction -- an
  ## input/unspecified bundle takes the left column, an output/bidirectional
  ## one the right, matching where its port pennant sits. Returns three empty
  ## seqs when `c` carries none, so `prepare` passes the historical
  ## `boxSlots` path unchanged.
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
  ## `uniform` is the collapse precondition: every member must touch the *same*
  ## entity set, so one merged pin per end really carries the whole bundle.
  ## Ported-ness is tested by `Net` object identity against `nl.ports` values,
  ## never by name.
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
  parts.len + (if ported: 1 else: 0) == 2

proc bundleUnionEntities(nl: Netlist, members: seq[Net]):
    tuple[parts: seq[string], ported: bool] =
  ## Every distinct component entity any member touches, plus whether any
  ## member is published. Used to decide net-label degradation, which is about
  ## the drawn mess of N thin wires among the *union* of endpoints, not one
  ## member's.
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
  ## The signal a member belongs to: `iface.signal` for an interface member,
  ## else `bus.name`. Never `iface.instance` -- a group text names *which
  ## signals* a component carries, not which interface.
  let s = n.attrs.getOrDefault("iface.signal")
  if s.len > 0: s else: n.attrs.getOrDefault("bus.name")

proc groupText(b: Bundle, owned, allMembers: seq[Net]): string =
  ## The tag on a merged net-label pin. `owned` is this component's member
  ## subset, `allMembers` the bundle's, both in bundle-member order.
  ##
  ## "Full" for a signal is computed from the bundle's own members, **never**
  ## `bus.width`: `busOf` (which interface recovery runs) rewrites
  ## `bus.index`/`bus.width` from table order, so `findBus` is forbidden here
  ## and the width it would report is not trustworthy anyway.
  ##
  ## Cases: whole interface -> `spi1`; a coherent slice -> `spi1(cs0)`; a
  ## two-wire tap -> `spi1(sclk, mosi)`; a CS-only analyzer -> `spi1(cs)`;
  ## a `bus dq` carrying bits 0 and 3 -> `dq(0, 3)`; all 8 -> `dq`.
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
  ## One pass over `nl.nets` in insertion order. Returns a zero-value plan the
  ## moment no net carries `iface.instance` or `bus.name`.
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
    ## The signal-level name of a member: the interface signal (with a bus
    ## index when the signal is wide), or the bare member net name for a
    ## plain bus. `connectPort` never emits `[`, so `pinName` (this plus the
    ## width) cannot collide with a real pin name.
    let sig = n.attrs.getOrDefault("iface.signal")
    if sig.len == 0: return n.name
    let w = n.attrs.getOrDefault("bus.width", "1")
    if w != "1": sig & "_" & n.attrs.getOrDefault("bus.index", "0") else: sig

  proc naturalName(key: string, tag: BundleTag): string =
    if tag == btInterface: key["iface:".len .. ^1]
    else: key["bus:".len .. ^1]

  var usedDisplays = initHashSet[string]()
  proc uniqueDisplay(natural: string, tag: BundleTag): string =
    ## `SchematicWire.net`, `SchematicPort.net`, the merged `SchematicPin.net`
    ## and `diagnostics.sceneRouterInputs` all key on this, so it must not
    ## collide with an authored net name or another bundle's display -- two
    ## scene entities sharing one occupancy tag is an invisible failure.
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
    b.pinName = b.display & "[" & $members.len & "]"
    for portName, pn in nl.ports:
      for n in members:
        if pn == n and portName notin b.portNames: b.portNames.add portName
    for n in members:
      b.sceneMembers.add BundleMember(name: memberLabel(n), net: n.name)
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
      for pn in b.portNames:
        plan.byPort[pn] = idx
      for d in b.parts: plan.bundled.incl d
    elif role == brNetLabel:
      # Merged groups only: `symbolFor`'s lane merge and `routing`'s merged
      # `SchematicPin` both key on `byPin`, and an unmerged (single-member, or
      # two-terminal) carrier must keep its bare per-pin tag.
      for lg in b.labelGroups:
        if not lg.merged: continue
        plan.bundled.incl lg.desig
        for pr in lg.pins:
          plan.byPin[pinKey(nl.components[lg.desig], pr.pin)] = idx

  proc disposeBus(key: string, members: seq[Net]) =
    ## A `btBus` candidate (no further retry): collapse if eligible, else
    ## net-label if ported **or spanning 3+ component entities**, else scalar
    ## recolour, else -- below two members -- discard (the `ofNet` colour still
    ## applies).
    ##
    ## The `>= 3` arm is the shared-bus rule: `union.parts` holds component
    ## designators only (the `p.component.netlist == nl` guard), never the
    ## sheet boundary, so three-plus *components* fanning off one bus draw as
    ## grouped net-label tags -- the conventional schematic -- rather than a
    ## nest of N recoloured wires. Collapse is still tested first, so a
    ## two-endpoint bus is unaffected.
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
      # A published interface, or one fanning to 3+ component entities, that
      # fails collapse becomes ONE net-label bundle over *all* its member
      # nets -- the per-`bus.name` retry is skipped entirely. The trade,
      # stated in `schematic/CLAUDE.md`: a >= 3-entity interface no longer
      # gets a collapsed sub-bus (e.g. `spiSharedBusSheet` loses its
      # `bus:spi1_cs` sub-bundle -- it is claimed by `iface:spi1`).
      if union.ported or union.parts.len >= 3:
        addBundle(key, btInterface, members, brNetLabel, union)
        continue

    # Retry: re-split by the members' recorded `bus.name` (`addInterface`
    # always sets it). Each sub-bus with >= 2 members re-runs as `btBus`.
    # Reached only for the < 3-entity, non-ported, non-uniform leftover,
    # where a wide sub-bus can still collapse point-to-point.
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

    # The old trailing "dispose the interface-level candidate when ported"
    # block is gone: a ported interface (and any >= 3-entity one) is now
    # claimed as `brNetLabel` in the main branch above and never reaches the
    # retry, so that block could only ever add a duplicate. An unpublished
    # < 3-entity interface still falls through to `ofNet` colour and nothing
    # else -- what keeps a genuinely point-to-point sub-bus free to collapse.

  result = plan

# --- public reporter -------------------------------------------------------

proc bundleReport*(nl: Netlist): seq[tuple[display, kind, role: string,
                                     members, entities, labels: seq[string]]] =
  ## Every grouped bundle, so "does `spi1_cs` collapse?" is a one-line unit
  ## test instead of an inference from geometry. A netlist with no bus or
  ## interface net attrs yields an empty report. `labels` renders each
  ## `brNetLabel` group's merged tag as `"U1=spi1"` / `"X1=spi1(cs0)"` /
  ## `"R1="` (empty for an unmerged carrier), in `labelGroups` order; it is
  ## empty for every other role.
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
                labels: labels)
