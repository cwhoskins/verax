## Board-level defaults for a parametric BOM compiler that does not exist yet
## in this submodule -- `verax/bom` (see `docs/bom_compiler_plan.md`) reads
## these, but `netlist/dsl.nim` may not import a module above `netlist/`, so
## the exact precedent `layouthints.nim`'s own `CLAUDE.md` entry states
## applies again here: *"`pcb/` depends on `netlist/`, never the reverse, so
## the binding is authored here and resolved there."* `bom/` will do nothing
## but read `bomDefaults(nl)`; this module owns the storage, the grammar and
## the validation.
##
## A board rarely wants every capacitor re-derived from first principles --
## "prefer X7R", "derate voltage by 2x", "round to E24", "TDK before Murata
## before anyone else" are facts about the *procurement policy* the board is
## built under, stated once, rather than repeated on every `spec:` block that
## would otherwise have to restate them. That is the same shape
## `environment.nim`'s ambient range takes for a *temperature* default, and
## the same shape `layouthints.nim`'s `layout:` block takes for a *rendering*
## one -- this is a third board-wide default family, and it gets the third
## dedicated module rather than growing either of the other two, because
## none of `tolerance`/`series`/`derating` is an electrical fact the way
## `t_ambient_max` is, and none is a schematic-rendering hint the way
## `layout.side` is.
##
## **Storage is a namespaced `attrs` key on the netlist that states it**
## (`bom.*`), the trade every sibling attrs-based module here makes:
## `graph.clone` copies `attrs` at every level, so a stated default survives
## `clone`/`instantiate`/`flatten`/`extractSubcircuit`/`isolate` for free, and
## a SPICE round trip is expected to lose it exactly as it loses `package.*`
## and `layout.*`. Namespaced rather than registered in
## `netlist/annotations.builtinAnnotations`, because a procurement default is
## not part of the shared *electrical* vocabulary `annotations.nim` exists to
## validate -- nothing about `bom.series` belongs beside `esr`/`package`.
##
## **The most specific statement wins, field by field.** `bomDefaults(nl)`
## reads each field from `nl` itself first, then from each parent in turn up
## to the root: a parent's `bom:` block fills only what a child left unstated.
## A library sheet that needs C0G load caps can say so in its own `bom:` block
## and keep saying so on any board that instances it, while a board's
## `bom: series = "e24"` still reaches every sheet that never stated a series.
## The fields resolve independently -- a child stating only `dielectric` still
## inherits the board's `series`.
##
## **There is no tree-wide override, deliberately.** A parent that wants a
## different default for one instanced sheet states it on *that instance*,
## through `instance ..., with = proc(sub: Netlist) = setBomDielectric(sub,
## "X7R")`: `instantiate` deep-clones, so the setter writes onto that
## instance's own clone -- replacing the template's stated value for this
## instance only, never for a sibling instance or the template itself. A
## blanket "force this on every child" would silently overrule a sheet
## whose author stated a default for a reason, with nothing at the call site
## saying which sheets it hit.
##
## **A default never overrides a part's own `spec:`.** These are what a
## part is bought under *when it states nothing*; a component's own
## `spec: tolerance = 1.pct` or `dielectric = "C0G"` is a requirement and
## always wins over every `bom:` default at every level. Changing one from a
## higher-level netlist means naming that component on that instance --
## `with = proc(sub: Netlist) = setAnnotation(findComponent(sub, "C1"),
## "tolerance", 1.pct)` -- never a default that happens to reach it.
## Enforced by `verax/bom`'s resolver, which reads the part's own annotation
## before consulting `bomDefaults` at all.

## Compile-time strictness comes from the DSL's `bom:` block
## (`netlist/dsl.handleBom`), not from this module -- the same split
## `layout:` makes: strict at the syntax boundary where an unknown key can
## only be a mistake, permissive in the open-ended `attrs` bag underneath,
## where a file reader or another tool may have written something this
## module does not yet parse. `bomDefaultKeys` is a `const seq` rather than
## inlined into the DSL, so a future key (a preferred package by family, a
## cost ceiling) has one place to be added on both sides -- the parser here
## and the dispatcher there, `layoutHintKeys`'s own reason for existing.

import std/[strutils, tables]

import ./types
import ./graph
import ./issue
import ../units

export issue

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
    ## Bare keys the DSL's `bom:` block accepts, spelled without the `bom.`
    ## prefix the block's own name already supplies -- `layoutHintKeys`'s
    ## shape.
  bomSeriesNames* = ["exact", "e12", "e24", "e96"]
    ## The only ladders `parts/series.nim` actually holds
    ## (`exactSeries`/`e12`/`e24`/`e96`). A closed set, unlike
    ## `layoutVariant`'s open-ended name, because this module can see the
    ## whole list -- `parts/` does not depend back on `netlist/`, so naming
    ## the four ladders here creates no edge the way naming a
    ## `pcb/variant.LayoutVariant` would.

