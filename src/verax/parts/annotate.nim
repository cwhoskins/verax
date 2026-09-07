## Writing a `Choice` onto a component.
##
## Every field of a `Choice` becomes a **registered** annotation -- `package`,
## `dielectric`, `voltage_rating`, `isat` and the rest are all in the bare
## vocabulary, which is the point: a policy's output is not private to the
## policy, it is the same thing a designer would have typed in a `spec:`
## block, and everything downstream reads it the same way either way.
##
## What a policy decides is therefore *visible* in the netlist, in `verax
## annotations`' vocabulary, and in the deck. A mechanism whose output could
## only be understood by re-reading the mechanism would be worse than typing
## the values out.
##
## Nothing is written for a zero field. A `Choice` that says nothing about a
## rating leaves the component saying nothing about it, rather than claiming
## zero -- the same reason the annotation accessors are pure and never
## default.

import ../netlist/types
import ../netlist/annotations
import ../units
import ./types

proc applyChoice*(c: Component, ch: Choice, source = annDerived) =
  ## Annotates `c` from `ch`, recording provenance.
  ##
  ## `annDerived` by default, and that is the honest source: a policy computed
  ## these from a request, nobody measured them and nobody looked them up in a
  ## datasheet. A policy backed by a real preferred-parts list should pass
  ## `annImported` instead, and one transcribing a datasheet `annAuthored`.
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

proc choiceNotes*(designator: string, ch: Choice): seq[Assumption] =
  ## A policy's `notes` as `Assumption`s, so they surface where every other
  ## invented number does rather than being swallowed by the builder.
  for n in ch.notes:
    result.add note(designator, n)
