## A solver-neutral finite-element mesh: nodes, elements, and the region and
## boundary tags a solver needs to apply materials and conditions.
##
## `nimcir/fem` does **not** contain a mesher. Meshing a 3-D geometry well is
## a research-grade problem and every serious FEM backend (MFEM, and gmsh
## behind it) ships its own; duplicating one here would be a project, not a
## skeleton. This type exists so a backend that *is* handed a mesh -- from a
## file, or from a future thin structured-grid generator for the
## rectangular-dielectric common case -- has one shape to translate from.
##
## **Coordinates are `float64` metres, not `nimcir/pcb/units.Nm`.** A mesh
## node is a solver artefact. It does not land on the 1 nm design lattice,
## and snapping it there is meaningless in the interior and actively wrong on
## a curved boundary. The single nm -> m conversion happens once, at
## `nimcir/fem/extrude`, and nothing downstream of it is integer. This is the
## same kind of call `src/nimcir/CLAUDE.md` records for keeping
## `pcb/units.nim` (`Nm`) disjoint from `units.nim` (`Volts`).
##
## Deliberately absent: quality metrics, refinement, adaptivity, periodic
## node pairing -- all of which belong to whichever backend owns the solve.

import std/tables

type
  ElementKind* = enum
    ekTri3, ekTri6      ## 2-D, first / second order
    ekQuad4, ekQuad9
    ekTet4, ekTet10     ## 3-D, first / second order
    ekHex8, ekHex20
    ekPrism6

  Node* = object
    x*, y*, z*: float   ## metres

  Element* = object
    kind*: ElementKind
    nodes*: seq[int]
      ## Indices into `Mesh.nodes`, in the backend's canonical local order.
    region*: int
      ## Index into `Mesh.regionNames`; -1 for an element not tied to a
      ## `FemProblem` region (e.g. an air-box filler element).

  Mesh* = object
    nodes*: seq[Node]
    elements*: seq[Element]
    regionNames*: seq[string]
      ## Parallel to `FemProblem.regions`, so `Element.region` round-trips a
      ## material assignment without a string lookup per element.
    boundaryFaces*: OrderedTable[string, seq[Element]]
      ## Named face sets -- one per `BoundaryCondition` / port. The elements
      ## here are surface elements (`ekTri*`/`ekQuad*`) whose nodes index the
      ## same `nodes` seq.

  MeshError* = object of CatchableError
    ## Raised on a structurally impossible mesh -- an element referencing a
    ## node index outside `nodes`, an element kind with the wrong node count.

const nodeCountFor*: array[ElementKind, int] = [
  ekTri3: 3, ekTri6: 6, ekQuad4: 4, ekQuad9: 9,
  ekTet4: 4, ekTet10: 10, ekHex8: 8, ekHex20: 20, ekPrism6: 6,
]

proc nodeCount*(m: Mesh): int {.inline.} = m.nodes.len
proc elementCount*(m: Mesh): int {.inline.} = m.elements.len

proc bounds*(m: Mesh): tuple[lo, hi: Node] =
  ## Axis-aligned extent of the mesh in metres. Both corners are the origin
  ## for an empty mesh.
  if m.nodes.len == 0: return
  result.lo = m.nodes[0]
  result.hi = m.nodes[0]
  for n in m.nodes:
    result.lo.x = min(result.lo.x, n.x); result.hi.x = max(result.hi.x, n.x)
    result.lo.y = min(result.lo.y, n.y); result.hi.y = max(result.hi.y, n.y)
    result.lo.z = min(result.lo.z, n.z); result.hi.z = max(result.hi.z, n.z)

proc check*(m: Mesh) =
  ## Raise `MeshError` unless every element has the right node count and
  ## every node index is in range. A backend should call this on a mesh it
  ## did not build itself.
  for i, e in m.elements:
    if e.nodes.len != nodeCountFor[e.kind]:
      raise newException(MeshError,
        "element " & $i & " (" & $e.kind & ") has " & $e.nodes.len &
        " nodes, expected " & $nodeCountFor[e.kind])
    for ni in e.nodes:
      if ni < 0 or ni >= m.nodes.len:
        raise newException(MeshError,
          "element " & $i & " references node " & $ni & " of " & $m.nodes.len)
