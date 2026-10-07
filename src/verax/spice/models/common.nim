## Shared helpers for `spice/models`: pin ordering, pin-name vocabularies,
## the ground reference.

import std/[strutils, tables]
import ../../netlist/types
import ../../netlist/kinds

proc orderedPins*(c: Component): seq[Pin] =
  for _, p in c.pins: result.add p

proc groundOf*(nl: Netlist): Net =
  ## The reference node: `"0"` if present, else the first ground-like net.
  if nl.nets.hasKey("0"): return nl.nets["0"]
  for _, n in nl.nets:
    if isGround(n): return n
  nil

const
  outNames* = ["out", "vout", "output", "o", "vo"]
  inNames* = ["in", "vin", "input", "i", "vi"]
  # Must match `analysis/opamp`'s lists: `Pin.kind` can't tell `+` from `-`,
  # so both match on names.
  opampPosNames* = ["+", "in+", "inp", "vin+", "ninv", "noninv"]
  opampNegNames* = ["-", "in-", "inn", "vin-", "inv"]
  opampOutNames* = ["out", "vout", "o", "output"]

  # Winding terminals, dotted end first (a choke's two lines use the same
  # names).
  priDotNames* = ["p1", "pri+", "pri1", "p+", "1a", "a"]
  priRetNames* = ["p2", "pri-", "pri2", "p-", "1b"]
  secDotNames* = ["s1", "sec+", "sec1", "s+", "2a", "b"]
  secRetNames* = ["s2", "sec-", "sec2", "s-", "2b"]

  # Control terminals of a two-terminal switch, and the throw it makes.
  switchCtrlNames* = ["ctrl", "ctrl+", "en", "c", "g", "gate", "sel"]
  switchCtrlRetNames* = ["ctrl-", "c-", "en-"]
  switchThrowInNames* = ["1", "in", "a", "com", "rfc", "d"]
  switchThrowOutNames* = ["2", "out", "b", "no", "rf"]

proc pinNamed*(c: Component, names: openArray[string]): Pin =
  for p in orderedPins(c):
    if p.name.toLowerAscii in names: return p
  nil

proc signalPathPins*(c: Component): tuple[inp, outp: Pin] =
  ## The pins a signal-passing stand-in would wire together, by name. Exposed
  ## so a static check can follow the same path the model will build, rather
  ## than guessing at it from the other side of the module boundary.
  (pinNamed(c, inNames), pinNamed(c, outNames))
