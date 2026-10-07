## One physical package, several channels on different sheets. A dual op-amp
## is one chip, footprint and BoM line, but N `Component`s (often in
## different instances). This states *these sections are the same die*.
##
## **Stored as namespaced `attrs`**, so membership survives clone, flatten
## and isolation (a root registry of references would need remapping).
##
## **A package needs a definition** (full pinout) so `pcb/graph.addLand`
## can resolve pad "7" to section B's `OUT`. Definitions are plain data in a
## runtime registry keyed by part number, with **no built-ins** -- designs
## supply the catalogue.
##
## **The shared-pin check is by identity, not name**: two channels' `VP`
## nets are distinct clone objects, so `validatePackages` resolves global
## pins to their outermost net and compares objects.
##
## **A SPICE round trip loses package metadata**; keep the Nim source.

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
  ## Build a definition from its pinout: one `(id, section, logical)` per
  ## pin, `section = ""` for global. Section and pin order follow first
  ## appearance.
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
  ## Every section and global pin appears in `pins` exactly once, and every
  ## entry names a declared section (or is global) -- catches transcription
  ## errors.
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
  ## Every package group under `nl`, keyed by `package.ref`, by walking the
  ## tree (no design-global registry, so `pcb` can read it).
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
  ## A package instance, created before the design block so an unknown
  ## definition raises at the `let`.
  PackageInstance(def: packageDef(defName), designator: designator)

proc assignSection*(pkg: PackageInstance, inst: Netlist,
                    sectionName, localDesignator: string) =
  ## Resolve `localDesignator` in `inst` (an instance clone, or the flat
  ## netlist) and write the three `package.*` keys. Raises on what it can
  ## see.
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
  ## A closure for `instance ..., with = u10.section("A", "U1")`, run on the
  ## instance's clone.
  let captured = pkg
  result = proc (nl: Netlist) =
    assignSection(captured, nl, name, localDesignator)

proc assign*(pkg: PackageInstance, nl: Netlist, name, localDesignator: string) =
  ## The flat path: assign after the design block.
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
  ## Resolve `p`'s net upward through ports to the outermost net; the global
  ## pin check compares these by identity.
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
  ## Problems with the declared package groups, as `Issue`s.
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
        # pins the def declares neither on this section nor as global
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
