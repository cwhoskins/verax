import std/[streams, strutils, tables, unittest]

import verax/netlist
import verax/netlist/layouthints
import verax/netlist/formats/spice

proc render(nl: Netlist): string =
  let outStream = newStringStream()
  writeNetlist(nl, outStream)
  result = outStream.data

proc board(): Netlist =
  ## `R1`, not `U1`: a `U`-prefixed designator reaches the SPICE writer as a
  ## hierarchical instance reference, which the round-trip test below does
  ## not want to exercise.
  result = newNetlist("t")
  let a = addNet(result, newNet("a"))
  let gnd = addNet(result, newNet("0", ntGround))
  let r1 = addComponent(result, newComponent("R1", kind = "resistor"))
  r1.attrs["value"] = "1k"
  discard connect(r1, "1", a, ptPassive)
  discard connect(r1, "2", gnd, ptPassive)

test "parseLayoutSide accepts exactly left/right/auto":
  check parseLayoutSide("left") == (true, sideLeft)
  check parseLayoutSide("right") == (true, sideRight)
  check parseLayoutSide("auto") == (true, sideAuto)
  check parseLayoutSide("LEFT") == (false, sideAuto)
  check parseLayoutSide("") == (false, sideAuto)

test "setLayoutSide/layoutSide round-trip, and sideAuto clears the key":
  let nl = board()
  let c = nl.components["R1"]
  check layoutSide(c) == sideAuto
  check not c.attrs.hasKey(layoutSideKey)

  setLayoutSide(c, sideLeft)
  check c.attrs[layoutSideKey] == "left"
  check layoutSide(c) == sideLeft

  setLayoutSide(c, sideRight)
  check c.attrs[layoutSideKey] == "right"
  check layoutSide(c) == sideRight

  setLayoutSide(c, sideAuto)
  check not c.attrs.hasKey(layoutSideKey)
  check layoutSide(c) == sideAuto

test "an unparseable stored value reads back as sideAuto, not an error":
  let nl = board()
  nl.components["R1"].attrs[layoutSideKey] = "lft"
  check layoutSide(nl.components["R1"]) == sideAuto

test "validateLayoutHints is silent on a clean netlist":
  let nl = board()
  setLayoutSide(nl.components["R1"], sideLeft)
  check validateLayoutHints(nl).len == 0

test "validateLayoutHints reports an unparseable value, naming the component":
  let nl = board()
  nl.components["R1"].attrs[layoutSideKey] = "lft"
  let issues = validateLayoutHints(nl)
  check issues.len == 1
  check issues[0].kind == KindLayoutHintUnparseable
  check issues[0].severity == sevWarning
  check issues[0].components == @[nl.components["R1"]]

test "validateLayoutHints recurses into children by default":
  let child = newNetlist("child")
  let a = addNet(child, newNet("a"))
  let u1 = addComponent(child, newComponent("U1", kind = "mcu"))
  discard connect(u1, "1", a, ptPassive)
  u1.attrs[layoutSideKey] = "bogus"
  let top = newNetlist("top")
  addChild(top, "X1", child)
  check validateLayoutHints(top).len == 1
  check validateLayoutHints(top, recursive = false).len == 0

test "layout.side survives clone":
  let nl = board()
  setLayoutSide(nl.components["R1"], sideLeft)
  var globals: OrderedTable[string, Net]
  let cloned = clone(nl, globals)
  check layoutSide(cloned.components["R1"]) == sideLeft

test "layout.side survives instantiate":
  let templ = newNetlist("B")
  let a = addNet(templ, newNet("a"))
  let gnd = addNet(templ, newNet("0", ntGround))
  let u1 = addComponent(templ, newComponent("U1", kind = "mcu"))
  discard connect(u1, "1", a, ptPassive)
  discard connect(u1, "2", gnd, ptGround)
  setLayoutSide(u1, sideRight)

  let top = newNetlist("top")
  var globals: OrderedTable[string, Net]
  discard instantiate(top, "X1", templ, @[], globals)
  check layoutSide(top.children["X1"].components["U1"]) == sideRight

test "a SPICE round trip loses layout.side, exactly like package metadata":
  let nl = board()
  setLayoutSide(nl.components["R1"], sideLeft)
  let text = render(nl)
  check "layout" notin text
  let back = readNetlist(newStringStream(text), "t")
  for _, c in back.components:
    check not c.attrs.hasKey(layoutSideKey)

test "parseLayoutMirror accepts exactly true/false/auto":
  check parseLayoutMirror("true") == (true, mirrorOn)
  check parseLayoutMirror("false") == (true, mirrorOff)
  check parseLayoutMirror("auto") == (true, mirrorAuto)
  check parseLayoutMirror("TRUE") == (false, mirrorAuto)
  check parseLayoutMirror("") == (false, mirrorAuto)

test "setLayoutMirror/layoutMirror round-trip, and mirrorAuto clears the key":
  let nl = board()
  let c = nl.components["R1"]
  check layoutMirror(c) == mirrorAuto
  check not c.attrs.hasKey(layoutMirrorKey)

  setLayoutMirror(c, mirrorOn)
  check c.attrs[layoutMirrorKey] == "true"
  check layoutMirror(c) == mirrorOn

  setLayoutMirror(c, mirrorOff)
  check c.attrs[layoutMirrorKey] == "false"
  check layoutMirror(c) == mirrorOff

  setLayoutMirror(c, mirrorAuto)
  check not c.attrs.hasKey(layoutMirrorKey)
  check layoutMirror(c) == mirrorAuto

