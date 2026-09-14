## Repeated-part grouping: a read-only index built once per layout, after
## the bundle plan and before any symbol is sized.
##
## Two passes share this module and its plumbing. The first
## (`buildSubsheetArrays`) groups **subsheet** instances -- when one
## subcircuit is instantiated three or more times, drawing each instance as
## its own fallback box gives the reader no help seeing that they are one
## sheet built N times. The second (`buildComponentArrays`) does the same for
## repeated **raw components**: eight identical 50-ohm terminations on eight
## RF channels draw as eight symbols and their fan of wires today, with
## nothing telling the reader they are one circuit repeated eight times. Per
## the user's decision, component grouping is **per component, not per
## motif**: an 8x(R+C) filter bank draws as one `R x8` and one `C x8`, never
## one merged "filter x8" glyph -- the two are different parts and a reader
## must still be able to ask "which resistor is this" independently of "which
## capacitor is this".
##
## Both passes build `PartArray`s the identical way (`classifyGroup`): the
## sub-grouping split, the four port classes, chain pairing, display/tag
## allocation. What differs is candidacy (a subsheet instance vs. a raw
## component sharing kind/value/pins) and one extra decline for a component
## group (`the all-common decline`, below).
##
## **The collapse floor is three members, with one deliberately narrow
## exception at two**: a raw-component group every one of whose ports
## genuinely shares both nets across every member -- a true parallel bank --
## *and* those shared nets are a rail/ground pair collapses at two (the
## bypass-bank floor, in `addSignatureArrays`). Two same-signature parts
## wired any other way (in series, or in parallel on an ordinary signal net)
## keep the three-member floor: two same-valued resistors that merely happen
## to sit in unrelated roles of one circuit (a divider's `R1`/`R2`) must not
## silently merge into one box just because their `value` matches -- only a
## group that is unambiguously *one repeated thing wired the same way*
## qualifies below three.
##
## The plan is a pure function of the netlist and the bundle plan. It reads
## `Component.subNetlist` identity, `Component.kind`/`value`/`partNumber`/
## `name`, pin structure, and the instance pins' parent nets (`Pin.net`); it
## never mutates. `recoverRouting`'s candidate part moves never rebuild it. A
## zero-value `ArrayPlan` (no subsheet has >= 3 instances, and no raw
## component either) is the whole byte-identity guarantee: every downstream
## code path is guarded on a non-empty plan.
##
## Precedence with `bundles.nim`: **the bundle wins at the pin, the array wins
## at the box.** An array declines to collapse only when a member carries a
## `brCollapsed` bundle (whose far endpoint would vanish); a `brNetLabel` /
## `brScalar` bundle degrades cleanly over hidden members, so the array still
## collapses and that port is marked `bundled` -- classified for the report but
## drawn entirely by the bundle plan.
##
## **The identity key for a component candidate** is
## `kind \x1f value \x1f partNumber \x1f name \x1f <pin names> \x1f <pin kinds>`.
## `value` is in the key deliberately: the collapsed symbol shows one value, so
## a 10k and a 2k bank must never merge. Other attrs (`package`, `dielectric`,
## `voltage_rating`, ...) are **not** in the key -- they do not change the
## drawing, and keying on them would fragment a group for no visual gain; the
## explorer's member list already expands them. **A component with *neither* a
## stated value nor a part number excludes it from candidacy outright**,
## checked before the key is even built: the collapsed symbol shows one
## value, and a blank one asserts nothing about the N real parts it stands
## for. Every worked example states one or the other (`xbar_rf`'s termination
## resistors state `value`; its SMA connectors and ADG904 switches carry no
## `value` at all but state `partNumber` -- a part identified by what it *is*
## rather than what it measures is just as real an identity); a bare topology
## fixture that states neither is not modelling a real part, and without this
## guard three same-kind, same-pin-shape parts wired for an unrelated purpose
## collapse into a phantom array the moment they share two empty strings --
## which is exactly what several of this repository's pre-existing
## placement/routing stress fixtures (many identical resistors in a chain or
## star, none of them stating a value or a part number because none of them
## are testing this feature) turned out to do.
##
## **The all-common decline** keeps a component group whose ports are all
## `apCommon` out of this feature *unless* the shared nets are all rail/
## ground -- a candidate group must have at least one port classified
## `apDistributed`, or every port must be `apCommon` **and** `railCommon`
## (`ArrayPort.railCommon`), or it is dropped. The second clause is
## deliberately narrow: it is exactly a bypass bank -- two or more identical
## decoupling/bulk capacitors sharing one rail/ground pair -- and nothing
## else, so `xbar_rf`'s eight `CBY*` caps on `(v3v3rf, gnd)` now collapse to
## one badged symbol the same way a repeated resistor bank does. A component
## group with no distributed port and *not* a pure rail/ground bank (an
## all-common group sharing an ordinary signal net, however that would
## arise) still declines: `composites/passive.parallelStackKind` already
## draws that shape, and stealing it would hide the count behind an `xN`
## badge instead of the composite's own visible members. (A port classified
## `apDistributed` can never itself be a rail -- the classifier routes a
## rail-differing port to `apIrregular` first -- so the first clause reads
## simply as "not every port is common", no separate rail carve-out needed.)
##
## **Chain pairing is skipped for a non-box representative.** The
## recirculation arc is a fixed staple drawn on the *box interior*
## (`routing.nim:705-748`); a resistor symbol has no interior to draw one on.
## A series ladder of raw components therefore degrades to *distributed*, the
## honest drawing -- gated on the same box predicate `symbolFor` uses, since
## `symbols.nim` is spliced before this file.
##
## **A net distributed at both ends** (`groupOf`/`suppressed`, below) is the
## one genuinely new failure mode per-component grouping introduces. The
## subsheet-only pass never had a distributed net with two array endpoints;
## `8x(R+C)` gives `in_i -[R_i]- mid_i -[C_i]- gnd`, and every `mid_i` sits on
## the R array's port 2 **and** the C array's port 1. Writing `suppressed`
## per-array (as the subsheet-only pass safely could, since a net was never
## claimed twice) is wrong here: the two arrays enumerate their members in
## independent orders (`nl.components` insertion order need not align R with
## C), so the two per-array writes can suppress overlapping-but-different
## subsets of the eight `mid_i` nets -- in the worst case suppressing every
## one, so the bus never routes, and the totality assertion does not catch it
## because every net is still accounted for (just unroutable). The fix:
## `finalizeArrayPlan` derives `suppressed` from the *final* `groupOf` (after
## every array that could claim a net has registered), bucketing nets by their
## `(array, port)` value and suppressing every member except the one that
## comes first in `nl.nets` order -- well-defined regardless of which array
## ends up owning the group.
##
## **A distributed port's members are declared members of one bus or
## interface, not merely N distinct nets.** `subGroupsOf`'s split key
## (`splitKeyOf`) reads `iface.instance` then `bus.name` off each bound net,
## falling back to the net's own name only when neither is present --
## because a port bound to N *distinct* nets never repeats a raw value, so
## identity-only counting cannot see the split a declared bus makes obvious:
## `xbar_rf`'s eight `rf_switch` instances bind `RFC` to `rin[0..3]` on four
## of them and `rout[0..3]` on the other four, sharing no net at all, yet the
## input/output boundary is exactly the two `x4` groups a reader expects, not
## one nonsensical `x8`. The same family name is also what a *bundled*
## distributed pin draws once collapsed (`ArrayPort.bundleFamily`,
## `arrayPinFor`, `arrayBundleLabelFor` in `routing.nim`): the representative
## alone binds one specific member (`rin_0`), but the collapsed box stands for
## every hidden member's binding on that bus, so its identity is the bus
## itself ("rin"), not the one index the representative happened to keep.

