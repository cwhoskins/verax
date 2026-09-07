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
    brScalar     ## fails collapse, non-ported (or a <2-entity candidate):
                 ## ordinary wires, membership colour only
    brCollapsed  ## exactly two endpoint entities, uniform: one merged pin per
                 ## end, one thick wire between them
    brNetLabel   ## ported and fails collapse: a deliberate net-label tag at
                 ## every member pin, no wires

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

  BundlePlan = object
    bundles: seq[Bundle]
    ofNet: Table[string, BundleTag]
      ## every membership net -> its kind, for colour. Covers a net whatever
      ## its bundle's role, and a discarded (<2-member) candidate's nets too.
    byNet: Table[string, int]
      ## member net -> bundle index. Only nets that belong to a real Bundle.
    byPin: Table[string, int]
      ## `pinKey(c, pin)` -> bundle index, collapsed bundles only
    byPort: Table[string, int]
      ## `nl.ports` key -> bundle index, collapsed bundles only
    bundled: HashSet[string]
      ## designators carrying any collapsed bundle

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
      for p in n.pins:
        if p.component != nil and p.component.netlist == nl:
          b.memberPins.add (p.component.designator, p.name, n.name)
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

  proc disposeBus(key: string, members: seq[Net]) =
    ## A `btBus` candidate (no further retry): collapse if eligible, else
    ## net-label if ported, else scalar recolour, else -- below two members --
    ## discard (the `ofNet` colour still applies).
    if members.len < 2 or anyRailOrGround(members): return
    let ent = bundleEntities(nl, members)
    let union = bundleUnionEntities(nl, members)
    if not anyNonBoxCarrier(union.parts) and ent.uniform and
       collapsible(ent.parts, ent.ported):
      addBundle(key, btBus, members, brCollapsed,
                (parts: ent.parts, ported: ent.ported))
    elif union.ported:
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

    # Retry: re-split by the members' recorded `bus.name` (`addInterface`
    # always sets it). Each sub-bus with >= 2 members re-runs as `btBus`.
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
    var claimedAny = false
    for sk in subOrder:
      let before = plan.bundles.len
      disposeBus(sk, subNets[sk])
      if plan.bundles.len > before: claimedAny = true

    # After a fruitless retry the interface-level candidate is disposed only
    # when it is ported -- net-label degradation additionally needs a port,
    # which is what keeps `designs/i2c_eeprom.nim` (an unpublished interface)
    # byte-identical: its members fall to `ofNet` colour and nothing else.
    if not claimedAny and members.len >= 2 and not anyRailOrGround(members):
      let union = bundleUnionEntities(nl, members)
      if union.ported:
        addBundle(key, btInterface, members, brNetLabel, union)

  result = plan

# --- public reporter -------------------------------------------------------

proc bundleReport*(nl: Netlist): seq[tuple[display, kind, role: string,
                                           members, entities: seq[string]]] =
  ## Every grouped bundle, so "does `spi1_cs` collapse?" is a one-line unit
  ## test instead of an inference from geometry. A netlist with no bus or
  ## interface net attrs -- and `designs/i2c_eeprom.nim`, whose interface is
  ## instantiated but never published -- yields an empty report.
  let plan = bundlePlan(nl)
  for b in plan.bundles:
    result.add (display: b.display,
                kind: (if b.tag == btInterface: "interface" else: "bus"),
                role: (case b.role
                       of brScalar: "scalar"
                       of brCollapsed: "collapsed"
                       of brNetLabel: "netlabel"),
                members: b.members,
                entities: b.parts)
