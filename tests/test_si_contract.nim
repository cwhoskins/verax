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
    # U3 bound to the [Component] whose pin 1 it lacks.
    let r = readiness(spiDesign(u3Component = "DEMO_FLASH"), allCapabilities, board())
    var mosi = 0
    for res in r.results:
      if res.assertion.origin == "mosi_si":
        check res.status == esNotEvaluable
        check "pin '1'" in res.reason
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