type
  ArrayOrigin = enum
    aoSubsheet     ## a subcircuit instantiated three or more times
    aoComponent    ## a raw (non-hierarchical) component repeated two or
                   ## more times, sharing kind/value/partNumber/name/pins

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
    bundled: bool              ## this port's nets are members of some
                               ## bus/interface bundle (reporting fact only --
                               ## see `mergedByBundle` for who actually draws)
    mergedByBundle: bool       ## apDistributed only: the bundle already
                               ## merges a pin at this representative for this
                               ## port -- a `brCollapsed` bundle, a
                               ## `brNetLabel` `LabelGroup` with >= 2 owned
                               ## members here (`bundles.byPin`), **or** a
                               ## bundle that merges a pin *anywhere at all*
                               ## (`ArrayBuildCtx.mixedMergeBundle`: `xbar_rf`'s
                               ## `a` bus merges `A0`+`A1` on every switch but
                               ## not on its lone-member pulldowns, so no
                               ## coherent single tag is left for a bus tree to
                               ## reuse -- every carrier defers). A `bundled`
                               ## port that is not merged *anywhere on its
                               ## bundle* (one member per carrier throughout,
                               ## e.g. `xbar_rf`'s `rin`/`rout`/`en`) is drawn
                               ## and routed by the array instead, reusing the
                               ## bundle's own occupancy tag so both sides
                               ## (and any other array sharing the same bus)
                               ## agree on one wire.
    display: string            ## scene/occupancy tag; "" for apCommon. For a
                               ## `bundled`, non-`mergedByBundle` port this is
                               ## the *bundle's own* `Bundle.display`, not a
                               ## freshly allocated one -- see `mergedByBundle`
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
    railCommon: bool           ## apCommon only: the shared net is ground/rail,
                               ## so `pmBusBar` is suppressed here -- a pin
                               ## that already draws a ground/supply glyph
                               ## says "shared rail" on its own, and on a
                               ## two-terminal symbol the tick and the glyph
                               ## bars would collide (see `arrayPinFor`)
    bundleFamily: string       ## apDistributed + bundled only: the plain
                               ## bus/interface-instance name behind this
                               ## port (`splitKeyOf` of the first bound
                               ## member's net) -- "rin", not "rin_0". "" when
                               ## `not bundled`. `arrayPinFor` reads this for
                               ## a `mergedByBundle` port instead of falling
                               ## through to the representative's own raw
                               ## net: once a whole array collapses to one
                               ## box, that box stands for every member's
                               ## binding on this bus, and one member's
                               ## specific index is no longer the box's
                               ## identity, the bus itself is.

  PartArray = object
    key: string                ## "<subNetlist.name|kind>\x1f<...>\x1f<sub>",
                               ## the first `\x1f`-field is `arrayReport`'s
                               ## `source` (a subckt name or a component kind)
    origin: ArrayOrigin
    members: seq[string]       ## designators, graph insertion order
    rep: string                ## members[0] -- the one drawn box/symbol
    label: string              ## "X1..X8"
    ports: seq[ArrayPort]      ## one per subsheet port / component pin, pin
                               ## declaration order

  ArrayPlan = object
    arrays: seq[PartArray]
    byRep: Table[string, int]              ## representative designator -> array
    hidden: HashSet[string]                ## the N-1 designators prepare drops
    portOfPin: Table[string, tuple[a, p: int]]  ## pinKey(rep, pin) -> port
    suppressed: HashSet[string]            ## nets that must not route at all
                                           ## (chain links; distributed members
                                           ## after the first)
    groupOf: Table[string, tuple[a, p: int]]  ## distributed member net -> port
    extraPins: Table[string, seq[tuple[desig, pin: string, outward: bool]]]
                                           ## chain head/tail re-homed onto the
                                           ## representative; `outward` is true
                                           ## only for the tail entry -- the
                                           ## array's real external output,
                                           ## physically on the hidden last
                                           ## member -- so a consumer that
                                           ## cares about signal direction
                                           ## (`constrained.nim`'s semantic
                                           ## layering) does not have to ask a
                                           ## positional instance pin, which is
                                           ## always `ptUnknown`
    arrayNets: HashSet[string]             ## what finish skips in the net-name
                                           ## pass (drawn group members + tags)