test "an unparseable stored mirror value reads back as mirrorAuto, not an error":
  let nl = board()
  nl.components["R1"].attrs[layoutMirrorKey] = "yes"
  check layoutMirror(nl.components["R1"]) == mirrorAuto

test "validateLayoutHints reports an unparseable mirror value, naming the component":
  let nl = board()
  nl.components["R1"].attrs[layoutMirrorKey] = "yes"
  let issues = validateLayoutHints(nl)
  check issues.len == 1
  check issues[0].kind == KindLayoutHintUnparseable
  check issues[0].severity == sevWarning
  check issues[0].components == @[nl.components["R1"]]

test "layout.mirror survives clone":
  let nl = board()
  setLayoutMirror(nl.components["R1"], mirrorOn)
  var globals: OrderedTable[string, Net]
  let cloned = clone(nl, globals)
  check layoutMirror(cloned.components["R1"]) == mirrorOn

test "a SPICE round trip loses layout.mirror, exactly like layout.side":
  let nl = board()
  setLayoutMirror(nl.components["R1"], mirrorOn)
  let text = render(nl)
  check "layout" notin text
  let back = readNetlist(newStringStream(text), "t")
  for _, c in back.components:
    check not c.attrs.hasKey(layoutMirrorKey)

test "parseLayoutPower accepts exactly true/false/auto":
  check parseLayoutPower("true") == (true, powerOn)
  check parseLayoutPower("false") == (true, powerOff)
  check parseLayoutPower("auto") == (true, powerAuto)
  check parseLayoutPower("TRUE") == (false, powerAuto)
  check parseLayoutPower("") == (false, powerAuto)

test "setLayoutPower/layoutPower round-trip, and powerAuto clears the key":
  let nl = board()
  let c = nl.components["R1"]
  check layoutPower(c) == powerAuto
  check not c.attrs.hasKey(layoutPowerKey)

  setLayoutPower(c, powerOn)
  check c.attrs[layoutPowerKey] == "true"
  check layoutPower(c) == powerOn

  setLayoutPower(c, powerOff)
  check c.attrs[layoutPowerKey] == "false"
  check layoutPower(c) == powerOff

  setLayoutPower(c, powerAuto)
  check not c.attrs.hasKey(layoutPowerKey)
  check layoutPower(c) == powerAuto

test "an unparseable stored power value reads back as powerAuto, not an error":
  let nl = board()
  nl.components["R1"].attrs[layoutPowerKey] = "yes"
  check layoutPower(nl.components["R1"]) == powerAuto

test "validateLayoutHints reports an unparseable power value, naming the component":
  let nl = board()
  nl.components["R1"].attrs[layoutPowerKey] = "yes"
  let issues = validateLayoutHints(nl)
  check issues.len == 1
  check issues[0].kind == KindLayoutHintUnparseable
  check issues[0].severity == sevWarning
  check issues[0].components == @[nl.components["R1"]]

test "layout.power survives clone":
  let nl = board()
  setLayoutPower(nl.components["R1"], powerOn)
  var globals: OrderedTable[string, Net]
  let cloned = clone(nl, globals)
  check layoutPower(cloned.components["R1"]) == powerOn

test "a SPICE round trip loses layout.power, exactly like layout.side":
  let nl = board()
  setLayoutPower(nl.components["R1"], powerOn)
  let text = render(nl)
  check "layout" notin text
  let back = readNetlist(newStringStream(text), "t")
  for _, c in back.components:
    check not c.attrs.hasKey(layoutPowerKey)

test "\"variant\" joins side/mirror/power as a registered layout hint key":
  check "variant" in layoutHintKeys

test "parseLayoutVariant accepts any non-empty string and rejects only empty":
  check parseLayoutVariant("compact") == (true, "compact")
  check parseLayoutVariant("A-B_2") == (true, "A-B_2")
  check parseLayoutVariant("") == (false, "")

test "setLayoutVariant/layoutVariant round-trip, and \"\" clears the key":
  let nl = board()
  let c = nl.components["R1"]
  check layoutVariant(c) == ""
  check not c.attrs.hasKey(layoutVariantKey)

  setLayoutVariant(c, "compact")
  check c.attrs[layoutVariantKey] == "compact"
  check layoutVariant(c) == "compact"

  setLayoutVariant(c, "")
  check not c.attrs.hasKey(layoutVariantKey)
  check layoutVariant(c) == ""

test "an explicitly-stored empty variant reads back as \"\", not an error":
  let nl = board()
  nl.components["R1"].attrs[layoutVariantKey] = ""
  check layoutVariant(nl.components["R1"]) == ""

test "validateLayoutHints reports an explicitly-empty variant, naming the component":
  let nl = board()
  nl.components["R1"].attrs[layoutVariantKey] = ""
  let issues = validateLayoutHints(nl)
  check issues.len == 1
  check issues[0].kind == KindLayoutHintUnparseable
  check issues[0].severity == sevWarning
  check issues[0].components == @[nl.components["R1"]]

test "layout.variant survives clone":
  let nl = board()
  setLayoutVariant(nl.components["R1"], "compact")
  var globals: OrderedTable[string, Net]
  let cloned = clone(nl, globals)
  check layoutVariant(cloned.components["R1"]) == "compact"

test "a SPICE round trip loses layout.variant, exactly like layout.side":
  let nl = board()
  setLayoutVariant(nl.components["R1"], "compact")
  let text = render(nl)
  check "layout" notin text
  let back = readNetlist(newStringStream(text), "t")
  for _, c in back.components:
    check not c.attrs.hasKey(layoutVariantKey)
