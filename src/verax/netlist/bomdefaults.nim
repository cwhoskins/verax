## Board-level procurement defaults read by `verax/bom` (`bomDefaults(nl)`).
## Owned here because `netlist/dsl` can't import above `netlist/`; this
## module owns storage, grammar and validation.
##
## "Prefer X7R", "derate by 2x", "round to E24", "TDK before Murata" are
## facts about the procurement policy, stated once rather than on every
## part. A separate module from `environment` and `layouthints` because
## these are neither electrical facts nor rendering hints.
##
## **Storage is namespaced `bom.*` attrs** on the stating netlist: copied by
## `graph.clone`, so they survive every transform (and are lost by a SPICE
## round trip). Not registered annotations -- not electrical vocabulary.
##
## **The most specific statement wins, field by field**: `nl` itself, then
## each parent to the root. A library sheet's `bom:` keeps applying wherever
## it's instanced, while a board's `series` reaches every sheet that didn't
## state one.
##
## **No tree-wide override.** To change one instance, set it in that
## instance's `with = proc(sub: Netlist) = setBomDielectric(sub, "X7R")`,
## which writes only that clone.
##
## **A default never overrides a part's own `spec:`** -- that is a
## requirement; `verax/bom` reads it first.
##
## The DSL's `bom:` block is strict (unknown key = compile error); the
## `attrs` underneath are permissive. `bomDefaultKeys` is the one list both
## sides read.

import std/[options, strutils, tables]

import ./types
import ./graph
import ./issue
import ../units

export issue, options

const
  bomToleranceKey* = "bom.tolerance"
  bomDielectricKey* = "bom.dielectric"
  bomSeriesKey* = "bom.series"
  bomDeratingKey* = "bom.derating"
  bomResistorPackageKey* = "bom.resistor_package"
  bomCapacitorPackageKey* = "bom.capacitor_package"
  bomInductorPackageKey* = "bom.inductor_package"
  bomManufacturersKey* = "bom.manufacturers"
  bomDefaultKeys* = ["tolerance", "dielectric", "series", "derating",
                      "resistor_package", "capacitor_package",
                      "inductor_package", "manufacturers"]
    ## Bare keys the `bom:` block accepts (without the `bom.` prefix).
  bomSeriesNames* = ["exact", "e12", "e24", "e96"]
    ## The ladders `parts/series.nim` holds. Closed, since this module can
    ## see the whole list.

type
  BomDefaults* = object
    tolerance*: Option[Fraction]  ## default part tolerance when a part states none
    dielectric*: string           ## default ceramic class for a cap that states none
    series*: string                ## "exact" | "e12" | "e24" | "e96"
    derating*: Option[float]       ## voltage derating factor
    resistorPackage*: string       ## default case size, per family
    capacitorPackage*: string
    inductorPackage*: string
    manufacturers*: seq[string]    ## preferred-manufacturer ranking, first wins

# --- parsing -------------------------------------------------------------
#
# One parse point per value, shared by `bomDefaults` and
# `validateBomDefaults`. Unparseable text only arrives from a foreign writer;
# the DSL calls the typed setters.

proc parseBomFloat(s: string): tuple[ok: bool, value: float] =
  try: (true, parseFloat(s.strip()))
  except ValueError: (false, 0.0)

# --- reading ---------------------------------------------------------------

proc statedBom(nl: Netlist, key: string): tuple[found: bool, text: string] =
  ## The nearest stated value of `key`: `nl`, then each parent to the root.
  var n = nl
  while n != nil:
    if n.attrs.hasKey(key): return (true, n.attrs[key])
    n = n.parent
  (false, "")

proc bomDefaults*(nl: Netlist): BomDefaults =
  ## The procurement defaults for parts in `nl`, each field from the nearest
  ## netlist stating it. Absent or unparseable reads as `none` / "" (pure
  ## and total); an unparseable value doesn't fall through to a parent's --
  ## `validateBomDefaults` reports it.
  var (ok, t) = statedBom(nl, bomToleranceKey)
  if ok:
    let (parsed, v) = parseBomFloat(t)
    if parsed: result.tolerance = some(Fraction(v))
  (ok, t) = statedBom(nl, bomDielectricKey)
  if ok: result.dielectric = t
  (ok, t) = statedBom(nl, bomSeriesKey)
  if ok: result.series = t
  (ok, t) = statedBom(nl, bomDeratingKey)
  if ok:
    let (parsed, v) = parseBomFloat(t)
    if parsed: result.derating = some(v)
  (ok, t) = statedBom(nl, bomResistorPackageKey)
  if ok: result.resistorPackage = t
  (ok, t) = statedBom(nl, bomCapacitorPackageKey)
  if ok: result.capacitorPackage = t
  (ok, t) = statedBom(nl, bomInductorPackageKey)
  if ok: result.inductorPackage = t
  (ok, t) = statedBom(nl, bomManufacturersKey)
  if ok:
    for m in t.split(';'):
      if m.len > 0: result.manufacturers.add m

