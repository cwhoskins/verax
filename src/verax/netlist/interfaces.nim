## Buses and declared interfaces.  These are authoring views; scalar nets and
## pins remain the graph representation.
import std/[tables, algorithm, strutils]
import ./types
import ./graph
import ./issue
import ./pinmux

type
  Bus* = object
    name*: string
    nets*: seq[Net]
    dims*: seq[int]
      ## The shape a multi-dimensional bus was declared with, outermost first
      ## (`[8, 2]` for `bus a, width = [8, 2]`). Empty means "1-D of
      ## `nets.len`" -- the zero value, so every existing `Bus` literal and
      ## every consumer that never heard of `dims` keeps working unchanged.
      ## `nets` stays flat and row-major regardless of `dims.len`; `dims` is
      ## only ever consulted by the multi-index accessors, `sub`, and
      ## `schematic/bundles.nim`'s range-notation label.
  SignalDef* = object
    name*: string
    width*: int
    shared*: bool
    doc*: string
  Modport* = object
    name*: string
    dirs*: OrderedTable[string, PinType]
    controller*: bool
  RoleClaim* = object
    role*: string
    binds*: OrderedTable[string, string]
    params*: OrderedTable[string, string]
  InterfaceDef* = object
    name*: string
    doc*: string
    signals*: seq[SignalDef]
    modports*: OrderedTable[string, Modport]
    implies*: seq[RoleClaim]
  Interface* = object
    def*: InterfaceDef
    name*: string
    signals*: OrderedTable[string, Bus]
  InterfaceView* = object
    iface*: Interface
    modport*: string

var interfaceRegistry: OrderedTable[string, InterfaceDef]

proc registerInterfaceDef*(def: InterfaceDef) =
  if def.name.len == 0: raise newException(NetlistError, "interface name must not be empty")
  var names: seq[string]
  for s in def.signals:
    if s.name in names: raise newException(NetlistError, "duplicate signal '" & s.name & "' in interface '" & def.name & "'")
    if s.width < 1: raise newException(NetlistError, "interface signal '" & s.name & "' has invalid width")
    names.add s.name
  for mpName, mp in def.modports:
    for signal, _ in mp.dirs:
      if signal notin names: raise newException(NetlistError, "modport '" & mpName & "' names undeclared signal '" & signal & "'")
  interfaceRegistry[def.name] = def
proc interfaceDefOf*(name: string): InterfaceDef =
  if not interfaceRegistry.hasKey(name): raise newException(NetlistError, "no such interface: " & name)
  interfaceRegistry[name]
proc registeredInterfaceDefs*(): seq[string] =
  for name in interfaceRegistry.keys: result.add name

proc `$`*(def: InterfaceDef): string =
  result = def.name
  if def.doc.len > 0: result &= " — " & def.doc
  if def.signals.len > 0:
    var signals: seq[string]
    for s in def.signals:
      signals.add s.name & (if s.width == 1: "" else: "[" & $s.width & "]")
    result &= " (" & signals.join(", ") & ")"

proc describeInterfaceDef*(def: InterfaceDef): string =
  result = $def
  for name, mp in def.modports:
    var dirs: seq[string]
    for signal, dir in mp.dirs: dirs.add signal & "=" & $dir
    result &= "\n  " & name & ": " & dirs.join(", ")
  for claim in def.implies: result &= "\n  implies " & claim.role

proc memberName(name: string, index, width: int): string =
  if width == 1: name else: name & "_" & $index
proc intsJoin(xs: openArray[int]): string =
  ## `[8, 2]` -> `"8,2"`. The wire format for `bus.dims`/`bus.coord`; there is
  ## no `strutils.join` for `openArray[int]`.
  for i, x in xs:
    if i > 0: result &= ","
    result &= $x
proc intsSplit(s: string): seq[int] =
  if s.len == 0: return
  for part in s.split(','): result.add parseInt(part)