proc isOpenBind(x: Net): bool {.inline.} =
  ## An instance pin that binds nothing, or an explicit no-connect
  ## (`instantiateByPortOpen`'s `nc_<inst>_<port>` net) -- both read as "this
  ## member leaves the port open" for array classification.
  x == nil or x.attrs.getOrDefault("iface.nc") == "1"

proc netNameOf(x: Net): string {.inline.} =
  (if x != nil and not isOpenBind(x): x.name else: "")

proc splitKeyOf(x: Net): string {.inline.} =
  ## The value `subGroupsOf` counts when hunting for a splitting port. Two
  ## members binding the *same* net share it trivially (raw identity, the
  ## historical behaviour); two members whose nets are *distinct* declared
  ## members of the same bus or interface instance must ALSO be found to
  ## share it, since that is precisely the "different halves of one family"
  ## signal a reader sees at a glance and raw identity is blind to: eight
  ## `rf_switch` instances whose `RFC` pin binds `rin[0..3]` on four of them
  ## and `rout[0..3]` on the other four never share a single net (`counts.len
  ## == n` fails the old "some value repeats" test outright), yet the split
  ## is exactly the input/output boundary the schematic must draw as two
  ## `x4` groups, not one `x8`.
  ## `iface.instance` is checked before `bus.name`, matching
  ## `bundles.nim`'s own "iface.instance wins, else bus.name" precedence:
  ## `bus.name` alone is the bare *signal* name (e.g. "cs"), identical across
  ## every instance of a declared interface, so keying on it first would fold
  ## every instance's same-named signal into one family and undo exactly the
  ## split `spi_memories`' three controllers need. Falls back to the net's
  ## own name -- today's behaviour -- when neither attr is present, so two
  ## genuinely unrelated distinct nets still fail the "repeated value" test
  ## exactly as before.
  if x == nil: ""
  else:
    let inst = x.attrs.getOrDefault("iface.instance", "")
    if inst.len > 0: inst
    else: x.attrs.getOrDefault("bus.name", x.name)

