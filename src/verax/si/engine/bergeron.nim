## Lossless lines by the method of characteristics (Bergeron). Each end is
## a conductance `1/Z0` to ground plus a history current
##
##   `J_a(t) = v_b(t - td) / Z0 + i_b(t - td)`   (and symmetrically `J_b`)
##
## with `i_k` the current flowing *into* the line at end `k`. Exact for a
## lossless line, no internal nodes.
##
## - `h <= td` keeps the two ends decoupled (the history is always in the
##   past). A correctness condition, enforced by the step policy, not a
##   stability rule.
## - `td` is generally not a multiple of `h`, so the delayed history is
##   **linearly interpolated** between stored samples. Before the first
##   sample the line holds its DC operating point.

import std/algorithm

type
  LineHistory* = object
    t*, va*, ia*, vb*, ib*: seq[float]

proc record*(h: var LineHistory, t, va, ia, vb, ib: float) =
  h.t.add t
  h.va.add va
  h.ia.add ia
  h.vb.add vb
  h.ib.add ib

proc sample*(h: LineHistory, tq: float): tuple[va, ia, vb, ib: float] =
  let n = h.t.len
  if n == 0: return (0.0, 0.0, 0.0, 0.0)
  if tq <= h.t[0]: return (h.va[0], h.ia[0], h.vb[0], h.ib[0])
  if tq >= h.t[^1]: return (h.va[^1], h.ia[^1], h.vb[^1], h.ib[^1])
  let k = upperBound(h.t, tq) - 1
  let f = (tq - h.t[k]) / (h.t[k + 1] - h.t[k])
  template lerp(s: seq[float]): float = s[k] + f * (s[k + 1] - s[k])
  (lerp(h.va), lerp(h.ia), lerp(h.vb), lerp(h.ib))

proc injections*(h: LineHistory, z0, td, t: float): tuple[ja, jb: float] =
  ## The history currents injected into each end at time `t`.
  let s = h.sample(t - td)
  (s.vb / z0 + s.ib, s.va / z0 + s.ia)