proc coordsOf(flat: int, dims: openArray[int]): seq[int] =
  ## The row-major multi-index of flat position `flat` in a `dims`-shaped
  ## bus -- the inverse of the flat index `addBus`/`sub` compute.
  result = newSeq[int](dims.len)
  var rem = flat
  for k in countdown(dims.len - 1, 0):
    result[k] = rem mod dims[k]
    rem = rem div dims[k]
proc coordSuffix(coords: openArray[int]): string =
  for c in coords: result &= "_" & $c
proc memberName(name: string, coords, dims: openArray[int]): string =
  ## Row-major multi-index naming: `a_0_0, a_0_1, .. a_7_1` for
  ## `dims = [8, 2]`. A single dimension defers to the 1-D form above, so a
  ## width-1 1-D bus keeps naming its one net bluntly `name` -- `dims = [1]`
  ## and `dims = @[]` (the 1-D `addBus(width: int)` path) agree.
  if dims.len == 1: return memberName(name, coords[0], dims[0])
  name & coordSuffix(coords)
proc addBus*(nl: Netlist, name: string, width: int, kind = ntSignal): Bus =
  if width <= 0: raise newException(NetlistError, "bus '" & name & "' width must be positive")
  result.name = name
  for i in 0 ..< width:
    let n = addNet(nl, newNet(memberName(name, i, width), kind))
    n.attrs["bus.name"] = name; n.attrs["bus.index"] = $i; n.attrs["bus.width"] = $width
    result.nets.add n
proc addBus*(nl: Netlist, name: string, dims: openArray[int], kind = ntSignal): Bus =
  ## A multi-dimensional bus: `width = [8, 2]` is drawn `a[7:0][1:0]`
  ## (`schematic/bundles.nim`) and indexed `a[i, j]` / sliced `a.sub(i)`.
  ## `nets` stays flat and row-major -- every existing consumer of a `Bus`
  ## (`connectPort`, `addPorts`, `wiringOf`, `bundles.nim`'s per-`bus.name`
  ## grouping) keeps working off `nets`/`bus.index`/`bus.width` exactly as it
  ## does for a 1-D bus; only `dims` is new, carried alongside for the
  ## multi-index accessors and the range-notation label.
  if dims.len == 0:
    raise newException(NetlistError, "bus '" & name & "' dims must not be empty")
  for d in dims:
    if d <= 0: raise newException(NetlistError, "bus '" & name & "' width must be positive")
  result.name = name
  result.dims = @dims
  var total = 1
  for d in dims: total *= d
  let dimsStr = intsJoin(dims)
  for flat in 0 ..< total:
    let coords = coordsOf(flat, dims)
    let n = addNet(nl, newNet(memberName(name, coords, dims), kind))
    n.attrs["bus.name"] = name; n.attrs["bus.index"] = $flat; n.attrs["bus.width"] = $total
    n.attrs["bus.dims"] = dimsStr; n.attrs["bus.coord"] = intsJoin(coords)
    result.nets.add n
proc busOf*(nl: Netlist, name: string, nets: openArray[Net]): Bus =
  ## 1-D only: grouping pre-existing nets by hand has no shape to infer. If a
  ## member was previously part of a multi-dimensional bus, its stale
  ## `bus.dims`/`bus.coord` are deleted along with the `bus.index` this proc
  ## rewrites -- left behind, they would report a shape the flat index no
  ## longer means.
  if nets.len == 0: raise newException(NetlistError, "bus '" & name & "' width must be positive")
  result.name = name; result.nets = @nets
  for i, n in result.nets:
    if n.netlist != nl: raise newException(NetlistError, "bus member does not belong to netlist")
    n.attrs["bus.name"] = name; n.attrs["bus.index"] = $i; n.attrs["bus.width"] = $nets.len
    n.attrs.del "bus.dims"; n.attrs.del "bus.coord"
proc len*(b: Bus): int = b.nets.len
proc `[]`*(b: Bus, i: int): Net =
  if b.dims.len > 1:
    raise newException(NetlistError, "bus '" & b.name & "' is " & $b.dims.len &
      "-D: index it with `" & b.name & "[i, j]` or take a slice with `" &
      b.name & ".sub(i)`, not a single index")
  b.nets[i]
