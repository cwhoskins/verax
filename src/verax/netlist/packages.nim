## One physical package, several channels on different sheets.
##
## A dual op-amp is one chip, one footprint, one BoM line, one silkscreen
## designator. The netlist models it as N `Component`s -- often in different
## child netlists, when the channels are two instances of one `subckt` -- that
## happen to share a `partNumber` and nothing else. This module adds the
## missing statement: *these sections are the same die*.
##
## **It stores its data in namespaced `attrs` and adds nothing to
## `types.nim`**, for the reason `environment.nim` and `contract/design.nim`
## do: `graph.clone` copies `attrs` verbatim at every level, so membership
## survives `clone`/`instantiate`/`flatten`/`extractSubcircuit`/`isolate` with
## no new code. A root registry of direct `Component`/`Pin` references would
## need remapping written and tested across every one of those transforms, and
## `extractInstance` (which clones a child alone) would strand it.
##
## **A package needs a definition** -- a full pinout -- because only that lets
## `pcb/graph.addLand` resolve pad "7" on an NE5532 to section B's `OUT`, and
## lets `bom.nim` fall back to a shared part number when `Placement.component`
## is nil. Definitions are a runtime registry of plain data (no procs, unlike
## `RoleDef` -- a package computes nothing), keyed by part number. **No
## built-ins**: there is no generic multi-channel package the way there is a
## generic `power_rail` role; every one is a specific part. This library owns
## the mechanism, `designs/lib/` owns the catalogue.
##
## **The shared-pin check is by object identity, not by name.** In a stereo
## board both channels' `V+` nets are distinct `Net` objects that share the
## name `VP` (clones of one template net). A name comparison would pass a
## genuinely miswired board -- the exact defect the check exists to catch. So
## `validatePackages` resolves each global pin upward through `Pin.hierNet`/
## ports to the outermost net and compares those by identity.
##
## **A SPICE round trip intentionally loses package metadata.** `attrs` never
## reach a deck, so a reparsed netlist carries no `package.*` keys and no
## synthetic device encodes package identity. A consumer that needs the
## packaging keeps the Nim source.

import std/[strutils, tables]

import ./types
import ./graph
import ./issue

export issue

# --- definitions ------------------------------------------------------------

type
  PackageSection* = object
    name*: string            ## "A", "B"
    pins*: seq[string]       ## logical pin names on this section

  PackagePin* = object
    section*: string         ## "" for a global pin
    logical*: string         ## "OUT", "V+"

  PackageDef* = ref object
    name*: string                              ## registry key, "NE5532"
    partNumber*, footprint*, doc*: string
    sections*: seq[PackageSection]
    globalPins*: seq[string]                   ## "V+", "V-", "EN"
    pins*: OrderedTable[string, PackagePin]    ## package pin id -> what it is
    attrs*: OrderedTable[string, string]

proc sectionNames*(def: PackageDef): seq[string] =
  for s in def.sections: result.add s.name

proc hasSection*(def: PackageDef, name: string): bool =
  for s in def.sections:
    if s.name == name: return true
  false

proc section*(def: PackageDef, name: string): PackageSection =
  for s in def.sections:
    if s.name == name: return s
  raise newException(NetlistError,
    "package '" & def.name & "' has no section '" & name & "'; it has: " &
    def.sectionNames.join(", "))

proc newPackageDef*(name: string,
                    pins: openArray[tuple[id, section, logical: string]],
                    partNumber = "", footprint = "", doc = ""): PackageDef =
  ## Build a definition from its full pinout: one `(id, section, logical)`
  ## triple per package pin, `section = ""` for a global pin. Section order
  ## and per-section pin order follow first appearance in `pins`.
  result = PackageDef(name: name, partNumber: partNumber, footprint: footprint,
                      doc: doc)
  for (id, sec, logical) in pins:
    if sec.len == 0:
      if logical notin result.globalPins: result.globalPins.add logical
    else:
      var found = -1
      for i in 0 ..< result.sections.len:
        if result.sections[i].name == sec: found = i
      if found < 0:
        result.sections.add PackageSection(name: sec)
        found = result.sections.high
      if logical notin result.sections[found].pins:
        result.sections[found].pins.add logical
    result.pins[id] = PackagePin(section: sec, logical: logical)

# --- registry -------------------------------------------------------------

var packageRegistry: OrderedTable[string, PackageDef]

