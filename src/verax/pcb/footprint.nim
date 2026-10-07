## The footprint model: what goes under a component and where each pad
## lands, resolved from the `footprint` annotation ("Lib:Name").
##
## **Minimal**: enough to put copper into a `Pcb` and emit a
## `(footprint ...)` node. `FootprintPad.id` is the pad/pin join key
## (`addLand`, `PackageDef`); mismatches are reported by `pcb/assemble`.
##
## **`source` is load-bearing**: the verbatim `(footprint ...)` bytes that
## `kicadgen` splices rather than regenerating KiCad graphics.
##
## **`FootprintPad.layers` are raw KiCad tokens** (`*.Cu`), expanded only
## when placed on a real board.
##
## **A registry of pure data, with no built-in source**:
## `import verax/pcb/formats/kicadmod` registers the KiCad one. Other
## sources can register alongside it.

import std/tables
import ./units
import ./geometry
import ./types

type
  PadType* = enum
    ptSmd, ptThruHole, ptNpThruHole, ptConnect

  FootprintPad* = object
    id*: string
      ## Pad id -- the `addLand`/`PackageDef.pins` join key.
    padType*: PadType
    aperture*: Aperture
      ## Interned into `Pcb.apertures` when placed, not here.
    at*: Point
      ## Footprint-local, canonical frame (Y up; the reader already flipped
      ## KiCad's Y).
    rot*: Deg
    layers*: seq[string]
      ## Raw KiCad layer tokens, wildcards preserved.
    drillDia*: Nm
      ## `0` for SMD.
    drillOffset*: Point
    attrs*: OrderedTable[string, string]

  Footprint* = ref object
    name*: string
      ## `"Lib:Name"` (or a bare path) as requested, not necessarily the
      ## file's own name.
    mount*: MountKind
    pads*: seq[FootprintPad]
    courtyard*: Polygon
      ## Footprint-local; empty without `*.CrtYd` graphics (grid spacing then
      ## falls back to `bodyBox`, then a fixed pitch).
    bodyBox*: Box
      ## Footprint-local bounding box of the body (`*.Fab`).
    height*: Nm
      ## `0` means unknown (`.kicad_mod` doesn't state it).
    graphics*: seq[tuple[layer: string, shape: Shape]]
      ## Silk / fab / courtyard, footprint-local (untransformed).
    source*: string
      ## The verbatim `(footprint ...)` text, spliced by `kicadgen`.
    attrs*: OrderedTable[string, string]

  FootprintSource* = ref object
    name*: string
    resolve*: proc (spec: string): Footprint {.nimcall.}
      ## Return `nil` for "not mine"; raise only for a spec this source
      ## recognises but can't resolve, so the error names the real problem.

var registry: seq[FootprintSource]
  ## Registration order is resolution order; the first source that claims a
  ## spec wins, so a specific source can shadow a generic one.

proc registerFootprintSource*(s: FootprintSource) =
  registry.add s

proc footprintSources*(): seq[string] =
  for s in registry: result.add s.name

proc findFootprint*(spec: string): Footprint =
  ## The first non-nil result across sources, or `nil` if none recognised
  ## `spec` (the caller decides what that means). Never raises for an
  ## unresolved spec.
  for s in registry:
    if s.resolve == nil: continue
    let fp = s.resolve(spec)
    if fp != nil: return fp
  nil