proc `[]`*(b: Bus, i, j: int): Net =
  if b.dims.len != 2:
    raise newException(NetlistError, "bus '" & b.name & "' is not 2-D (dims=" &
      intsJoin(b.dims) & "); use `[i]`/`.sub(i)` matching its actual shape")
  b.nets[i * b.dims[1] + j]
proc sub*(b: Bus, i: int): Bus =
  ## The inner bus at outer index `i`, dropping the leading dimension --
  ## `a.sub(3)` on an `[8, 2]` bus is a plain width-2 1-D bus over the same
  ## `Net` objects. Pure value-space, like `narrow` below: it writes nothing
  ## to the netlist and cannot desync `bus.index`, which `busOf` rewrites
  ## from table order.
  if b.dims.len < 2:
    raise newException(NetlistError, "bus '" & b.name & "' has no inner dimension to take (dims=" &
      intsJoin(b.dims) & ")")
  let innerDims = b.dims[1 ..^ 1]
  var innerLen = 1
  for d in innerDims: innerLen *= d
  result.name = b.name & "_" & $i
  result.dims = innerDims
  result.nets = b.nets[i * innerLen ..< (i + 1) * innerLen]
proc `[]`*(b: Bus, s: HSlice[int, int]): seq[Net] =
  if b.dims.len > 1:
    raise newException(NetlistError, "bus '" & b.name & "' is " & $b.dims.len &
      "-D: a flat slice does not follow its shape -- use `" & b.name &
      "[i, j]` or `" & b.name & ".sub(i)`")
  b.nets[s]
proc findBus*(nl: Netlist, name: string): Bus =
  var indexed: seq[(int, Net)]
  for _, n in nl.nets:
    if n.attrs.getOrDefault("bus.name") == name:
      try: indexed.add (parseInt(n.attrs["bus.index"]), n)
      except ValueError: raise newException(NetlistError, "invalid bus metadata for '" & name & "'")
  if indexed.len == 0: raise newException(NetlistError, "no such bus: " & name)
  indexed.sort(proc(a,b:(int,Net)): int = cmp(a[0],b[0]))
  let width = parseInt(indexed[0][1].attrs.getOrDefault("bus.width", "0"))
  if width != indexed.len: raise newException(NetlistError, "incomplete bus metadata for '" & name & "'")
  result.name = name
  result.dims = intsSplit(indexed[0][1].attrs.getOrDefault("bus.dims"))
  for i, pair in indexed:
    if pair[0] != i: raise newException(NetlistError, "incomplete bus metadata for '" & name & "'")
    result.nets.add pair[1]

proc addInterface*(nl: Netlist, name: string, def: InterfaceDef): Interface =
  result.def = def; result.name = name
  for s in def.signals:
    let b = addBus(nl, name & "_" & s.name, s.width)
    for n in b.nets:
      n.attrs["iface.instance"] = name; n.attrs["iface.def"] = def.name; n.attrs["iface.signal"] = s.name
      if s.shared: n.attrs["iface.shared"] = "1"
    result.signals[s.name] = b
proc addInterfaceArray*(nl: Netlist, name: string, def: InterfaceDef, count: int): seq[Interface] =
  if count < 0: raise newException(NetlistError, "interface array count must not be negative")
  for i in 0 ..< count: result.add addInterface(nl, name & "_" & $i, def)
proc bus*(i: Interface, signal: string): Bus =
  if not i.signals.hasKey(signal): raise newException(NetlistError, "interface '" & i.name & "' has no signal '" & signal & "'")
  i.signals[signal]
proc `[]`*(i: Interface, signal: string): Net =
  let b = i.bus(signal)
  if b.len != 1: raise newException(NetlistError, "interface signal '" & signal & "' is wide")
  b[0]
proc `[]`*(i: Interface, signal: string, k: int): Net = i.bus(signal)[k]
  ## One member of a wide signal by index. `spi1["cs", 0]` parses as
  ## `` `[]`(spi1, "cs", 0) `` -- the arity-3 form, no ambiguity with the
  ## arity-2 whole-signal overload above. Replaces `spi1.bus("cs")[0]`, the
  ## boilerplate `spi_memories.nim` repeated six times.

