## Coupled inductors: a `transformer` / `common_mode_choke` becomes two
## windings and a SPICE `K` card, and the barrier is a barrier.

import std/[os, osproc, streams, strutils, tables, unittest]

import verax/netlist
import verax/netlist/formats/spice
import verax/netlist/annotations
import verax/spice/models
import verax/spice/isolate

proc xfmr(attrs: openArray[(string, string)]): Netlist =
  result = newNetlist("t")
  let a = addNet(result, newNet("pa", ntSignal))
  let b = addNet(result, newNet("pb", ntSignal))
  let x = addNet(result, newNet("sa", ntSignal))
  let y = addNet(result, newNet("sb", ntSignal))
  discard addNet(result, newNet("0", ntGround))
  let c = addComponent(result, newComponent("T1", kind = "transformer"))
  discard connect(c, "P1", a, ptPassive)
  discard connect(c, "P2", b, ptPassive)
  discard connect(c, "S1", x, ptPassive)
  discard connect(c, "S2", y, ptPassive)
  for (k, v) in attrs: c.attrs[k] = v

test "a transformer becomes two windings coupled by a K card":
  let nl = xfmr([("lpri", "0.001"), ("lsec", "0.001"), ("k_coupling", "0.995"),
                 ("dcr", "0.1")])
  let notes = expandCoupledInductors(nl)
  check not nl.components.hasKey("T1")
  check nl.components["LT1_PRI"].kind == "inductor"
  check nl.components["LT1_SEC"].kind == "inductor"
  check nl.components["KT1"].kind == "mutual_inductance"
  check nl.components["KT1"].attrs["spice.couples"] == "LT1_PRI,LT1_SEC"
  check nl.components["KT1"].pins.len == 0
  # k stated -> no assumption for it
  for n in notes:
    check n.key != "k_coupling"

test "the K line names the two inductors by their deck spelling":
  let nl = xfmr([("lpri", "1e-3"), ("turns", "0.5"), ("dcr", "0.2")])
  discard expandCoupledInductors(nl)
  let s = newStringStream()
  writeNetlist(nl, s)
  var kline = ""
  for ln in s.data.splitLines:
    if ln.startsWith("KT1 "): kline = ln
  check kline.len > 0
  let toks = kline.split(' ')
  check toks[1] == "LT1_PRI"
  check toks[2] == "LT1_SEC"
  check parseFloat(toks[3]) > 0.9

test "secondary inductance comes from turns when lsec is absent":
  let nl = xfmr([("lpri", "1e-3"), ("turns", "0.5")])
  discard expandCoupledInductors(nl)
  var lp, ls: float
  check parseSpiceMagnitude(nl.components["LT1_PRI"].attrs["value"], lp)
  check parseSpiceMagnitude(nl.components["LT1_SEC"].attrs["value"], ls)
  check abs(ls - lp * 0.25) / (lp * 0.25) < 1e-6   # Ls = Lp * turns^2

test "no inductance stated -> left alone with a note":
  let nl = xfmr([("k_coupling", "0.99")])
  let notes = expandCoupledInductors(nl)
  check nl.components.hasKey("T1")
  check notes.len == 1
  check "unmodelled" in notes[0].detail

test "isolation pulls in a K whose windings are both selected":
  # rail -- Lpri/Rpri -- railmid ; sensed -- Lsec/Rsec -- sensedmid, coupled.
  let nl = newNetlist("cmc")
  let g = addNet(nl, newNet("0", ntGround))
  let ra = addNet(nl, newNet("a", ntSignal))
  let rb = addNet(nl, newNet("b", ntSignal))
  let sc = addNet(nl, newNet("c", ntSignal))
  let sd = addNet(nl, newNet("d", ntSignal))
  let t = addComponent(nl, newComponent("T1", kind = "common_mode_choke"))
  discard connect(t, "P1", ra, ptPassive)
  discard connect(t, "P2", rb, ptPassive)
  discard connect(t, "S1", sc, ptPassive)
  discard connect(t, "S2", sd, ptPassive)
  t.attrs["lpri"] = "1e-4"
  # loads so every winding node touches a second component
  for (nm, n) in {"RA": ra, "RB": rb, "RC": sc, "RD": sd}:
    let r = addComponent(nl, newComponent(nm, kind = "resistor"))
    discard connect(r, "1", n, ptPassive)
    discard connect(r, "2", g, ptPassive)
    r.attrs["value"] = "50"
  discard expandCoupledInductors(nl)
  check nl.components.hasKey("KT1")

  var globals: OrderedTable[string, Net]
  var spec = defaultIsolationSpec("frag")
  spec.requireKnownRails = false
  let iso = isolate(nl, ["RA", "RB", "RC", "RD"], spec, globals)
  check iso.netlist.components.hasKey("KT1")
  check iso.netlist.components.hasKey("LT1_PRI")
  check iso.netlist.components.hasKey("LT1_SEC")

  # ...and left behind when only one winding is in the fragment.
  var g2: OrderedTable[string, Net]
  var spec2 = defaultIsolationSpec("frag2")
  spec2.requireKnownRails = false
  spec2.maxHops = 1
  let iso2 = isolate(nl, ["RA"], spec2, g2)
  check iso2.netlist.components.hasKey("LT1_PRI")
  check not iso2.netlist.components.hasKey("LT1_SEC")
  check not iso2.netlist.components.hasKey("KT1")

test "and no DC path across the barrier":
  when defined(windows): skip()
  else:
    if findExe("ngspice").len == 0:
      skip()
    else:
      let nl = xfmr([("lpri", "1e-3"), ("lsec", "1e-3"), ("dcr", "0.5")])
      # drive the primary, load the secondary; a transformer passes no DC.
      let vp = addComponent(nl, newComponent("VP", kind = "voltage_source"))
      discard connect(vp, "+", nl.nets["pa"], ptPassive)
      discard connect(vp, "-", nl.nets["0"], ptPassive)
      vp.attrs["value"] = "DC 5"
      let rb = addComponent(nl, newComponent("RB", kind = "resistor"))
      discard connect(rb, "1", nl.nets["pb"], ptPassive)
      discard connect(rb, "2", nl.nets["0"], ptPassive)
      rb.attrs["value"] = "1"
      let rl = addComponent(nl, newComponent("RL", kind = "resistor"))
      discard connect(rl, "1", nl.nets["sa"], ptPassive)
      discard connect(rl, "2", nl.nets["sb"], ptPassive)
      rl.attrs["value"] = "1k"
      let rlg = addComponent(nl, newComponent("RLG", kind = "resistor"))
      discard connect(rlg, "1", nl.nets["sb"], ptPassive)
      discard connect(rlg, "2", nl.nets["0"], ptPassive)
      rlg.attrs["value"] = "1meg"
      discard expandCoupledInductors(nl)

      let dir = getTempDir() / "verax_mag_test"
      createDir(dir)
      let deck = dir / "t.cir"
      let s = newFileStream(deck, fmWrite)
      writeNetlist(nl, s, @[".op", ".control", "set filetype=ascii",
                            "run", "print v(sa)", "quit", ".endc"])
      s.close()
      let (outp, _) = execCmdEx("ngspice -b " & deck)
      # secondary sits at ~0 V: no DC path from the 5 V primary.
      var seen = false
      for ln in outp.splitLines:
        if "v(sa)" in ln.toLowerAscii:
          seen = true
          let f = ln.splitWhitespace
          check abs(parseFloat(f[^1])) < 1e-3
      check seen