proc validateDef(def: PackageDef) =
  ## Every section pin and every global pin must appear in `pins` exactly
  ## once, and every entry in `pins` must name a section the def declares (or
  ## be global). A datasheet transcription error is what this catches.
  if def.pins.len == 0:
    raise newException(NetlistError,
      "package '" & def.name & "' has no pin map")
  var seen: OrderedTable[string, int]
  for id, pp in def.pins:
    if pp.section.len > 0 and not def.hasSection(pp.section):
      raise newException(NetlistError,
        "package '" & def.name & "' pin '" & id & "' names section '" &
        pp.section & "', which the definition does not declare")
    let key = pp.section & "|" & pp.logical
    seen[key] = seen.getOrDefault(key, 0) + 1
  for s in def.sections:
    for lp in s.pins:
      let n = seen.getOrDefault(s.name & "|" & lp, 0)
      if n != 1:
        raise newException(NetlistError,
          "package '" & def.name & "' section '" & s.name & "' pin '" & lp &
          "' appears " & $n & " times in the pin map, expected exactly once")
  for gp in def.globalPins:
    let n = seen.getOrDefault("|" & gp, 0)
    if n != 1:
      raise newException(NetlistError,
        "package '" & def.name & "' global pin '" & gp & "' appears " & $n &
        " times in the pin map, expected exactly once")

proc knownPackages*(): seq[string] =
  for k in packageRegistry.keys: result.add k

proc registerPackage*(def: PackageDef) =
  ## Raises on an empty or duplicate name, and validates the pinout.
  if def == nil or def.name.len == 0:
    raise newException(NetlistError, "package definition must have a name")
  if packageRegistry.hasKey(def.name):
    raise newException(NetlistError,
      "package '" & def.name & "' is already registered")
  validateDef(def)
  packageRegistry[def.name] = def

proc packageDef*(name: string): PackageDef =
  if not packageRegistry.hasKey(name):
    raise newException(NetlistError,
      "no such package: " & name &
      (if knownPackages().len > 0: " (known: " & knownPackages().join(", ") & ")"
       else: " (none registered)"))
  packageRegistry[name]

proc isPackageRegistered*(name: string): bool = packageRegistry.hasKey(name)

# --- membership: three dotted keys on the member component ----------------

const
  packagePrefix* = "package."
  keyPackageRef* = "package.ref"        ## the physical package's board designator
  keyPackageSection* = "package.section"  ## which section this component is
  keyPackageDef* = "package.def"        ## the PackageDef name it was assigned under

proc packageRef*(c: Component): tuple[has: bool, value: string] =
  if c != nil and c.attrs.hasKey(keyPackageRef):
    (true, c.attrs[keyPackageRef])
  else:
    (false, "")

proc packageSection*(c: Component): tuple[has: bool, value: string] =
  if c != nil and c.attrs.hasKey(keyPackageSection):
    (true, c.attrs[keyPackageSection])
  else:
    (false, "")

proc packageDefName*(c: Component): tuple[has: bool, value: string] =
  if c != nil and c.attrs.hasKey(keyPackageDef):
    (true, c.attrs[keyPackageDef])
  else:
    (false, "")

proc isPackaged*(c: Component): bool =
  c != nil and c.attrs.hasKey(keyPackageRef)

proc displayDesignator*(c: Component): string =
  ## "U10A" for a packaged part, else `c.designator`.
  let r = packageRef(c)
  let s = packageSection(c)
  if r.has and s.has: r.value & s.value
  else: c.designator

proc designatorsOf(comps: seq[Component]): string =
  var ds: seq[string]
  for c in comps: ds.add c.designator
  ds.join(", ")

iterator walkComponents(nl: Netlist): Component =
  ## Every component of `nl` and its children, recursively.
  var stack = @[nl]
  while stack.len > 0:
    let cur = stack.pop()
    for _, c in cur.components: yield c
    for _, child in cur.children: stack.add child

proc packageMembers*(nl: Netlist, pkgRef: string): seq[Component] =
  ## Every component under `nl` (walking children) tagged with this
  ## `package.ref`.
  for c in walkComponents(nl):
    let r = packageRef(c)
    if r.has and r.value == pkgRef: result.add c

proc packages*(nl: Netlist): OrderedTable[string, seq[Component]] =
  ## Every package group under `nl`, keyed by `package.ref`. Reconstructed by
  ## walking `nl` and its `children` -- there is no design-global registry, so
  ## `pcb` (which does not import `contract`) can read this too.
  for c in walkComponents(nl):
    let r = packageRef(c)
    if r.has:
      if not result.hasKey(r.value): result[r.value] = @[]
      result[r.value].add c

