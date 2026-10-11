## `Stated[T]`: a value plus whether, and how, somebody said it.
##
## The one idiom for **"not stated"** at a boundary. `NaN` keeps exactly one
## meaning -- *measured, and the feature was not there* (no anti-resonance,
## no dropout) -- and zero is never "unknown" where zero is physical (an
## insulator's conductivity, a 0 ohm ESR). Plain presence with no provenance
## to carry is `std/options.Option`; `Stated` is for a value whose origin a
## report has to show.
##
## Below everything (beside `units`), so any submodule can use it. The
## netlist's annotation reads (`AnnValue[T]`) are this type under their old
## name; the enum keeps its `ann*` spelling because annotations are where it
## started and every consumer already reads it.

type
  AnnSource* = enum
    annAbsent     ## not present
    annAuthored   ## stated by the designer
    annImported   ## read from a design file
    annDefaulted  ## invented from a defaults table by a consumer
    annDerived    ## inferred from the graph

  Stated*[T] = object
    source*: AnnSource
    value*: T
      ## Meaningless when `source == annAbsent`; read through `has`/`get`.

proc stated*[T](value: T, source = annAuthored): Stated[T] {.inline.} =
  ## A present value. `source` must not be `annAbsent`; use `absent`.
  assert source != annAbsent, "a stated value cannot be absent"
  Stated[T](source: source, value: value)

proc absent*[T](_: typedesc[T]): Stated[T] {.inline.} =
  ## Nothing was said (`absent(Volts)`).
  Stated[T](source: annAbsent)

proc has*[T](v: Stated[T]): bool {.inline.} =
  v.source != annAbsent

proc get*[T](v: Stated[T]): T =
  ## The value; raises when absent, so a missing value can't read as zero.
  if v.source == annAbsent:
    raise newException(ValueError, "value was not stated")
  v.value

proc get*[T](v: Stated[T], fallback: T): T {.inline.} =
  ## The value, or `fallback` when absent. A fallback is a policy, so a
  ## caller that uses one should also record it (an `Assumption`).
  if v.source == annAbsent: fallback else: v.value

proc `$`*[T](v: Stated[T]): string =
  if v.source == annAbsent: "(unstated)"
  else: $v.value & " (" & $v.source & ")"
