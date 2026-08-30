## Opt-in constrained layered placement for ordinary schematic sheets.
##
## This is deliberately bounded rather than a general graph-drawing solver: it
## derives a stable directed skeleton from output pins, follows two-terminal
## signal paths to their input endpoints, assigns monotonically increasing
## columns, and orders each column from the deterministic seed. The existing
## separator remains the authority for non-overlap.

const
  constrainedMaxParts = 64
  constrainedLayerPitch = 200.0
  # A semantic column can hold a fallback box as well as a two-terminal
  # symbol; leave enough vertical room that legalization need not spill it
  # into a neighbouring column.
  constrainedRowPitch = 240.0

type TraversedPath = object
  parts: seq[int]
  inputs: seq[int]

proc isTraversable(c: Component, nl: Netlist): bool =
  ## Semantic path walking is intentionally topology-only. All flat,
  ## two-terminal devices qualify, regardless of their electrical kind.
  if c == nil or c.netlist != nl or c.subNetlist != nil:
    return false
  var connected = 0
  for _, pin in c.pins:
    if pin.net != nil:
      if pin.net.netlist != nl: return false
      inc connected
  connected == 2

proc inputPort(nl: Netlist, net: Net): bool =
  ## Keep port semantics exactly aligned with routing, including its
  ## all-passive/no-driver fallback.
  for _, portNet in nl.ports:
    if portNet == net:
      return portDirection(net) == pdInput
  false

proc pathsFrom(nl: Netlist, start: Net, skip: int,
               idxOf: Table[string, int]): seq[TraversedPath] =
  ## Follow a signal net through eligible two-terminal devices. A component is
  ## not revisited within one walk, making feedback loops bounded and stable.
  var found: seq[TraversedPath]
  proc walk(net: Net, path: seq[int], seen: HashSet[int]) =
    if net == nil or net.netlist != nl or isGround(net) or isRail(net): return
    var ends: seq[int]
    for pin in net.pins:
      let c = pin.component
      if c != nil and c.netlist == nl and idxOf.hasKey(c.designator) and
         pin.kind == ptInput:
        ends.add idxOf[c.designator]
    if ends.len > 0:
      found.add TraversedPath(parts: path, inputs: ends)
      # An input is a semantic endpoint. Continuing through its component
      # would turn an ordinary forward receiver into a spurious self-return.
      return
    for pin in net.pins:
      let c = pin.component
      if not isTraversable(c, nl) or not idxOf.hasKey(c.designator): continue
      let i = idxOf[c.designator]
      if i == skip or i in seen: continue
      var other: Net
      for _, mate in c.pins:
        if mate.net != net:
          other = mate.net
          break
      if other == nil: continue
      var nextSeen = seen
      nextSeen.incl i
      var nextPath = path
      nextPath.add i
      walk(other, nextPath, nextSeen)
  walk(start, @[], initHashSet[int]())
  result = found

