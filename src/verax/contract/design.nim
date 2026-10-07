## A `Design`: a netlist plus what is claimed about it. A `Design` **owns** a
## `Netlist` (as `Pcb` does): the electrical model isn't duplicated and
## nothing is added to `netlist/types.nim`.
##
## Role *membership* is stored on the entity (`net.attrs["role.i2c0"] =
## "sda"`) so it survives clone and isolation. Role definitions and
## parameters stay here.

import std/[strutils, tables]
import ../netlist/types
import ../netlist/graph
import ../netlist/annotations
import ../netlist/interfaces
import ./types as ctypes
import ./roles/built_in as roles

export ctypes, roles

const rolePrefix* = "role."
  ## Membership-key namespace, owned by this module.

type
  Design* = ref object
    netlist*: Netlist
    roles*: OrderedTable[string, RoleInstance]
    assertions*: seq[Assertion]
      ## Authored directly rather than via a role.

proc newDesign*(nl: Netlist): Design =
  Design(netlist: nl)

proc innerNames(nl: Netlist, what: string): string =
  var names: seq[string]
  if what == "component":
    for k in nl.components.keys: names.add k
  elif what == "net":
    for k in nl.nets.keys: names.add k
  for k in nl.children.keys: names.add k & " (instance)"
  names.join(", ")

proc innerComponent*(inst: Component, path: varargs[string]): Subject =
  ## A component *inside* this instance as a bindable `Subject`
  ## (`opamp = XL.innerComponent("U1")`): inner identifiers are out of scope
  ## at the design site. Walked **immediately**, so a typo raises naming
  ## what the instance contains.
  if inst == nil:
    raise newException(NetlistError, "innerComponent on a nil instance")
  if inst.subNetlist == nil:
    raise newException(NetlistError,
      inst.designator & " is not a subcircuit instance, so nothing is inside it")
  let rel = hierName(path)
  let c = findComponent(inst.subNetlist, rel)
  if c == nil:
    raise newException(NetlistError,
      "no component '" & rel & "' inside " & inst.designator & "; it contains: " &
      innerNames(inst.subNetlist, "component"))
  Subject(kind: skComponent, name: hierName(inst.designator, rel))

proc innerNet*(inst: Component, path: varargs[string]): Subject =
  ## As `innerComponent`, for a net inside the instance.
  if inst == nil:
    raise newException(NetlistError, "innerNet on a nil instance")
  if inst.subNetlist == nil:
    raise newException(NetlistError,
      inst.designator & " is not a subcircuit instance, so nothing is inside it")
  let rel = hierName(path)
  let n = findNet(inst.subNetlist, rel)
  if n == nil:
    raise newException(NetlistError,
      "no net '" & rel & "' inside " & inst.designator & "; it contains: " &
      innerNames(inst.subNetlist, "net"))
  Subject(kind: skNet, name: hierName(inst.designator, rel))

proc innerPin*(inst: Component, comp, pin: string): Subject =
  ## As `innerComponent`, for one pin of a component inside the instance.
  let c = innerComponent(inst, comp)
  let target = findComponent(inst.subNetlist, comp)
  if not target.pins.hasKey(pin):
    var names: seq[string]
    for k in target.pins.keys: names.add k
    raise newException(NetlistError,
      "no pin '" & pin & "' on " & comp & " inside " & inst.designator &
      "; it has: " & names.join(", "))
  Subject(kind: skPin, name: hierName(c.name, pin))

proc roleRef*(name: string): Subject =
  ## A reference to another role instance, as a binding for a multi-subject
  ## role (`a = roleRef("left")`). Routes through the `role` macro via the
  ## `subjectOf(Subject)` identity overload; `resolve` raises if the instance
  ## isn't declared yet.
  Subject(kind: skClass, name: name)

proc resolve(d: Design, s: Subject): tuple[net: Net, comp: Component, pin: Pin] =
  ## Subject -> live entity, so a bad binding is caught when attached. Via
  ## `graph.find*`, so a `hierSep` path (`XL.U1`) reaches inside an instance,
  ## before or after flattening.
  case s.kind
  of skNet:
    let n = findNet(d.netlist, s.name)
    if n == nil:
      raise newException(NetlistError, "no such net: " & s.name)
    (n, nil, nil)
  of skComponent:
    let c = findComponent(d.netlist, s.name)
    if c == nil:
      raise newException(NetlistError, "no such component: " & s.name)
    (nil, c, nil)
  of skPin:
    if hierSep notin s.name:
      raise newException(NetlistError,
        "a pin subject must be written 'DESIGNATOR" & hierSep & "pin', got: " & s.name)
    let p = findPin(d.netlist, s.name)
    if p == nil:
      raise newException(NetlistError, "no such pin: " & s.name)
    (nil, p.component, p)
  of skClass:
    # A role reference resolves to no entity (so nothing is tagged), but
    # raises if the instance is absent: declare referenced roles first.
    if not d.roles.hasKey(s.name):
      var have: seq[string]
      for k in d.roles.keys: have.add k
      raise newException(NetlistError,
        "no role instance '" & s.name & "' -- a role that references another " &
        "(a `channel_match` binding its two channels, say) must be declared " &
        "after the roles it names. Declared so far: " &
        (if have.len == 0: "(none)" else: have.join(", ")))
    (nil, nil, nil)
  of skDesign:
    (nil, nil, nil)