proc narrow*(i: Interface, signal: string, k: int): Interface =
  ## `i` presented with one wide signal cut down to the single member `k`, as a
  ## width-1 bus -- the parent-side view a child that owns exactly one member
  ## of a shared bus sees. Pure value space: it copies `i` and rewrites only
  ## the local `signals` table and `def.signals[j].width`, touching neither the
  ## netlist nor the registry, so it survives `clone` and cannot rewrite a
  ## net's `bus.index` (the reason `busOf` is dangerous to reach for here).
  ##
  ## `{"spi": spi1.narrow("cs", 0)}` wires through `wiringOf(label, Interface)`
  ## to `spi_sclk, spi_mosi, spi_miso, spi_cs` -- exactly a single-select
  ## peripheral sheet's port list. The rejected alternative was a `spi1 with
  ## cs = 0` macro form: it does not parse in a Nim macro argument position,
  ## and passing a bare interface would leave `vdd`/`gnd` unwired and raise.
  result = i
  let b = i.bus(signal)
  if k notin 0 ..< b.len:
    raise newException(NetlistError, "interface '" & i.name & "' signal '" &
      signal & "' has no member " & $k & " (width " & $b.len & ")")
  result.signals[signal] = Bus(name: b.name, nets: @[b.nets[k]])
  for j in 0 ..< result.def.signals.len:
    if result.def.signals[j].name == signal: result.def.signals[j].width = 1

proc narrow*(i: Interface, signal: string, s: HSlice[int, int]): Interface =
  ## The `hostData[4..7]` shape: `i` with one wide signal cut to the members
  ## `s`, re-indexed from zero in the returned view. Same value-space rules as
  ## the single-member overload.
  result = i
  let b = i.bus(signal)
  if s.a < 0 or s.b >= b.len or s.a > s.b:
    raise newException(NetlistError, "interface '" & i.name & "' signal '" &
      signal & "' has no members " & $s.a & ".." & $s.b & " (width " & $b.len & ")")
  result.signals[signal] = Bus(name: b.name, nets: b.nets[s.a .. s.b])
  for j in 0 ..< result.def.signals.len:
    if result.def.signals[j].name == signal:
      result.def.signals[j].width = s.b - s.a + 1

proc view*(i: Interface, modport: string): InterfaceView =
  if not i.def.modports.hasKey(modport): raise newException(NetlistError, "interface '" & i.def.name & "' has no modport '" & modport & "'")
  InterfaceView(iface: i, modport: modport)
proc addInterfaceRecovery(nl: Netlist, name: string, def: InterfaceDef): Interface

proc findInterface*(nl: Netlist, name: string): Interface =
  var defName = ""
  for _, n in nl.nets:
    if n.attrs.getOrDefault("iface.instance") == name:
      let d = n.attrs.getOrDefault("iface.def")
      if defName.len != 0 and d != defName: raise newException(NetlistError, "disagreeing interface metadata for '" & name & "'")
      defName = d
  if defName.len == 0: raise newException(NetlistError, "no such interface: " & name)
  result = addInterfaceRecovery(nl, name, interfaceDefOf(defName))
proc addInterfaceRecovery(nl: Netlist, name: string, def: InterfaceDef): Interface =
  ## The registry supplies the interface shape, while bus metadata supplies
  ## parameter values.  This matters for e.g. `spiInterface(2)`: its
  ## registered catalogue entry is the one-CS default, but a recovered
  ## instance really has a two-member `cs` bus.  Width is the only
  ## parameterised part of an interface definition today, and recording it
  ## on every bus member makes this work for user definitions too.
  result.name = name; result.def = def
  for i in 0 ..< result.def.signals.len:
    let signal = result.def.signals[i].name
    var members: seq[Net]
    for _, n in nl.nets:
      if n.attrs.getOrDefault("iface.instance") == name and
         n.attrs.getOrDefault("iface.signal") == signal:
        members.add n
    if members.len == 0:
      raise newException(NetlistError,
        "incomplete interface metadata for '" & name & "." & signal & "'")
    let b = busOf(nl, name & "_" & signal, members)
    result.def.signals[i].width = b.len
    result.signals[signal] = b