type
  BomDefaults* = object
    tolerance*: Fraction          ## default part tolerance when a part states none
    dielectric*: string           ## default ceramic class for a cap that states none
    series*: string                ## "exact" | "e12" | "e24" | "e96"
    derating*: float               ## voltage derating factor
    resistorPackage*: string       ## default case size, per family
    capacitorPackage*: string
    inductorPackage*: string
    manufacturers*: seq[string]    ## preferred-manufacturer ranking, first wins

# --- parsing -------------------------------------------------------------
#
# One parse point per value, shared by `bomDefaults` and `validateBomDefaults`
# -- `layouthints.parseLayoutSide`'s discipline -- so an unrecognised value is
# reported once rather than divergently. Unlike `layouthints`' closed enums,
# `tolerance`/`derating` are open floats, so "unparseable" here means the same
# thing `annotations.parseAnnFloat` refuses: text that is not a plain decimal
# or scientific literal. Reachable only through a foreign writer (a file
# reader, or a raw `nl.attrs[...] =`) -- the DSL's `bom:` block only ever
# calls the typed setters below, which cannot produce unparseable text.

proc parseBomFloat(s: string): tuple[ok: bool, value: float] =
  try: (true, parseFloat(s.strip()))
  except ValueError: (false, 0.0)

# --- reading ---------------------------------------------------------------

proc statedBom(nl: Netlist, key: string): tuple[found: bool, text: string] =
  ## The nearest stated value of `key`: `nl` itself, then each parent up to
  ## the root. The one place the "most specific wins" rule lives.
  var n = nl
  while n != nil:
    if n.attrs.hasKey(key): return (true, n.attrs[key])
    n = n.parent
  (false, "")

proc bomDefaults*(nl: Netlist): BomDefaults =
  ## The procurement defaults that apply to parts in `nl`, each field taken
  ## from the nearest netlist that states it -- `nl` itself, then each parent
  ## up to the root (see the module comment). Absent or unparseable both read
  ## as the zero value for that field: pure and total, like every other
  ## accessor in this submodule's attrs-backed modules -- `validateBomDefaults`
  ## is the only place a bad *stated* value is reported. An unparseable value
  ## does not fall through to a parent's: it was stated, just stated wrongly,
  ## and the validator says so rather than this quietly substituting another.
  var (ok, t) = statedBom(nl, bomToleranceKey)
  if ok:
    let (parsed, v) = parseBomFloat(t)
    if parsed: result.tolerance = Fraction(v)
  (ok, t) = statedBom(nl, bomDielectricKey)
  if ok: result.dielectric = t
  (ok, t) = statedBom(nl, bomSeriesKey)
  if ok: result.series = t
  (ok, t) = statedBom(nl, bomDeratingKey)
  if ok:
    let (parsed, v) = parseBomFloat(t)
    if parsed: result.derating = v
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
# Every setter writes to exactly the `nl` it is given -- never the root. That
# is what makes a per-instance override work: inside an `instance ..., with =`
# proc the clone already has a parent, and writing through to the root there
# would turn "this instance buys X7R" into "the whole board does".

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
  ## `;`-delimited, the flat-list shape `switch.select_pins`/`spice.couples`
  ## already use for a homogeneous list that has to survive as one string in
  ## `attrs`. `openArray` rather than `seq` so both a literal `["TDK",
  ## "Murata"]` and a computed `seq[string]` work from the DSL without the
  ## caller writing `@[...]` by hand.
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
  ## What is wrong with what a `bom:` block actually *stated*, anywhere in the
  ## hierarchy under `nl`, as distinct from what it left unstated -- a board
  ## that says nothing about procurement is not reported here, the same
  ## restraint `validateEnvironment` shows a board that states no ambient
  ## range: nothing forces every design to adopt a BOM policy, and a design
  ## that never states one does not need one flagged.
  ##
  ## Every netlist in the tree is checked, not only the root, because a
  ## child's stated default is read (see `bomDefaults`) -- a typo in a
  ## library sheet's `bom:` block is as live as one on the board. Each
  ## message names the instance path that stated the value.
  validateBomDefaultsAt(nl, "")

proc validateBomDefaultsAt(nl: Netlist, path: string): seq[Issue] =
  ## `path` is the instance path (`XL.XA`), empty at the netlist
  ## `validateBomDefaults` was called on -- a child netlist carries its
  ## template's name, which two instances share, so the path is the only
  ## thing that says *which* sheet stated the value.
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