# --- shared build context (both passes) ------------------------------------

type
  ArrayBuildCtx = object
    usedDisplays: HashSet[string]
      ## Every display tag already spoken for -- by a bundle, or by an
      ## earlier-registered array of *either* origin. Shared across both
      ## passes so `buildComponentArrays` never allocates a display the
      ## subsheet pass already gave out (and vice versa were the order ever
      ## reversed).
    mixedMergeBundle: HashSet[int]
      ## Index (into `BundlePlan.bundles`) of every `brNetLabel` bundle with
      ## at least one merged `LabelGroup` -- `xbar_rf`'s `a` bus, where every
      ## switch merges its own `A0`+`A1` but every pulldown resistor owns
      ## just one member. `ap.mergedByBundle` (`classifyGroup`) treats every
      ## port on such a bundle as bundle-owned, even one whose OWN
      ## representative merges nothing (the pulldowns' `"1"` port): a bundle
      ## drawn as a mix of merged tags and real wires between different
      ## carriers of the *same* members has no coherent single occupancy tag
      ## left for a bus tree to reuse, so the array must defer to it
      ## wholesale rather than only at the carriers that happen to merge.

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
  ## A `brCollapsed` bundle is a bus tree between its endpoint entities;
  ## hiding members down to fewer than two surviving entities deletes its far
  ## end, so that is the only decline this checks -- shared verbatim by both
  ## passes. Unlike the old blanket "any member of this whole candidate
  ## touches *some* collapsed bundle" rule, this is evaluated per sub-group
  ## (`g` from `subGroupsOf`, via its own `candidateHidden` -- the members
  ## that sub-group would hide) against every `brCollapsed` bundle, so a
  ## bundle that keeps two or more of its own entities placeable after this
  ## group's members disappear does not veto it. `xbar_rf`'s two `rf_switch
  ## x4` groups each hide three of the eight switches carrying the (now
  ## collapsible) `m` bus -- five, then two, switches remain on it, so both
  ## groups still collapse.
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
  # `used` is threaded explicitly rather than closed over: a nested proc may
  # not capture a `var` *parameter* of its enclosing proc (only a local var),
  # since that parameter is a hidden pointer with no lifetime guarantee past
  # the call -- Nim rejects it outright ("cannot be captured as it would
  # violate memory safety").
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

