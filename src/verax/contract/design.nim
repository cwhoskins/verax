## A `Design`: a netlist plus what is claimed about it.
##
## `netlist(...)` returns a bare `Netlist`, which has nowhere to hang
## design-global data -- role instances and directly-authored assertions
## belong to the design as a whole, not to any one net or component. So a
## `Design` **owns** a `Netlist`, exactly as `Pcb` does and for the same
## reasons: the electrical model is not duplicated, nothing is added to
## `netlist/types.nim`, and a netlist-only consumer carries none of this.
##
## Role *membership* is the exception and is stored on the entity itself
## (`net.attrs["role.i2c0"] = "sda"`), because membership must survive
## `clone`, `extractSubcircuit` and `isolate` -- a fragment cut out for
## simulation should still know its nets were an I2C bus. Role *definitions*
## and parameters stay here, where losing them on a fragment extraction is
## the correct behaviour.

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
  ## A component *inside* this instance, as a `Subject` a role can bind.
  ##
  ## `role "gain_stage", left, opamp = XL.innerComponent("U1")` is the whole
  ## point: the instance `XL` is a real Nim binding at the design site, but
  ## nothing inside it is -- those identifiers were bound inside a `subckt`
  ## in another module and are long out of scope. So the instance is asked
  ## for them by name.
  ##
  ## The path is walked **immediately**, so a typo raises here, naming what
  ## the instance actually contains, rather than surfacing later as a role
  ## binding that resolves to nothing.
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
  ## A reference to another role instance, as a subject a multi-subject role
  ## can bind: `role "channel_match", stereo, a = roleRef("left"), ...`.
  ##
  ## One line, and no validation of its own on purpose. `dsl.subjectOf(Subject)`
  ## is an identity overload, so a helper returning a `Subject` routes through
  ## the `role` macro as a *binding* with no macro change -- and `resolve`
  ## below raises when the named instance is not there yet, which is also what
  ## makes "declare the referenced roles first" an enforced ordering rather
  ## than a convention. This is the `skClass` counterpart of `innerComponent`
  ## walking its path immediately.
  Subject(kind: skClass, name: name)

proc resolve(d: Design, s: Subject): tuple[net: Net, comp: Component, pin: Pin] =
  ## Subject -> live entity, so a binding to something that does not exist is
  ## caught when the role is attached rather than when it is evaluated.
  ##
  ## Names are resolved through `graph.find*`, so a subject may address
  ## something **inside a subcircuit instance** by a `hierSep`-separated path
  ## (`XL.U1`). A stereo board is two instances of one channel, and a claim
  ## about the left channel's amplifier has no other way to say which
  ## amplifier it means. The same call finds the entity before flattening, by
  ## descending, and after it, by the flat key -- so whatever holds the name
  ## does not have to know which of the two it is looking at.
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
    # A reference to another role instance. It resolves to no netlist entity
    # -- a role is not a net or a component -- so this returns all-nil, and
    # `tagMembership` below therefore tags nothing, which is correct. What it
    # does do is raise when the instance is absent: a `channel_match` naming
    # `left`/`right` must be declared *after* the two `gain_stage`s, and this
    # is where that is enforced.
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
    # An `skClass` binding resolves to all-nil and so tags nothing, which is
    # right: a role instance is not a netlist entity and has nothing to carry
    # a membership attr. The reference is still validated -- `resolve` raised
    # above if the named instance did not exist.

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
  ## Attaches a role instance: validates it, tags membership on the bound
  ## entities, and runs the role's `apply` half so its parameters land as
  ## ordinary annotations that existing consumers already read.
  if d.roles.hasKey(instanceName):
    raise newException(NetlistError, "duplicate role instance: " & instanceName)
  let def = roleDef(roleName)

  var inst = RoleInstance(role: roleName, name: instanceName)
  for (k, v) in bindings: inst.bindings[k] = v
  for (k, v) in params:
    # `without` is reserved on every role rather than declared by each one:
    # it says which of the role's claims this instance does not make, and a
    # role should not have to opt into being declinable.
    if k == "without":
      for part in v.split(','):
        let name = part.strip()
        if name.len > 0: inst.declined.add name
    else:
      inst.params[k] = v

  d.validate(def, inst)
  d.tagMembership(inst)
  # Validated by expanding once, which is free: an expander is pure. A
  # declined suffix that matches nothing is the same hazard as a misspelled
  # annotation key -- indistinguishable from an absent one, and it would
  # leave the claim standing while reading as though it had been dropped.
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
      if d.roles.hasKey(iface.name): continue
      var params: seq[(string, string)]
      for key, value in claim.params: params.add (key, value)
      # `claim.binds` maps a role part name to the interface signal it reads
      # from, for a def whose signals are not named to match the role's
      # parts (a `dp`/`dn` differential pair implying `diff_pair`, whose
      # parts are `p`/`n`). Everything not named here still auto-binds by
      # same-name matching in `addRoleFromInterface`; an explicit entry
      # simply reaches that call as a normal explicit binding.
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
      discard addRoleFromInterface(d, claim.role, iface.name, iface, bindings, params)

proc expandInstance*(inst: RoleInstance): seq[Assertion] =
  ## One role instance's claims, minus the ones it declined. Everything that
  ## reads a design's claims goes through here, so what `explain` prints and
  ## what `evaluate` checks cannot drift apart.
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
  ## Everything claimed about this design: what was authored directly, plus
  ## what every role instance expands to.
  result = d.assertions
  for _, inst in d.roles:
    result.add expandInstance(inst)

proc rolesOf*(e: Net | Component | Pin): seq[tuple[instance, part: string]] =
  ## Which role instances an entity belongs to, read back from the membership
  ## tags -- so this still works on a fragment that was cut out of the design
  ## and no longer has the `Design` object around it.
  for key, part in e.attrs:
    if key.startsWith(rolePrefix):
      result.add (instance: key[rolePrefix.len .. ^1], part: part)

proc explain*(d: Design): string =
  ## What each role claims, in full.
  ##
  ## Printability is not a nicety. Assertions generated on your behalf, that
  ## you cannot inspect, are how a contract layer turns into filler that
  ## always passes -- so the expansion is always dumpable.
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
    # Declining is stated, never silent: a claim dropped without a trace is
    # the same failure as a claim nobody evaluated.
    if inst.declined.len > 0:
      lines.add "    declines " & inst.declined.join(", ")
    for a in expandInstance(inst):
      lines.add "    -> " & $a
  if d.assertions.len > 0:
    lines.add "  authored:"
    for a in d.assertions: lines.add "    -> " & $a
  lines.join("\n")
