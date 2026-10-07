## Stage 2 of docs/ibis_simulator_plan.md: `si/topology` (templates, pin ->
## behaviour mapping), `si/drive` (stimulus) and `pcb/via` (closed form).

import std/[streams, unittest, math, tables, strutils]

import verax/netlist
import verax/ibis
import verax/ibis/behave
import verax/pcb/via
import verax/si/topology
import verax/si/drive
import ./fixtures/ibis/synthetic

proc drv(): DriverBehaviour =
  driverBehaviour(readIbis(newStringStream(defaultLinearDriver().toIbs())).model("lin_drv"))

proc rx(): ReceiverBehaviour =
  receiverBehaviour(readIbis(newStringStream(linearReceiverIbs())).model("lin_rx"))

proc count(n: SiNet, k: SiElemKind): int =
  for e in n.elements:
    if e.kind == k: inc result

proc tmpl(topo: TemplateTopology, nrx: int): SiTemplate =
  result = SiTemplate(name: "t", driver: drv(), topology: topo,
                      driverPort: TemplatePort(label: "U1.1", pkg: PackageRlc(r: 0.2, l: 2e-9, c: 0.5e-12)),
                      line: idealLine(50.0, 6e-9))
  for k in 0 ..< nrx:
    result.receivers.add rx()
    result.receiverPorts.add TemplatePort(label: "U" & $(k + 2) & ".1",
                                          pkg: PackageRlc(r: 0.2, l: 2e-9, c: 0.5e-12))

suite "via model":
  test "Johnson & Graham's worked example":
    # 0.063 in board, 28 mil pad, 50 mil clearance, er 4.4 -> ~0.50 pF;
    # 0.063 in barrel, 16 mil drill -> ~1.2 nH.
    let c = viaCapacitance(4.4, 0.063 * 0.0254, 0.028 * 0.0254, 0.050 * 0.0254)
    check abs(c - 0.497e-12) < 0.005e-12
    let l = viaInductance(0.063 * 0.0254, 0.016 * 0.0254)
    check abs(l - 1.20e-9) < 0.01e-9

  test "stub lengths, backdrill and the quarter-wave resonance":
    let T = 1.6e-3
    var g = ViaGeometry(drillDia: 0.3e-3, padDia: 0.6e-3, antipadDia: 1.0e-3,
                        barrelLength: T, er: 4.3, entryDepth: 0.0,
                        exitDepth: 0.4e-3, backdrillResidual: -1.0,
                        entryRef: "GND", exitRef: "GND")
    let v = viaModel(g)
    check abs(v.stubBottom - 1.2e-3) < 1e-12
    check v.stubTop == 0.0
    check abs(v.usedLength - 0.4e-3) < 1e-12
    check abs(v.stubResonance - 1.0 / (4 * 1.2e-3 * v.stubTdPerM)) < 1.0
    check not v.referenceChange
    g.backdrillResidual = 0.2e-3
    let vb = viaModel(g)
    check abs(vb.stubBottom - 0.2e-3) < 1e-12
    check vb.stubResonance > 5 * v.stubResonance

  test "a reference change is an issue, never a silent barrel":
    let v = viaModel(ViaGeometry(drillDia: 0.3e-3, padDia: 0.6e-3, antipadDia: 1e-3,
                                 barrelLength: 1.6e-3, er: 4.3, exitDepth: 1.6e-3,
                                 backdrillResidual: -1, entryRef: "GND", exitRef: "PWR"))
    check v.referenceChange
    check v.issues[0].kind == "via_reference_change"