proc subGroupsOf(n: int, portNames: seq[string], binding: seq[seq[Net]]):
    seq[seq[int]] =
  ## Splits `0 ..< n` member indices by every *splitting* port -- one whose
  ## nets partition the members into 2+ groups each of size >= 2, with no
  ## member left open -- before classification, so `spi_memories`'s nine
  ## memories draw as three `x3` boxes instead of one nonsensical `x9`, and
  ## `xbar_rf`'s eight `rf_switch` instances draw as an input `x4` and an
  ## output `x4` rather than one `x8`. A singleton group (a member differing
  ## from everyone) is left alone: it is the irregular signal, not a
  ## sub-array boundary.
  ##
  ## The partition key is `splitKeyOf`, not raw net identity: a port bound to
  ## N *distinct* nets (every member on its own wire) never repeats a value,
  ## so raw-identity counting is blind to a split that exists only through
  ## declared bus/interface membership (`rin[0..3]` vs `rout[0..3]`) -- see
  ## `splitKeyOf`'s comment. A port with no such attrs on either side counts
  ## by net name exactly as before.
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
  ## Builds one `PartArray` for the sub-group `g` (indices into `members`):
  ## per-port classification, chain pairing (skipped when `allowChain` is
  ## false), and display/tag allocation. Shared verbatim by both passes --
  ## the only difference between a subsheet array and a component array is
  ## candidacy (what counts as a "member") and `allowChain`, decided by the
  ## caller. Registration into the plan (`registerArray`) is a separate step,
  ## also shared, so a caller can veto a built group (the all-common decline)
  ## before it is ever wired in.
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
        # First bound member sets the family and every later one is left
        # alone: `subGroupsOf` already split this array apart on any port
        # whose family value disagreed enough to partition evenly, so within
        # one final sub-group every member's family is expected to agree --
        # the first is as good a witness as any.
        if ap.bundleFamily.len == 0: ap.bundleFamily = splitKeyOf(x)
    # The bundle merges a pin here iff it already claims THIS representative
    # pin (`bundles.byPin`) -- true for a `brCollapsed` bundle (every member
    # pin registered) or a `brNetLabel` `LabelGroup` merging >= 2 owned
    # members on this carrier (e.g. `xbar_rf`'s `a` bus: `A0`+`A1` both land
    # on one switch) -- **or** iff the bundle merges a pin *anywhere at all*
    # (`ctx.mixedMergeBundle`): a bundle that merges on one carrier (a
    # switch's `A0`+`A1`) but not on another sharing the very same members
    # (a pulldown's lone `"1"`) has no single occupancy tag left that a bus
    # tree could reuse coherently, so every carrier defers to the bundle
    # wholesale rather than only the ones that individually merge. A
    # `bundled` port that owns only one member per carrier, on a bundle that
    # never merges anywhere (`rin`/`rout`/`en`), is drawn/routed by the array
    # instead.
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
  # wins -- skipped entirely for a non-box representative (`allowChain`
  # false): the recirculation arc is drawn on the box interior, which a
  # two-terminal symbol has none of, so a would-be chain is left classified
  # `apDistributed`, the honest drawing for a repeated raw component.
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

  # Parallel chains (a pass-through-strapped SPI bus: sclk, cs and data all
  # walking the same members in the same order) draw as ONE arc, so the box
  # does not sprout three near-identical loops. The first OUT half of each
  # `chainKey` group leads; the rest point at it.
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
        # Not merged anywhere -- the array draws and routes this port itself,
        # but reusing the bundle's OWN occupancy tag (never a fresh one) is
        # what lets this array's route, the port pennant already folded by
        # `bundles.byPort`, and -- when the same bus is distributed across
        # more than one array (`xbar_rf`'s `rin`: a `connector x4` on one end,
        # an `rf_switch x4` on the other) -- the OTHER array's own route all
        # agree on one wire under one name, with no cross-array coordination
        # needed: whichever array's `plan.groupOf` write is registered last
        # is the one `arrayRouteFor` honours, and every competing array's own
        # `display` is identical anyway.
        let bi = bundles.byNet.getOrDefault(sub.ports[pi].nets[0], -1)
        if bi >= 0: sub.ports[pi].display = bundles.bundles[bi].display
      if sub.ports[pi].display.len == 0:
        sub.ports[pi].display = uniqueDisplay(ctx, nl, sub.ports[pi].name)
      # A `bundled` port's drawn tag is the one visible label this pin ever
      # gets -- the true net-name pass skips every net in `arrayNets`
      # (`finish.nim`), so a bare pin name here is not merely cosmetically
      # redundant with `display`, it is the ONLY text a reader sees. Two
      # bundles that happen to share a pin name on their originating
      # component (`xbar_rf`'s `rin`/`rout`: both SMA connectors call their
      # pin "RF") would otherwise draw the identical tag "RF[1:4]" on both
      # boxes despite being electrically distinct buses. Use the bundle's own
      # resolved `display` (already disambiguated against `nl.nets`, see
      # above) instead of the coincidental pin name whenever one is bound;
      # an unbundled distributed port (no declared bus/interface) keeps the
      # historical pin-name tag, e.g. `chainSheet`'s "tap[1:4]".
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
  ## Wires a built `PartArray` into the plan: `byRep`/`hidden`/`portOfPin`,
  ## `groupOf`/`arrayNets` for a distributed port, `suppressed`/`extraPins`
  ## for a chained one. Shared by both passes, called only for a group the
  ## caller has already decided belongs (the all-common decline runs before
  ## this, in the caller).
  ##
  ## Deliberately does **not** suppress a distributed port's members here --
  ## that decision needs the *final* `groupOf` (see `finalizeArrayPlan`), so
  ## writing it per-array is exactly the both-ends-distributed bug this
  ## module's doc comment describes. Chain-link suppression has no such
  ## hazard (a link net is wholly internal to one subsheet array, which is
  ## the only origin that ever builds a chain) and is written immediately.
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
  ## Sub-groups one candidate signature's members, classifies each sub-group
  ## of >= 3 (or, for a component group whose members genuinely share *both*
  ## nets -- a true parallel bank, see the bypass-bank floor below -- >= 2),
  ## and registers every one that survives the collapsed-bundle decline
  ## (`survivesCollapsedBundles`) and, for a component group only, the
  ## all-common decline (a subsheet array has no such veto, since a repeated
  ## subcircuit is a design decision, not an inferred visual motif).
  for gi, g in subGroupsOf(members.len, portNames, binding):
    if g.len < 2: continue
    var hidden: seq[string]
    for i in 1 ..< g.len: hidden.add members[g[i]]
    if not survivesCollapsedBundles(bundles, plan.hidden, hidden): continue
    let sub = classifyGroup(ctx, nl, sig, gi, members, g, portNames, binding,
                            bundles, rep0, origin, allowChain)
    if origin == aoComponent:
      var anyDistributed = false
      var allCommonRail = sub.ports.len > 0
      for ap in sub.ports:
        if ap.cls == apDistributed: anyDistributed = true
        if ap.cls != apCommon or not ap.railCommon: allCommonRail = false
      # The bypass-bank floor: a group every one of whose ports is `apCommon`
      # *and* `railCommon` genuinely shares both nets across every member --
      # a decoupling/bulk-cap bank on one rail/ground pair, and nothing else
      # can be, since two members merely wired the *same way* to *different*
      # nets (an ordinary divider's same-valued resistors, wired in series
      # rather than in parallel) read as `apDistributed`/`apIrregular`
      # instead. That is exactly the bundling this feature is now asked to
      # draw, so it alone is allowed at two members. The all-common decline
      # (below) still applies to any other all-common group -- a component
      # with no distributed port that is *not* a pure bypass bank -- and the
      # general case (an `apDistributed` port, `xbar_rf`'s eight-channel
      # filter bank) keeps its historical three-member floor: a coincidence
      # of two same-valued parts wired into unrelated roles (two resistors of
      # a divider) must not silently merge into one box.
      if allCommonRail: discard
      elif g.len < 3 or not anyDistributed: continue
    elif g.len < 3: continue
    registerArray(nl, plan, sub)

