## Pseudo-random bit sequences and the eye diagram a receiver sees: the
## figures a serial link is judged on.
##
## - **PRBS** (`prbs`): the ITU-T O.150 Fibonacci LFSRs, PRBS7 `x^7 + x^6 +
##   1`, PRBS9 `x^9 + x^5 + 1`, PRBS15 `x^15 + x^14 + 1`, PRBS23 `x^23 +
##   x^18 + 1`, PRBS31 `x^31 + x^28 + 1`, from the all-ones seed. One
##   period of PRBS7 (127 bits) holds every run of up to seven equal bits:
##   the classic ISI stress.
## - **The eye** (`eyeOf`): the receiver wave folded on the UI. For a
##   sampling offset `o` after each bit's start at the driver, bit `k` is
##   read at `delay + k UI + o`; the offset sweeps `0 .. maxOffset` (it
##   absorbs the channel's delay) in `UI / phases` steps.
##   - **Eye height** at an offset: the lowest "1" sample minus the highest
##     "0" sample. The figure is its best value over the offsets.
##   - **Eye width**: the longest run of offsets, around the best one,
##     where every "1" sits at or above the receiver's high threshold and
##     every "0" at or below its low one -- the time the receiver is sure
##     to resolve every bit (at most one UI). Without thresholds, where the
##     eye is open at all (height > 0).
##   - The first `skipBits` bits are left out (the run starts at a DC
##     operating point, not mid-pattern).
## - Linear interpolation between engine samples; the offset grid is the
##   width's resolution (`UI / phases`).

import std/math

type
  PrbsKind* = enum
    prbs7, prbs9, prbs15, prbs23, prbs31

  EyeOptions* = object
    phases*: int
      ## Offsets per UI.
    skipBits*: int
    maxOffset*: float
      ## How far after a bit's start to look for its sample, seconds: at
      ## least the channel's delay plus a UI. `NaN` = 10 UI.

  Eye* = object
    height*: float
      ## Volts, at `bestOffset`; negative: closed.
    width*: float
      ## Seconds of offsets with every bit on the right side of its
      ## threshold; `0`: none.
    bestOffset*: float
      ## The sampling offset after each bit's start with the most height.
    margin*: float
      ## At `bestOffset`, the least distance of any bit beyond its
      ## threshold (volts; negative: some bit is misread there). `NaN`
      ## without thresholds.
    bits*: int
      ## Bits folded into the eye.
    note*: string

proc defaultEyeOptions*(): EyeOptions =
  EyeOptions(phases: 64, skipBits: 8, maxOffset: NaN)

proc taps(k: PrbsKind): tuple[n, a, b: int] =
  case k
  of prbs7: (7, 7, 6)
  of prbs9: (9, 9, 5)
  of prbs15: (15, 15, 14)
  of prbs23: (23, 23, 18)
  of prbs31: (31, 31, 28)

proc period*(k: PrbsKind): int = (1 shl taps(k).n) - 1

proc prbs*(k: PrbsKind, length = -1): string =
  ## `length` bits (default: one period) of the sequence, as `'0'`/`'1'`.
  let (n, a, b) = taps(k)
  let count = if length < 0: period(k) else: length
  var reg = (1'u64 shl n) - 1
  result = newString(count)
  for i in 0 ..< count:
    let bit = ((reg shr (a - 1)) xor (reg shr (b - 1))) and 1
    reg = ((reg shl 1) or bit) and ((1'u64 shl n) - 1)
    result[i] = if bit == 1: '1' else: '0'

proc sampleAt(t, v: openArray[float], tq: float, hint: var int): float =
  ## Linear interpolation, walking forward from `hint`.
  if tq <= t[0]: return v[0]
  if tq >= t[^1]: return v[^1]
  if hint < 0 or hint >= t.len - 1 or t[hint] > tq: hint = 0
  while hint < t.len - 2 and t[hint + 1] < tq: inc hint
  let f = (tq - t[hint]) / (t[hint + 1] - t[hint])
  v[hint] + f * (v[hint + 1] - v[hint])

proc eyeOf*(t, v: openArray[float], bits: string, ui, delay: float,
            vinh, vinl: float, hasThresholds: bool,
            o = defaultEyeOptions()): Eye =
  ## Fold `v` (the receiver wave of a run driven with `bits` at `ui` from
  ## `delay`) into the eye. `vinh`/`vinl`: what a "1"/"0" must reach.
  result = Eye(height: NaN, width: 0.0, bestOffset: NaN, margin: NaN)
  let maxOff = if o.maxOffset.isNaN: 10.0 * ui else: o.maxOffset
  let steps = max(1, int(ceil(maxOff / ui * o.phases.float)))
  let dOff = maxOff / steps.float
  var heights = newSeq[float](steps + 1)
  var margins = newSeq[float](steps + 1)
  var counted = 0
  for s in 0 .. steps:
    let off = s.float * dOff
    var lo1 = Inf
    var hi0 = -Inf
    var hint = 0
    var n = 0
    for k in o.skipBits ..< bits.len:
      let tq = delay + k.float * ui + off
      if tq > t[^1]: break
      let x = sampleAt(t, v, tq, hint)
      if bits[k] == '1': lo1 = min(lo1, x) else: hi0 = max(hi0, x)
      inc n
    if s == 0: counted = n
    heights[s] = if lo1 == Inf or hi0 == -Inf: NaN else: lo1 - hi0
    margins[s] =
      if not hasThresholds or lo1 == Inf or hi0 == -Inf: NaN
      else: min(lo1 - vinh, vinl - hi0)
  result.bits = counted
  var best = -1
  for s in 0 .. steps:
    if heights[s].isNaN: continue
    if best < 0 or heights[s] > heights[best]: best = s
  if best < 0:
    result.note = "no bit of both values was folded into the eye"
    return
  result.height = heights[best]
  result.bestOffset = best.float * dOff
  result.margin = margins[best]
  proc open(s: int): bool =
    if hasThresholds: not margins[s].isNaN and margins[s] >= 0
    else: not heights[s].isNaN and heights[s] > 0
  if open(best):
    var a = best
    var b = best
    while a > 0 and open(a - 1): dec a
    while b < steps and open(b + 1): inc b
    result.width = min((b - a).float * dOff, ui)
    if a == 0 or b == steps:
      result.note = "the open region reaches the end of the offset search"
  else:
    result.note = "closed at the best offset"
