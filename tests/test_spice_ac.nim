import std/[complex, math, os, tables, unittest]

import verax/netlist
import verax/spice/ngspice

let haveNgspice = findExe("ngspice").len > 0

proc realResult(): SimResult =
  result.plotName = "Transient Analysis"
  result.dataKind = sdReal
  var v = newSimVector("v(out)", sdReal)
  v.values = @[1.0, -2.0, 0.0]
  result.vectors["v(out)"] = v

proc complexResult(): SimResult =
  ## |1+0j| = 1 (0 dB, 0 deg); |0-1j| = 1 (0 dB, -90 deg);
  ## |3+4j| = 5 (~13.979 dB).
  result.plotName = "AC Analysis"
  result.dataKind = sdComplex
  var f = newSimVector("frequency", sdComplex)
  f.cvalues = @[complex64(10.0, 0.0), complex64(100.0, 0.0), complex64(1000.0, 0.0)]
  result.vectors["frequency"] = f
  var v = newSimVector("v(out)", sdComplex)
  v.cvalues = @[complex64(1.0, 0.0), complex64(0.0, -1.0), complex64(3.0, 4.0)]
  result.vectors["v(out)"] = v

test "a real vector reads through [] and refuses the complex accessors":
  let r = realResult()
  check r["v(out)"] == @[1.0, -2.0, 0.0]
  check r.mag("v(out)") == @[1.0, 2.0, 0.0]
  expect(SpiceSimError):
    discard r.cplx("v(out)")
  expect(SpiceSimError):
    discard r.phaseDeg("v(out)")

test "a complex vector refuses [] rather than handing back only the real part":
  let r = complexResult()
  expect(SpiceSimError):
    discard r["v(out)"]

test "magnitude, dB and phase of a complex vector":
  let r = complexResult()
  let m = r.mag("v(out)")
  check abs(m[0] - 1.0) < 1e-12
  check abs(m[1] - 1.0) < 1e-12
  check abs(m[2] - 5.0) < 1e-12

  let d = r.db("v(out)")
  check abs(d[0] - 0.0) < 1e-12
  check abs(d[2] - 20.0 * log10(5.0)) < 1e-12

  let p = r.phaseDeg("v(out)")
  check abs(p[0] - 0.0) < 1e-9
  check abs(p[1] - (-90.0)) < 1e-9

test "the frequency axis comes back real even though ngspice writes it complex":
  check complexResult().freq() == @[10.0, 100.0, 1000.0]

test "a zero magnitude yields -Inf dB rather than raising":
  let r = realResult()
  check r.db("v(out)")[2] == -Inf

test "phase unwrapping removes the arctan2 discontinuity":
  check unwrapDeg(@[170.0, -170.0, -150.0]) == @[170.0, 190.0, 210.0]

test "a missing vector still raises KeyError, as spice_fallback relies on":
  let r = realResult()
  expect(KeyError):
    discard r["v(nosuchnet)"]

proc rcLowPass(): Netlist =
  ## R=1k, C=100n -> f_c = 1/(2*pi*R*C) = 1591.549... Hz
  result = newNetlist("rc_lowpass")
  let vin = addNet(result, newNet("vin"))
  let vout = addNet(result, newNet("vout"))
  let gnd = addNet(result, newNet("0", ntGround))

  let v1 = addComponent(result, newComponent("V1", kind = "voltage_source"))
  discard connect(v1, "+", vin)
  discard connect(v1, "-", gnd)
  v1.attrs["value"] = "DC 0 AC 1"

  let r1 = addComponent(result, newComponent("R1", kind = "resistor"))
  discard connect(r1, "1", vin, ptPassive)
  discard connect(r1, "2", vout, ptPassive)
  r1.attrs["value"] = "1k"

  let c1 = addComponent(result, newComponent("C1", kind = "capacitor"))
  discard connect(c1, "1", vout, ptPassive)
  discard connect(c1, "2", gnd, ptPassive)
  c1.attrs["value"] = "100n"

if not haveNgspice:
  echo "SKIP: ngspice not found on PATH, skipping real-simulation tests"
else:
  test "a real .ac run of an RC low-pass matches the closed-form response":
    let nl = rcLowPass()
    # The corner is deliberately a sweep point: `dec 20` from 100 Hz places
    # points at 100 * 10^(k/20), and none lands exactly on 1591.5 Hz, so this
    # also exercises reading a point either side of the corner.
    let res = run(nl, @[".ac dec 20 100 100k"])
    check res.plotName == "AC Analysis"
    check res.dataKind == sdComplex

    let f = res.freq()
    let m = res.mag("v(vout)")
    let p = res.phaseDeg("v(vout)")
    check f.len == m.len
    check f.len > 40

    let fc = 1.0 / (2.0 * PI * 1000.0 * 100e-9)

    # Find the sweep point nearest the corner and check it against the exact
    # first-order response at that same frequency (not against 1/sqrt(2) at a
    # frequency the sweep never visits).
    var best = 0
    for i in 1 ..< f.len:
      if abs(f[i] - fc) < abs(f[best] - fc): best = i
    let ratio = f[best] / fc
    let expectMag = 1.0 / sqrt(1.0 + ratio * ratio)
    let expectPhase = -radToDeg(arctan(ratio))
    check abs(m[best] - expectMag) < 1e-4
    check abs(p[best] - expectPhase) < 1e-3

    # Deep in the stopband a first-order roll-off is -20 dB/decade.
    let d = res.db("v(vout)")
    check abs((d[^1] - d[^21]) - (-20.0)) < 0.2

  test "an .ac result refuses to be read as real all the way through run()":
    let res = run(rcLowPass(), @[".ac dec 10 1k 10k"])
    expect(SpiceSimError):
      discard res["v(vout)"]

  test "a .op run is still real after the variant change":
    let res = run(rcLowPass(), @[".op"])
    check res.dataKind == sdReal
    check abs(res["v(vin)"][0] - 0.0) < 1e-9
