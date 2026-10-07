import std/[math, os, streams, strutils, tables, unittest]

import verax/netlist/dsl
import verax/netlist/graph
import verax/netlist/formats/spice
import verax/units
import verax/spice/models
import verax/spice/ngspice
import verax/spice/probes

let haveNgspice = findExe("ngspice").len > 0

proc bead(value = "600", extra: openArray[(string, string)] = []): Netlist =
  result = newNetlist("b")
  let a = addNet(result, newNet("a", ntSignal))
  let b = addNet(result, newNet("0", ntGround))
  let fb = addComponent(result, newComponent("FB1", kind = "ferrite_bead"))
  discard connect(fb, "1", a, ptPassive)
  discard connect(fb, "2", b, ptPassive)
  fb.attrs["value"] = value
  for (k, v) in extra: fb.attrs[k] = v

proc valueOf(nl: Netlist, d: string): float =
  discard parseSpiceMagnitude(nl.components[d].attrs["value"], result)

suite "a ferrite bead is not an inductor":
  # A bead's impedance peaks where the core goes lossy and falls again, and
  # it has a real DC resistance.

  test "it expands to the standard three-element model":
    let nl = bead()
    discard expandFerriteBeads(nl)
    check not nl.components.hasKey("FB1")
    for d in ["RFB1_DCR", "RFB1_RP", "LFB1_L", "CFB1_C"]:
      check nl.components.hasKey(d)

  test "the element values come from the datasheet numbers, not a fit":
    # R = z_peak - dcr, L = R/(w0*Q), C = Q/(w0*R): at f_peak the reactances
    # cancel and Z = R.
    let nl = bead("600", {"dcr": "0.1"})
    discard expandFerriteBeads(nl)
    let w0 = 2.0 * PI * 100.0e6
    check abs(valueOf(nl, "RFB1_DCR") - 0.1) < 1e-9
    check abs(valueOf(nl, "RFB1_RP") - 599.9) < 1e-6
    check abs(valueOf(nl, "LFB1_L") - 599.9 / w0) / (599.9 / w0) < 1e-9
    check abs(valueOf(nl, "CFB1_C") - 1.0 / (w0 * 599.9)) / (1.0 / (w0 * 599.9)) < 1e-9

  test "f_peak moves the peak, z_peak moves its height":
    let low = bead("600", {"f_peak": "10e6"})
    discard expandFerriteBeads(low)
    let high = bead("600", {"f_peak": "100e6"})
    discard expandFerriteBeads(high)
    # Ten times lower resonance: ten times the inductance.
    check abs(valueOf(low, "LFB1_L") / valueOf(high, "LFB1_L") - 10.0) < 1e-6

    let big = bead("1000")
    discard expandFerriteBeads(big)
    check valueOf(big, "RFB1_RP") > valueOf(high, "RFB1_RP")

  test "every invented input is declared":
    let nl = bead()
    let notes = expandFerriteBeads(nl)
    var sawDcr, sawFPeak, sawValue = false
    for n in notes:
      if "dcr" in $n: sawDcr = true
      if "f_peak" in $n: sawFPeak = true
      if "`value` read as" in $n: sawValue = true
    check sawDcr        # no dcr stated
    check sawFPeak      # no f_peak stated
    check sawValue      # value read by convention as ohms

  test "a stated value produces no assumption for it":
    let nl = bead("600", {"dcr": "0.35", "f_peak": "100e6", "z_peak": "600"})
    let notes = expandFerriteBeads(nl)
    for n in notes:
      check "typical for a small bead" notin $n
      check "datasheets quote" notin $n

  test "a bead that states nothing usable is left alone and says so":
    # `value` may be a source spec, never assumed numeric.
    let nl = bead("TBD")
    let notes = expandFerriteBeads(nl)
    check nl.components.hasKey("FB1")
    var told = false
    for n in notes:
      if "cannot be modelled" in $n: told = true
    check told

  test "expanding twice is not doubling":
    let nl = bead()
    discard expandFerriteBeads(nl)
    let after = nl.components.len
    discard expandFerriteBeads(nl)
    check nl.components.len == after

  test "no F device survives to the deck":
    # `isPassive` accepts beads, but SPICE has no bead device and reads `F`
    # as a CCCS.
    let nl = bead()
    discard expandPinModels(nl)          # the pass every analysis calls
    let s = newStringStream()
    writeNetlist(nl, s)
    for line in s.data.splitLines:
      check not line.startsWith("FB")
    check "RFB1_DCR" in s.data

  if not haveNgspice:
    echo "SKIP: ngspice not found on PATH"
  else:
    test "the impedance really does peak at z_peak, at f_peak":
      let nl = bead("600", {"dcr": "0.1"})
      discard expandFerriteBeads(nl)
      discard addImpedanceProbe(nl, nl.nets["a"], nl.nets["0"])
      let r = run(nl, @[".ac dec 100 1e5 1e9"])
      let f = r.freq()
      let z = r.mag("v(a)")
      var peak = 0.0
      var atF = 0.0
      for i in 0 ..< f.len:
        if z[i] > peak:
          peak = z[i]
          atF = f[i]
      check abs(peak - 600.0) / 600.0 < 0.01
      check abs(atF - 100.0e6) / 100.0e6 < 0.02

    test "and falls again above it, which an inductor would not":
      let nl = bead("600", {"dcr": "0.1"})
      discard expandFerriteBeads(nl)
      discard addImpedanceProbe(nl, nl.nets["a"], nl.nets["0"])
      let r = run(nl, @[".ac dec 100 1e5 1e9"])
      let f = r.freq()
      let z = r.mag("v(a)")
      var zAtPeak, zAbove = 0.0
      for i in 0 ..< f.len:
        if abs(f[i] - 100.0e6) / 100.0e6 < 0.02: zAtPeak = z[i]
        if abs(f[i] - 900.0e6) / 900.0e6 < 0.02: zAbove = z[i]
      check zAbove < zAtPeak * 0.5
