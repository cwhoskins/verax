## Where orderable parts come from: a registry of `CatalogSource`s, asked in
## registration order ("first source that answers wins").
##
## **Nothing registers here**: sources are opt-in per import or call
## (`sources/local.registerCatalogFile`), so nothing loads or reaches a
## network unasked. Source procs are closures (unlike `FootprintSource`)
## because sources carry state (a loaded catalogue, credentials, a cache).

import std/[math, strutils, tables]

import ./types

type
  PartQuery* = object
    ## A parametric search. Every float left `NaN` is "no requirement".
    family*: PartFamily
    value*: float
      ## Wanted value, SI base units. `NaN` matches nothing.
    valueTolerance*: float
      ## Allowed deviation of the nominal, as a fraction; `NaN` or 0 means
      ## exact.
    caseCode*: string
      ## Required; `""` matches nothing (`classify.caseCodeOf` found no
      ## searchable case code).
    minVoltage*, minPower*, minCurrent*: float
      ## When a minimum is stated, a candidate with that rating unknown is
      ## rejected.
    dielectric*: string
      ## `""` for any; else must match (case-insensitive). An unstated
      ## dielectric is rejected.
    maxTolerance*: float
      ## The loosest acceptable tolerance; an unknown tolerance is rejected.
    manufacturers*: seq[string]
      ## Preferred manufacturers: a hint for narrowing, **never a filter**
      ## (ranking is the resolver's job).
    limit*: int
      ## At most this many candidates; `0` for no limit.

  CatalogSource* = ref object
    name*: string
    search*: proc (q: PartQuery): seq[Candidate]
      ## `nil` => this source cannot answer a parametric query.
    lookup*: proc (mpn, manufacturer: string): Candidate
      ## `nil` => no lookups. A `nil` result means "don't know this part",
      ## never an exception. `manufacturer = ""` matches any.

proc newPartQuery*(family: PartFamily, value: float, caseCode: string):
    PartQuery =
  ## A query with every optional requirement unstated (`NaN`); a
  ## default-constructed `PartQuery` would have `0.0`.
  PartQuery(family: family, value: value, valueTolerance: NaN,
            caseCode: caseCode, minVoltage: NaN, minPower: NaN,
            minCurrent: NaN, maxTolerance: NaN)

proc atLeast(have, want: float): bool =
  want.isNaN or (not have.isNaN and have >= want)

proc matches*(c: Candidate, q: PartQuery): bool =
  ## Whether `c` meets every requirement `q` states -- the one definition
  ## of a match.
  if c.family != q.family or not q.family.isParametric: return false
  if q.caseCode.len == 0 or q.value.isNaN or c.value.isNaN: return false
  if cmpIgnoreCase(c.caseCode, q.caseCode) != 0: return false
  let tol =
    if q.valueTolerance.isNaN or q.valueTolerance <= 0: 1e-9
    else: q.valueTolerance
  if abs(c.value - q.value) > tol * abs(q.value): return false
  if not atLeast(c.voltageRating, q.minVoltage): return false
  if not atLeast(c.powerRating, q.minPower): return false
  if not atLeast(c.currentRating, q.minCurrent): return false
  if q.dielectric.len > 0 and cmpIgnoreCase(c.dielectric, q.dielectric) != 0:
    return false
  if not q.maxTolerance.isNaN and
      (c.tolerance.isNaN or c.tolerance > q.maxTolerance):
    return false
  true

proc partKey*(manufacturer, mpn: string): string =
  ## A part's identity, case-insensitive on manufacturer and MPN.
  manufacturer.strip.toLowerAscii & "\t" & mpn.strip.toLowerAscii

var registry: seq[CatalogSource]
  ## Registration order is resolution order (a house catalogue can shadow a
  ## distributor).

proc registerCatalogSource*(s: CatalogSource) =
  registry.add s

proc clearCatalogSources*() =
  ## Drops every source (for tests and reruns).
  registry.setLen 0

proc catalogSources*(): seq[string] =
  for s in registry: result.add s.name

proc foldAvailability(into: var Availability, other: Availability) =
  if into.stock < 0: into.stock = other.stock
  if into.moq < 0: into.moq = other.moq
  if into.lifecycle.len == 0: into.lifecycle = other.lifecycle

proc searchAll*(q: PartQuery): seq[Candidate] =
  ## Every source's candidates, deduped on `(manufacturer, mpn)`: the first
  ## record wins; later sources only fill unstated availability. Returns
  ## caller-owned copies.
  var seen: Table[string, int]
  for s in registry:
    if s.search == nil: continue
    for c in s.search(q):
      if c == nil: continue
      let k = partKey(c.manufacturer, c.mpn)
      if k in seen:
        foldAvailability(result[seen[k]].avail, c.avail)
      else:
        seen[k] = result.len
        result.add copyCandidate(c)

proc lookupAll*(mpn: string, manufacturer = ""): Candidate =
  ## The first registered source that knows `mpn`, or `nil`.
  for s in registry:
    if s.lookup == nil: continue
    let c = s.lookup(mpn, manufacturer)
    if c != nil: return copyCandidate(c)
  nil
