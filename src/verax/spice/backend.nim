## Shared contract for SPICE simulation-backend modules.
##
## This is the *simulation runner* half of the "spice" name in this
## codebase; for the *file-format* deck reader/writer see
## `verax/netlist/formats/spice`.
##
## Every backend module (e.g. `verax/spice/ngspice`) implements the same
## proc names operating only on the core `verax/netlist` types plus this
## module's result/error types, so callers needing more than one backend at
## once can import both and disambiguate with module-qualified calls:
##
## .. code-block:: nim
##   proc writeDeck*(nl: Netlist, cards: seq[string], s: Stream)
##   proc writeDeckFile*(nl: Netlist, cards: seq[string], path: string)
##   proc run*(nl: Netlist, cards: seq[string]): SimResult
##
## `cards` are raw analysis card lines only (e.g. `@[".op"]`, `@[".tran 1u 1m"]`
## or `@[".ac dec 20 1k 1G"]`); a backend decides internally how to capture
## output for them. Only one analysis card is supported per `run()` call in
## every backend implemented so far -- see each backend's own doc comment for
## its specific reasoning/limitations.
##
## **Real vs complex results.** `.op`/`.tran`/`.dc` produce real vectors;
## `.ac` produces complex ones. `SimVector` is an *object variant* over that
## distinction rather than a real-valued vector with a "is it complex?" flag,
## so reading an `.ac` result as `seq[float]` is not merely discouraged --
## the field does not exist on that branch. The `[]` accessor still raises a
## `SpiceSimError` (rather than letting a bare `FieldDefect` escape) so the
## failure stays catchable as a `CatchableError`, like every other failure in
## this submodule.

import std/[complex, math, strutils, tables]

type
  SpiceSimError* = object of CatchableError
    ## Raised when a simulation run fails to produce usable results --
    ## covers both "the backend process itself failed" and "it produced
    ## output we couldn't parse" -- and when a result is read at the wrong
    ## `SimDataKind`.

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
      ## Kind of every vector in `vectors`; a plot never mixes the two.
      ## Defaults to `sdReal`, so a zero-initialized `SimResult` behaves as
      ## it always has.
    vectors*: OrderedTable[string, SimVector]
      ## Keyed by lowercased backend vector name (e.g. `"v(vout)"`).

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
  ## Looks up a real vector's values by name (case-insensitive, matching how
  ## SPICE vector names are conventionally treated). Raises `KeyError` if
  ## `name` isn't present, or `SpiceSimError` if it is complex.
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
  ## Magnitude per point. Defined for both kinds (`abs` of a real value), so
  ## an impedance/gain reader needn't branch on the analysis type.
  let key = name.toLowerAscii
  case r.vectors[key].kind
  of sdReal:
    for x in r.vectors[key].values: result.add abs(x)
  of sdComplex:
    for c in r.vectors[key].cvalues: result.add abs(c)

proc db*(r: SimResult, name: string): seq[float] =
  ## `20*log10(|x|)`. An exactly-zero magnitude yields `-Inf` rather than
  ## raising -- a null in a response is a real result, not an error.
  for m in mag(r, name):
    result.add(if m <= 0.0: -Inf else: 20.0 * log10(m))

proc unwrapDeg*(phases: openArray[float]): seq[float] =
  ## Removes the +-360 discontinuities `arctan2` introduces, so a phase curve
  ## is continuous and a phase-margin calculation reads the true accumulated
  ## lag rather than a wrapped value.
  var offset = 0.0
  for i, p in phases:
    if i > 0:
      let d = (p + offset) - result[i - 1]
      if d > 180.0: offset -= 360.0
      elif d < -180.0: offset += 360.0
    result.add p + offset

proc phaseDeg*(r: SimResult, name: string): seq[float] =
  ## Unwrapped phase in degrees. Complex vectors only -- asking for the phase
  ## of a `.op`/`.tran` vector is a category error, so it raises rather than
  ## returning a meaningless 0/180 sequence.
  let key = name.toLowerAscii
  if r.vectors[key].kind != sdComplex:
    raise wrongKind(name, sdReal)
  var raw: seq[float]
  for c in r.vectors[key].cvalues:
    raw.add radToDeg(phase(c))
  unwrapDeg(raw)

proc freq*(r: SimResult): seq[float] =
  ## The `.ac` sweep axis. ngspice emits `frequency` as a complex vector with
  ## a zero imaginary part, so this pulls the real part rather than making
  ## every caller do it. Raises `KeyError` on a plot with no frequency axis.
  let key = "frequency"
  case r.vectors[key].kind
  of sdReal:
    result = r.vectors[key].values
  of sdComplex:
    for c in r.vectors[key].cvalues: result.add c.re
