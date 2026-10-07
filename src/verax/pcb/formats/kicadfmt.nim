## KiCad's number formatting, for **regenerated** nodes only (untouched
## nodes are copied bytes).
##
## Hand-rolled because `formatFloat(90.0, ffDefault, 10)` gives
## `"90.00000000"`; KiCad never writes trailing zeros, so the naive route
## makes every regenerated node a diff.
##
## Lengths are formatted from the integer nanometre count (no float
## rounding). **Angles are signed, never normalised to `[0, 360)`**: KiCad
## files commonly write `-90`, and folding to `270` is pure diff noise.

import std/[math, strutils]
import ../units
import ../geometry

proc formatMm*(v: Nm): string =
  ## Nanometres to millimetres, up to six decimals, trailing zeros and bare
  ## `.` stripped (`"90"`, not `"90.0"`), and `"0"` rather than `"-0"`.
  let raw = v.raw
  if raw == 0: return "0"
  let neg = raw < 0
  let mag = abs(raw)
  let whole = mag div NmPerMm
  let frac = mag mod NmPerMm
  result = $whole
  if frac != 0:
    var fs = $frac
    while fs.len < 6: fs = "0" & fs   # pad to six decimal places
    while fs.len > 0 and fs[^1] == '0': fs.setLen(fs.len - 1)
    result.add('.')
    result.add(fs)
  if neg: result = "-" & result

proc formatDeg*(a: Deg): string =
  ## A bare integer when whole, else up to ten significant digits with
  ## trailing zeros stripped. **Signed, never folded.**
  let v = a.value
  if v == trunc(v) and abs(v) < 1e15:
    return $int64(v)
  result = formatFloat(v, ffDecimal, 10)
  while result.len > 0 and result[^1] == '0': result.setLen(result.len - 1)
  if result.len > 0 and result[^1] == '.': result.setLen(result.len - 1)

proc formatAt*(p: Point, rot: Deg): string =
  ## The body of `(at x y [rot])`: `p` is canonical (Y-up) and is Y-flipped
  ## here; `rot` must already be in KiCad's sign (`-rot_canonical`) -- the
  ## caller flips it, since footprint and pad rotations compose differently.
  ## The angle is **omitted when zero**, as KiCad does.
  result = formatMm(p.x) & " " & formatMm(-p.y)
  if rot.value != 0.0:
    result.add(" ")
    result.add(formatDeg(rot))

proc escapeKicadString*(s: string): string =
  ## Inverse of `sexp.decodeString`, for synthesized strings only (read
  ## values are copied raw). Escapes `\\`, `\"`, `\n` and always quotes, as
  ## KiCad does (`(net 0 "")`).
  result = "\""
  for ch in s:
    case ch
    of '\\': result.add("\\\\")
    of '"': result.add("\\\"")
    of '\n': result.add("\\n")
    else: result.add(ch)
  result.add("\"")
