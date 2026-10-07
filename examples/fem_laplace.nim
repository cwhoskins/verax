## Solve Laplace's equation on a unit square through MFEM and compare with the
## exact (linear) answer. Needs MFEM: run `nimble mfem` first.
##
##   nim c -r --path:./src examples/fem_laplace.nim
import verax/fem/mfem

if not available():
  echo "MFEM not available:\n", $loadStatus()
  quit(0)

echo mfemVersion()
let m = cartesian2d(8, 8)
let g = [1.0, 2.0, -3.0, 0.0]          # u = 1 + 2x - 3y on the boundary
let s = m.solveLaplaceDirichlet(g, order = 2)
var err = 0.0
for i, p in m.dofCoords(2):
  err = max(err, abs(s.nodal[i] - (g[0] + g[1] * p.x + g[2] * p.y)))
echo "dofs: ", s.nodal.len, "  CG iterations: ", s.iterations,
     "  max error vs exact: ", err