proc interfacesOf*(nl: Netlist): seq[Interface] =
  var names: seq[string]
  for _, n in nl.nets:
    let name = n.attrs.getOrDefault("iface.instance")
    if name.len > 0 and name notin names: names.add name
  for name in names: result.add findInterface(nl, name)

proc netsOf*(n: Net): seq[Net] = @[n]
proc netsOf*(n: seq[Net]): seq[Net] = n
proc netsOf*(b: Bus): seq[Net] = b.nets
proc netsOf*(i: Interface): seq[Net] =
  for s in i.def.signals: result.add i.bus(s.name).nets
proc netsOf*(v: InterfaceView): seq[Net] =
  let mp = v.iface.def.modports[v.modport]
  for s in v.iface.def.signals:
    if mp.dirs.hasKey(s.name): result.add v.iface.bus(s.name).nets
proc wiringOf*(label: string, n: Net): seq[(string, Net)] = @[(label, n)]
proc wiringOf*(label: string, ns: seq[Net]): seq[(string, Net)] =
  ## A width-1 group is the bare `label` (it maps to one scalar child port); a
  ## wider one is `label_0 .. label_(N-1)`, matching how `addPorts` names a bus
  ## on the child side. Fixing the previous all-bare form is what makes
  ## `docs/buses_and_interfaces.md` item 9 true -- there was no call site
  ## passing a Bus/seq here to break (checked across `designs/`, `tests/`,
  ## `templates/`).
  if ns.len == 1: return @[(label, ns[0])]
  for i, n in ns: result.add (label & "_" & $i, n)
proc wiringOf*(label: string, b: Bus): seq[(string, Net)] =
  ## `dims.len <= 1` forwards to the plain-seq form above (its width-1 bare
  ## label collapse). A multi-dim bus does not forward -- forwarding to
  ## `wiringOf(label, b.nets)` would drop `dims` and wire `a_0_0..a_7_1`
  ## instead of following `b`'s own shape -- so it names each member
  ## `label_<i0>_<i1>..` directly off `coordsOf`, matching `addPorts` below.
  if b.dims.len <= 1: return wiringOf(label, b.nets)
  for flat, n in b.nets:
    result.add (label & coordSuffix(coordsOf(flat, b.dims)), n)
proc wiringOf*(label: string, i: Interface): seq[(string, Net)] =
  ## Member-suffix a wide signal the same way `addPorts(_, _, InterfaceView)`
  ## does (`label_signal` for width 1, `label_signal_k` for a wide one), so a
  ## `narrow`ed interface -- one signal presented as width 1 -- wires straight
  ## onto a single-member child port.
  for s in i.def.signals:
    let nets = i.bus(s.name).nets
    for k, n in nets:
      result.add (label & "_" & memberName(s.name, k, s.width), n)
proc wiringOf*(label: string, v: InterfaceView): seq[(string, Net)] =
  ## Off `def.signals` directly, mirroring `addPorts(_, _, InterfaceView)`.
  ## The previous version recovered the signal name from
  ## `entry[0].substr(label.len + 1)` and tested `mp.dirs` on it -- once the
  ## interface overload member-suffixes a wide signal that substring is
  ## `cs_0`, never a modport key, so every wide-signal entry was silently
  ## dropped.
  let mp = v.iface.def.modports[v.modport]
  for s in v.iface.def.signals:
    if not mp.dirs.hasKey(s.name): continue
    let nets = v.iface.bus(s.name).nets
    for k, n in nets:
      result.add (label & "_" & memberName(s.name, k, s.width), n)
