## KiCad's own number formatting, reproduced for the one case that needs it:
## a **regenerated** node. An untouched node is never reformatted -- it is
## copied bytes, via `sexp.raw` -- so everything in this module exists only
## for the write path of an entity `verax/pcb/graph` actually changed.
##
## **Why a hand-rolled formatter instead of `std/strutils.formatFloat`,
## verified this session:** `formatFloat(90.0, ffDefault, 10)` yields
## `"90.00000000"`, not `"90"` -- Nim's `ffDefault` passes `sprintf`'s `#`
## flag, which *keeps* trailing zeros. The corpus never writes a trailing
## zero on a coordinate or an angle (`90`, not `90.000000`; `2.5`, not
## `2.500000`), so the naive route would make every regenerated node a diff
## against every untouched neighbour that happens to share a round value.
##
## Lengths are formatted from the **integer** nanometre count, not from the
## `float` millimetre value `toMm` would hand back -- there is no rounding
## question, no locale, and no risk of `2.5` printing as `2.4999999999998`
## the way float division occasionally does. Angles have no integer
## representation to lean on (KiCad states them directly in degrees, and a
## regenerated arc's `sweep` is a `Deg`, a `float64`), so `formatDeg` frames
## the risk instead: **angles are signed, never normalised to `[0, 360)`.**
## Verified against the corpus: a footprint's `(at x y [rot])` third field is
## absent 1307 times (the omitted-when-zero case), `180` 1149 times, `90` 883,
## **`-90` 768**, `-135` 19, `-45` 11, `45` 10, `135` 5, across all 18 demo
## boards. A formatter that folds into `[0, 360)` would turn every one of
## those 768 `-90`s into `270` -- valid KiCad, and pure diff noise against
## what the file already said.

import std/[math, strutils]
import ../units
import ../geometry

proc formatMm*(v: Nm): string =
  ## KiCad's internal-unit formatting: nanometres to millimetres, up to six
  ## decimal digits, trailing zeros and a trailing bare `.` both stripped,
  ## a whole-millimetre value written bare (`"90"`, not `"90.0"`), and `"0"`
  ## rather than `"-0"` for an exact zero (`Nm`'s `int64` has no signed zero
  ## to accidentally print, but the check is cheap and the corpus-matching
  ## behaviour is worth stating explicitly rather than leaving to that
  ## accident).
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
  ## A bare integer when the value is a whole number, else up to ten
  ## significant decimal digits with trailing zeros (and then a bare
  ## trailing `.`) stripped. **Signed, never folded into `[0, 360)`** -- see
  ## the module doc comment.
  let v = a.value
  if v == trunc(v) and abs(v) < 1e15:
    return $int64(v)
  result = formatFloat(v, ffDecimal, 10)
  while result.len > 0 and result[^1] == '0': result.setLen(result.len - 1)
  if result.len > 0 and result[^1] == '.': result.setLen(result.len - 1)

proc formatAt*(p: Point, rot: Deg): string =
  ## The body of a KiCad `(at x y [rot])` node (without the surrounding
  ## `(at ... )`): `p` is in **canonical** (Y-up) coordinates and is
  ## Y-flipped here; `rot` must already be in KiCad's sign convention
  ## (`rot_kicad = -rot_canonical`, exact on `float64` negation) -- the
  ## caller flips it, not this proc, because a footprint's own rotation and
  ## a pad's rotation-within-the-footprint compose differently and only the
  ## caller knows which is being formatted. The angle field is **omitted
  ## entirely when it is zero**, matching the corpus's dominant case
  ## (1307 of 4152 `(at)` nodes across the demo boards carry no third field
  ## at all) rather than writing a spurious `0`.
  result = formatMm(p.x) & " " & formatMm(-p.y)
  if rot.value != 0.0:
    result.add(" ")
    result.add(formatDeg(rot))

proc escapeKicadString*(s: string): string =
  ## The inverse of `sexp.decodeString`, and the one place this codebase
  ## re-encodes a KiCad string atom rather than copying source bytes --
  ## needed only for a value this stage **synthesizes** (a new net's name, a
  ## regenerated property value), never for anything read from the file,
  ## which is emitted through `sexp.raw` untouched. Escapes exactly the
  ## three sequences the corpus uses (`\\`, `\"`, `\n` -- finding 6) and
  ## wraps the result in quotes; an input needing none of them still comes
  ## back quoted, matching KiCad's own writer, which quotes every string
  ## field unconditionally (`(net 0 "")`, not `(net 0 )`).
  result = "\""
  for ch in s:
    case ch
    of '\\': result.add("\\\\")
    of '"': result.add("\\\"")
    of '\n': result.add("\\n")
    else: result.add(ch)
  result.add("\"")
