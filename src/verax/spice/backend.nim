## Shared contract for SPICE simulation backends (the runner; the deck
## reader/writer is `verax/netlist/formats/spice`).
##
## Every backend implements the same procs over `verax/netlist` types plus
## this module's result/error types, so several can be imported and
## module-qualified:
##
## .. code-block:: nim
##   proc writeDeck*(nl: Netlist, cards: seq[string], s: Stream)
##   proc writeDeckFile*(nl: Netlist, cards: seq[string], path: string)
##   proc run*(nl: Netlist, cards: seq[string]): SimResult
##
## `cards` are raw analysis cards (`@[".op"]`, `@[".ac dec 20 1k 1G"]`); one
## analysis per `run()` (see each backend).
##
## **`SimVector` is a variant over real/complex**, so reading an `.ac`
## result as `seq[float]` is impossible; `[]` raises `SpiceSimError` (not a
## `FieldDefect`) so the failure stays catchable.

import std/[complex, math, strutils, tables]

type
  SpiceSimError* = object of CatchableError
    ## Raised when a run fails (process failure or unparseable output), or a
    ## result is read as the wrong `SimDataKind`.

  SimDataKind* = enum
    sdReal      ## `.op`, `.tran`, `.dc`
    sdComplex   ## `.ac`

  SimVector* = object
    name*: string
    case kind*: SimDataKind
    of sdReal:
      values*: seq[float]
    of sdComplex:
      cvalues*: seq[Complex64]

  SimResult* = object
    plotName*: string
    dataKind*: SimDataKind
      ## Kind of every vector (a plot never mixes). Defaults to `sdReal`.
    vectors*: OrderedTable[string, SimVector]
      ## Keyed by lowercased vector name (`"v(vout)"`).

proc newSimVector*(name: string, kind: SimDataKind = sdReal): SimVector =
  case kind
  of sdReal: SimVector(kind: sdReal, name: name)
  of sdComplex: SimVector(kind: sdComplex, name: name)

proc len*(v: SimVector): int =
  case v.kind
  of sdReal: v.values.len
  of sdComplex: v.cvalues.len

proc names*(r: SimResult): seq[string] =
  ## Vector names in the order the backend reported them, original casing.
  for _, v in r.vectors: result.add v.name

proc wrongKind(name: string, got: SimDataKind): ref SpiceSimError =
  case got
  of sdComplex:
    newException(SpiceSimError,
      "vector '" & name & "' is complex (.ac): read it with cplx(), mag(), " &
      "db() or phaseDeg() rather than []")
  of sdReal:
    newException(SpiceSimError,
      "vector '" & name & "' is real (.op/.tran/.dc), not complex: read it with []")

proc `[]`*(r: SimResult, name: string): seq[float] =
  ## A real vector's values by name (case-insensitive). Raises `KeyError` if
  ## absent, `SpiceSimError` if complex.
  let key = name.toLowerAscii
  if r.vectors[key].kind != sdReal:
    raise wrongKind(name, sdComplex)
  r.vectors[key].values

proc cplx*(r: SimResult, name: string): seq[Complex64] =
  ## The complex counterpart of `[]`. Raises `SpiceSimError` on a real vector.
  let key = name.toLowerAscii
  if r.vectors[key].kind != sdComplex:
    raise wrongKind(name, sdReal)
  r.vectors[key].cvalues

proc mag*(r: SimResult, name: string): seq[float] =
  ## Magnitude per point, for either kind.
  let key = name.toLowerAscii
  case r.vectors[key].kind
  of sdReal:
    for x in r.vectors[key].values: result.add abs(x)
  of sdComplex:
    for c in r.vectors[key].cvalues: result.add abs(c)

proc db*(r: SimResult, name: string): seq[float] =
  ## `20*log10(|x|)`; an exact zero gives `-Inf` (a real null, not an error).
  for m in mag(r, name):
    result.add(if m <= 0.0: -Inf else: 20.0 * log10(m))

proc unwrapDeg*(phases: openArray[float]): seq[float] =
  ## Removes `arctan2`'s +-360 jumps so a phase curve shows true accumulated
  ## lag.
  var offset = 0.0
  for i, p in phases:
    if i > 0:
      let d = (p + offset) - result[i - 1]
      if d > 180.0: offset -= 360.0
      elif d < -180.0: offset += 360.0
    result.add p + offset

proc phaseDeg*(r: SimResult, name: string): seq[float] =
  ## Unwrapped phase in degrees. Complex vectors only; raises otherwise.
  let key = name.toLowerAscii
  if r.vectors[key].kind != sdComplex:
    raise wrongKind(name, sdReal)
  var raw: seq[float]
  for c in r.vectors[key].cvalues:
    raw.add radToDeg(phase(c))
  unwrapDeg(raw)

proc freq*(r: SimResult): seq[float] =
  ## The `.ac` sweep axis (ngspice writes `frequency` as complex with zero
  ## imaginary part). Raises `KeyError` if absent.
  let key = "frequency"
  case r.vectors[key].kind
  of sdReal:
    result = r.vectors[key].values
  of sdComplex:
    for c in r.vectors[key].cvalues: result.add c.re
