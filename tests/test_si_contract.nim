## Stage 6 of docs/ibis_simulator_plan.md: SI as part of `verax check`. The
## `capSiTran` capability, the `si_net` role, the `si.net` evaluator on a
## board reaching it through `EvalContext.scratch`, and the readiness
## report telling a missing board, unsupported input and a failed claim
## apart.

import std/[os, strutils, tables, unittest, math]

import verax/netlist
import verax/contract
import verax/verify
import verax/pcb/types as pcbtypes
import verax/pcb/formats/kicad

const demo = currentSourcePath().parentDir.parentDir / "designs" / "si_spi"

proc pinS(name: string): Subject = Subject(kind: skPin, name: name)
proc netS(name: string): Subject = Subject(kind: skNet, name: name)

proc spiDesign(u3Component = "DEMO_FLASH_SO8B",
               params: seq[(string, string)] = @[("max_flight_time", "1.5e-9")]): Design =
  let nl = newNetlist("si_spi_test")
  let gnd = addNet(nl, newNet("GND", ntGround))
  let vcc = addNet(nl, newNet("VCC", ntPower))
  let sck = addNet(nl, newNet("SCK", ntSignal))
  let mosi = addNet(nl, newNet("MOSI", ntSignal))
  for (des, file, comp, pins) in [
      ("U1", "demo_mcu.ibs", "", @["1", "2"]),
      ("U2", "demo_flash.ibs", "DEMO_FLASH", @["1", "2"]),
      ("U3", "demo_flash.ibs", u3Component, @["2"])]:
    let c = addComponent(nl, newComponent(des, kind = "ic"))
    for p in pins: discard connect(c, p, (if p == "1": sck else: mosi))
    discard connect(c, "3", vcc, ptPower)
    discard connect(c, "4", gnd, ptGround)
    c.attrs["ibis_file"] = demo / file
    if comp.len > 0: c.attrs["ibis_component"] = comp
  result = newDesign(nl)
  discard result.addRole("si_net", "sck_si",
    [("net", netS("SCK")), ("driver", pinS("U1.1")), ("rx", pinS("U2.1"))], params)
  discard result.addRole("si_net", "mosi_si",
    [("net", netS("MOSI")), ("driver", pinS("U1.2")), ("rx", pinS("U2.2")),
     ("rx2", pinS("U3.2"))], params)

proc board(): Pcb = readPcb(demo / "si_spi.kicad_pcb")

suite "capability":
  test "capSiTran: label, --caps spelling, sets, availability":
    check capLabel(capSiTran) == "si"
    check parseCapabilities("si") == {capStatic, capSiTran}
    check capSiTran in parseCapabilities("all")
    check capSiTran notin parseCapabilities("sim")
    check capSiTran in allCapabilities
    check capSiTran in offlineCapabilities       # open decision 4: included
    check capSiTran notin simCapabilities
    check capSiTran in availableCapabilities("")  # native: always present
    expect ValueError:
      discard parseCapabilities("sii")

suite "role":
  test "si_net claims: margins always, the rest only when stated":
    let d0 = spiDesign(params = @[])
    var n = 0
    for _, inst in d0.roles: n += expandInstance(inst).len
    check n == 6                                  # 3 receivers x 2
    let d = spiDesign(params = @[("max_flight_time", "1.5e-9"), ("ui", "2e-8"),
                                 ("max_overshoot", "0.5")])
    var qs: seq[string]
    for a in expandInstance(d.roles["sck_si"]): qs.add a.quantity
    check qs == @["si_threshold_margin_v", "si_ringback_margin_v", "si_flight_time",
                  "si_overshoot_v", "si_settle_time"]

  test "a receiver that is the driver is refused at attach time":
    let d = spiDesign(params = @[])
    expect NetlistError:
      discard d.addRole("si_net", "bad", [("net", netS("SCK")), ("driver", pinS("U1.1")),
                                          ("rx", pinS("U1.1"))])