# --- writing -----------------------------------------------------------
#
# Setters write exactly the `nl` given, never the root, so a per-instance
# `with =` override stays per-instance.

proc setBomTolerance*(nl: Netlist, t: Fraction) =
  nl.attrs[bomToleranceKey] = formatFloat(float(t), ffScientific, 9)

proc setBomDielectric*(nl: Netlist, d: string) =
  nl.attrs[bomDielectricKey] = d

proc setBomSeries*(nl: Netlist, s: string) =
  nl.attrs[bomSeriesKey] = s

proc setBomDerating*(nl: Netlist, f: float) =
  nl.attrs[bomDeratingKey] = formatFloat(f, ffScientific, 9)

proc setBomResistorPackage*(nl: Netlist, p: string) =
  nl.attrs[bomResistorPackageKey] = p

proc setBomCapacitorPackage*(nl: Netlist, p: string) =
  nl.attrs[bomCapacitorPackageKey] = p

proc setBomInductorPackage*(nl: Netlist, p: string) =
  nl.attrs[bomInductorPackageKey] = p

proc setBomManufacturers*(nl: Netlist, mfrs: openArray[string]) =
  ## `;`-delimited, like other flat lists in `attrs`. `openArray` accepts
  ## both literals and seqs.
  var parts: seq[string]
  for m in mfrs: parts.add m
  nl.attrs[bomManufacturersKey] = parts.join(";")

# --- validation --------------------------------------------------------

const
  KindBomDefaultUnknownSeries* = "bom_default_unknown_series"
  KindBomDefaultDeratingTooLow* = "bom_default_derating_too_low"
  KindBomDefaultNegativeTolerance* = "bom_default_negative_tolerance"

proc validateBomDefaultsAt(nl: Netlist, path: string): seq[Issue]

proc validateBomDefaults*(nl: Netlist): seq[Issue] =
  ## Problems with what a `bom:` block *stated*, anywhere under `nl` (an
  ## unstated policy isn't reported). Every netlist in the tree is checked,
  ## since child defaults are read; messages name the instance path.
  validateBomDefaultsAt(nl, "")

proc validateBomDefaultsAt(nl: Netlist, path: string): seq[Issue] =
  ## `path` is the instance path (`XL.XA`); template names are shared, so
  ## only the path says which sheet stated a value.
  let where =
    if path.len == 0: "the bom: block on " & nl.name.escape()
    else: "the bom: block inside instance " & path
  if nl.attrs.hasKey(bomSeriesKey):
    let s = nl.attrs[bomSeriesKey]
    if s notin bomSeriesNames:
      result.add newIssue(KindBomDefaultUnknownSeries, sevError,
        where & " states series = " & s.escape() &
        ", which is not one of " & bomSeriesNames.join(", ") &
        " -- parts/series only holds those four ladders, so this default " &
        "would be read by nothing.")
  if nl.attrs.hasKey(bomDeratingKey):
    let (ok, v) = parseBomFloat(nl.attrs[bomDeratingKey])
    if ok and v < 1.0:
      result.add newIssue(KindBomDefaultDeratingTooLow, sevError,
        where & " states derating = " & $v & ", which rates " &
        "a part below the voltage actually across it. A derating factor " &
        "scales the working voltage *up* to find the rating to buy at -- " &
        "below 1.0 asks for a part rated for less than it will see.")
  if nl.attrs.hasKey(bomToleranceKey):
    let (ok, t) = parseBomFloat(nl.attrs[bomToleranceKey])
    if ok and t < 0.0:
      result.add newIssue(KindBomDefaultNegativeTolerance, sevError,
        where & " states a negative tolerance (" & $t &
        "), which is not a fraction any part is sold at.")
  for designator, child in nl.children:
    result.add validateBomDefaultsAt(child, hierName(path, designator))
