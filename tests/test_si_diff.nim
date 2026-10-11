## Stage 8.2 of docs/ibis_simulator_plan.md: differential pairs. `[Diff
## Pin]` (the other leg, `Vdiff`, `tdelay`), a pair template coupled
## throughout with a differential termination, the differential receiver
## measured on `v(p) - v(n)` against `+-Vdiff`, and the intra-pair length
## mismatch as a constraint (KiCad `skew`).

import std/[unittest, streams, strutils, math]

import verax/ibis
import verax/pcb/impedance
import verax/si/simulate
import verax/si/measure
import verax/si/sweep
import verax/si/constrain
import ./fixtures/ibis/synthetic

proc thevenin(r = 50.0): LinearDriver =
  result = defaultLinearDriver()
  result.rpu = r
  result.rpd = r

proc pairFile(d: LinearDriver): IbisFile =
  ## The driver's component with a second output on pin 4 and a `[Diff
  ## Pin]` row 1/4: no Vdiff, inverting leg 50 ps late (typ), 80 ps (max).
  var s = d.toIbs()
  s = s.replace("\n2 VCC POWER", "\n4 OUTN " & d.name & "\n2 VCC POWER")
  s = s.replace("[Model] ", "[Diff Pin] inv_pin vdiff tdelay_typ tdelay_min tdelay_max\n" &
                            "1 4 NA 50ps NA 80ps\n[Model] ")
  readIbis(newStringStream(s))

proc rxB(cComp = 0.0): ReceiverBehaviour =
  receiverBehaviour(readIbis(newStringStream(linearReceiverIbs(cComp = cComp))).model("lin_rx"))

suite "[Diff Pin]":
  let d = thevenin()
  let f = pairFile(d)
  let b = IbisBinding(file: f, componentName: "LINDEV", designator: "U1")

  test "tdelay columns are read":
    let row = f.component("LINDEV").diffPins[0]
    check row.pin == "1" and row.invPin == "4"
    check not row.vdiff.present
    check abs(row.tdelayTyp.value - 50e-12) < 1e-18
    check not row.tdelayMin.present
    check abs(row.tdelayMax.value - 80e-12) < 1e-18

  test "the other leg from either side, tdelay per corner (an absent min is typ)":
    let p = diffPartner([b], PinRef(designator: "U1", pin: "1"))
    check p.ok and p.inverting and p.other.pin == "4"
    check abs(p.tdelay - 50e-12) < 1e-18
    check p.vdiff.isNone
    let n = diffPartner([b], PinRef(designator: "U1", pin: "4"), coMax)
    check n.ok and not n.inverting and n.other.pin == "1"
    check abs(n.tdelay - 80e-12) < 1e-18
    check abs(diffPartner([b], PinRef(designator: "U1", pin: "1"), coMin).tdelay - 50e-12) < 1e-18

  test "a pin with no row is a named reason":
    let x = diffPartner([b], PinRef(designator: "U1", pin: "2"))
    check not x.ok
    check "no [Diff Pin] row for pin 2" in x.reason

# --- the pair --------------------------------------------------------------

let pairSpec = LineSpec(geometry: lgEdgeCoupledMicrostrip, w: 0.25e-3, t: 35e-6,
                        h1: 0.15e-3, er: 4.3, s: 0.2e-3)

proc pairTemplate(vdiff = 0.2): SiTemplate =
  let drv = driverBehaviour(readIbis(newStringStream(thevenin().toIbs())).model(thevenin().name))
  var single = pairSpec
  single.geometry = lgMicrostrip
  result = SiTemplate(name: "D_P", driver: drv, topology: ttPointToPoint,
                      driverPort: TemplatePort(label: "U1.1"), line: lineSection(single),
                      receivers: @[rxB()], receiverPorts: @[TemplatePort(label: "U2.1")])
  result.partner = TemplatePartner(role: prDiffPair, name: "D_N", driver: drv,
                                   driverPort: TemplatePort(label: "U1.4"), receiver: rxB(),
                                   receiverPort: TemplatePort(label: "U2.4"), coupled: pairSpec,
                                   vdiff: some(vdiff), vdiffSource: "test")