# --- assignment: the one writer -----------------------------------------

type
  PackageInstance* = object
    def*: PackageDef
    designator*: string

proc packageInstance*(defName, designator: string): PackageInstance =
  ## A package instance, created before the design block so an unregistered
  ## definition raises at the `let` rather than inside a macro expansion.
  PackageInstance(def: packageDef(defName), designator: designator)

proc assignSection*(pkg: PackageInstance, inst: Netlist,
                    sectionName, localDesignator: string) =
  ## Resolve `localDesignator` in `inst` (an instance's own clone, or the
  ## design netlist for the flat case) and write the three `package.*` keys.
  ## Raises immediately on what it can see at the statement.
  if pkg.def == nil:
    raise newException(NetlistError, "assignSection: package instance has no def")
  if not pkg.def.hasSection(sectionName):
    raise newException(NetlistError,
      "package '" & pkg.def.name & "' has no section '" & sectionName &
      "'; it declares: " & pkg.def.sectionNames.join(", "))
  let c = findComponent(inst, localDesignator)
  if c == nil:
    raise newException(NetlistError,
      "assignSection " & pkg.designator & "." & sectionName & ": '" &
      localDesignator & "' names no component here")

  # Reconstruct the existing group by walking the true root.
  let r = root(if c.netlist != nil: c.netlist else: inst)
  var members: seq[Component]
  for m in walkComponents(r):
    if m == c: continue
    let mr = packageRef(m)
    if mr.has and mr.value == pkg.designator: members.add m

  let already = packageRef(c)
  if already.has and already.value != pkg.designator:
    raise newException(NetlistError,
      "component " & c.designator & " is already assigned to package '" &
      already.value & "'")

  for m in members:
    if packageSection(m).value == sectionName and m != c:
      raise newException(NetlistError,
        "package '" & pkg.designator & "' section '" & sectionName &
        "' is already assigned to " & m.designator)
    if root(m.netlist) != r:
      raise newException(NetlistError,
        "package '" & pkg.designator & "' spans two designs: " & m.designator &
        " and " & c.designator & " live under different roots")
  if not already.has and members.len + 1 > pkg.def.sections.len:
    raise newException(NetlistError,
      "package '" & pkg.designator & "' (" & pkg.def.name & ") has " &
      $pkg.def.sections.len & " section(s); assigning a " & $(members.len + 1) &
      "th")

  c.attrs[keyPackageRef] = pkg.designator
  c.attrs[keyPackageSection] = sectionName
  c.attrs[keyPackageDef] = pkg.def.name

proc section*(pkg: PackageInstance, name, localDesignator: string): proc (nl: Netlist) =
  ## A closure for `instance ..., with = u10.section("A", "U1")`. `handleInstance`
  ## runs it against the instance's own clone.
  let captured = pkg
  result = proc (nl: Netlist) =
    assignSection(captured, nl, name, localDesignator)

proc assign*(pkg: PackageInstance, nl: Netlist, name, localDesignator: string) =
  ## The flat path: assign after the design block, for components with no
  ## instance to hang a `with =` hook on.
  assignSection(pkg, nl, name, localDesignator)

proc assign*(pkg: PackageInstance, c: Component, name: string) =
  ## The flat path, when the caller holds the component object.
  if c.netlist == nil:
    raise newException(NetlistError,
      "assign " & pkg.designator & "." & name & ": " & c.designator &
      " does not belong to a netlist yet")
  assignSection(pkg, c.netlist, name, c.designator)

# --- the global-pin identity walk -------------------------------------

proc outermostNet*(p: Pin): Net =
  ## Resolve `p`'s net upward through subcircuit ports to the outermost net
  ## it is joined to. Compared by object identity by the global-pin check --
  ## two same-named clone nets on one rail are the same conductor only if
  ## they resolve to the same object.
  if p == nil or p.net == nil: return nil
  var n = p.net
  while true:
    let owner = n.netlist
    if owner == nil or owner.parent == nil: return n
    var isPort = false
    for _, pn in owner.ports:
      if pn == n: isPort = true
    if not isPort: return n
    let inst = owner.instanceOf
    if inst == nil: return n
    var up: Net = nil
    for _, ip in inst.pins:
      if ip.hierNet == n: up = ip.net
    if up == nil: return n
    n = up

