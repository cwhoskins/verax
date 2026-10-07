## Validation ladder for the MFEM call path. Each rung isolates one failure
## class, so the first red rung names the broken layer. Skipped (with the
## reason printed) when MFEM / the shim is absent -- see `nimble mfem`.
import std/[strutils, tables, unittest]
import verax/fem/mfem

if not available():
  echo "SKIP: MFEM not available.\n", $loadStatus()
else:
  # Exact solution of the validation problems: linear, so P1 and P2 both
  # reproduce it to solver tolerance.
  const g = [1.0, 2.0, -3.0, 0.5]
  proc exact(n: Node): float = g[0] + g[1]*n.x + g[2]*n.y + g[3]*n.z
  proc maxErr(s: LaplaceSolution, pts: seq[Node]): float =
    doAssert s.nodal.len == pts.len
    for i, p in pts: result = max(result, abs(s.nodal[i] - exact(p)))

  suite "MFEM ladder":
    test "1. version string resolves through the shim":
      check mfemVersion().startsWith("MFEM v4.10")

    test "2. an ABI mismatch is a graceful no, not a crash":
      check not available(abiExpected = 999)
      let s = loadStatus(abiExpected = 999)
      check not s.loaded
      check s.abiGot == shimAbiVersion
      check available()          # and the right ABI still works afterwards

    test "3. object lifetime across the boundary: 4x4 cartesian":
      let m = cartesian2d(4, 4)
      let c = m.counts
      check c.nv == 25
      check c.ne == 32           # triangles; 16 quads split in two
      check c.nbe == 16

    test "4. a bad vertex index raises FemSolveError with a message, process lives":
      let xyz = @[0.0,0,0, 1,0,0, 0,1,0]
      var msg = ""
      try:
        discard fromArrays(2, xyz, ekTri3, @[0, 1, 7])
      except FemSolveError as e:
        msg = e.msg
      check "vertex 7" in msg
      # still usable after the exception
      check cartesian2d(1, 1).counts.nv == 4

    test "5. Laplace on the unit square, P1: exact to 1e-10":
      let m = cartesian2d(4, 4)
      let s = m.solveLaplaceDirichlet(g, 1)
      let e = maxErr(s, m.dofCoords(1))
      echo "  rung 5 (cartesian 4x4, P1) max error = ", e,
           " residual = ", s.residual, " iters = ", s.iterations
      check e < 1e-10

    test "6. verax Mesh (Tri3) -> toMfem -> solve: exact to 1e-10":
      # A 3x3 grid of unit-square cells split into triangles, built in Nim,
      # with half the triangles deliberately clockwise: toMfem must cope with
      # orientation, not assume it.
      var vm: Mesh
      for j in 0 .. 3:
        for i in 0 .. 3:
          vm.nodes.add Node(x: i.float / 3, y: j.float / 3)
      proc id(i, j: int): int = j * 4 + i
      for j in 0 ..< 3:
        for i in 0 ..< 3:
          let a = id(i, j); let b = id(i+1, j)
          let c = id(i+1, j+1); let d = id(i, j+1)
          vm.elements.add Element(kind: ekTri3, nodes: @[a, b, c], region: 0)
          vm.elements.add Element(kind: ekTri3, nodes: @[a, d, c], region: 0) # clockwise
      let r = solveLaplaceDirichlet(vm, g, 1)
      var e = 0.0
      for i, n in vm.nodes: e = max(e, abs(r["potential"][i] - exact(n)))
      echo "  rung 6 (Nim Mesh Tri3, mixed orientation) max error = ", e
      check e < 1e-10
      check r.converged
      check r.fields["potential"].perNode

    test "7. Tet4 cube (2x2x2 cells, 48 tets, interior dofs), P2: exact to 1e-10":
      # Each cell is cut into 6 tets around its 0-6 diagonal (Kuhn split).
      # 2 cells per side, not 1: a single cell has no interior vertex and
      # nearly every dof is pinned by the boundary, which would let a broken
      # interior assembly pass.
      const n = 2
      var vm: Mesh
      for k in 0 .. n:
        for j in 0 .. n:
          for i in 0 .. n:
            vm.nodes.add Node(x: i / n, y: j / n, z: k / n)
      proc v(i, j, k: int): int = i + (n+1)*j + (n+1)*(n+1)*k
      let perms = [[0,1,2],[0,2,1],[1,0,2],[1,2,0],[2,0,1],[2,1,0]]
      for k in 0 ..< n:
        for j in 0 ..< n:
          for i in 0 ..< n:
            for p in perms:
              var cur = [i, j, k]
              var ns = @[v(i, j, k)]
              for step in 0 ..< 3:
                cur[p[step]] += 1
                ns.add v(cur[0], cur[1], cur[2])
              vm.elements.add Element(kind: ekTet4, nodes: ns, region: 0)
      let mm = toMfem(vm)
      check mm.counts.nv == 27
      check mm.counts.ne == 48
      let s = mm.solveLaplaceDirichlet(g, 2)
      check s.nodal.len > 27      # edge dofs exist
      let e = maxErr(s, mm.dofCoords(2))
      echo "  rung 7 (Tet4 cube 2x2x2, P2) max error = ", e, " ndofs = ", s.nodal.len,
           " residual = ", s.residual, " iters = ", s.iterations
      check e < 1e-10

    test "unsupported element kinds are refused naming what is supported":
      var vm: Mesh
      vm.nodes = @[Node(), Node(x: 1), Node(y: 1), Node(x: 1, y: 1), Node(x: 0.5),
                   Node(x: 0.5, y: 0.5), Node(y: 0.5)]
      vm.elements = @[Element(kind: ekTri6, nodes: @[0,1,2,4,5,6], region: 0)]
      expect FemError:
        discard toMfem(vm)
