## The data model for **multiple physical layouts of one subcircuit** --
## types, a registry, and the instance -> variant binding -- committed now so
## a later place-and-route stage has nothing left to re-litigate about the
## *shape* of a variant. **No algorithm lives here**: no placer, no router,
## no variant-selection policy beyond naming what a real one would need to
## decide between. `selectVariant`/`instantiateVariant` raise "not
## implemented" by name rather than stubbing a plausible-looking answer --
## see each proc's own doc comment for why a stub here is worse than a
## refusal.
##
## Four decisions, each stated so a later stage does not reopen it:
##
## **Keyed by `Netlist.name`, not by instance.** `verify.nim` and
## `schematic/render.keepFullSchematic` already spell a subcircuit's identity
## this way -- a block instanced twice is drawn once -- so a variant attaches
## to the *template*, which is the whole point of having one: one layout, N
## instances.
##
## **A registry of pure data, no procs on the variant, no built-ins** -- the
## `PackageDef`/`PartPinmux` shape (`netlist/packages.nim`, `netlist/pinmux.nim`):
## a variant computes nothing, so it could later be read from a file rather
## than written in Nim, and there is no generic variant the way there is no
## generic multi-channel package -- every one is a specific board's specific
## layout, owned by whatever `designs/lib/` module states it. Duplicate
## `(subcircuit, name)` raises, the same posture `registerPackage` and
## `registerInterfaceDef` already take on a collision.
##
## **"This instance uses variant X" is `attrs["layout.variant"]` on the
## instance `Component`**, joining the `netlist/layouthints.nim` `layout.*`
## family (`layoutVariant`/`setLayoutVariant`, that module's `"variant"` key)
## rather than a field here -- `pcb/` must not gain an edge *from*
## `netlist/`, and the binding is authored on the netlist side (the DSL's
## `layout:` block) long before any `Pcb` exists to hold it.
##
## **`selectVariant` raises, naming the constraints asked for and the
## variants that exist**, rather than returning the first match: a stub that
## silently ignored `VariantConstraints` would look like it worked while
## quietly picking a variant that does not fit the copper-layer count or
## extent a caller actually has -- precisely the failure mode this
## codebase's named refusals exist to avoid (`spice/models.expandSourceImpedance`'s
## own doc comment in `verify.nim`, for the identical reasoning applied to a
## PDN check that would otherwise always pass). `instantiateVariant` raises
## for the same reason: stamping copper onto a `Pcb` from a `LayoutVariant`
## is a placer-and-router's job, which this stage deliberately does not do.

import std/[strutils, tables]

import ./units
import ./geometry
import ./types

type
  VariantPlacement* = object
    designator*: string
      ## Subcircuit-local -- the component's own designator inside the
      ## template netlist, before any hierarchical prefix.
    at*: Point
      ## Subcircuit-local frame: offset from the variant's own origin, not
      ## board coordinates. `instantiateVariant` is what would apply the
      ## instance's own placement transform on top of this.
    rot*: Deg
    side*: BoardSide
    footprint*: string

  VariantRoute* = object
    net*: string
      ## Subcircuit-local net name.
    layer*: string
    path*: Path
    width*: Nm

  LayoutVariant* = ref object
    name*: string
    subcircuit*: string
      ## `Netlist.name` of the template this lays out.
    copperLayers*: int
    extent*: Box
    placements*: seq[VariantPlacement]
    routes*: seq[VariantRoute]
    vias*: seq[Hole]
    attrs*: OrderedTable[string, string]

  VariantConstraints* = object
    maxCopperLayers*: int
    maxExtent*: Box
    requireSide*: BoardSide

var registry: OrderedTable[string, seq[LayoutVariant]]
  ## Keyed by `subcircuit`, variants in registration order.

proc registerLayoutVariant*(v: LayoutVariant) =
  if v == nil or v.subcircuit.len == 0 or v.name.len == 0:
    raise newException(PcbError,
      "registerLayoutVariant: a variant needs both a subcircuit and a name")
  if not registry.hasKey(v.subcircuit): registry[v.subcircuit] = @[]
  for existing in registry[v.subcircuit]:
    if existing.name == v.name:
      raise newException(PcbError,
        "layout variant '" & v.name & "' is already registered for " &
        "subcircuit '" & v.subcircuit & "'")
  registry[v.subcircuit].add v

proc layoutVariants*(subcircuit: string): seq[LayoutVariant] =
  registry.getOrDefault(subcircuit, @[])

proc fits(v: LayoutVariant, c: VariantConstraints): bool =
  if c.maxCopperLayers > 0 and v.copperLayers > c.maxCopperLayers: return false
  if not c.maxExtent.isEmpty and not c.maxExtent.contains(v.extent): return false
  if c.requireSide in {bsTop, bsBottom}:
    # A constraint names a side only when every placement must land on it --
    # nothing here infers "which side does this variant mostly use", since
    # that is a policy question the caller (not this data model) answers.
    for p in v.placements:
      if p.side != c.requireSide: return false
  true

proc describe(c: VariantConstraints): string =
  var parts: seq[string]
  if c.maxCopperLayers > 0: parts.add "<= " & $c.maxCopperLayers & " copper layers"
  if not c.maxExtent.isEmpty:
    parts.add "extent <= " & $width(c.maxExtent).toMm & " x " & $height(c.maxExtent).toMm & " mm"
  if c.requireSide in {bsTop, bsBottom}: parts.add "side = " & $c.requireSide
  if parts.len == 0: "(no constraints stated)" else: parts.join(", ")

proc selectVariant*(subcircuit: string, c: VariantConstraints): LayoutVariant =
  ## Deliberately never implemented as "return the first fit": a real
  ## selection policy has to rank candidates that all satisfy `c` (fewest
  ## layers, smallest extent, best courtyard utilisation -- a later stage's
  ## question), and a stub that picked one anyway would look like it worked
  ## while silently ignoring every constraint that did not happen to rule
  ## its pick out. Names what was asked for and what actually exists, which
  ## a caller reading the raise can act on today; a real policy replaces
  ## this proc's body, not its signature.
  let candidates = layoutVariants(subcircuit)
  var fitting: seq[string]
  var all: seq[string]
  for v in candidates:
    all.add v.name
    if fits(v, c): fitting.add v.name
  raise newException(PcbError,
    "selectVariant: not implemented -- no selection policy exists yet. " &
    "Subcircuit '" & subcircuit & "' has " & $candidates.len & " registered " &
    "variant(s)" & (if all.len > 0: " (" & all.join(", ") & ")" else: "") &
    ", asked for " & describe(c) &
    (if fitting.len > 0: "; " & fitting.join(", ") & " would fit"
     else: "; none registered fit that"))

proc instantiateVariant*(pcb: Pcb, v: LayoutVariant, instance: string,
                         at: Point, rot: Deg, side: BoardSide) =
  ## Deliberately never implemented: stamping `v`'s placements, routes and
  ## vias onto `pcb` at `(at, rot, side)` is a placer-and-router's job (real
  ## collision checking against whatever else already occupies `pcb`, a
  ## mirror for `side == bsBottom`, keepouts), none of which this stage
  ## builds. A version that copied geometry in blindly would produce a
  ## `Pcb` that *looks* routed while silently overlapping or mis-siding
  ## whatever it landed on.
  raise newException(PcbError,
    "instantiateVariant: not implemented -- '" & v.name & "' (" &
    v.subcircuit & ") has " & $v.placements.len & " placement(s) and " &
    $v.routes.len & " route(s) to stamp onto '" & instance &
    "'; no placer or router exists yet to do it safely")
