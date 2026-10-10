## Stage 8.6 of docs/ibis_simulator_plan.md: power-aware IBIS
## (`[ISSO PU]`/`[ISSO PD]`, `[Composite Current]`) and simultaneous
## switching noise through the package's power and ground pins.

import std/[unittest, streams, strutils, math]

import verax/ibis
import verax/si/engine/transient
import verax/si/simulate
import verax/si/ssn
import ./fixtures/ibis/synthetic

proc model(d: LinearDriver): IbisModel =
  readIbis(newStringStream(d.toIbs())).model(d.name)

proc rxB(): ReceiverBehaviour =
  receiverBehaviour(readIbis(newStringStream(linearReceiverIbs(cComp = 1e-12))).model("lin_rx"))

const issoPd = "[ISSO PD]\n-3.3 -0.2475 NA NA\n0 -0.165 NA NA\n3.3 -0.0825 NA NA\n"
  ## Vtable 0: the pulldown table's current at Vcc (3.3 V / 20 ohm, into the
  ## component is negative here: IBIS sign); half as much at a 3.3 V ground
  ## rise, 1.5x at -3.3 V -- Ksso(v) = 1 - v / 6.6.

suite "power-aware keywords":
  test "[ISSO PD] and [Composite Current] are read":
    var d = defaultLinearDriver()
    d.extraModelTables = issoPd
    d.preDriverPulse = (0.02, 0.2e-9, 0.4e-9)
    let m = d.model
    check m.issoPd.len == 3
    check m.issoPu.len == 0
    check m.risingWaveforms[0].composite.len == d.samples
    check m.fallingWaveforms[1].composite.len == d.samples

  test "Ksso is Isso(Vtable) / Isso(0)":
    var d = defaultLinearDriver()
    d.extraModelTables = issoPd
    let b = driverBehaviour(d.model)
    check b.kssoPu.isEmpty
    check abs(b.kssoPd.eval(0.0).i - 1.0) < 1e-12
    check abs(b.kssoPd.eval(3.3).i - 0.5) < 1e-12
    check abs(b.kssoPd.eval(1.0).i - (1 - 1.0 / 6.6)) < 1e-9

  test "the pre-driver current: composite minus the I/V tables' share":
    var d = defaultLinearDriver()
    d.preDriverPulse = (0.02, 0.2e-9, 0.4e-9)
    let b = driverBehaviour(d.model)
    for e in Edge:
      let p = b.preDriver[e]
      check p.t.len == d.samples
      var worst = 0.0
      for k, t in p.t: worst = max(worst, abs(p.i[k] - d.preDriverAt(t)))
      checkpoint edgeName(e) & " " & $worst
      check worst < 1e-9

  test "a [Composite Current] that follows no waveform is refused":
    var d = defaultLinearDriver()
    d.extraModelTables = "[Composite Current]\n0 0 NA NA\n1n 0 NA NA\n"
    expect IbisError:
      discard d.model

suite "rail-referenced devices":
  test "a pulldown hanging from a lifted ground: the series circuit, then Ksso":
    # Vs - Rs - pad -[pulldown R0, from rail g]- g - Rg - 0.
    const vs = 2.0
    const rs = 50.0
    const r0 = 20.0
    const rg = 5.0
    var c = newCircuit()
    let s = c.addNode("s")
    let p = c.addNode("pad")
    let g = c.addNode("g")
    c.vsources.add VSrc(a: s, b: 0, wave: constPwl(vs), label: "Vs")
    c.resistors.add Res(a: s, b: p, r: rs, label: "Rs")
    c.resistors.add Res(a: g, b: 0, r: rg, label: "Rg")
    let pd = IvCurve(v: @[-10.0, 10.0], i: @[10.0 / r0, -10.0 / r0])
    c.devices.add NlDevice(node: p, curves: @[pd], refs: @[g], refNominal: @[0.0], label: "pd")
    let r = transient(c, defaultSimOptions(1e-9))
    check r.ok
    let i = vs / (rs + r0 + rg)
    check abs(r.v[g][^1] - i * rg) < 1e-6
    check abs(r.v[p][^1] - (vs - i * rs)) < 1e-6
    # Ksso(vt) = 0.5 at any rise: the pulldown is 40 ohm once the loop
    # has seen the rail.
    var c2 = c
    c2.devices[0].ksso = @[IvCurve(v: @[-10.0, 10.0], i: @[0.5, 0.5])]
    c2.devices[0].kssoSign = @[1.0]
    let r2 = transient(c2, defaultSimOptions(1e-9))
    check r2.ok
    let i2 = vs / (rs + 2 * r0 + rg)
    check abs(r2.v[g][^1] - i2 * rg) < 1e-6

suite "simultaneous switching":
  proc spec(n: int, lGnd: float, d = defaultLinearDriver()): SsnSpec =
    SsnSpec(name: "bus", driver: driverBehaviour(d.model), receiver: rxB(),
            switching: n, quiet: 1, line: idealLine(50.0, 6e-9), length: 0.05,
            pkgSignal: PackageRlc(r: 0.1, l: 1e-9, c: 0.3e-12),
            powerPins: 1, groundPins: 1,
            pkgPower: PackageRlc(r: 0.05, l: lGnd), pkgGround: PackageRlc(r: 0.05, l: lGnd),
            supply: NaN)

  let falling = [edgeStimulus(edFalling, 0.5e-9)]

  test "ground bounce grows with the switching count and the pin inductance":
    let a = ssn(spec(1, 1e-9), falling)
    let b = ssn(spec(4, 1e-9), falling)
    let c = ssn(spec(4, 4e-9), falling)
    check a.status == ssOk and b.status == ssOk and c.status == ssOk
    checkpoint $a & "\n" & $b & "\n" & $c
    check b.groundBounce > 2.5 * a.groundBounce
    check c.groundBounce > b.groundBounce
    check b.quietNoise > a.quietNoise
    check b.quietNoise > 0.0

  test "small inductance: bounce in proportion to L (L dI/dt)":
    let lo = ssn(spec(2, 0.05e-9), falling)
    let hi = ssn(spec(2, 0.1e-9), falling)
    let ratio = hi.groundBounce / lo.groundBounce
    checkpoint $ratio
    check ratio > 1.6 and ratio < 2.1

  test "ISSO PD: the held-low quiet output's pulldown follows its bouncing ground":
    # The bounce peaks ~40 ps into the edge, set by the onset of dI/dt
    # before any bounce exists for Ksso to act on (it is updated per step);
    # the quiet line, held through a pulldown that weakens as its ground
    # rises, shows it. Ksso's exact scaling is checked at engine level.
    var d = defaultLinearDriver()
    let plain = ssn(spec(4, 1e-9, d), falling)
    d.extraModelTables = issoPd
    let aware = ssn(spec(4, 1e-9, d), falling)
    checkpoint $plain & "\n" & $aware
    check abs(aware.groundBounce - plain.groundBounce) < 0.01 * plain.groundBounce
    check aware.quietMargin > plain.quietMargin + 0.02

  test "a pre-driver current adds rail-to-rail di/dt":
    var d = defaultLinearDriver()
    let plain = ssn(spec(4, 1e-9, d), falling)
    d.preDriverPulse = (0.05, 0.1e-9, 0.3e-9)
    let pre = ssn(spec(4, 1e-9, d), falling)
    var said = false
    for a in pre.assumptions:
      if "pre-driver" in $a: said = true
    check pre.groundBounce != plain.groundBounce
    check pre.powerDroop > plain.powerDroop
