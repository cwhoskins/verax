## FEM -- stating a field problem over a printed-circuit board and running it
## through an external finite-element solver.
##
## Like `nimcir/spice`, this is a *simulator interface*, not a general
## solver: it owns the problem statement, the mesh vocabulary and the
## backend contract, and knows nothing about what question a field answers
## -- that is `nimcir/analysis`'s job.
##
## **Scope: electromagnetic and thermal, one contract.** `ProblemKind`
## covers electrostatic / magnetostatic / full-wave and steady / transient
## heat conduction; `Material` carries both physics' constants so the same
## region serves either.
##
## **This is a skeleton.** The problem, mesh and result types are real and
## the backend contract is settled, but:
##
## - there is **no backend** -- MFEM is the intended first one
##   (`nimcir/fem/mfem`), opt-in per import as `nimcir/spice/ngspice` is, and
##   it is not written;
## - there is **no mesher** -- a mesh is something a backend or a file
##   supplies;
## - `nimcir/fem/extrude` turns a `Pcb` into a `FemProblem`, but is blocked
##   from real usefulness by two `pcb` gaps it documents: no board-file
##   reader exists, and `Zone` has no filled-copper geometry.
##
## The backend-free parts are all here; a solver backend will not be.

import nimcir/fem/types
import nimcir/fem/mesh
import nimcir/fem/backend
import nimcir/fem/extrude

export types, mesh, backend, extrude
