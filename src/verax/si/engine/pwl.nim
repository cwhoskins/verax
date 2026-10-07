## Piecewise-linear time functions: source waveforms and the `Ku`/`Kd`
## weights. Two points at the same time are a **jump** (right-continuous:
## the later value applies from that instant); before the first point and
## after the last the end value holds.

import std/algorithm

type
  Pwl* = object
    t*, v*: seq[float]

proc constPwl*(v: float): Pwl = Pwl(t: @[0.0], v: @[v])

proc isEmpty*(p: Pwl): bool {.inline.} = p.t.len == 0

proc add*(p: var Pwl, t, v: float) =
  ## Appends a point; `t` must not go backwards (equal = jump).
  assert p.t.len == 0 or t >= p.t[^1], "Pwl time went backwards"
  p.t.add t
  p.v.add v

proc at*(p: Pwl, t: float): float =
  ## Value at `t`; right-continuous at a jump. An empty `Pwl` is `1` (the
  ## neutral weight).
  let n = p.t.len
  if n == 0: return 1.0
  if t < p.t[0]: return p.v[0]
  if t >= p.t[^1]: return p.v[^1]
  # Last index with p.t[k] <= t.
  let k = upperBound(p.t, t) - 1
  if p.t[k + 1] == p.t[k]: return p.v[k + 1]
  p.v[k] + (p.v[k + 1] - p.v[k]) * (t - p.t[k]) / (p.t[k + 1] - p.t[k])

proc initial*(p: Pwl): float =
  ## The value before anything happens (the DC operating point's).
  if p.t.len == 0: 1.0 else: p.v[0]

proc breakpoints*(p: Pwl): seq[tuple[t: float, jump: bool]] =
  ## Every knot, and whether the waveform is discontinuous there.
  var k = 0
  while k < p.t.len:
    var jump = false
    var j = k
    while j + 1 < p.t.len and p.t[j + 1] == p.t[k]:
      if p.v[j + 1] != p.v[j]: jump = true
      inc j
    result.add (p.t[k], jump)
    k = j + 1

proc shifted*(p: Pwl, dt: float): Pwl =
  result = p
  for x in result.t.mitems: x += dt

proc atLeft*(p: Pwl, t: float): float =
  ## The left limit at `t`: the value just *before* a jump at `t`.
  let n = p.t.len
  if n == 0: return 1.0
  if t <= p.t[0]: return p.v[0]
  if t > p.t[^1]: return p.v[^1]
  # First index with p.t[k] >= t.
  let k = lowerBound(p.t, t)
  if p.t[k] == t: return p.v[k]
  p.v[k - 1] + (p.v[k] - p.v[k - 1]) * (t - p.t[k - 1]) / (p.t[k] - p.t[k - 1])
