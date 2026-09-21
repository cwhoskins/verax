## The footprint model this repository lacked: what to put under a
## component, and where each pad lands -- the piece `netlist/annotations`'
## `footprint` key names ("Lib:Name") and `pcb/assemble.nim` needs turned
## into real copper.
##
## **Minimal and honest**: exactly what is needed to put copper into a `Pcb`
## and to emit a `(footprint ...)` node, not a general CAD library format.
## `FootprintPad.id` is the join key `pcb/graph.addLand`/`packages.PackageDef`
## already use for a component pin, so a pad the footprint declares and a pin
## the netlist declares either agree by that string or `pcb/assemble.nim`
## reports the mismatch (`footprint_pad_unmatched`) -- nothing here resolves
## that itself.
##
## **`source` is load-bearing.** It holds the defining `(footprint ...)`
## node's raw bytes, and `formats/kicadgen.nim` splices those rather than
## regenerating silkscreen, 3D-model references or KiCad's `Prettify()`
## spacing -- the same bet `formats/sexp.nim` already makes for a board
## ("an untouched node needs no escape rule, no quoting policy and no number
## formatter to get right, because its raw bytes already are correct"). It is
## also the only thing that makes `formats/kicad.nim`'s documented capability
## boundary -- "do not create or reshape a component" -- liftable at all: a
## synthesized `.kicad_pcb` can carry a real footprint because it is quoting
## one, never inventing KiCad's own graphics syntax by rule.
##
## **`FootprintPad.layers` is raw, un-expanded KiCad layer tokens**
## (`*.Cu`, `F.Mask`, ...), not `PcbLayer` references. A `.kicad_mod` library
## file is read with no target board to expand a wildcard against -- there is
## no stack to resolve `*.Cu` into yet -- so expansion is deferred to whoever
## eventually places the footprint onto a real `Pcb` (`pcb/assemble.nim`).
## `formats/kicadgeom.expandPadLayers` is the board-aware counterpart, used
## only where a `Pcb` already exists (a footprint already embedded in a
## board being read).
##
## **Registry, mirroring `netlist/packages.nim`/`netlist/annotations.nim`: a
## runtime table of pure data, no built-in source registered here.** Nothing
## in this module knows KiCad exists -- `import verax/pcb/formats/kicadmod`
## is what registers the KiCad source, opt-in per import, the rule everywhere
## else in this codebase. That is also the seam `docs/layout_variants.md`
## records for an eventual OpenSCAD source: it would register a second
## `FootprintSource` here with no change to `findFootprint` or any caller,
## because OpenSCAD's own exports (STL/3MF mesh, or a flattened SVG/DXF) have
## no channel for pad identity -- see that doc for why that rules OpenSCAD
## out of *this* stage rather than out of the registry shape.

import std/tables
import ./units
import ./geometry
import ./types

type
  PadType* = enum
    ptSmd, ptThruHole, ptNpThruHole, ptConnect

  FootprintPad* = object
    id*: string
      ## Pad id -- the key `pcb/graph.addLand`/`PackageDef.pins` join on.
    padType*: PadType
    aperture*: Aperture
      ## Interned into `Pcb.apertures` at instantiation, not here: a bare
      ## `Footprint` belongs to no board yet.
    at*: Point
      ## Footprint-local, canonical frame (Y up, KiCad's Y already flipped
      ## by whichever reader built this).
    rot*: Deg
    layers*: seq[string]
      ## Raw KiCad layer tokens, wildcards preserved -- see the module doc
      ## comment on why expansion waits for a target `Pcb`.
    drillDia*: Nm
      ## `0` for SMD.
    drillOffset*: Point
    attrs*: OrderedTable[string, string]

  Footprint* = ref object
    name*: string
      ## `"Lib:Name"` as stated (or a bare path, for a literal `.kicad_mod`
      ## spec) -- what a caller asked `findFootprint` for, not necessarily
      ## what the source file calls itself.
    mount*: MountKind
    pads*: seq[FootprintPad]
    courtyard*: Polygon
      ## Footprint-local. Empty when the source carries no `*.CrtYd`
      ## graphics -- `pcb/assemble.nim` falls back to `bodyBox`, then a fixed
      ## pitch, for grid spacing when this is empty.
    bodyBox*: Box
      ## Footprint-local bounding box of the part's physical body
      ## (`*.Fab` graphics), independent of the courtyard clearance.
    height*: Nm
      ## `0` means unknown -- nothing in a `.kicad_mod` file states it.
    graphics*: seq[tuple[layer: string, shape: Shape]]
      ## Silk / fab / courtyard, footprint-local (untransformed).
    source*: string
      ## The verbatim `(footprint ...)` text this was read from. See the
      ## module doc comment -- this is what `formats/kicadgen.nim` splices
      ## rather than regenerating.
    attrs*: OrderedTable[string, string]

  FootprintSource* = ref object
    name*: string
    resolve*: proc (spec: string): Footprint {.nimcall.}
      ## `nil` return means "not mine" -- distinct from raising, which a
      ## source should reserve for a spec it recognises as its own but
      ## cannot actually resolve (a malformed path, a library it can open
      ## but that has no such name), so the caller's error names the real
      ## problem instead of "no source recognised this spec" for a spec one
      ## source *did* recognise and then failed on.

var registry: seq[FootprintSource]
  ## Registration order is resolution order -- the same "first source that
  ## claims it wins" contract `netlist/packages`'s definition registry and
  ## `contract`'s evaluator registry both use, so a caller registering a
  ## second, more specific source ahead of a generic one can shadow it
  ## deliberately.

proc registerFootprintSource*(s: FootprintSource) =
  registry.add s

proc footprintSources*(): seq[string] =
  for s in registry: result.add s.name

proc findFootprint*(spec: string): Footprint =
  ## Tries every registered source in registration order, returning the
  ## first non-nil result. `nil` when nothing recognised `spec` -- the caller
  ## (`pcb/assemble.nim`) is the one that knows whether that is a refusal or
  ## a data problem, so this never raises on an unresolved spec itself.
  for s in registry:
    if s.resolve == nil: continue
    let fp = s.resolve(spec)
    if fp != nil: return fp
  nil
