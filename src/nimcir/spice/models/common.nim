## Helpers shared across the `spice/models` model files: pin ordering, the
## pin-name vocabularies the stand-ins match on, and the ground reference.

import std/[strutils, tables]
import ../../netlist/types
import ../../netlist/kinds

proc orderedPins*(c: Component): seq[Pin] =
  for _, p in c.pins: result.add p

proc groundOf*(nl: Netlist): Net =
  ## The node everything is referenced to: SPICE's `"0"` if it exists, else
  ## the first net that reads as ground by kind or by pin.
  if nl.nets.hasKey("0"): return nl.nets["0"]
  for _, n in nl.nets:
    if isGround(n): return n
  nil

const
  outNames* = ["out", "vout", "output", "o", "vo"]
  inNames* = ["in", "vin", "input", "i", "vi"]
  # Kept deliberately identical to `analysis/opamp`'s lists. `Pin.kind`
  # cannot make this distinction -- it separates input from output but not
  # `+` from `-`, and that difference is the entire content of "negative
  # feedback" -- so both modules match on names, and they must agree.
  opampPosNames* = ["+", "in+", "inp", "vin+", "ninv", "noninv"]
  opampNegNames* = ["-", "in-", "inn", "vin-", "inv"]
  opampOutNames* = ["out", "vout", "o", "output"]

proc pinNamed*(c: Component, names: openArray[string]): Pin =
  for p in orderedPins(c):
    if p.name.toLowerAscii in names: return p
  nil

proc signalPathPins*(c: Component): tuple[inp, outp: Pin] =
  ## The pins a signal-passing stand-in would wire together, by name. Exposed
  ## so a static check can follow the same path the model will build, rather
  ## than guessing at it from the other side of the module boundary.
  (pinNamed(c, inNames), pinNamed(c, outNames))
