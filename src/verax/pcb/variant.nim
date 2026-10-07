## The data model for **multiple physical layouts of one subcircuit**:
## types, registry, and the instance -> variant binding. **No algorithm**:
## `selectVariant`/`instantiateVariant` raise by name rather than stub a
## plausible answer.
##
## **Keyed by `Netlist.name`** (the template): one layout, N instances.
##
## **A registry of pure data, no built-ins** (like `PackageDef`), so it
## could come from a file. Duplicate `(subcircuit, name)` raises.
##
## **The binding is `attrs["layout.variant"]` on the instance component**
## (`netlist/layouthints`), authored on the netlist side.
##
## **`selectVariant` raises**, naming the constraints and the variants that
## exist: a first-match stub would silently ignore constraints.
## `instantiateVariant` raises too -- that's a placer-and-router's job.

import std/[strutils, tables]

import ./units
import ./geometry
import ./types

type
  VariantPlacement* = object
    designator*: string
      ## The component's designator inside the template, unprefixed.
    at*: Point
      ## Offset from the variant's origin, not board coordinates.
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
    # A side constraint means every placement must be on that side.
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
  ## Never "return the first fit": a real policy must rank candidates (layer
  ## count, extent, utilisation). Raises naming what was asked and what
  ## exists; a real policy replaces the body, not the signature.
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
  ## Never implemented: stamping a variant onto `pcb` needs collision
  ## checks, bottom-side mirroring and keepouts (a placer/router's job).
  raise newException(PcbError,
    "instantiateVariant: not implemented -- '" & v.name & "' (" &
    v.subcircuit & ") has " & $v.placements.len & " placement(s) and " &
    $v.routes.len & " route(s) to stamp onto '" & instance &
    "'; no placer or router exists yet to do it safely")
