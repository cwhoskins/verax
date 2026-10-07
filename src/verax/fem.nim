## FEM: stating a field problem over a board and running it through an
## external finite-element solver. A simulator interface, like `verax/spice`
## (what a field answers is `analysis`'s job).
##
## EM (electrostatic, magnetostatic, full-wave) and thermal (steady,
## transient) share one contract.
##
## **A skeleton**: types and backend contract are settled. The only backend is
## `verax/fem/mfem` (stage 0: call path only; opt-in, deliberately not
## re-exported here) and there is no mesher.
## `verax/fem/extrude` turns a `Pcb` into a `FemProblem`.

import verax/fem/types
import verax/fem/mesh
import verax/fem/backend
import verax/fem/extrude

export types, mesh, backend, extrude
