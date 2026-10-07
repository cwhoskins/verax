## Canonical units for the physical board model.
##
## Lengths are signed nanometres in a `distinct int64` (`Nm`): it spans
## ODB++'s +/-2450 mm range and round-trips KiCad exactly. ODB++'s 2.5 nm
## quantum rounds to the nearest nm (far below any fab tolerance).
##
## Angles are degrees in a `distinct float64` (`Deg`), **CCW positive**
## (see `verax/pcb/geometry`).

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
    ## ODB++ minimum resolution (1/400 micron) in nm -- the one quantity not
    ## held exactly.

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
  ## Nanometres as metres, a plain `float` (no `Metres` type: computed
  ## lengths are used in ordinary arithmetic).
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
  ## The raw nanometre count (`"1000000nm"`), lossless for tests; use `toMm`
  ## for display.
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
