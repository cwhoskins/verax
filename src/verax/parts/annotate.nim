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
  if float(ch.voltageRating) > 0.0:
    setAnnotation(c, "voltage_rating", ch.voltageRating, source)
  if float(ch.currentRating) > 0.0:
    setAnnotation(c, "current_rating", ch.currentRating, source)
  if float(ch.isat) > 0.0: setAnnotation(c, "isat", ch.isat, source)
  if float(ch.powerRating) > 0.0:
    setAnnotation(c, "power_rating", ch.powerRating, source)
  if float(ch.tolerance) > 0.0: setAnnotation(c, "tolerance", ch.tolerance, source)
  if float(ch.esr) > 0.0: setAnnotation(c, "esr", ch.esr, source)
  if float(ch.esl) > 0.0: setAnnotation(c, "esl", ch.esl, source)
  if ch.use.len > 0: setAnnotation(c, "part_use", ch.use, source)

proc choiceNotes*(designator: string, ch: Choice): seq[Assumption] =
  ## A policy's `notes` as `Assumption`s.
  for n in ch.notes:
    result.add note(designator, n)