proc tagMembership(d: Design, inst: RoleInstance) =
  for partName, subj in inst.bindings:
    let (n, c, p) = d.resolve(subj)
    let key = rolePrefix & inst.name
    if p != nil: p.attrs[key] = partName
    elif c != nil: c.attrs[key] = partName
    elif n != nil: n.attrs[key] = partName
    # `skClass` bindings tag nothing (a role isn't a netlist entity); the
    # reference was validated by `resolve`.

proc validate(d: Design, def: RoleDef, inst: RoleInstance) =
  var known: Table[string, RolePart]
  for part in def.parts: known[part.name] = part

  for partName, subj in inst.bindings:
    if not known.hasKey(partName):
      raise newException(NetlistError,
        "role '" & def.name & "' has no part '" & partName & "'; it has " &
        (block:
          var ns: seq[string]
          for p in def.parts: ns.add p.name
          ns.join(", ")))
    if subj.kind != known[partName].kind:
      raise newException(NetlistError,
        "part '" & partName & "' of role '" & def.name & "' must be a " &
        $known[partName].kind & ", got a " & $subj.kind)
    discard d.resolve(subj)

  for part in def.parts:
    if not part.optional and not inst.bindings.hasKey(part.name):
      raise newException(NetlistError,
        "role '" & def.name & "' requires part '" & part.name & "'")

  var declared: Table[string, AnnDef]
  for p in def.params: declared[p.key] = p
  for name, raw in inst.params:
    if not declared.hasKey(name):
      raise newException(NetlistError,
        "role '" & def.name & "' has no parameter '" & name & "'")
    if declared[name].kind == akFloat:
      discard parseAnnFloat(name, raw)

proc addRole*(d: Design, roleName, instanceName: string,
              bindings: openArray[(string, Subject)],
              params: openArray[(string, string)] = []): RoleInstance =
  ## Attaches a role instance: validates it, tags membership, and runs
  ## `apply` so its parameters land as ordinary annotations.
  if d.roles.hasKey(instanceName):
    raise newException(NetlistError, "duplicate role instance: " & instanceName)
  let def = roleDef(roleName)

  var inst = RoleInstance(role: roleName, name: instanceName)
  for (k, v) in bindings: inst.bindings[k] = v
  for (k, v) in params:
    # `without` is reserved on every role: any claim may be declined.
    if k == "without":
      for part in v.split(','):
        let name = part.strip()
        if name.len > 0: inst.declined.add name
    else:
      inst.params[k] = v

  d.validate(def, inst)
  d.tagMembership(inst)
  # Expand once (pure) to check declined suffixes: one matching nothing
  # would leave the claim standing while looking dropped.
  if inst.declined.len > 0:
    var claimed: seq[string]
    for a in def.expand(inst):
      if a.id.startsWith(instanceName & "."):
        claimed.add a.id[instanceName.len + 1 .. ^1]
    for name in inst.declined:
      if name notin claimed:
        raise newException(NetlistError,
          "role '" & roleName & "' instance '" & instanceName &
          "' cannot decline '" & name & "': it does not claim that. It " &
          "claims " & (if claimed.len == 0: "nothing" else: claimed.join(", ")))

  if def.apply != nil:
    def.apply(inst, d.netlist)
  d.roles[instanceName] = inst
  inst

proc addRoleFromInterface*(d: Design, roleName, instanceName: string,
                           iface: Interface,
                           bindings: openArray[(string, Subject)] = [],
                           params: openArray[(string, string)] = []): RoleInstance =
  ## Binds matching net parts from a declared interface. Explicit bindings
  ## win; the one controller component is recovered from its modport pin.
  let def = roleDef(roleName)
  if def.expects.len > 0 and def.expects != iface.def.name:
    raise newException(NetlistError, "role '" & roleName & "' expects interface '" &
      def.expects & "', got '" & iface.def.name & "'")
  var merged: seq[(string, Subject)] = @bindings
  for part in def.parts:
    var present = false
    for pair in merged:
      if pair[0] == part.name: present = true
    if present: continue
    if part.kind == skNet and iface.signals.hasKey(part.name):
      let b = iface.bus(part.name)
      if b.len != 1:
        raise newException(NetlistError, "interface signal '" & part.name &
          "' is wide and cannot bind scalar role part '" & part.name & "'")
      merged.add (part.name, Subject(kind: skNet, name: b[0].name))
    elif part.kind == skComponent and part.name == "controller":
      var controller: Component = nil
      for signal in iface.def.signals:
        for p in iface.bus(signal.name).nets[0].pins:
          let mp = p.attrs.getOrDefault("iface.modport")
          if iface.def.modports.hasKey(mp) and iface.def.modports[mp].controller:
            if controller != nil and controller != p.component:
              raise newException(NetlistError, "interface '" & iface.name & "' has multiple controllers")
            controller = p.component
      if controller != nil: merged.add (part.name, Subject(kind: skComponent, name: controller.designator))
  addRole(d, roleName, instanceName, merged, params)