proc finalizeArrayPlan(nl: Netlist, bundles: BundlePlan, plan: var ArrayPlan) =
  ## Two jobs, both requiring every array that will ever claim a net to have
  ## already registered: derive `suppressed` for every distributed group from
  ## the *final* `groupOf` (the both-ends-distributed fix, see this module's
  ## doc comment), then run the totality assertion over the complete plan.
  ## Called exactly **once**, by a caller that runs `buildSubsheetArrays`
  ## and/or `buildComponentArrays` first (`arrayReport`, `state.prepare` --
  ## either builder alone, standalone, is a valid plan to finalize) -- never
  ## twice on the same `ArrayPlan` value, since a
  ## stale suppression decision from an earlier finalize could survive
  ## alongside a fresh one for the same net once a later pass reassigns that
  ## net's `groupOf` entry to a different array (`suppressed` only ever
  ## grows: nothing un-suppresses a net the first finalize wrongly kept in).
  var bucketFirst = initTable[tuple[a, p: int], string]()
  for name, _ in nl.nets:
    if plan.groupOf.hasKey(name):
      let key = plan.groupOf[name]
      if key notin bucketFirst: bucketFirst[key] = name
  for name, key in plan.groupOf:
    if bucketFirst[key] != name: plan.suppressed.incl name

  # Totality: every distinct net named by a hidden member's pin must be
  # accounted for -- suppressed, drawn by a group, still on the
  # representative's own pin (common / irregular / chain head-tail), or on
  # an irregular port. A net every pin of which is on a hidden member and
  # is in none of these would vanish with no marker.
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
  ## Repeated-**subsheet** groups: one pass over `nl.components` in insertion
  ## order, adding to `plan` in place. A no-op the moment no subsheet has
  ## three or more instances. Deliberately does not derive `suppressed` or
  ## run the totality assertion -- `finalizeArrayPlan` is the caller's job,
  ## run once after every enabled pass (this one, `buildComponentArrays`, or
  ## both) has registered its arrays; see this module's doc comment for why
  ## finalizing per-pass is the both-ends-distributed bug.
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
  ## Repeated **raw component** groups, added to `plan` in place: eight
  ## identical terminations, an eight-channel filter bank's resistor rank or
  ## capacitor rank, and so on. Must run against the same *unfinalized* `plan`
  ## `buildSubsheetArrays` left (or a zero-value one, standalone) -- see
  ## `buildSubsheetArrays`'s doc comment on why finalizing runs once, by the
  ## caller, after both builders.
  var ctx = initArrayBuildCtx(nl, bundles, plan)

  var sigOrder: seq[string]
  var sigMembers = initTable[string, seq[string]]()
  for _, c in nl.components:
    if c.subNetlist != nil: continue          # the subsheet pass owns those
    if isPackaged(c): continue                # a section already has "U10A"
    let value = c.attrs.getOrDefault("value", "")
    # A component with *neither* a stated value nor a part number is excluded
    # from candidacy entirely, not merely one whose value fails to match: the
    # collapsed symbol shows one value, and a blank one asserts nothing about
    # the N real parts it stands for -- worse than not collapsing. Every part
    # that draws as a symbol with a printed value (a resistor, a capacitor)
    # states one; a part identified instead by what it *is* (`xbar_rf`'s
    # `kind = "connector", partNumber = "SMA-50"` SMA edges and
    # `kind = "rf_switch", partNumber = "ADG904"` switches carry no `value`
    # at all) states a part number instead, which is just as much a real
    # identity as a value is. A bare topology fixture that states neither
    # (this schematic test file's own
    # `starNet`/`resistorChain`/`parallelPairChain`/`portedSubckt`, none of
    # which are testing this feature) is not modelling a real part, and
    # without this guard dozens of same-kind, same-pin-shape resistors wired
    # for an unrelated placement/routing property would silently collapse
    # into a phantom array the moment three of them shared two empty strings.
    if value.len == 0 and c.partNumber.len == 0: continue
    var keys, kinds: seq[string]
    for pn, p in c.pins:
      keys.add pn
      kinds.add $p.kind
    if keys.len == 0: continue
    let sig = c.kind & "\x1f" & value & "\x1f" &
              c.partNumber & "\x1f" & c.name & "\x1f" & keys.join("\x1f") &
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

      # A resistor/capacitor/diode/... symbol has no box interior for a
      # recirculation arc; a hierarchical or unrecognised kind draws as a box
      # and keeps the chain treatment `symbolFor` already gives a subsheet.
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
  ## Reserved for a future need. The chain arc anchors directly on the box
  ## edge beside its own IN/OUT pins now -- a dashed annotation, exempt from
  ## the routed-wire separation invariants -- so no lane is drawn and the box
  ## keeps its historical size.
  discard

