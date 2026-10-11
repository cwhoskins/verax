## Writing a `Choice` onto a component. Every field becomes a **registered**
## annotation -- the same thing a designer would type in `spec:` -- so a
## policy's decisions are visible in the netlist and deck. Zero fields are
## not written (no claiming zero).

import ../netlist/types
import ../netlist/annotations
import ../units
import ./types

proc applyChoice*(c: Component, ch: Choice, source = annDerived) =
  ## Annotates `c` from `ch`. `annDerived` by default (computed, not
  ## measured); pass `annImported` for a parts-list policy, `annAuthored`
  ## for a datasheet transcription.
  if c == nil: return
  if ch.package.len > 0: setAnnotation(c, "package", ch.package, source)
  if ch.dielectric.len > 0: setAnnotation(c, "dielectric", ch.dielectric, source)
  if ch.partNumber.len > 0 and c.partNumber.len == 0: c.partNumber = ch.partNumber
  if ch.voltageRating.isSome:
    setAnnotation(c, "voltage_rating", ch.voltageRating.get, source)
  if ch.currentRating.isSome:
    setAnnotation(c, "current_rating", ch.currentRating.get, source)
  if ch.isat.isSome: setAnnotation(c, "isat", ch.isat.get, source)
  if ch.powerRating.isSome:
    setAnnotation(c, "power_rating", ch.powerRating.get, source)
  if ch.tolerance.isSome: setAnnotation(c, "tolerance", ch.tolerance.get, source)
  if ch.esr.isSome: setAnnotation(c, "esr", ch.esr.get, source)
  if ch.esl.isSome: setAnnotation(c, "esl", ch.esl.get, source)
  if ch.use.len > 0: setAnnotation(c, "part_use", ch.use, source)

proc choiceNotes*(designator: string, ch: Choice): seq[Assumption] =
  ## A policy's `notes` as `Assumption`s.
  for n in ch.notes:
    result.add note(designator, n)
