## Stage 0 of docs/ibis_simulator_plan.md: the reader gaps the SI engine needs
## (`[Model Spec]`, `[Receiver Thresholds]`, `V_fixture_min/max`) and the
## synthetic fixtures every later stage builds on.

import std/[streams, unittest, math, strutils]

import verax/ibis
import ./fixtures/ibis/synthetic

proc near(a, b: float, tol = 1e-12): bool = abs(a - b) <= tol

const specIbs = """
[IBIS Ver] 4.2
[Component] SPECDEV
[Pin] signal_name model_name
1 IN rx
[Model] rx
Model_type Input
C_comp 2pF NA NA
Vinl = 0.8
Vinh = 2.0
[Voltage Range] 3.3 3.0 3.6
[Model Spec]
| subparameter   typ    min    max
Vinh             2.1    1.9    2.3
Vinl             0.7    NA     0.9
Vinh+            2.2    NA     NA
S_overshoot_high 3.8    3.5    4.1
S_overshoot_low  -0.5   -0.4   NA
D_overshoot_time 2n     NA     NA
Vmeas            1.65   1.5    1.8
Rref             50     NA     NA
Some_future_param 7     7      7
[Receiver Thresholds]
Vth = 1.25
Vth_min = 1.2
Vth_max = 1.3
Vinh_ac = +0.2
Vinl_ac = -0.2
Vinh_dc = 0.1
Vinl_dc = -0.1
Threshold_sensitivity = 0.5
Reference_supply Pullup_ref
Tslew_ac = 0.4n
[End Model]
[End]
"""

suite "[Model Spec]":
  test "every row is a triplet with per-corner presence":
    let m = readIbis(newStringStream(specIbs)).model("rx")
    let ms = m.modelSpec
    check ms.present
    check near(ms.vinh.get(coTyp), 2.1)
    check near(ms.vinh.get(coMin), 1.9)
    check near(ms.vinh.get(coMax), 2.3)
    check ms.vinl.has(coTyp) and not ms.vinl.has(coMin) and ms.vinl.has(coMax)
    check near(ms.vinhPlus.get(coTyp), 2.2)
    check near(ms.sOvershootHigh.get(coMax), 4.1)
    check near(ms.sOvershootLow.get(coTyp), -0.5)
    check not ms.sOvershootLow.has(coMax)
    check near(ms.dOvershootTime.get(coTyp), 2e-9, 1e-21)
    check near(ms.vmeas.get(coMin), 1.5)
    check near(ms.rref.get(coTyp), 50.0)
    expect IbisError:
      discard ms.vinl.get(coMin)

  test "the [Model] scalars are left alone":
    let m = readIbis(newStringStream(specIbs)).model("rx")
    check near(m.vinh.value, 2.0)
    check near(m.vinl.value, 0.8)

  test "an unknown subparameter stays reachable through raw":
    let m = readIbis(newStringStream(specIbs)).model("rx")
    var found = false
    for ch in m.raw.children:
      if ch.keyword == "model_spec":
        for ln in ch.body:
          if ln.text.startsWith("Some_future_param"): found = true
    check found

  test "absent keyword reads as not present":
    let m = readIbis(newStringStream(linearReceiverIbs())).model("lin_rx")
    check not m.modelSpec.present
    check not m.receiverThresholds.present

  test "a malformed number raises with its line":
    try:
      discard readIbis(newStringStream(malformedRowIbs))
      check false
    except IbisError as e:
      check "Model Spec" in e.msg
      check "line 9" in e.msg

suite "[Receiver Thresholds]":
  test "single values, offsets kept as written":
    let rt = readIbis(newStringStream(specIbs)).model("rx").receiverThresholds
    check rt.present
    check near(rt.vth.value, 1.25)
    check near(rt.vthMin.value, 1.2)
    check near(rt.vthMax.value, 1.3)
    check near(rt.vinhAc.value, 0.2)
    check near(rt.vinlAc.value, -0.2)
    check near(rt.vinhDc.value, 0.1)
    check near(rt.thresholdSensitivity.value, 0.5)
    check rt.referenceSupply == "Pullup_ref"
    check near(rt.tslewAc.value, 0.4e-9, 1e-21)
    check not rt.vcrossLow.present

suite "V_fixture corners":
  test "V_fixture_min/max fill the triplet's corners":
    const src = """
[IBIS Ver] 3.2
[Component] D
[Pin] signal_name model_name
1 OUT drv
[Model] drv
Model_type Output
[Voltage Range] 3.3 3.0 3.6
[Rising Waveform]
R_fixture = 50
V_fixture = 3.3
V_fixture_min = 3.0
V_fixture_max = 3.6
0.0  0.0  0.0  0.0
1n   3.3  3.0  3.6
[End Model]
[End]
"""
    let w = readIbis(newStringStream(src)).model("drv").risingWaveforms[0]
    check near(w.vFixture.get(coTyp), 3.3)
    check near(w.vFixture.get(coMin), 3.0)
    check near(w.vFixture.get(coMax), 3.6)
    check w.points.len == 2

suite "synthetic fixtures parse":
  test "linear driver: tables, waveforms, ramp":
    let d = defaultLinearDriver()
    let f = readIbis(newStringStream(d.toIbs()))
    let m = f.model("lin_drv")
    check m.modelType == mtOutput
    check m.pulldown.len == 7 and m.pullup.len == 7
    check m.risingWaveforms.len == 2 and m.fallingWaveforms.len == 2
    check m.risingWaveforms[0].points.len == d.samples
    check near(m.risingWaveforms[1].vFixture.get(coTyp), 3.3)
    # The pulldown is a 20 ohm resistor: I = V / 20 into the device.
    check near(m.pulldown[^1].i.get(coTyp), 6.6 / 20.0, 1e-9)
    check near(m.ramp.dtR.get(coTyp), 0.6e-9, 1e-18)

  test "generated waveform is the closed-form divider at t = 0 and t = end":
    let d = defaultLinearDriver()
    let m = readIbis(newStringStream(d.toIbs())).model("lin_drv")
    # Rising into 50 ohm to 3.3 V: at t=0 the 20 ohm pulldown is on.
    let w = m.risingWaveforms[1]
    check near(w.points[0].v.get(coTyp), 3.3 * 20.0 / 70.0, 1e-9)
    # At the end the 25 ohm pullup alone: the pad sits at the rail.
    check near(w.points[^1].v.get(coTyp), 3.3, 1e-9)

  test "selector, reserved pins and per-pin RLC":
    let f = readIbis(newStringStream(selectorIbs))
    check f.modelSelectors.len == 1
    check f.modelSelectors[0].choices.len == 2
    let c = f.component("SELDEV")
    check c.pin("2").present == {prR, prL, prC}
    check near(c.pin("2").lPin, 3e-9, 1e-18)
    expect IbisError:
      discard f.modelFor("SELDEV", "3")     # POWER

  test "incomplete corners parse, absences preserved":
    let m = readIbis(newStringStream(incompleteCornersIbs)).model("drv")
    check not m.cComp.has(coMin)
    check m.cComp.has(coMax)
    check not m.pulldown[1].i.has(coMax)
    check m.pullup[1].i.has(coMax)

  test "unsupported fixture parasitic survives into Waveform":
    var d = defaultLinearDriver()
    d.extraFixtureLines = "L_fixture = 2nH\n"
    let w = readIbis(newStringStream(d.toIbs())).model("lin_drv").risingWaveforms[0]
    check near(w.lFixture, 2e-9, 1e-18)