proc arrayTitleWidth(plan: ArrayPlan, c: Component): float {.inline.} =
  ## The width `boxSlots` must reserve at the box top for "X1..X8" at the left
  ## and the "xN" badge at the right. 0.0 for every other part -- the one
  ## default that keeps the historical sizing bit-for-bit. Unread for a
  ## non-box representative (`boxSlots` is never called for one), harmless to
  ## still compute.
  if not plan.byRep.hasKey(c.designator): return 0.0
  let a = plan.arrays[plan.byRep[c.designator]]
  float(a.label.len + 4 + ($a.members.len).len) * 7.2 + 24.0

proc arrayPinFor(plan: ArrayPlan, c: Component, pinName: string):
    tuple[found: bool, mark: PinMark, tag, net: string,
          members: seq[BundleMember]] =
  ## Scene decoration for one representative pin. `net` is the name the drawn
  ## pin carries: the head/tail net for the two halves of a chain, the group
  ## `display` for a distributed pin, the bus/interface family name for a
  ## *bundled* distributed pin (below), "" (unchanged) otherwise. `members`
  ## is one entry per array member, `name` the member *designator* and `net`
  ## its binding on this port.
  if not plan.portOfPin.hasKey(pinKey(c, pinName)): return
  let (ai, pi) = plan.portOfPin[pinKey(c, pinName)]
  let a = plan.arrays[ai]
  let ap = a.ports[pi]
  result.found = true
  for k, d in a.members:
    result.members.add BundleMember(name: d, net: ap.nets[k])
  case ap.cls
  of apCommon:
    # A ground/rail common pin already draws its own glyph -- the tick would
    # sit right on top of it, and on a two-terminal symbol (not just a box)
    # the two would collide outright.
    if not ap.bundled and not ap.railCommon: result.mark = pmBusBar
  of apDistributed:
    if not ap.mergedByBundle:
      # Not merged anywhere: the array draws and routes this port itself
      # (`display`/`tag` were computed accordingly in `classifyGroup` --
      # `display` is the bundle's own tag when `bundled`, so this agrees with
      # whatever the bundle's port pennant and any other array sharing the
      # same bus already draw).
      result.mark = pmBusSlash
      result.tag = ap.tag
      result.net = ap.display
    else:
      # "Bundle wins at the pin" (arrays declines its own mark/tag here) still
      # leaves the drawn pin's `net` field to fill in -- and the caller's
      # fallback (the representative's own raw binding, e.g. "rin_0") is
      # exactly one array member's specific index. Once the array collapses,
      # this one box stands for every member's binding on the bus, not just
      # the representative's own, so the bus/interface family name ("rin")
      # is what the box's identity actually is.
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
  ## The array-aware net-label text for a bundled distributed array
  ## representative's pin; "" everywhere else, so the caller's ordinary
  ## per-net text (a hidden member's own tag, or any pin `arrayPinFor` never
  ## claims) is used unchanged.
  ##
  ## `bundles.nim`'s net-label pass tags each carrier with its own bound net
  ## ("rin_0" for the specific component sitting on that one wire) unless two
  ## or more bundle members land on the *same* component, which is the only
  ## case it merges into one compact tag. A representative that used to be
  ## one lone component (unmerged, correctly "rin_0") now stands for every
  ## hidden member's own binding once the array collapses it -- the bundle
  ## pass has no way to know that, since it never sees a collapsed scene, so
  ## it keeps drawing the representative's single specific index. This
  ## substitutes the bus/interface family name at exactly that one spot.
  if not plan.portOfPin.hasKey(pinKey(c, pinName)): return ""
  let (ai, pi) = plan.portOfPin[pinKey(c, pinName)]
  let ap = plan.arrays[ai].ports[pi]
  if ap.cls == apDistributed and ap.mergedByBundle: ap.bundleFamily else: ""