suite "evaluator":
  test "with the board: measured and passing, worst corner named":
    let r = readiness(spiDesign(), allCapabilities, board())
    check count(r.results, esPass) == 9
    check count(r.results, esNotEvaluable) == 0
    check r.checks.len == 2                       # one run per net
    for c in r.checks:
      check c.evaluator == "si.net"
      check capSiTran in c.needs

  test "without a board: not evaluable, pointing at --board and constraints":
    let r = readiness(spiDesign(), allCapabilities)
    check count(r.results, esNotEvaluable) == 9
    for res in r.results:
      check "--board" in res.reason
      check "verax constraints" in res.reason

  test "a tight budget is a failure, not an unchecked claim":
    let r = readiness(spiDesign(params = @[("max_flight_time", "1e-10")]), allCapabilities, board())
    check count(r.results, esFail) == 3
    check count(r.results, esPass) == 6

  test "unsupported input is not evaluable and names the problem":
    # U3 bound to a [Component] its file does not have. (Binding it to
    # `DEMO_FLASH`, whose pin 1 U3 lacks, is fine: a part may declare
    # fewer pins than its file describes.)
    let r = readiness(spiDesign(u3Component = "NO_SUCH_PART"), allCapabilities, board())
    var mosi = 0
    for res in r.results:
      if res.assertion.origin == "mosi_si":
        check res.status == esNotEvaluable
        check "NO_SUCH_PART" in res.reason
        inc mosi
      else:
        check res.status == esPass
    check mosi == 6

  test "offline still checks SI (no ngspice needed)":
    let r = readiness(spiDesign(), offlineCapabilities, board())
    check count(r.results, esPass) == 9

suite "--board and verax constraints":
  test "parseVerifyArgs reads the SI flags":
    let o = parseVerifyArgs(["--board=x.kicad_pcb", "--si-constraints", "--net=SCK",
                             "--dru=r.kicad_dru", "--stackup-layers=6", "--si-format=json"])
    check o.board.endsWith("x.kicad_pcb")
    check o.siConstraints
    check o.siNet == "SCK"
    check o.siDru.endsWith("r.kicad_dru")
    check o.stackupLayers == 6
    check o.siJson

  test "the role's claims are the constraint criteria":
    let d = spiDesign(params = @[("max_flight_time", "1.5e-9"), ("ui", "2e-8")])
    let c = siCriteria(d.roles["sck_si"])
    check abs(c.maxFlightTime - 1.5e-9) < 1e-21
    check abs(c.maxSettleTime - 2e-8) < 1e-20
    check not c.requireMonotonic
    check c.maxOvershoot.isNaN

suite "crosstalk victim (stage 8)":
  proc victimDesign(params: seq[(string, string)]): Design =
    result = spiDesign()
    discard result.addRole("si_net", "sck_x",
      [("net", netS("SCK")), ("driver", pinS("U1.1")), ("rx", pinS("U2.1")),
       ("victim", netS("MOSI")), ("victim_driver", pinS("U1.2")),
       ("victim_rx", pinS("U2.2"))], params)

  test "a victim adds its noise-margin claim, and a budget when stated":
    let d = victimDesign(@[("max_crosstalk", "0.2"), ("coupled_length", "0.04")])
    var qs: seq[string]
    for a in expandInstance(d.roles["sck_x"]): qs.add a.quantity
    check "si_noise_margin_v" in qs and "si_crosstalk_v" in qs
    check abs(siCriteria(d.roles["sck_x"]).maxCrosstalk - 0.2) < 1e-12

  test "a victim is named whole or not at all":
    let d = spiDesign()
    expect NetlistError:
      discard d.addRole("si_net", "half",
        [("net", netS("SCK")), ("driver", pinS("U1.1")), ("rx", pinS("U2.1")),
         ("victim", netS("MOSI"))], @[])

  test "on a board the crosstalk claims are not evaluable, and say why":
    let d = victimDesign(@[("max_crosstalk", "0.2")])
    let rep = readiness(d, allCapabilities, board())
    var seen = 0
    for r in rep.results:
      if r.assertion.quantity in ["si_noise_margin_v", "si_crosstalk_v"]:
        inc seen
        check r.status == esNotEvaluable
        check "verax constraints" in r.reason
    check seen == 2

  test "verax constraints derives a minimum spacing and a KiCad clearance":
    let d = victimDesign(@[("max_crosstalk", "0.1"), ("coupled_length", "0.04")])
    var o = parseVerifyArgs(["--si-constraints", "--net=SCK"])
    let dir = getTempDir() / "verax_si_xtalk"
    createDir(dir)
    o.siOut = dir / "out.txt"
    o.siDru = dir / "out.kicad_dru"
    discard siConstraints(d, o)
    let txt = readFile(o.siOut)
    check "spacing to MOSI over a 40.000 mm parallel run" in txt
    check "min spacing:" in txt
    let dru = readFile(o.siDru)
    check "(constraint clearance (min " in dru
    check "A.NetName == 'SCK' && B.NetName == 'MOSI'" in dru

