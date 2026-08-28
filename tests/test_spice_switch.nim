## Switches: a two-terminal `switch` becomes an `S` element + `.MODEL SW`
## card, and an `rf_switch` becomes a decoded absorptive bank.

import std/[os, osproc, streams, strutils, tables, unittest]

import nimcir/netlist
import nimcir/netlist/formats/spice
import nimcir/netlist/annotations
import nimcir/spice/models

test "a two-terminal switch becomes an S element and a SW model":
  let nl = newNetlist("t")
  let a = addNet(nl, newNet("a", ntSignal))
  let b = addNet(nl, newNet("b", ntSignal))
  let e = addNet(nl, newNet("en", ntSignal))
  discard addNet(nl, newNet("0", ntGround))
  let sw = addComponent(nl, newComponent("SW1", kind = "switch"))
  discard connect(sw, "IN", a, ptPassive)
  discard connect(sw, "OUT", b, ptPassive)
  discard connect(sw, "CTRL", e, ptInput)
  sw.attrs["ron"] = "4"
  sw.attrs["roff"] = "1e9"
  let notes = expandSwitches(nl)
  check not nl.components.hasKey("SW1")
  check nl.components["SSW1"].kind == "vswitch"
  check nl.components["SSW1"].attrs["value"] in nl.models
  check "SW(Ron=" in nl.models[nl.components["SSW1"].attrs["value"]]
  # ron/roff stated -> no assumptions for them; vt is still defaulted
  var keys: seq[string]
  for n in notes: keys.add n.key
  check "ron" notin keys
  check "vt" in keys

test "the S line is positional: n+ n- nc+ nc- MODEL":
  let nl = newNetlist("t")
  let a = addNet(nl, newNet("a", ntSignal))
  let b = addNet(nl, newNet("b", ntSignal))
  let e = addNet(nl, newNet("en", ntSignal))
  discard addNet(nl, newNet("0", ntGround))
  let sw = addComponent(nl, newComponent("SW1", kind = "switch"))
  discard connect(sw, "IN", a, ptPassive)
  discard connect(sw, "OUT", b, ptPassive)
  discard connect(sw, "CTRL", e, ptInput)
  discard expandSwitches(nl)
  let s = newStringStream()
  writeNetlist(nl, s)
  var line = ""
  for ln in s.data.splitLines:
    if ln.startsWith("SSW1 "): line = ln
  let t = line.split(' ')
  check t[1] == "a"
  check t[2] == "b"
  check t[3] == "en"
  check t[4] == "0"
  check t[5] in nl.models

proc adg904(nl: Netlist, desig: string, rfc: Net, m: array[4, Net],
            a0, a1, en, vdd, g: Net) =
  let u = addComponent(nl, newComponent(desig, kind = "rf_switch"))
  discard connect(u, "RFC", rfc, ptPassive)
  for i in 0 ..< 4:
    discard connect(u, "RF" & $(i + 1), m[i], ptPassive)
  discard connect(u, "A0", a0, ptInput)
  discard connect(u, "A1", a1, ptInput)
  discard connect(u, "EN", en, ptInput)
  discard connect(u, "VDD", vdd, ptPower)
  discard connect(u, "GND", g, ptGround)
  u.attrs["ron"] = "4"
  u.attrs["switch.select_pins"] = "A1,A0"
  u.attrs["switch.off_termination"] = "50"

test "an rf_switch decodes its throws and terminates the rest":
  if findExe("ngspice").len == 0:
    skip()
  else:
    let nl = newNetlist("mux")
    let g = addNet(nl, newNet("0", ntGround))
    let rfc = addNet(nl, newNet("rfc", ntSignal))
    var m: array[4, Net]
    for i in 0 ..< 4: m[i] = addNet(nl, newNet("m" & $(i + 1), ntSignal))
    let a0 = addNet(nl, newNet("a0", ntSignal))
    let a1 = addNet(nl, newNet("a1", ntSignal))
    let en = addNet(nl, newNet("en", ntSignal))
    let vdd = addNet(nl, newNet("vdd", ntPower))
    vdd.attrs["voltage"] = "3.3"
    rfc.attrs["voltage"] = "3.3"      # gives the decoder a logic rail

    adg904(nl, "U1", rfc, m, a0, a1, en, vdd, g)

    # drive: 1 V on RFC, EN high, A1A0 = 10 -> throw 3 (m3) live
    for (nm, net, v) in [("VC", rfc, "1"), ("VEN", en, "3.3"),
                         ("VA0", a0, "0"), ("VA1", a1, "3.3"),
                         ("VDD", vdd, "3.3")]:
      let vs = addComponent(nl, newComponent(nm, kind = "voltage_source"))
      discard connect(vs, "+", net, ptPassive)
      discard connect(vs, "-", g, ptPassive)
      vs.attrs["value"] = "DC " & v
    # 50 ohm to ground on every midplane rail (the far-end loads)
    for i in 0 ..< 4:
      let r = addComponent(nl, newComponent("RL" & $i, kind = "resistor"))
      discard connect(r, "1", m[i], ptPassive)
      discard connect(r, "2", g, ptPassive)
      r.attrs["value"] = "50"

    discard expandPinModels(nl)
    check not nl.components.hasKey("U1")

    let dir = getTempDir() / "nimcir_sw_test"
    createDir(dir)
    let deck = dir / "m.cir"
    let s = newFileStream(deck, fmWrite)
    writeNetlist(nl, s, @[".op", ".control", "set filetype=ascii", "run",
                          "print v(m1) v(m2) v(m3) v(m4)", "quit", ".endc"])
    s.close()
    let (outp, _) = execCmdEx("ngspice -b " & deck)
    var vals: array[4, float]
    for ln in outp.splitLines:
      let low = ln.toLowerAscii
      for i in 0 ..< 4:
        if ("v(m" & $(i + 1) & ")") in low:
          vals[i] = parseFloat(ln.splitWhitespace[^1])
    # throw 3 (m3) carries the signal; the rest sit near ground in 50 ohm.
    check vals[2] > 0.3
    check vals[0] < 0.05
    check vals[1] < 0.05
    check vals[3] < 0.05