proc instantiateByPortOpen*(parent: Netlist, instanceDesignator: string,
                            defNetlist: Netlist, wiring: openArray[(string, Net)],
                            openGroups: openArray[string],
                            globalNets: var OrderedTable[string, Net],
                            componentKind = "subcircuit"): Component =
  ## Strict named wiring with explicit grouped opens. Each exposed scalar port
  ## gets its own net, preserving the graph and flattening invariants.
  var all = @wiring
  for group in openGroups:
    var matched = false
    for portName, _ in defNetlist.ports:
      if portName == group or portName.startsWith(group & "_"):
        matched = true
        var already = false
        for pair in all:
          if pair[0] == portName: already = true
        if not already:
          let n = addNet(parent, newNet("nc_" & instanceDesignator & "_" & portName))
          n.attrs["iface.nc"] = "1"
          all.add (portName, n)
    if not matched:
      raise newException(NetlistError, "'" & defNetlist.name & "' has no port group '" & group & "'")
  instantiateByPort(parent, instanceDesignator, defNetlist, all, globalNets, componentKind)

proc addPorts*(nl: Netlist, label: string, n: Net) = addPort(nl, label, n)
proc addPorts*(nl: Netlist, label: string, b: Bus) =
  if b.dims.len <= 1:
    for i, n in b.nets: addPort(nl, if b.len == 1: label else: label & "_" & $i, n)
    return
  for flat, n in b.nets:
    addPort(nl, label & coordSuffix(coordsOf(flat, b.dims)), n)
proc addPorts*(nl: Netlist, label: string, v: InterfaceView) =
  let mp = v.iface.def.modports[v.modport]
  for s in v.iface.def.signals:
    if mp.dirs.hasKey(s.name):
      for k, n in v.iface.bus(s.name).nets:
        n.attrs["iface.dir"] = $mp.dirs[s.name]
        addPort(nl, label & "_" & memberName(s.name, k, s.width), n)
proc promotePortDirections*(inst: Component) =
  for _, p in inst.pins:
    if p.hierNet != nil:
      let d = p.hierNet.attrs.getOrDefault("iface.dir")
      if d.len > 0:
        for k in PinType:
          if $k == d: p.kind = k
      # Direction belongs to the child port, but shared-bus identity belongs
      # to the parent net this instance pin joins.  Carry it onto the pin so
      # ERC sees the same declaration through a hierarchy boundary.
      let source = if p.net != nil and
                      p.net.attrs.getOrDefault("iface.instance").len > 0:
                     p.net
                   else: p.hierNet
      for key, value in source.attrs:
        if key.startsWith("iface."): p.attrs[key] = value
proc connectPort*(c: Component, b: Bus, pins: openArray[(string,string)] = [], prefix = "") =
  ## A bare bus deliberately states no direction -- and no pin function, so
  ## this overload takes no `peripheral`/`functions` the way the `InterfaceView`
  ## one does.
  for k, n in b.nets:
    var pinName = if b.len == 1: b.name else: $k
    for pair in pins:
      if pair[0] == b.name: pinName = pair[1]
    discard connect(c, prefix & pinName, n, ptUnknown)