suite "differential pair constraints (stage 8)":
  test "diff_pair with IBIS pins: max length and max mismatch, as KiCad rules":
    let dir = getTempDir() / "verax_si_diff"
    createDir(dir)
    let drvIbs = """
[IBIS Ver] 3.2
[File Name] tx.ibs
[File Rev] 1.0
[Component] TX
Manufacturer verax tests
[Package]
R_pkg 0.2 NA NA
L_pkg 1nH NA NA
C_pkg 0.3pF NA NA
[Pin] signal_name model_name
1 D_P tx
2 D_N tx
3 GND GND
[Diff Pin] inv_pin vdiff tdelay_typ tdelay_min tdelay_max
1 2 NA 0 NA NA
[Model] tx
Model_type Output
C_comp 1p NA NA
Vmeas = 1.65
Rref = 50
[Voltage Range] 3.3 NA NA
[Pulldown]
-3.3 -0.066 NA NA
 6.6  0.132 NA NA
[Pullup]
-3.3  0.066 NA NA
 6.6 -0.132 NA NA
[Ramp]
dV/dt_r 1.98/0.5n NA NA
dV/dt_f 1.98/0.5n NA NA
[End Model]
[End]
"""
    let rxIbs = """
[IBIS Ver] 3.2
[File Name] rx.ibs
[File Rev] 1.0
[Component] RX
Manufacturer verax tests
[Package]
R_pkg 0.2 NA NA
L_pkg 1nH NA NA
C_pkg 0.3pF NA NA
[Pin] signal_name model_name
1 D_P rx
2 D_N rx
3 GND GND
[Diff Pin] inv_pin vdiff tdelay_typ tdelay_min tdelay_max
1 2 0.2 NA NA NA
[Model] rx
Model_type Input
C_comp 1p NA NA
[Voltage Range] 3.3 NA NA
[End Model]
[End]
"""
    writeFile(dir / "tx.ibs", drvIbs)
    writeFile(dir / "rx.ibs", rxIbs)
    let nl = newNetlist("pair")
    let gnd = addNet(nl, newNet("GND", ntGround))
    let dp = addNet(nl, newNet("D_P", ntSignal))
    let dn = addNet(nl, newNet("D_N", ntSignal))
    for (des, file) in [("U1", "tx.ibs"), ("U2", "rx.ibs")]:
      let c = addComponent(nl, newComponent(des, kind = "ic"))
      discard connect(c, "1", dp)
      discard connect(c, "2", dn)
      discard connect(c, "3", gnd, ptGround)
      c.attrs["ibis_file"] = dir / file
    let r = addComponent(nl, newComponent("R1", kind = "resistor"))
    r.attrs["value"] = "100"
    discard connect(r, "1", dp)
    discard connect(r, "2", dn)
    let d = newDesign(nl)
    discard d.addRole("diff_pair", "usb",
      [("p", netS("D_P")), ("n", netS("D_N")), ("driver", pinS("U1.1")), ("rx", pinS("U2.1"))],
      @[("skew_intra_max", "5e-12")])
    var o = parseVerifyArgs(["--si-constraints"])
    o.siOut = dir / "out.txt"
    o.siDru = dir / "out.kicad_dru"
    check siConstraints(d, o) == 0
    let txt = readFile(o.siOut)
    checkpoint txt
    check "partner:     differential pair with D_N" in txt
    check "differential termination 100.0 ohm" in txt
    check "max mismatch:" in txt
    check "skew budget 5.0 ps" in txt
    let dru = readFile(o.siDru)
    check "(constraint skew (max " in dru
    check "D_N max length" in dru

  test "a pseudo-differential pair: N leg named by the role, series R read, vendor pin names":
    # The driver's file numbers its package pins and has no [Diff Pin] (USB
    # full-speed: two single-ended buffers in opposition); the part names
    # its pins by signal. Each driver pin reaches the pair through 27 ohm.
    let dir = getTempDir() / "verax_si_pseudo"
    createDir(dir)
    writeFile(dir / "tx.ibs", """
[IBIS Ver] 3.2
[File Name] tx.ibs
[File Rev] 1.0
[Component] TX
Manufacturer verax tests
[Package]
R_pkg 0.2 NA NA
L_pkg 1nH NA NA
C_pkg 0.3pF NA NA
[Pin] signal_name model_name
11 D_P tx
12 D_N tx
13 VDD POWER
14 GND GND
[Model] tx
Model_type Output
C_comp 1p NA NA
Vmeas = 1.65
Rref = 50
[Voltage Range] 3.3 NA NA
[Pulldown]
-3.3 -0.33 NA NA
 6.6  0.66 NA NA
[Pullup]
-3.3  0.33 NA NA
 6.6 -0.66 NA NA
[Ramp]
dV/dt_r 1.98/4n NA NA
dV/dt_f 1.98/4n NA NA
[End Model]
[End]
""")
    writeFile(dir / "rx.ibs", """
[IBIS Ver] 3.2
[File Name] rx.ibs
[File Rev] 1.0
[Component] RX
Manufacturer verax tests
[Package]
R_pkg 0 NA NA
L_pkg 0 NA NA
C_pkg 0 NA NA
[Pin] signal_name model_name
DP DP rx
DM DM rx
[Diff Pin] inv_pin vdiff tdelay_typ tdelay_min tdelay_max
DP DM 0.2 NA NA NA
[Model] rx
Model_type Input
C_comp 10p NA NA
[Voltage Range] 3.3 NA NA
[End Model]
[End]
""")
    proc build(rxN = ""): (Design, VerifyOptions) =
      let nl = newNetlist("pseudo")
      discard addNet(nl, newNet("GND", ntGround))
      let tp = addNet(nl, newNet("TX_P", ntSignal))
      let tn = addNet(nl, newNet("TX_N", ntSignal))
      let dp = addNet(nl, newNet("D_P", ntSignal))
      let dn = addNet(nl, newNet("D_N", ntSignal))
      let u1 = addComponent(nl, newComponent("U1", kind = "ic"))
      discard connect(u1, "D_P", tp)
      discard connect(u1, "D_N", tn)
      u1.attrs["ibis_file"] = dir / "tx.ibs"
      let j1 = addComponent(nl, newComponent("J1", kind = "connector"))
      discard connect(j1, "DP", dp)
      discard connect(j1, "DM", dn)
      discard connect(j1, "DP2", addNet(nl, newNet("SPARE", ntSignal)))
      j1.attrs["ibis_mate_file"] = dir / "rx.ibs"
      for (des, a, b) in [("R1", tp, dp), ("R2", tn, dn)]:
        let r = addComponent(nl, newComponent(des, kind = "resistor"))
        r.attrs["value"] = "27"
        discard connect(r, "1", a)
        discard connect(r, "2", b)
      let d = newDesign(nl)
      var parts = @[("p", netS("D_P")), ("n", netS("D_N")), ("driver", pinS("U1.D_P")),
                    ("driver_n", pinS("U1.D_N")), ("rx", pinS("J1.DP"))]
      if rxN.len > 0: parts.add ("rx_n", pinS(rxN))
      discard d.addRole("diff_pair", "usb", parts, @[("ui", "83.33e-9")])
      var o = parseVerifyArgs(["--si-constraints"])
      o.siOut = dir / "out.txt"
      (d, o)
    let (d, o) = build()
    check siConstraints(d, o) == 0
    let txt = readFile(o.siOut)
    checkpoint txt
    check "partner:     differential pair with D_N" in txt
    check "termination: series 27.000 ohm" in txt
    check "series termination 27.0 ohm at the driver on each leg" in txt
    check "J1.DP" in txt
    # rx_n disagreeing with the receiver's own [Diff Pin] is refused, named.
    let (d2, o2) = build(rxN = "J1.DP2")
    check siConstraints(d2, o2) != 0
    check "the role names J1.DP2" in readFile(o2.siOut)

  test "driver_n without driver is refused at attach time":
    let d = spiDesign()
    expect NetlistError:
      discard d.addRole("diff_pair", "half",
        [("p", netS("SCK")), ("n", netS("MOSI")), ("driver_n", pinS("U1.2"))], @[])

  test "driver without rx is refused at attach time":
    let d = spiDesign()
    expect NetlistError:
      discard d.addRole("diff_pair", "half",
        [("p", netS("SCK")), ("n", netS("MOSI")), ("driver", pinS("U1.1"))], @[])

suite "eye claims (stage 8)":
  test "min_eye_height / min_eye_width: measured on the board from a PRBS7 run":
    var d = spiDesign(params = @[])
    discard d.addRole("si_net", "sck_eye",
      [("net", netS("SCK")), ("driver", pinS("U1.1")), ("rx", pinS("U2.1"))],
      @[("ui", "1e-8"), ("min_eye_height", "2.0"), ("min_eye_width", "1e-7")])
    let r = readiness(d, allCapabilities, board())
    var seen = 0
    for res in r.results:
      case res.assertion.quantity
      of "si_eye_height_v":
        inc seen
        check res.status == esPass
      of "si_eye_width":
        inc seen
        check res.status == esFail      # wider than the UI: cannot pass
      else: discard
    check seen == 2

  test "an eye claim without a UI is refused at attach time":
    let d = spiDesign(params = @[])
    expect NetlistError:
      discard d.addRole("si_net", "bad",
        [("net", netS("SCK")), ("driver", pinS("U1.1")), ("rx", pinS("U2.1"))],
        @[("min_eye_height", "1.0")])