proc addImpliedRoles*(d: Design) =
  for iface in interfacesOf(d.netlist):
    for claim in iface.def.implies:
      var params: seq[(string, string)]
      for key, value in claim.params: params.add (key, value)
      # `claim.binds` maps role parts to differently-named interface signals
      # (`dp`/`dn` -> `p`/`n`); everything else auto-binds by name.
      var bindings: seq[(string, Subject)]
      for partName, signalName in claim.binds:
        if not iface.signals.hasKey(signalName):
          raise newException(NetlistError, "interface '" & iface.def.name &
            "' implies role '" & claim.role & "' binding '" & partName &
            "' to undeclared signal '" & signalName & "'")
        let b = iface.bus(signalName)
        if b.len != 1:
          raise newException(NetlistError, "interface signal '" & signalName &
            "' is wide and cannot bind scalar role part '" & partName & "'")
        bindings.add (partName, Subject(kind: skNet, name: b[0].name))

      # Fan-out: a scalar role part matching a wide signal (`cs` of
      # `spiInterface(3)`) gets one instance per member, via
      # `interfaces.narrow`. Done here rather than by loosening
      # `addRoleFromInterface`, which must keep refusing to bind a wide bus
      # to a scalar part.
      let def = roleDef(claim.role)
      var wideSignal = ""
      var width = 0
      for part in def.parts:
        if part.kind != skNet: continue
        var signalName = part.name
        for pn, sn in claim.binds:
          if pn == part.name: signalName = sn
        if not iface.signals.hasKey(signalName): continue
        let b = iface.bus(signalName)
        if b.len == 1: continue
        if wideSignal.len == 0:
          wideSignal = signalName
          width = b.len
        elif b.len != width:
          raise newException(NetlistError, "interface '" & iface.def.name &
            "' implies role '" & claim.role & "': signal '" & signalName &
            "' has width " & $b.len & " but '" & wideSignal & "' has width " &
            $width & " -- an interface whose selects and data lanes " &
            "disagree in width is a real error, not something to guess " &
            "through")

      if wideSignal.len == 0:
        # Unfanned path: every signal is width 1.
        if d.roles.hasKey(iface.name): continue
        discard addRoleFromInterface(d, claim.role, iface.name, iface,
                                      bindings, params)
      else:
        for k in 0 ..< width:
          # `<iface>_<signal><k>` (`spi_0_cs0`, ...). An explicitly declared
          # role of that name wins, per member.
          let instName = iface.name & "_" & wideSignal & $k
          if d.roles.hasKey(instName): continue
          discard addRoleFromInterface(d, claim.role, instName,
                                       iface.narrow(wideSignal, k),
                                       bindings, params)
          d.roles[instName].member = k

proc expandInstance*(inst: RoleInstance): seq[Assertion] =
  ## One role instance's claims, minus declined ones. Everything that reads
  ## claims goes through here, so `explain` and `evaluate` can't drift.
  for a in roleDef(inst.role).expand(inst):
    var suffix = ""
    if a.id.startsWith(inst.name & "."):
      suffix = a.id[inst.name.len + 1 .. ^1]
    if suffix.len > 0 and suffix in inst.declined: continue
    result.add a

proc assertThat*(d: Design, a: Assertion) =
  var it = a
  if it.origin.len == 0: it.origin = "authored"
  d.assertions.add it

proc expandAll*(d: Design): seq[Assertion] =
  ## Everything claimed: authored assertions plus every role's expansion.
  result = d.assertions
  for _, inst in d.roles:
    result.add expandInstance(inst)

proc rolesOf*(e: Net | Component | Pin): seq[tuple[instance, part: string]] =
  ## Which role instances an entity belongs to, from its membership tags
  ## (works on a fragment without the `Design`).
  for key, part in e.attrs:
    if key.startsWith(rolePrefix):
      result.add (instance: key[rolePrefix.len .. ^1], part: part)

proc explain*(d: Design): string =
  ## What each role claims, in full: generated assertions must be
  ## inspectable.
  var lines = @["design '" & d.netlist.name & "'"]
  if d.roles.len == 0 and d.assertions.len == 0:
    lines.add "  (no roles or assertions)"
  for _, inst in d.roles:
    var binds: seq[string]
    for part, subj in inst.bindings: binds.add part & " = " & $subj
    var ps: seq[string]
    for k, v in inst.params: ps.add k & " = " & prettyValue(v)
    lines.add "  role " & inst.name & " : " & inst.role
    lines.add "    binds " & binds.join(", ")
    if ps.len > 0: lines.add "    params " & ps.join(", ")
    # Declining is always stated.
    if inst.declined.len > 0:
      lines.add "    declines " & inst.declined.join(", ")
    for a in expandInstance(inst):
      lines.add "    -> " & $a
  if d.assertions.len > 0:
    lines.add "  authored:"
    for a in d.assertions: lines.add "    -> " & $a
  lines.join("\n")