suite "differential pair":
  let t = pairTemplate()
  let m = coupledModes(pairSpec)

  test "the pair is coupled throughout, the other leg driven inverted":
    let net = t.build(templateParams(0.1, diffR = 100.0))
    check net.unsupported.len == 0
    check net.extraDrivers.len == 1 and net.extraDrivers[0].mode == dmInverted
    check net.diffReceivers.len == 1
    var coupled = 0
    for e in net.elements:
      if e.kind == sekCoupledLine: inc coupled
    check coupled == 1

  test "settled differential level: the termination against both sources":
    # Each leg a 50 ohm Thevenin source of 0 / 3.3 V; across 100 ohm the
    # difference settles to 3.3 * 100 / (100 + 2 * 50).
    let net = t.build(templateParams(0.1, diffR = 100.0))
    let r = simulate(net, edgeStimulus(edRising, 0.5e-9))
    check r.status == ssOk
    let vd = diffWave(r, net.diffReceivers[0])
    check abs(vd[0] - (-1.65)) < 0.01
    check abs(vd[^1] - 1.65) < 0.01

  test "the differential edge crosses its threshold once the odd mode has arrived":
    let net = t.build(templateParams(0.1, diffR = 100.0))
    let r = simulate(net, edgeStimulus(edRising, 0.5e-9))
    let vd = diffWave(r, net.diffReceivers[0])
    let tc = firstCrossing(r.t, vd, 0.0, true)
    # Odd-mode delay over 0.1 m plus the 1 ns edge's midpoint (and package).
    let tdo = 0.1 * sqrt(m.epsOdd) / 299_792_458.0
    check tc > 0.5e-9 + tdo
    check tc < 0.5e-9 + tdo + 1.0e-9

  test "sweep: a differential probe and two legs":
    let net = t.build(templateParams(0.1, diffR = 100.0))
    let sw = sweepNet([SweepCorner(corner: coTyp, net: net)], sweepStimuli(NaN))
    check sw.status == ssOk
    var kinds: seq[ProbeKind]
    for p in sw.probes: kinds.add p.kind
    check kinds == @[pkLeg, pkLeg, pkDiff]
    let w = sw.worst[2][sfThresholdMargin]
    check abs(w.value - (1.65 - 0.2)) < 0.05
    check "U2.1/U2.4 (diff)" in renderText(sw)

  test "no Vdiff: the differential criteria cannot be judged":
    let p = judge([pairTemplate(vdiff = 0.2)], templateParams(0.1, diffR = 100.0),
                  defaultCriteria())
    check p.verdict == vPass
    var t2 = pairTemplate()
    t2.partner.vdiff = none(float)
    let q = judge([t2], templateParams(0.1, diffR = 100.0), defaultCriteria())
    check q.verdict == vInvalid
    check "Vdiff" in q.reason

  test "intra-pair mismatch delays the differential edge: a max mismatch, as KiCad skew":
    var c = defaultCriteria()
    c.requireMonotonic = false
    let base = templateParams(0.1, diffR = 100.0)
    let r0 = judge([t], base, c)
    check r0.verdict == vPass
    # A flight-time budget 100 ps over the matched pair's (synthetic driver:
    # no timing load, so use the settle time of the differential edge).
    var maxSettle = 0.0
    for me in r0.measures: maxSettle = max(maxSettle, me.settleTime)
    c.maxSettleTime = maxSettle + 150e-12
    let sk = sweep([t], base, spLegMismatch, 0.0, 0.05, 11, c, 0.2e-3)
    let mm = sk.maxFromStart
    checkpoint $sk.passing & " " & sk.binding
    check not mm.isNaN and mm > 1e-3 and mm < 0.05
    check "settle time" in sk.binding
    let rep = ConstraintReport(net: "D_P", identity: identity(t, [coTyp], base, c),
                               skew: sk, hasSkew: true, pairNet: "D_N")
    var found = false
    for r in druRules(rep, "D_P"):
      if not r.maxSkew.isNaN:
        found = true
        check abs(r.maxSkew - mm) < 1e-12
    check found
    check "max mismatch" in renderText(rep)
