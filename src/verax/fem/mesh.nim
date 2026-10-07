## A solver-neutral finite-element mesh: nodes, elements, region and
## boundary tags. **No mesher** (backends like MFEM/gmsh own that); this is
## the shape a backend translates from.
##
## **Coordinates are `float64` metres, not `Nm`**: mesh nodes don't sit on
## the design lattice. The nm -> m conversion happens once, in `extrude`.
##
## Absent: quality metrics, refinement, adaptivity, periodic pairing.

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
      ## MFEM (`fem/mfem.toMfem`): Tri3 and Quad4 counter-clockwise from any
      ## corner; Tet4 is any 4 vertices; Hex8 is bottom face 0-3 counter-
      ## clockwise then top face 4-7 above them. Orientation is not required:
      ## the shim re-orients negative-Jacobian elements (measured for Tri3
      ## and Tet4 -- half the elements of the test meshes were reversed and fixed;
      ## Quad4/Hex8 translate but are not yet exercised by a test).
    region*: int
      ## Index into `Mesh.regionNames`; -1 for an element with no `FemProblem`
      ## region (air-box filler).

  Mesh* = object
    nodes*: seq[Node]
    elements*: seq[Element]
    regionNames*: seq[string]
      ## Parallel to `FemProblem.regions`, so `Element.region` maps to a
      ## material without string lookups.
    boundaryFaces*: OrderedTable[string, seq[Element]]
      ## Named surface-element face sets, one per boundary condition or port.

  MeshError* = object of CatchableError
    ## Raised on a structurally impossible mesh (index out of range, wrong
    ## node count).

const nodeCountFor*: array[ElementKind, int] = [
  ekTri3: 3, ekTri6: 6, ekQuad4: 4, ekQuad9: 9,
  ekTet4: 4, ekTet10: 10, ekHex8: 8, ekHex20: 20, ekPrism6: 6,
]

proc nodeCount*(m: Mesh): int {.inline.} = m.nodes.len
proc elementCount*(m: Mesh): int {.inline.} = m.elements.len

proc bounds*(m: Mesh): tuple[lo, hi: Node] =
  ## Axis-aligned extent in metres; origin corners for an empty mesh.
  if m.nodes.len == 0: return
  result.lo = m.nodes[0]
  result.hi = m.nodes[0]
  for n in m.nodes:
    result.lo.x = min(result.lo.x, n.x); result.hi.x = max(result.hi.x, n.x)
    result.lo.y = min(result.lo.y, n.y); result.hi.y = max(result.hi.y, n.y)
    result.lo.z = min(result.lo.z, n.z); result.hi.z = max(result.hi.z, n.z)

proc check*(m: Mesh) =
  ## Raise `MeshError` unless node counts and indices are valid. Call on any
  ## mesh a backend didn't build.
  for i, e in m.elements:
    if e.nodes.len != nodeCountFor[e.kind]:
      raise newException(MeshError,
        "element " & $i & " (" & $e.kind & ") has " & $e.nodes.len &
        " nodes, expected " & $nodeCountFor[e.kind])
    for ni in e.nodes:
      if ni < 0 or ni >= m.nodes.len:
        raise newException(MeshError,
          "element " & $i & " references node " & $ni & " of " & $m.nodes.len)