proc connectPort*(c: Component, v: InterfaceView, pins: openArray[(string,string)] = [], prefix = "",
                  peripheral = "", functions: openArray[(string,string)] = []) =
  ## `peripheral` names the concrete peripheral instance this port is wired as
  ## ("SPI1"), and `functions` overrides that per member -- `{"cs_1": "GPIO"}`
  ## for a software chip select that is not an SPI function. Both are stamped
  ## onto the pins as `pinmux.*` attrs for `validatePinmux` and default to
  ## stamping nothing, so a design that names no peripheral is unaffected.
  let mp = v.iface.def.modports[v.modport]
  for pair in pins:
    var known = v.iface.signals.hasKey(pair[0])
    if not known:
      for s in v.iface.def.signals:
        if s.width > 1:
          for k in 0 ..< s.width:
            if pair[0] == s.name & "_" & $k: known = true
    if not known:
      raise newException(NetlistError, "interface '" & v.iface.name & "' has no signal or member '" & pair[0] & "'")
  for pair in functions:
    var known = v.iface.signals.hasKey(pair[0])
    if not known:
      for s in v.iface.def.signals:
        if s.width > 1:
          for k in 0 ..< s.width:
            if pair[0] == s.name & "_" & $k: known = true
    if not known:
      raise newException(NetlistError, "interface '" & v.iface.name & "' has no signal or member '" & pair[0] & "'")
  for s in v.iface.def.signals:
    if not mp.dirs.hasKey(s.name): continue
    for k, n in v.iface.bus(s.name).nets:
      let member = if s.width == 1: s.name else: s.name & "_" & $k
      var pinName = member
      for pair in pins:
        if pair[0] == s.name: pinName = pair[1]
      for pair in pins:
        # A member mapping wins over a signal mapping regardless of the table
        # literal's order.  Mapping a wide signal as one pin would otherwise
        # attempt to connect that one pin N times.
        if pair[0] == member: pinName = pair[1]
      if prefix.len > 0:
        pinName = prefix & pinName
      let p = connect(c, pinName, n, mp.dirs[s.name])
      p.attrs["iface.instance"] = v.iface.name; p.attrs["iface.signal"] = s.name
      p.attrs["iface.modport"] = v.modport; p.attrs["iface.def"] = v.iface.def.name
      # Pin function: a per-member `functions` entry wins over the port-wide
      # `peripheral`.  A member override wearing "PERIPH.sig" also sets the
      # peripheral; a bare "GPIO" clears it.
      var fn = ""
      if peripheral.len > 0: fn = peripheral & "." & s.name
      for pair in functions:
        if pair[0] == s.name or pair[0] == member: fn = pair[1]
      if fn.len > 0: setPinFunction(p, fn)

proc validateInterfaces*(nl: Netlist, recursive = true): seq[Issue] =
  ## Validate both graph-authored metadata and direction constraints.  The
  ## unknown-modport case is reachable from importers/manual graph builders,
  ## while DSL construction rejects it immediately.
  for iface in interfacesOf(nl):
    var hasController = false
    var needsController = false
    for _, mp in iface.def.modports:
      if mp.controller: needsController = true
    for signal in iface.def.signals:
      for n in iface.bus(signal.name).nets:
        for p in n.pins:
          let mpName = p.attrs.getOrDefault("iface.modport")
          if mpName.len > 0:
            if not iface.def.modports.hasKey(mpName):
              result.add newIssue("interface_modport_unknown", sevError,
                "unknown modport '" & mpName & "' on interface '" & iface.name & "'", net = n, pins = @[p])
            elif iface.def.modports[mpName].controller:
              hasController = true
    if needsController and not hasController:
      result.add newIssue("interface_no_controller", sevWarning,
        "interface '" & iface.name & "' has no controller modport pin")
  for _, n in nl.nets:
    if n.attrs.getOrDefault("iface.instance").len == 0: continue
    # A child sheet's published port is driven from its parent.  Its local
    # pins alone cannot say whether that boundary is dangling or driven; the
    # parent-level interface is where both sides meet and is checked there.
    var published = false
    for _, portNet in nl.ports:
      if portNet == n: published = true
    if published: continue
    var outs = 0; var inputs = 0
    for p in n.pins:
      if p.kind == ptOutput: inc outs
      if p.kind == ptInput: inc inputs
    if outs >= 2: result.add newIssue("interface_direction_conflict", sevError, "multiple outputs on interface net '" & n.name & "'", net=n)
    # A shared line may deliberately be released by every participant.  It
    # is not an undriven unicast signal merely because no chip select is live.
    if inputs > 0 and outs == 0 and n.attrs.getOrDefault("iface.shared") != "1":
      result.add newIssue("interface_signal_undriven", sevWarning, "interface net '" & n.name & "' is undriven", net=n)
    if n.pins.len < 2 and n.attrs.getOrDefault("iface.nc") != "1": result.add newIssue("interface_signal_dangling", sevWarning, "interface net '" & n.name & "' is dangling", net=n)
  if recursive:
    for _, child in nl.children:
      result.add validateInterfaces(child)
