// See shim.h for the contract. Everything here is `noexcept` by construction:
// each entry point is one try/catch(...) around the work.
#include "shim.h"
#include "mfem.hpp"

#include <memory>
#include <stdexcept>
#include <string>

struct vx_mesh {
  std::unique_ptr<mfem::Mesh> mesh;
};

namespace {

thread_local std::string g_err;

int fail(const std::string& m) { g_err = m; return 1; }

template <class F> int guarded(F&& f) {
  try { g_err.clear(); f(); return 0; }
  catch (const std::exception& e) { return fail(e.what()); }  // mfem::ErrorException too
  catch (...) { return fail("unknown C++ exception in verax MFEM shim"); }
}

int nodesPer(int geom) {
  switch (geom) {
    case VX_TRI: return 3;
    case VX_QUAD: return 4;
    case VX_TET: return 4;
    case VX_HEX: return 8;
    default: throw std::invalid_argument("unsupported element geometry code " + std::to_string(geom));
  }
}

}  // namespace

extern "C" {

int vx_mfem_abi_version(void) { return VX_MFEM_ABI_VERSION; }
const char* vx_mfem_version(void) {
  static const std::string v = mfem::GetVersionStr();
  return v.c_str();
}
const char* vx_mfem_last_error(void) { return g_err.c_str(); }

int vx_mesh_cartesian_2d(int nx, int ny, double sx, double sy, vx_mesh** out) {
  return guarded([&] {
    if (!out) throw std::invalid_argument("null out");
    *out = nullptr;
    if (nx < 1 || ny < 1) throw std::invalid_argument("cartesian mesh needs nx, ny >= 1");
    auto h = std::make_unique<vx_mesh>();
    h->mesh = std::make_unique<mfem::Mesh>(
        mfem::Mesh::MakeCartesian2D(nx, ny, mfem::Element::TRIANGLE, false, sx, sy));
    *out = h.release();
  });
}

int vx_mesh_from_arrays(int dim, int nverts, const double* xyz, int nelem,
                        int elemGeom, const int* conn, const int* attr,
                        vx_mesh** out) {
  return guarded([&] {
    if (!out) throw std::invalid_argument("null out");
    *out = nullptr;
    if (dim != 2 && dim != 3) throw std::invalid_argument("dim must be 2 or 3");
    const int npe = nodesPer(elemGeom);
    // Checked here, not left to MFEM: an out-of-range vertex index is not
    // always caught by MFEM's own asserts (they compile out of release builds)
    // and reads past the vertex array instead.
    for (int e = 0; e < nelem; ++e)
      for (int k = 0; k < npe; ++k) {
        const int v = conn[e * npe + k];
        if (v < 0 || v >= nverts)
          throw std::invalid_argument("element " + std::to_string(e) +
              " references vertex " + std::to_string(v) + " but the mesh has " +
              std::to_string(nverts) + " vertices");
      }
    auto m = std::make_unique<mfem::Mesh>(dim, nverts, nelem, 0, dim);
    for (int i = 0; i < nverts; ++i)
      m->AddVertex(xyz[3 * i], xyz[3 * i + 1], xyz[3 * i + 2]);
    for (int e = 0; e < nelem; ++e) {
      const int* c = conn + e * npe;
      const int a = attr ? attr[e] : 1;
      switch (elemGeom) {
        case VX_TRI: m->AddTriangle(c, a); break;
        case VX_QUAD: m->AddQuad(c, a); break;
        case VX_TET: m->AddTet(c, a); break;
        case VX_HEX: m->AddHex(c, a); break;
      }
    }
    m->FinalizeTopology();       // generates boundary elements from outer faces
    m->Finalize(false, true);    // fix_orientation: negative-Jacobian elements flipped
    auto h = std::make_unique<vx_mesh>();
    h->mesh = std::move(m);
    *out = h.release();
  });
}

int vx_mesh_counts(const vx_mesh* h, int* nv, int* ne, int* nbe) {
  return guarded([&] {
    if (!h || !nv || !ne || !nbe) throw std::invalid_argument("null argument");
    *nv = h->mesh->GetNV(); *ne = h->mesh->GetNE(); *nbe = h->mesh->GetNBE();
  });
}

void vx_mesh_free(vx_mesh* h) { delete h; }

int vx_h1_ndofs(const vx_mesh* h, int order, int* ndofs) {
  return guarded([&] {
    if (!h || !ndofs) throw std::invalid_argument("null argument");
    mfem::H1_FECollection fec(order, h->mesh->Dimension());
    mfem::FiniteElementSpace fes(h->mesh.get(), &fec);
    *ndofs = fes.GetNDofs();
  });
}

int vx_h1_dof_coords(const vx_mesh* h, int order, double* xyz, int len) {
  return guarded([&] {
    if (!h || !xyz) throw std::invalid_argument("null argument");
    mfem::H1_FECollection fec(order, h->mesh->Dimension());
    mfem::FiniteElementSpace fes(h->mesh.get(), &fec);
    if (len < 3 * fes.GetNDofs())
      throw std::invalid_argument("xyz buffer holds " + std::to_string(len) +
          " doubles, need " + std::to_string(3 * fes.GetNDofs()));
    // Interpolating a coordinate function into the same space returns each
    // dof's position exactly (nodal basis), edge dofs of order >= 2 included.
    for (int d = 0; d < 3; ++d) {
      mfem::FunctionCoefficient c([d](const mfem::Vector& x) {
        return d < x.Size() ? x(d) : 0.0; });
      mfem::GridFunction g(&fes);
      g.ProjectCoefficient(c);
      for (int i = 0; i < fes.GetNDofs(); ++i) xyz[3 * i + d] = g(i);
    }
  });
}

int vx_solve_laplace_dirichlet(const vx_mesh* h, int order,
                               const double* bc, double* nodalOut, int nodalLen,
                               double* residualOut, int* itersOut) {
  return guarded([&] {
    if (!h || !bc || !nodalOut) throw std::invalid_argument("null argument");
    if (order < 1) throw std::invalid_argument("order must be >= 1");
    mfem::Mesh& mesh = *h->mesh;
    const int dim = mesh.Dimension();
    if (mesh.bdr_attributes.Size() == 0)
      throw std::runtime_error("mesh has no boundary elements; nothing to apply a Dirichlet condition to");
    mfem::H1_FECollection fec(order, dim);
    mfem::FiniteElementSpace fes(&mesh, &fec);
    if (nodalLen < fes.GetNDofs())
      throw std::invalid_argument("nodal buffer holds " + std::to_string(nodalLen) +
          " values, need " + std::to_string(fes.GetNDofs()));

    mfem::Array<int> ess_bdr(mesh.bdr_attributes.Max());
    ess_bdr = 1;
    mfem::Array<int> ess_tdof;
    fes.GetEssentialTrueDofs(ess_bdr, ess_tdof);

    const double c0 = bc[0], cx = bc[1], cy = bc[2], cz = bc[3];
    mfem::FunctionCoefficient g([=](const mfem::Vector& p) {
      return c0 + cx * p(0) + (dim > 1 ? cy * p(1) : 0.0) + (dim > 2 ? cz * p(2) : 0.0);
    });
    mfem::GridFunction x(&fes);
    x = 0.0;
    x.ProjectBdrCoefficient(g, ess_bdr);

    mfem::LinearForm b(&fes);
    b.Assemble();
    mfem::BilinearForm a(&fes);
    a.AddDomainIntegrator(new mfem::DiffusionIntegrator);
    a.Assemble();
    mfem::SparseMatrix A;
    mfem::Vector B, X;
    a.FormLinearSystem(ess_tdof, x, b, A, X, B);

    mfem::GSSmoother M(A);
    // Relative tolerance far below what the 1e-10 validation needs: the
    // exact-reproduction test is meant to expose assembly bugs, not CG slack.
    mfem::CGSolver cg;
    cg.SetOperator(A);
    cg.SetPreconditioner(M);
    cg.SetRelTol(1e-28);
    cg.SetAbsTol(0.0);
    cg.SetMaxIter(5000);
    cg.SetPrintLevel(-1);
    cg.Mult(B, X);
    a.RecoverFEMSolution(X, b, x);

    mfem::Vector r(B.Size());
    A.Mult(X, r); r -= B;
    if (residualOut) *residualOut = r.Norml2();
    if (itersOut) *itersOut = cg.GetNumIterations();
    for (int i = 0; i < fes.GetNDofs(); ++i) nodalOut[i] = x(i);
  });
}

}  // extern "C"
