import std/[math, os, strutils, tables, unittest]

import verax/netlist/dsl
import verax/analysis/analyses/pdn

let haveNgspice = findExe("ngspice").len > 0

proc rail(caps: openArray[tuple[desig, value, esr, esl: string]]): Netlist =
  ## A VDD rail with an IC on it and the given capacitors to ground.
  result = newNetlist("board")
  let vdd = addNet(result, newNet("vdd", ntPower))
  vdd.attrs["voltage"] = "3.3"
  let gnd = addNet(result, newNet("0", ntGround))
  let sig = addNet(result, newNet("sig", ntSignal))

  let u1 = addComponent(result, newComponent("U1", kind = "mcu"))
  discard connect(u1, "VDD", vdd, ptPower)
  discard connect(u1, "GND", gnd, ptGround)
  discard connect(u1, "IO", sig, ptOutput)

  for c in caps:
    let comp = addComponent(result, newComponent(c.desig, kind = "capacitor"))
    discard connect(comp, "1", vdd, ptPassive)
    discard connect(comp, "2", gnd, ptPassive)
    comp.attrs["value"] = c.value
    comp.attrs["esr"] = c.esr
    comp.attrs["esl"] = c.esl
    # Class 1, so the closed-form identities below check against the
    # capacitance the simulation uses; unstated, these 3.3 V ceramics would
    # be bias-derated.
    comp.attrs["dielectric"] = "C0G"

test "a rail with no capacitor is an error, not a simulation":
  let nl = rail([])
  let r = analyzePdn(nl, "vdd")
  check r.issues.len == 1
  check r.issues[0].kind == KindNoDecoupling
  check r.issues[0].severity == sevError
  check r["cap_count"] == 0.0

test "analyzePdn rejects an unknown net by name":
  expect(NetlistError):
    discard analyzePdn(rail([]), "nosuchrail")

if not haveNgspice:
  echo "SKIP: ngspice not found on PATH, skipping real-simulation tests"
