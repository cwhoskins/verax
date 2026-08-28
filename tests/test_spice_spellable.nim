## Every kind SPICE must be able to read.
##
## The invariant this file exists to hold is narrow and was violated three
## times before anyone wrote it down:
##
##   **A `kind` that `kinds.isPassive` accepts must be something the deck
##   writer can spell -- either because `designatorPrefix` knows its device
##   letter, or because a model pass rewrites it into parts that do.**
##
## Passivity is what makes it load-bearing. `models.expandPinModels` stands in
## for every part `isPassive` *rejects*, so those never reach a deck as
## themselves; and `spice/isolate` absorbs every part `isPassive` *accepts*
## into the fragment, so those do. A kind on the accepted side with no device
## letter therefore lands in the deck under its own first letter, and ngspice
## reads that letter as whatever it means -- `FB1` as a current-controlled
## current source, `CCCS1` as a 2 F capacitor. Silently, in both cases.
##
## This is a *generated* test rather than a list, for the same reason
## `verify.describeQuantities` computes reachability rather than reciting it:
## a hand-kept list is exactly the thing that drifts from the tables it is
## meant to describe. Add a kind to `conductiveKinds` with no model and no
## letter and this file fails.

import std/[strutils, streams, tables, unittest]

import nimcir/netlist/types
import nimcir/netlist/graph
import nimcir/netlist/kinds
import nimcir/netlist/formats/spice
import nimcir/spice/models

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
    # The concrete failure, rather than the property: a component whose
    # designator prefix is a SPICE device letter for something else.
    for kind in passiveKinds():
      let nl = oneOf(kind)
      discard expandPinModels(nl)
      let s = newStringStream()
      writeNetlist(nl, s)
      # The first line is the deck title, not a device.
      let lines = s.data.splitLines
      for i in 1 ..< lines.len:
        let line = lines[i]
        if line.len == 0 or line[0] == '.' or line[0] == '*': continue
        if not line[0].isUpperAscii and not line[0].isLowerAscii: continue
        # Whatever the line claims to be, the component it came from must
        # agree -- which is exactly what `deckDesignator` guarantees when the
        # kind is known and cannot when it is not.
        var matched = false
        for _, c in nl.components:
          if deckDesignator(c) == line.split(' ')[0]: matched = true
        check matched
        if not matched:
          echo "  kind '", kind, "' produced an unattributable line: ", line

  test "the kinds that needed a model got one, not a letter":
    # `ferrite_bead` and the links are expanded rather than lettered, and the
    # distinction matters: a bead is not an inductor and a fuse's `value` is
    # amps, so giving either a device letter would have been the wrong fix.
    for kind in ["ferrite_bead", "wire", "jumper", "fuse"]:
      let nl = oneOf(kind)
      discard expandPinModels(nl)
      check not nl.components.hasKey(designatorPrefixFor(kind) & "1")
      check nl.components.len > 0

  test "a switch stood up as an S element is spellable and self-attributing":
    # `vswitch`/`iswitch` are never authored -- `spice/models/switch` emits
    # them -- and they reach passivity through `hasDeviceModel`, not through
    # any of the three kind lists above. Check the deck line directly.
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
    # Reading a 2 A fuse's value as 2 ohms would put forty times its real cold
    # resistance in series with a rail and quietly explain away a drop.
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
