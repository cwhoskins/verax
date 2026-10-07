## Where orderable parts come from: a registry of `CatalogSource`s, asked in
## registration order, the same "first source that answers wins" contract as
## `pcb/footprint.FootprintSource`.
##
## **No source is registered here.** A source is opt-in per import, or per
## call (`bom/sources/local.registerCatalogFile`): a design that never asks
## for a BOM never loads a catalogue, and nothing reaches a network unless a
## network source was imported.
##
## A source's procs are closures, not `{.nimcall.}` as `FootprintSource`'s
## are, because a source carries state the registry does not: the local
## source the catalogue it loaded, a network source its credentials and
## cache.

import std/[math, strutils, tables]

import ./types

type
  PartQuery* = object
    ## A parametric search. Every float left `NaN` is "no requirement".
    family*: PartFamily
    value*: float
      ## Wanted value, SI base units. `NaN` matches nothing: there is no
      ## search for "a resistor".
    valueTolerance*: float
      ## How far a candidate's nominal value may sit from `value`, as a
      ## fraction of it. `NaN` or 0 means the nominal must equal `value`.
    caseCode*: string
      ## Required. `""` matches nothing -- the standard-footprint gate
      ## (`classify.caseCodeOf`) has already said this part has no case code
      ## a search may fill.
    minVoltage*, minPower*, minCurrent*: float
      ## A candidate whose matching rating is unknown (`NaN`) is rejected
      ## when the minimum is stated, never assumed to meet it.
    dielectric*: string
      ## `""` for any; otherwise must match, ignoring case. A candidate that
      ## does not state one is rejected.
    maxTolerance*: float
      ## The loosest acceptable tolerance; an unknown tolerance is rejected.
    manufacturers*: seq[string]
      ## Preferred manufacturers -- a hint a remote source may use to narrow
      ## its own search, **never a filter**. Ranking by preference is the
      ## resolver's job.
    limit*: int
      ## At most this many candidates; `0` for no limit.

  CatalogSource* = ref object
    name*: string
    search*: proc (q: PartQuery): seq[Candidate]
      ## `nil` => this source cannot answer a parametric query.
    lookup*: proc (mpn, manufacturer: string): Candidate
      ## `nil` => this source cannot look parts up. A `nil` *result* means
      ## "I don't know this part", never an exception. `manufacturer = ""`
      ## matches any.

proc newPartQuery*(family: PartFamily, value: float, caseCode: string):
    PartQuery =
  ## A query with every optional requirement left unstated (`NaN`), which a
  ## default-constructed `PartQuery` -- its floats `0.0` -- would not be.
  PartQuery(family: family, value: value, valueTolerance: NaN,
            caseCode: caseCode, minVoltage: NaN, minPower: NaN,
            minCurrent: NaN, maxTolerance: NaN)

proc atLeast(have, want: float): bool =
  want.isNaN or (not have.isNaN and have >= want)

proc matches*(c: Candidate, q: PartQuery): bool =
  ## Whether `c` meets every requirement `q` states. The one definition of a
  ## match, so every source that filters locally filters the same way.
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
  ## The identity of an orderable part: case-insensitive on both halves,
  ## since distributors and datasheets disagree on the case of either.
  manufacturer.strip.toLowerAscii & "\t" & mpn.strip.toLowerAscii

var registry: seq[CatalogSource]
  ## Registration order is resolution order, so a house catalogue
  ## registered ahead of a distributor shadows it deliberately.

proc registerCatalogSource*(s: CatalogSource) =
  registry.add s

proc clearCatalogSources*() =
  ## Drops every registered source -- for tests, and for a caller that
  ## re-runs with a different catalogue in one process.
  registry.setLen 0

proc catalogSources*(): seq[string] =
  for s in registry: result.add s.name

proc foldAvailability(into: var Availability, other: Availability) =
  if into.stock < 0: into.stock = other.stock
  if into.moq < 0: into.moq = other.moq
  if into.lifecycle.len == 0: into.lifecycle = other.lifecycle

proc searchAll*(q: PartQuery): seq[Candidate] =
  ## Every registered source's candidates, de-duplicated on
  ## `(manufacturer, mpn)`. The first source's record is kept; a later
  ## source fills only the availability the first did not state. Returned
  ## candidates are the caller's own (`copyCandidate`).
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