else:
  test "a single capacitor's impedance floor is its ESR, at its self-resonance":
    # C = 100nF, ESR = 20 mohm, ESL = 1nH: SRF = 15.915 MHz, |Z| = ESR there.
    let nl = rail([(desig: "C1", value: "100n", esr: "0.02", esl: "1e-9")])
    var spec = defaultPdnSpec()
    spec.fStart = 1.0e3
    spec.fStop = 1.0e9
    spec.ptsPerDecade = 50
    let r = analyzePdn(nl, "vdd", spec = spec)

    check r["cap_count"] == 1.0
    let srf = 1.0 / (2.0 * PI * sqrt(1.0e-9 * 100.0e-9))
    check abs(r["z_min"] - 0.02) / 0.02 < 0.02
    check abs(r["f_z_min"] - srf) / srf < 0.05

    # Well below resonance: Z = 1/(2*pi*f*C).
    let z100k = r["z_at_100kHz"]
    let expect100k = 1.0 / (2.0 * PI * 1.0e5 * 100.0e-9)
    check abs(z100k - expect100k) / expect100k < 0.02

    # Well above: Z = 2*pi*f*L.
    let z100m = r["z_at_100MHz"]
    let expect100m = 2.0 * PI * 1.0e8 * 1.0e-9
    check abs(z100m - expect100m) / expect100m < 0.05

  test "ESR and ESL really are being applied, not ignored":
    # An ideal capacitor would put z_min at the top of the sweep.
    let nl = rail([(desig: "C1", value: "100n", esr: "0.02", esl: "1e-9")])
    let r = analyzePdn(nl, "vdd")
    check r["f_z_min"] < 1.0e8   # resonance is interior to the sweep
    check r["z_min"] > 0.0       # there is a real ESR floor

  test "two capacitor families produce an anti-resonant peak between them":
    # 10uF/3nH resonates at ~919 kHz, 100nF/0.6nH at ~20.5 MHz; between them
    # the bulk is inductive and the ceramic capacitive, so they ring.
    let nl = rail([
      (desig: "C1", value: "10u", esr: "0.05", esl: "3e-9"),
      (desig: "C2", value: "100n", esr: "0.02", esl: "0.6e-9"),
    ])
    var spec = defaultPdnSpec()
    spec.ptsPerDecade = 50
    spec.targetZ = 0.01     # low enough that the peak is flagged
    let r = analyzePdn(nl, "vdd", spec = spec)

    var peaks: seq[Issue]
    for i in r.issues:
      if i.kind == KindAntiresonance: peaks.add i
    check peaks.len >= 1
    check "anti-resonant" in peaks[0].message

    # The peak lies strictly between the two self-resonances.
    let fBulk = 1.0 / (2.0 * PI * sqrt(3.0e-9 * 10.0e-6))
    let fCer = 1.0 / (2.0 * PI * sqrt(0.6e-9 * 100.0e-9))
    check r["f_antiresonance"] > fBulk
    check r["f_antiresonance"] < fCer
    check r["z_antiresonance"] > r["z_min"]

  test "package defaults stand in when parasitics are not annotated, and say so":
    let nl = newNetlist("board")
    let vdd = addNet(nl, newNet("vdd", ntPower))
    let gnd = addNet(nl, newNet("0", ntGround))
    let u1 = addComponent(nl, newComponent("U1", kind = "mcu"))
    discard connect(u1, "VDD", vdd, ptPower)
    discard connect(u1, "GND", gnd, ptGround)
    let c1 = addComponent(nl, newComponent("C1", kind = "capacitor"))
    discard connect(c1, "1", vdd, ptPassive)
    discard connect(c1, "2", gnd, ptPassive)
    c1.attrs["value"] = "100n"
    c1.attrs["package"] = "0402"

    let r = analyzePdn(nl, "vdd")
    check r["z_min"] > 0.0
    var sawPackage = false
    for a in r.assumptions:
      if "package default (0402)" in $a: sawPackage = true
    check sawPackage

  test "a part with no model is stood in for per pin, and says so":
  # The rail sees a load where the IC hangs, and the invented impedance is
  # declared.
    let nl = rail([(desig: "C1", value: "100n", esr: "0.02", esl: "1e-9")])
    let r = analyzePdn(nl, "vdd")
    var stoodIn = false
    for a in r.assumptions:
      if "U1" in $a and "zin" in $a and "no model" in $a: stoodIn = true
    check stoodIn

  test "the older cut-at-the-boundary behaviour is still reachable":
    let nl = rail([(desig: "C1", value: "100n", esr: "0.02", esl: "1e-9")])
    var spec = defaultPdnSpec()
    spec.modelUnmodelledParts = false
    let r = analyzePdn(nl, "vdd", spec = spec)
    var sawDropped = false
    for a in r.assumptions:
      if "U1" in $a and "cut at the boundary" in $a: sawDropped = true
    check sawDropped

  test "a single-capacitor rail has no anti-resonance to report":
    let nl = rail([(desig: "C1", value: "100n", esr: "0.02", esl: "1e-9")])
    let r = analyzePdn(nl, "vdd")
    check r["f_antiresonance"].isNaN
    var peaks = 0
    for i in r.issues:
      if i.kind == KindAntiresonance: inc peaks
    check peaks == 0

  test "the target band excludes the low-frequency region the regulator owns":
    # At 1 kHz the regulator's job, not the decoupling's; flagging it would
    # false-positive every good board.
    let nl = rail([(desig: "C1", value: "100n", esr: "0.02", esl: "1e-9")])
    var spec = defaultPdnSpec()
    spec.targetZ = 100.0        # far above anything above 100 kHz here
    let r = analyzePdn(nl, "vdd", spec = spec)
    check r["z_max_in_band"] < 100.0
    for i in r.issues:
      check i.kind != KindImpedanceExceedsTarget
    # Lowering the band brings the capacitive region into scope.
    spec.targetFrom = 1.0e3
    let r2 = analyzePdn(nl, "vdd", spec = spec)
    check r2["z_max_in_band"] > 100.0

  test "an impedance above target is reported against that target":
    let nl = rail([(desig: "C1", value: "100n", esr: "0.02", esl: "1e-9")])
    var spec = defaultPdnSpec()
    spec.targetZ = 0.001
    let r = analyzePdn(nl, "vdd", spec = spec)
    var found = false
    for i in r.issues:
      if i.kind == KindImpedanceExceedsTarget:
        found = true
        check "target" in i.message
    check found
