## The engine's linear solver: a **band LU with partial pivoting** over a
## reverse Cuthill-McKee ordering of the matrix's structure. SI nets are
## chains (lines, ladders, packages), so after RCM the bandwidth stays small
## while the node count grows with ladder sections and drops; a small net
## degenerates to dense LU at the same cost.
##
## - **Ordering**: RCM on the symmetric pattern (MNA stamps are structurally
##   symmetric), computed once per `Pattern`. It changes the order of
##   elimination only; the pivot is still chosen by magnitude.
## - **Factorisation** (LINPACK `dgbfa` layout): row `i` stores columns
##   `i - kl .. i + ku + kl`; a pivot swap exchanges only the columns not yet
##   eliminated, and the multipliers stay where they were made, so the
##   solve replays the swaps in order. Rows more than `kl` below the
##   diagonal are structurally zero in that column, so the pivot choice is
##   the dense one.
## - **Singular**: a pivot below `1e-18` of the largest entry, as before.
## - **Reuse** is the caller's (`newton`): a `BandLu` is valid until the
##   matrix changes.

type
  Pattern* = object
    ## Structure of an `n x n` matrix and the RCM ordering derived from it.
    n*: int
    perm*: seq[int]
      ## New position -> original index.
    pos*: seq[int]
      ## Original index -> new position.
    kl*, ku*: int

  BandLu* = object
    n, kl, ku, w: int
    m: seq[float]
      ## Row-major, `w = 2 kl + ku + 1` per row.
    piv: seq[int]
    ok*: bool

proc rcm(n: int, adj: seq[seq[int]]): seq[int] =
  ## Reverse Cuthill-McKee, deterministic: every component starts at a
  ## minimum-degree unvisited vertex, neighbours by ascending degree then
  ## index.
  var seen = newSeq[bool](n)
  var order: seq[int]
  proc deg(i: int): int = adj[i].len
  while order.len < n:
    var start = -1
    for i in 0 ..< n:
      if not seen[i] and (start < 0 or deg(i) < deg(start)): start = i
    seen[start] = true
    var head = order.len
    order.add start
    while head < order.len:
      let v = order[head]
      inc head
      var nb: seq[int]
      for u in adj[v]:
        if not seen[u]:
          seen[u] = true
          nb.add u
      # insertion sort: small lists
      for i in 1 ..< nb.len:
        let x = nb[i]
        var j = i - 1
        while j >= 0 and (deg(nb[j]) > deg(x) or (deg(nb[j]) == deg(x) and nb[j] > x)):
          nb[j + 1] = nb[j]
          dec j
        nb[j + 1] = x
      order.add nb
  result = newSeq[int](n)
  for i in 0 ..< n: result[i] = order[n - 1 - i]

proc patternOf*(n: int, a: openArray[float]): Pattern =
  ## The pattern of a row-major `a` (nonzero entries, plus the diagonal).
  var adj = newSeq[seq[int]](n)
  for r in 0 ..< n:
    for c in 0 ..< n:
      if r != c and (a[r * n + c] != 0.0 or a[c * n + r] != 0.0):
        adj[r].add c
  result = Pattern(n: n, perm: rcm(n, adj))
  result.pos = newSeq[int](n)
  for k, i in result.perm: result.pos[i] = k
  for r in 0 ..< n:
    for c in adj[r]:
      let d = result.pos[c] - result.pos[r]
      if d > 0: result.ku = max(result.ku, d)
      else: result.kl = max(result.kl, -d)

proc factor*(lu: var BandLu, p: Pattern, a: openArray[float]) =
  ## Factor the row-major `a` (original order) in `p`'s ordering. Entries
  ## outside `p`'s structure must be zero.
  let n = p.n
  lu.n = n
  lu.kl = p.kl
  lu.ku = p.ku
  lu.w = 2 * p.kl + p.ku + 1
  let w = lu.w
  let kl = lu.kl
  lu.m.setLen n * w
  for x in lu.m.mitems: x = 0.0
  lu.piv.setLen n
  var scale = 0.0
  for r in 0 ..< n:
    let pr = p.pos[r]
    for c in 0 ..< n:
      let v = a[r * n + c]
      if v != 0.0:
        lu.m[pr * w + (p.pos[c] - pr + kl)] = v
        scale = max(scale, abs(v))
  if scale == 0.0: scale = 1.0
  let span = kl + lu.ku   # columns right of the diagonal after fill
  template at(i, j: int): untyped = lu.m[(i) * w + (j) - (i) + kl]
  for k in 0 ..< n:
    let rEnd = min(n - 1, k + kl)
    var piv = k
    var best = abs(at(k, k))
    for r in k + 1 .. rEnd:
      let v = abs(at(r, k))
      if v > best: best = v; piv = r
    lu.piv[k] = piv
    if best <= 1e-300 or best < scale * 1e-18:
      lu.ok = false
      return
    let cEnd = min(n - 1, k + span)
    if piv != k:
      for c in k .. cEnd: swap(at(k, c), at(piv, c))
    let d = at(k, k)
    for r in k + 1 .. rEnd:
      let f = at(r, k) / d
      at(r, k) = f
      if f == 0.0: continue
      for c in k + 1 .. cEnd: at(r, c) -= f * at(k, c)
  lu.ok = true

proc solve*(lu: BandLu, p: Pattern, b: openArray[float], x: var seq[float]) =
  ## `x = A^-1 b`, both in the original order.
  let n = lu.n
  let w = lu.w
  let kl = lu.kl
  let span = kl + lu.ku
  x.setLen n
  var y = move x   # reuse the caller's buffer as the permuted work vector
  y.setLen n
  for i in 0 ..< n: y[p.pos[i]] = b[i]
  template at(i, j: int): untyped = lu.m[(i) * w + (j) - (i) + kl]
  for k in 0 ..< n:
    let pv = lu.piv[k]
    if pv != k: swap(y[k], y[pv])
    let yk = y[k]
    if yk == 0.0: continue
    for r in k + 1 .. min(n - 1, k + kl): y[r] -= at(r, k) * yk
  for k in countdown(n - 1, 0):
    var acc = y[k]
    for c in k + 1 .. min(n - 1, k + span): acc -= at(k, c) * y[c]
    y[k] = acc / at(k, k)
  x = newSeqUninit[float](n)
  for i in 0 ..< n: x[i] = y[p.pos[i]]