suite "templates":
  test "point-to-point: package, line, receiver":
    let n = tmpl(ttPointToPoint, 1).build(TemplateParams(length: 0.1))
    check n.unsupported.len == 0
    check n.count(sekLine) == 1
    check n.count(sekResistor) == 2      # two R_pkg
    check n.count(sekInductor) == 2
    check n.count(sekCapacitor) == 2     # two C_pkg
    for e in n.elements:
      if e.kind == sekLine:
        check abs(e.td - 0.6e-9) < 1e-18
        check e.a == n.driverPort.pinNode
        check e.b == n.receiverPorts[0].pinNode

  test "series R and vias split the trunk":
    var t = tmpl(ttPointToPoint, 1)
    t.hasVia = true
    t.via = viaModel(ViaGeometry(drillDia: 0.3e-3, padDia: 0.6e-3, antipadDia: 1e-3,
                                 barrelLength: 1.6e-3, er: 4.3, exitDepth: 0.4e-3,
                                 backdrillResidual: -1, entryRef: "GND", exitRef: "GND"))
    let n = t.build(TemplateParams(length: 0.09, viaCount: 2, seriesR: 33.0))
    check n.unsupported.len == 0
    # 3 trunk pieces + 2 bottom stubs
    check n.count(sekLine) == 5
    var trunk = 0.0
    for e in n.elements:
      if e.kind == sekLine and e.label.startsWith("trunk"): trunk += e.td
    check abs(trunk - 0.09 * 6e-9) < 1e-18
    var rs = false
    for e in n.elements:
      if e.label == "series R": rs = abs(e.value - 33.0) < 1e-12
    check rs

  test "daisy chain taps, star branches, parallel termination":
    let d = tmpl(ttDaisyChain, 3).build(TemplateParams(length: 0.15, stubLength: 0.01,
                                                       parallelR: 50.0, parallelV: 1.65))
    check d.unsupported.len == 0
    check d.receiverPorts.len == 3
    check d.count(sekLine) == 6
    check d.count(sekVoltage) == 1
    let s = tmpl(ttStar, 2).build(TemplateParams(length: 0.05, stubLength: 0.02))
    check s.count(sekLine) == 3

  test "a via with a reference change makes the net unsupported":
    var t = tmpl(ttPointToPoint, 1)
    t.hasVia = true
    t.via = viaModel(ViaGeometry(drillDia: 0.3e-3, padDia: 0.6e-3, antipadDia: 1e-3,
                                 barrelLength: 1.6e-3, er: 4.3, exitDepth: 0.4e-3,
                                 backdrillResidual: -1, entryRef: "GND", exitRef: "VCC"))
    let n = t.build(TemplateParams(length: 0.05, viaCount: 1))
    check n.unsupported.len == 1
    check "reference" in n.unsupported[0]

  test "an unsupported driver is carried as the limitation":
    var t = tmpl(ttPointToPoint, 1)
    var d = defaultLinearDriver()
    d.modelType = "Series"
    t.driver = driverBehaviour(readIbis(newStringStream(d.toIbs())).model("lin_drv"))
    let n = t.build(TemplateParams(length: 0.05))
    check n.unsupported.len == 1
    check "Series" in n.unsupported[0]

suite "pin -> behaviour mapping":
  proc board(): (Netlist, seq[IbisBinding]) =
    let nl = newNetlist("sel")
    let n = addNet(nl, newNet("n"))
    let u1 = addComponent(nl, newComponent("U1", kind = "ic"))
    for p in ["1", "2", "3", "4"]: discard connect(u1, p, n)
    let f = readIbis(newStringStream(selectorIbs))
    (nl, @[bindIbis(nl, "U1", f)])

  test "literal model, per-pin RLC override":
    let (_, bs) = board()
    let r = resolvePin(bs, PinRef(designator: "U1", pin: "2"))
    check r.ok
    check r.model.name == "rx_only"
    check abs(r.pkg.l - 3e-9) < 1e-18
    check abs(r.pkg.r - 0.3) < 1e-12

  test "selector needs an explicit, valid choice":
    let (_, bs) = board()
    let p = PinRef(designator: "U1", pin: "1")
    let none = resolvePin(bs, p)
    check not none.ok
    check "needs a choice" in none.reason
    let bad = resolvePin(bs, p, {"U1": "io_turbo"}.toTable)
    check not bad.ok
    let good = resolvePin(bs, p, {"U1": "io_slow"}.toTable)
    check good.ok
    check good.model.name == "io_slow"
    check abs(good.pkg.l - 1e-9) < 1e-18

  test "POWER / NC / unbound pins are named":
    let (_, bs) = board()
    check "POWER" in resolvePin(bs, PinRef(designator: "U1", pin: "3")).reason
    check "NC" in resolvePin(bs, PinRef(designator: "U1", pin: "4")).reason
    check "no IBIS binding" in resolvePin(bs, PinRef(designator: "U9", pin: "1")).reason

suite "stimulus":
  test "single edge: held, then the series shifted by the delay":
    let w = driveWaves(drv(), edgeStimulus(edRising, 1e-9))
    check w.supported
    check abs(w.ku.at(0.0)) < 1e-12
    check abs(w.kd.at(0.5e-9) - 1.0) < 1e-12
    check abs(w.ku.at(1.5e-9) - 0.5) < 1e-9
    check abs(w.ku.at(5e-9) - 1.0) < 1e-12
    check abs(w.tr - 0.8e-9) < 1e-15
    check w.issues.len == 0

  test "a bit pattern stitches edges; a short UI warns and jumps":
    let w = driveWaves(drv(), patternStimulus("0110", 3e-9))
    check w.supported
    check w.issues.len == 0
    check abs(w.ku.at(2e-9)) < 1e-12
    check abs(w.ku.at(4e-9) - 1.0) < 1e-12        # risen by 3+1 ns
    check abs(w.ku.at(9.5e-9) - 0.5) < 1e-9       # falling from 9 ns
    let s = driveWaves(drv(), patternStimulus("010", 0.5e-9))
    check s.issues.len == 1
    check s.issues[0].kind == "si_ui_short"
    var jumps = 0
    for b in s.ku.breakpoints:
      if b.jump: inc jumps
    check jumps >= 1

  test "a malformed pattern is unsupported":
    check not driveWaves(drv(), patternStimulus("01x", 1e-9)).supported
