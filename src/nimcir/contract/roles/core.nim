## Roles: named, parameterized bundles of assertions.
##
## A role says what something *is* in a design -- "this net is the 3V3 rail",
## "these two nets are a 400 kHz I2C bus" -- which is the metadata a whole
## family of planned checks is blocked on. The design decision worth stating
## plainly is that **a role is a template, not a tag**.
##
## A bare tag (`kind = "i2c"`) puts the meaning in whatever reads the tag, so
## supporting a new protocol means changing this library. A template puts the
## meaning in the definition, so a user with a niche protocol writes a
## `RoleDef` in their own file and registers it. The built-in roles use
## **no privileged mechanism** -- they are ordinary `RoleDef`s registered the
## ordinary way -- because a built-in that cheats makes user-defined roles
## second-class and then nobody writes them.
##
## **A role has two halves, and they are deliberately separate procs.**
##
## * `apply` writes annotations onto the netlist. This is the half with a life
##   independent of any checking: `spice/isolate` terminates a cut rail using
##   `Net.attrs["voltage"]`, long before anything asks whether the rail is
##   *correct*. If a role were only a bundle of assertions, `isolate` would
##   have to introspect the assertion list to recover a rail voltage, which is
##   backwards and fragile.
## * `expand` is pure and returns assertions. It never touches the graph.
##
## `RoleDef.expand`/`apply` are **proc values on a data object**, not
## compile-time constructs, so a role built at runtime -- from a config file,
## an MCP call, or a loaded plugin -- registers and behaves identically to one
## written here.
##
## **This module is the core only** -- the `RoleDef`/`RoleInstance` types, the
## registry, and the parameter/subject helpers every expander shares. The
## built-in `RoleDef`s themselves live beside it under `contract/roles/`,
## split by category (`power`, `analog`, `digital`), and
## `contract/roles/built_in` houses `registerBuiltinRoles` and calls it at
## init. Importing `contract/roles/core` gives you the machinery to define
## and register a role; importing `contract/roles/built_in` (which the
## `contract` hub and `contract/dsl` do) additionally registers the
## built-ins.

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
    declined*: seq[string]
      ## Claim suffixes this instance does not make, from the reserved
      ## `without` parameter. A role's *always-claims* are otherwise
      ## unconditional, and some of them do not fit every circuit the role
      ## otherwise describes: `opamp_stage` claims `phase_margin_deg`, and
      ## `analyzeLoopGain` cannot open a Sallen-Key's loop, so the claim can
      ## only ever come back unchecked. Carrying an unmeasurable claim in
      ## every run is its own harm -- `NOT CHECKED` is the section that must
      ## not become background noise -- and the alternative was to fork the
      ## role, which is how a shared vocabulary dies.
      ##
      ## Declining is **not** silence: `explain` still prints what was
      ## declined, and a suffix that matches nothing is an error rather than
      ## a typo that quietly leaves the claim in place.

  RoleExpander* = proc (inst: RoleInstance): seq[Assertion] {.nimcall.}
    ## May raise: `addRole` validates bindings and parameters before an
    ## expander ever sees an instance, so an expander is entitled to assume
    ## its required parts are present rather than defending against it.
  RoleApplier* = proc (inst: RoleInstance, nl: Netlist) {.nimcall.}

  RoleDef* = object
    name*: string
    doc*: string
    expects*: string
      ## Optional interface definition this role is written against.
    parts*: seq[RolePart]
    params*: seq[AnnDef]
      ## Reuses the annotation registry's vocabulary type rather than
      ## inventing a second one: a role parameter and a design annotation are
      ## the same kind of thing (a named, typed, documented value) and should
      ## not be described twice in two ways.
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
  ## A role parameter as a number, falling back when unset. Roles apply their
  ## own defaults explicitly rather than the registry carrying them: a
  ## defaulted *design annotation* is a silent-drift hazard worth keeping
  ## visible, and lumping role defaults in with it would blur the two.
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
