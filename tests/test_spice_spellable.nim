## Every kind SPICE must be able to read.
##
## **A `kind` that `kinds.isPassive` accepts must be spellable by the deck
## writer -- `designatorPrefix` knows its letter, or a model pass rewrites
## it.**
##
## `spice/isolate` pulls every passive into the fragment, so one with no
## device letter lands under its own first letter, which ngspice reads as
## whatever that means (`FB1` a CCCS, `CCCS1` a 2 F capacitor).
##
## Generated rather than listed, so it can't drift from the tables.

import std/[strutils, streams, tables, unittest]

import verax/netlist/types
import verax/netlist/graph
import verax/netlist/kinds
import verax/netlist/formats/spice
import verax/spice/models

proc passiveKinds(): seq[string] =
  for k in conductiveKinds: result.add k
  for k in blockingKinds: result.add k
  for k in behaviouralKinds: result.add k
  for k in couplingKinds: result.add k

proc oneOf(kind: string): Netlist =
  ## A two-terminal part of `kind` between a signal net and ground.
  result = newNetlist("t")
  let a = addNet(result, newNet("a", ntSignal))
  let g = addNet(result, newNet("0", ntGround))
  let c = addComponent(result, newComponent(
    designatorPrefixFor(kind) & "1", kind = kind))
  discard connect(c, "1", a, ptPassive)
  discard connect(c, "2", g, ptPassive)
  c.attrs["value"] = "1"

suite "every passive kind survives to a deck as a device SPICE knows":

  test "each one either has a device letter or is expanded away":
    for kind in passiveKinds():
      var hasLetter = true
      try: discard designatorPrefix(kind)
      except CatchableError: hasLetter = false

      let nl = oneOf(kind)
      discard expandPinModels(nl)
      let survived = nl.components.len > 0 and
                     nl.components.hasKey(designatorPrefixFor(kind) & "1")

      check hasLetter or not survived
      if not (hasLetter or not survived):
        echo "  kind '", kind, "' has no SPICE device letter and was not ",
             "expanded: it reaches a deck as itself"

  test "and no deck line starts with a letter meaning a different device":
    # The concrete failure: a designator prefix that's a SPICE letter for
    # something else.
    for kind in passiveKinds():
      let nl = oneOf(kind)
      discard expandPinModels(nl)
      let s = newStringStream()
      writeNetlist(nl, s)
      # The first line is the title.
      let lines = s.data.splitLines
      for i in 1 ..< lines.len:
        let line = lines[i]
        if line.len == 0 or line[0] == '.' or line[0] == '*': continue
        if not line[0].isUpperAscii and not line[0].isLowerAscii: continue
        # The line's device letter must agree with its source component.
        var matched = false
        for _, c in nl.components:
          if deckDesignator(c) == line.split(' ')[0]: matched = true
        check matched
        if not matched:
          echo "  kind '", kind, "' produced an unattributable line: ", line

  test "the kinds that needed a model got one, not a letter":
    # These are expanded rather than lettered: a bead isn't an inductor and a
    # fuse's `value` is amps.
    for kind in ["ferrite_bead", "wire", "jumper", "fuse"]:
      let nl = oneOf(kind)
      discard expandPinModels(nl)
      check not nl.components.hasKey(designatorPrefixFor(kind) & "1")
      check nl.components.len > 0

  test "a switch stood up as an S element is spellable and self-attributing":
    # `vswitch`/`iswitch` are emitted by `spice/models/switch` and reach
    # passivity via `hasDeviceModel`; check the deck line directly.
    let nl = newNetlist("t")
    let a = addNet(nl, newNet("a", ntSignal))
    let b = addNet(nl, newNet("b", ntSignal))
    let e = addNet(nl, newNet("en", ntSignal))
    discard addNet(nl, newNet("0", ntGround))
    let sw = addComponent(nl, newComponent("SW1", kind = "switch"))
    discard connect(sw, "IN", a, ptPassive)
    discard connect(sw, "OUT", b, ptPassive)
    discard connect(sw, "CTRL", e, ptInput)
    discard expandPinModels(nl)
    check nl.components.hasKey("SSW1")
    check nl.components["SSW1"].kind == "vswitch"
    check isPassive(nl.components["SSW1"])
    let s = newStringStream()
    writeNetlist(nl, s)
    for line in s.data.splitLines:
      if line.startsWith("S"):
        check deckDesignator(nl.components["SSW1"]) == line.split(' ')[0]

  test "a fuse's value is amps and a link's is ohms":
    # A 2 A fuse read as 2 ohms would put a large false drop on a rail.
    let f = oneOf("fuse")
    f.components["F1"].attrs["value"] = "2"
    discard expandResistiveParts(f)
    var r: float
    check parseSpiceMagnitude(f.components["RF1_R"].attrs["value"], r)
    check r < 1.0                      # its dcr, not 2 ohms

    let j = oneOf("jumper")
    j.components["JP1"].attrs["value"] = "0.05"
    discard expandResistiveParts(j)
    check parseSpiceMagnitude(j.components["RJP1_R"].attrs["value"], r)
    check abs(r - 0.05) < 1e-9         # ohms, as a link is sold