# --- validation --------------------------------------------------------

proc validatePackages*(nl: Netlist): seq[Issue] =
  ## What is wrong with the package groups a netlist declares. An `Issue`,
  ## not a raise, for anything a netlist can legitimately be *in*.
  let r = root(nl)
  let groups = packages(r)
  for pkgRef, members in groups:
    # def agreement / existence
    var defNames: seq[string]
    for m in members:
      let dn = packageDefName(m)
      if dn.has and dn.value notin defNames: defNames.add dn.value
    if defNames.len > 1:
      result.add newIssue("package_def_disagreement", sevError,
        "package '" & pkgRef & "' members disagree on which definition they " &
        "were assigned under: " & defNames.join(", "), components = members)
      continue
    if defNames.len == 0:
      continue
    let defName = defNames[0]
    if not isPackageRegistered(defName):
      result.add newIssue("package_unknown_def", sevError,
        "package '" & pkgRef & "' names definition '" & defName &
        "', which is not registered", components = members)
      continue
    let def = packageDef(defName)

    # per-member root check
    for m in members:
      if root(m.netlist) != r:
        result.add newIssue("package_foreign_root", sevError,
          "package '" & pkgRef & "' member " & m.designator &
          " lives under a different root than the rest of its package",
          components = @[m])

    # section-level checks
    var bySection: OrderedTable[string, seq[Component]]
    for m in members:
      let s = packageSection(m)
      let key = if s.has: s.value else: ""
      if not bySection.hasKey(key): bySection[key] = @[]
      bySection[key].add m
    for sName, comps in bySection:
      if sName.len == 0 or not def.hasSection(sName):
        result.add newIssue("package_unknown_section", sevError,
          "package '" & pkgRef & "' assigns section '" & sName &
          "', which '" & def.name & "' does not declare (it has: " &
          def.sectionNames.join(", ") & ")", components = comps)
        continue
      if comps.len > 1:
        result.add newIssue("package_duplicate_section", sevError,
          "package '" & pkgRef & "' section '" & sName &
          "' is assigned to more than one component: " & designatorsOf(comps),
          components = comps)
      let secDef = def.section(sName)
      for c in comps:
        # pins the component carries that the def declares neither on this
        # section nor as global
        for pinName, _ in c.pins:
          if pinName notin secDef.pins and pinName notin def.globalPins:
            result.add newIssue("package_unknown_pin", sevError,
              "package '" & pkgRef & "' section '" & sName & "' (" &
              c.designator & ") carries pin '" & pinName & "', which '" &
              def.name & "' declares neither as a section pin nor as global",
              components = @[c])
        # declared section pins the component does not have
        for lp in secDef.pins:
          if not c.pins.hasKey(lp):
            result.add newIssue("package_pin_unconnected", sevWarning,
              "package '" & pkgRef & "' section '" & sName & "' (" &
              c.designator & ") leaves section pin '" & lp & "' unconnected",
              components = @[c])
        # part number agreement
        if def.partNumber.len > 0 and c.partNumber.len > 0 and
           c.partNumber != def.partNumber:
          result.add newIssue("package_part_number_mismatch", sevWarning,
            "package '" & pkgRef & "' member " & c.designator & " has part " &
            "number '" & c.partNumber & "', but '" & def.name & "' is '" &
            def.partNumber & "'", components = @[c])

    let sectionCount = block:
      var n = 0
      for sName, comps in bySection:
        if def.hasSection(sName): inc n
      n
    if sectionCount > def.sections.len:
      result.add newIssue("package_over_assigned", sevError,
        "package '" & pkgRef & "' assigns " & $sectionCount & " sections, but '" &
        def.name & "' declares only " & $def.sections.len, components = members)

    # the global-pin check: identity across sections
    for gp in def.globalPins:
      var seenNet: Net = nil
      var seenOn = ""
      for m in members:
        if not m.pins.hasKey(gp): continue
        let outer = outermostNet(m.pins[gp])
        if outer == nil: continue
        if seenNet == nil:
          seenNet = outer
          seenOn = m.designator
        elif outer != seenNet:
          result.add newIssue("package_global_pin_conflict", sevError,
            "package '" & pkgRef & "' global pin '" & gp & "' resolves to '" &
            seenNet.name & "' on " & seenOn & " but '" & outer.name & "' on " &
            m.designator & "': the sections are not the same die",
            components = @[m])
          break