proc arrayOwnsDistributedPin(plan: ArrayPlan, c: Component, pinName: string): bool =
  ## True when a collapsed array's own bus now carries this exact
  ## representative pin's port -- `routing.nim`'s net-label pass must not
  ## also draw a bare tag (or a portConn marker) for it: the array draws a
  ## real wire instead, under the bundle's own occupancy tag
  ## (`ArrayPort.display`, see `classifyGroup`), so the bundle's net-label
  ## pass steps aside for exactly the ports it does. `mergedByBundle` is the
  ## opposite case -- bundle wins at the pin -- and stays with the ordinary
  ## net-label drawing.
  if not plan.portOfPin.hasKey(pinKey(c, pinName)): return false
  let (ai, pi) = plan.portOfPin[pinKey(c, pinName)]
  let ap = plan.arrays[ai].ports[pi]
  ap.cls == apDistributed and not ap.mergedByBundle

proc arrayRouteFor(plan: ArrayPlan, netName: string):
    tuple[skip: bool, group: bool, tag: string, members: seq[string],
          first: bool] =
  ## The routing decision for one `nl.nets` entry. `skip` for a suppressed net
  ## (a chain link, a distributed member after the first). `group` marks a
  ## distributed member net that routes as the one drawn bus.
  ##
  ## `first` is `true` whenever this branch is reached at all: the `skip`
  ## check above already returned for every *other* member of the same group
  ## (`finalizeArrayPlan` suppresses every member but one), so by the time a
  ## net passes both tests it is, by construction, the sole survivor -- no
  ## comparison against the port's own member-order `nets[0]` is needed, and
  ## none is made, because that index need not agree with `suppressed`'s
  ## `nl.nets`-order pick when two arrays enumerate the same physical members
  ## in different orders (the both-ends-distributed case).
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
  ## Every collapsed array -- subsheet or component -- so "does `sclk_out`
  ## chain?" or "does the termination bank collapse?" is a one-line unit test
  ## instead of an inference from geometry. A subsheet, or a raw component
  ## group with no port that genuinely shares both nets across every member,
  ## needs three or more instances; a raw component group that does share
  ## both nets on every port -- and those nets are a rail/ground pair, a
  ## bypass bank -- needs only two (see the bypass-bank floor in
  ## `addSignatureArrays`). Fewer than that, for either shape, yields an
  ## empty report. Builds the bundle plan itself, so the report is exactly
  ## what `prepare` computes with both `lsArrays` and `lsPartArrays` on (the
  ## default). `source` is the subckt name for a subsheet array or the
  ## component `kind` for a component array -- both are the first `\x1f`
  ## field of `PartArray.key` by construction, so no separate storage is
  ## needed to tell them apart; `origin` says which ("subsheet" /
  ## "component").
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
