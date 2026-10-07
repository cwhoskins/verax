/* C ABI between verax (Nim, loaded with std/dynlib) and MFEM (C++).
 *
 * Rules: no C++ type crosses this boundary; every entry point catches
 * everything and returns nonzero with vx_mfem_last_error() set (MFEM is built
 * with MFEM_USE_EXCEPTIONS=ON so mfem_error throws instead of abort()ing);
 * the caller owns output buffers; every handle has a vx_*_free.
 *
 * Bump VX_MFEM_ABI_VERSION on ANY change to a signature or struct meaning --
 * it is part of the cached .so's filename and checked by the Nim binding.
 */
#ifndef VERAX_MFEM_SHIM_H
#define VERAX_MFEM_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

#define VX_MFEM_ABI_VERSION 1

/* Element geometry codes for vx_mesh_from_arrays: MFEM's Element::Type
 * (2 triangle, 3 quad, 4 tet, 5 hex). */
enum { VX_TRI = 2, VX_QUAD = 3, VX_TET = 4, VX_HEX = 5 };

int         vx_mfem_abi_version(void);
const char* vx_mfem_version(void);
const char* vx_mfem_last_error(void);

typedef struct vx_mesh vx_mesh;

/* nx*ny*2 triangles on [0,sx]x[0,sy]. */
int  vx_mesh_cartesian_2d(int nx, int ny, double sx, double sy, vx_mesh** out);
/* xyz is 3*nverts doubles; conn is nodes-per-geom ints per element, in MFEM's
 * local node order; attr one int per element (>= 1). Boundary elements are
 * generated from the outer faces. Elements with a negative Jacobian are
 * re-oriented by MFEM (Finalize fix_orientation). */
int  vx_mesh_from_arrays(int dim, int nverts, const double* xyz,
                         int nelem, int elemGeom, const int* conn,
                         const int* attr, vx_mesh** out);
int  vx_mesh_counts(const vx_mesh*, int* nv, int* ne, int* nbe);
void vx_mesh_free(vx_mesh*);

/* Number of H1 dofs of the given order (vertices come first, then edges, ...). */
int  vx_h1_ndofs(const vx_mesh*, int order, int* ndofs);
/* 3 doubles per dof, written into xyz (len doubles, must be >= 3*ndofs). */
int  vx_h1_dof_coords(const vx_mesh*, int order, double* xyz, int len);

/* -lap(u) = 0, u = g on the whole boundary, H1 order p. g = c[0] + c[1]x +
 * c[2]y + c[3]z (bcCoeffs has 4 doubles). nodalOut gets ndofs values. */
int  vx_solve_laplace_dirichlet(const vx_mesh*, int order,
                                const double* bcCoeffs,
                                double* nodalOut, int nodalLen,
                                double* residualOut, int* itersOut);

#ifdef __cplusplus
}
#endif
#endif
