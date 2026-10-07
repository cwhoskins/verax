## Roles: named, parameterized bundles of assertions -- "this net is the 3V3
## rail", "these nets are a 400 kHz I2C bus".
##
## **A role is a template, not a tag**: the meaning lives in the definition,
## so a user with a niche protocol writes and registers a `RoleDef`.
## Built-ins use no privileged mechanism.
##
## **Two separate halves**: `apply` writes annotations (`spice/isolate`
## reads `Net.attrs["voltage"]` regardless of checking); `expand` is pure
## and returns assertions. Both are proc values, so a role built at runtime
## behaves identically.
##
## This module is the core (types, registry, helpers). Built-ins live in
## `contract/roles/` by category; `contract/roles/built_in` registers them.

import std/tables
import ../../netlist/types
import ../../netlist/annotations
import ../types as ctypes

export ctypes

type
  RolePart* = object
    name*: string
      ## The part this subject plays: `"rail"`, `"sda"`, `"controller"`.
    kind*: SubjectKind
    optional*: bool
    doc*: string

  RoleInstance* = object
    role*: string
      ## Which `RoleDef`.
    name*: string
      ## This instance: `"vdd_rail"`, `"i2c0"`.
    bindings*: OrderedTable[string, Subject]
    params*: OrderedTable[string, string]
    member*: int
      ## Which member of a fanned-out interface array this instance is (`0`
      ## by default), set by `design.addImpliedRoles` for `spi`'s per-CS
      ## fan-out so once-per-bus claims (`controller_count`) appear once.
      ## A field, not a param: `verify.claimingRoles` states params as `"1"`,
      ## which would hide a param-gated claim.
    declined*: seq[string]
      ## Claim suffixes this instance declines (the reserved `without`
      ## param), for always-claims that don't fit (e.g. `phase_margin_deg` on
      ## a Sallen-Key, whose loop can't be opened). Better than forking the
      ## role. `explain` prints them; a suffix matching nothing is an error.

  RoleExpander* = proc (inst: RoleInstance): seq[Assertion] {.nimcall.}
    ## May raise. `addRole` validates bindings and params first, so an
    ## expander may assume required parts are present.
  RoleApplier* = proc (inst: RoleInstance, nl: Netlist) {.nimcall.}

  RoleDef* = object
    name*: string
    doc*: string
    expects*: string
      ## Optional interface definition this role is written against.
    parts*: seq[RolePart]
    params*: seq[AnnDef]
      ## Reuses the annotation registry's type: a role parameter and a design
      ## annotation are the same kind of thing.
    apply*: RoleApplier
    expand*: RoleExpander

var roleRegistry: OrderedTable[string, RoleDef]

proc registerRole*(def: RoleDef) =
  if def.name.len == 0:
    raise newException(NetlistError, "role name must not be empty")
  if def.expand == nil:
    raise newException(NetlistError, "role '" & def.name & "' has no expander")
  roleRegistry[def.name] = def

proc roleDef*(name: string): RoleDef =
  if not roleRegistry.hasKey(name):
    raise newException(NetlistError, "no such role: " & name)
  roleRegistry[name]

proc isRole*(name: string): bool = roleRegistry.hasKey(name)
proc registeredRoles*(): seq[string] =
  for k in roleRegistry.keys: result.add k

# --- parameter access --------------------------------------------------

proc paramFloat*(inst: RoleInstance, name: string, fallback: float): float =
  ## A role parameter as a number, or `fallback`. Roles apply defaults
  ## explicitly rather than through the registry.
  if not inst.params.hasKey(name): return fallback
  parseAnnFloat(name, inst.params[name])

proc hasParam*(inst: RoleInstance, name: string): bool =
  inst.params.hasKey(name)

proc subject*(inst: RoleInstance, part: string): Subject =
  if not inst.bindings.hasKey(part):
    raise newException(NetlistError,
      "role '" & inst.name & "' has no binding for part '" & part & "'")
  inst.bindings[part]

proc hasPart*(inst: RoleInstance, part: string): bool =
  inst.bindings.hasKey(part)

proc assertionId*(inst: RoleInstance, suffix: string): string =
  inst.name & "." & suffix
