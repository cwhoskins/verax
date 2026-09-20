## Canonical units for the physical board model.
##
## Lengths are signed nanometres in a `distinct int64` (`Nm`), so mixing a raw
## integer with a length is a compile error. `int64` nanometres span the entire
## ODB++ legal coordinate range (+/-2450 mm, about +/-2.45e12 nm) with room to
## spare, and exactly round-trip KiCad, which is `int32` nanometres internally
## and never writes more than six decimal places.
##
## Known, deliberate precision loss: ODB++'s finest legal quantum is
## 1/400 micron = 2.5 nm, so ODB++ input rounds to the nearest nanometre. That
## is far below any real fab or design-rule tolerance.
##
## Angles are degrees in a `distinct float64` (`Deg`), **counter-clockwise
## positive**, matching the canonical frame described in
## `verax/pcb/geometry`.

import std/math

type
  Nm* = distinct int64
    ## Canonical length: signed nanometres.

  Deg* = distinct float64
    ## Canonical angle: degrees, counter-clockwise positive.

  LengthUnit* = enum
    ## Source-file unit, for readers converting at the I/O boundary.
    luNm, luUm, luMm, luMil, luInch

const
  NmPerUm* = 1_000'i64
  NmPerMm* = 1_000_000'i64
  NmPerMil* = 25_400'i64
  NmPerInch* = 25_400_000'i64

  OdbQuantumNm* = 2.5
    ## ODB++ minimum resolution, 1/400 micron, in nanometres. Documented here
    ## because it is the one quantity this representation cannot hold exactly.

# ---------------------------------------------------------------- Nm

proc `+`*(a, b: Nm): Nm {.borrow.}
proc `-`*(a, b: Nm): Nm {.borrow.}
proc `-`*(a: Nm): Nm {.borrow.}
proc `<`*(a, b: Nm): bool {.borrow.}
proc `<=`*(a, b: Nm): bool {.borrow.}
proc `==`*(a, b: Nm): bool {.borrow.}
proc abs*(a: Nm): Nm {.borrow.}

proc raw*(a: Nm): int64 {.inline.} =
  ## The underlying nanometre count.
  int64(a)

proc nm*(v: int64): Nm {.inline.} = Nm(v)
proc nm*(v: int): Nm {.inline.} = Nm(int64(v))

proc `*`*(a: Nm, k: int): Nm {.inline.} = Nm(a.raw * int64(k))
proc `*`*(k: int, a: Nm): Nm {.inline.} = Nm(a.raw * int64(k))
proc `*`*(a: Nm, k: float): Nm {.inline.} = Nm(int64(round(a.raw.float * k)))
proc `*`*(k: float, a: Nm): Nm {.inline.} = Nm(int64(round(a.raw.float * k)))
proc `div`*(a: Nm, k: int): Nm {.inline.} = Nm(a.raw div int64(k))
proc `/`*(a, b: Nm): float {.inline.} = a.raw.float / b.raw.float

proc um*(v: float): Nm {.inline.} = Nm(int64(round(v * NmPerUm.float)))
proc mm*(v: float): Nm {.inline.} = Nm(int64(round(v * NmPerMm.float)))
proc mil*(v: float): Nm {.inline.} = Nm(int64(round(v * NmPerMil.float)))
proc inch*(v: float): Nm {.inline.} = Nm(int64(round(v * NmPerInch.float)))

proc toUm*(a: Nm): float {.inline.} = a.raw.float / NmPerUm.float
proc toMm*(a: Nm): float {.inline.} = a.raw.float / NmPerMm.float
proc toMil*(a: Nm): float {.inline.} = a.raw.float / NmPerMil.float
proc toInch*(a: Nm): float {.inline.} = a.raw.float / NmPerInch.float

proc toMetres*(a: Nm): float {.inline.} =
  ## Nanometres as a plain metre-valued `float`. The conversion
  ## `fem/extrude.nim` used to open-code privately (`a.raw.float * 1e-9`) as
  ## its own local `metres` proc; promoted here once `pcb/geometry.length`
  ## needed the identical factor, so the two do not silently drift apart.
  ##
  ## Returns a bare `float`, not a new distinct type: `findings.md` §18 asked
  ## whether a `Metres` type belongs here or in `verax/units`, and the answer
  ## this stage lands on is neither -- a computed length is a real number
  ## used in ordinary arithmetic (summed, divided by a velocity, squared into
  ## an area), `pcb/units.Nm` stays integer nanometres for the geometry it
  ## already serves, and `verax/units` stays electrical quantities
  ## (`Volts`/`Ohms`/...), which a board length is not. Adding a third unit
  ## type to carry one already-scaled `float` around would buy type safety
  ## nothing else here has and cost every consumer an extra conversion.
  a.raw.float * 1e-9

proc toNm*(v: float, u: LengthUnit): Nm =
  ## Converts a source-file value in unit `u` to canonical nanometres.
  case u
  of luNm: Nm(int64(round(v)))
  of luUm: um(v)
  of luMm: mm(v)
  of luMil: mil(v)
  of luInch: inch(v)

proc `$`*(a: Nm): string =
  ## Renders as the raw nanometre count, e.g. `"1000000nm"`. Lossless, so it
  ## is safe to compare in tests; use `toMm` for human-facing output.
  $a.raw & "nm"

# ---------------------------------------------------------------- Deg

proc `+`*(a, b: Deg): Deg {.borrow.}
proc `-`*(a, b: Deg): Deg {.borrow.}
proc `-`*(a: Deg): Deg {.borrow.}
proc `<`*(a, b: Deg): bool {.borrow.}
proc `<=`*(a, b: Deg): bool {.borrow.}
proc `==`*(a, b: Deg): bool {.borrow.}

proc deg*(v: float): Deg {.inline.} = Deg(v)
proc value*(a: Deg): float {.inline.} = float(a)

proc `*`*(a: Deg, k: float): Deg {.inline.} = Deg(a.value * k)

proc toRadians*(a: Deg): float {.inline.} = a.value * PI / 180.0
proc fromRadians*(r: float): Deg {.inline.} = Deg(r * 180.0 / PI)

proc normalized*(a: Deg): Deg =
  ## Folds into `[0, 360)`.
  var v = a.value mod 360.0
  if v < 0: v += 360.0
  Deg(v)

proc `$`*(a: Deg): string = $a.value & "deg"