proc constrainedLayers(comps: seq[Component], idxOf: Table[string, int]): seq[int] =
  ## Longest-path relaxation on semantic output arcs. Insertion order breaks
  ## ordinary reverse arcs. A path returning to its own source is deliberately
  ## co-columnar; a path returning to an earlier component is feedback, whose
  ## passive path remains to the right of the output that drives it.
  result = newSeq[int](comps.len)
  var arcs: seq[tuple[src, dst: int]]
  var sameColumn: seq[tuple[src, part: int]]
  var feedback: seq[tuple[src, part: int]]

  proc addPathArcs(src: int, path: seq[int], dst: int) =
    var previous = src
    for part in path:
      if previous < part: arcs.add (previous, part)
      previous = part
    if previous < dst: arcs.add (previous, dst)

  for i, c in comps:
    for _, pin in c.pins:
      if pin.kind != ptOutput or pin.net == nil or isGround(pin.net) or isRail(pin.net):
        continue
      # Preserve the direct output-pin skeleton as well as the longer
      # two-terminal semantic paths below. A final unannotated sink still
      # belongs after the output that drives its net.
      for mate in pin.net.pins:
        if mate.component == nil or mate.component.netlist != c.netlist or
           mate.component.designator == c.designator or
           not idxOf.hasKey(mate.component.designator): continue
        let dst = idxOf[mate.component.designator]
        if i < dst: arcs.add (i, dst)
      for path in pathsFrom(c.netlist, pin.net, i, idxOf):
        for dst in path.inputs:
          if dst == i:
            for part in path.parts: sameColumn.add (i, part)
          elif i < dst:
            addPathArcs(i, path.parts, dst)
          else:
            # This is the insertion-order-broken feedback direction. Do not
            # pull it left toward the receiving input: feedback passives read
            # as an output-side path.
            for part in path.parts: feedback.add (i, part)

  # An input interface is a virtual layer-zero source. `portDirection` is the
  # shared implementation used by routing, so explicit pin direction and its
  # no-driver fallback have exactly the same meaning here.
  for _, net in comps[0].netlist.ports:
    if not inputPort(comps[0].netlist, net): continue
    for path in pathsFrom(comps[0].netlist, net, -1, idxOf):
      for dst in path.inputs:
        if path.parts.len > 0:
          var previous = path.parts[0]
          for at in 1 ..< path.parts.len:
            if previous < path.parts[at]: arcs.add (previous, path.parts[at])
            previous = path.parts[at]
          if previous < dst: arcs.add (previous, dst)

  # The insertion-order cycle break makes these arcs a DAG, so n-1 longest-
  # path passes are a strict bound.
  for _ in 1 ..< comps.len:
    var next = result
    for a in arcs:
      if result[a.src] + 1 > next[a.dst]: next[a.dst] = result[a.src] + 1
    if next == result: break
    result = next

  for f in feedback:
    result[f.part] = max(result[f.part], result[f.src] + 1)
  for s in sameColumn:
    result[s.part] = result[s.src]

proc constrainedTargets(comps: seq[Component], pos: seq[Point],
                        idxOf: Table[string, int]): seq[Point] =
  ## Stable columns and rows. The incoming seed only resolves within-layer row
  ## ties, so it preserves useful local topology without randomness.
  if comps.len > constrainedMaxParts: return pos
  let layers = constrainedLayers(comps, idxOf)
  var minLayer = 0
  for x in layers: minLayer = min(minLayer, x)
  result = newSeq[Point](comps.len)
  var maxRows = 0
  for layer in 0 ..< comps.len:
    var members: seq[int]
    for i in 0 ..< comps.len:
      if layers[i] == layer: members.add i
    if members.len == 0: continue
    members.sort(proc(a, b: int): int =
      result = cmp(pos[a].y, pos[b].y)
      if result == 0: result = cmp(a, b))
    maxRows = max(maxRows, members.len)
    for row, i in members:
      result[i] = Point(x: float(layer - minLayer) * constrainedLayerPitch,
                        y: float(row) * constrainedRowPitch)
  # Centre the sheet about the origin, retaining exact grid coordinates.
  let yShift = float(maxRows - 1) * constrainedRowPitch / 2.0
  for p in mitems(result): p.y -= yShift

proc constrainedSemanticSeed(comps: seq[Component], pos: var seq[Point],
                             idxOf: Table[string, int]) =
  if comps.len <= constrainedMaxParts and comps.len > 0:
    pos = constrainedTargets(comps, pos, idxOf)

proc constrainedRefine(comps: seq[Component], pos: var seq[Point],
                       idxOf: Table[string, int]) =
  ## Reassert columns after force placement. This bounded snap is the policy's
  ## constrained refinement; legalization below resolves every body conflict.
  if comps.len <= constrainedMaxParts and comps.len > 0:
    pos = constrainedTargets(comps, pos, idxOf)
