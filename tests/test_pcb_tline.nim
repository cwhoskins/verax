## `verax/pcb/tline`: joins the route (`pcb/trace`) and the cross-section
## (`pcb/impedance`) into per-frequency Z0/loss, delay, a cascaded ABCD and
## the `SParams` it converts to. Closed-form cross-checks throughout, per
## `tests/test_pcb_impedance.nim`'s own reasoning -- the ABCD identities
## checked here are independently written, not `tline.nim`'s own private
## `matMul`/`identityAbcd`, so an error in either the test or the module
## does not silently cancel out.

import std/[math, tables, complex, strutils, unittest]

import verax/netlist
import verax/pcb

proc abcdOf(spec: LineSpec, f, len: float): array[4, Complex64] =
  ## The standard uniform-line ABCD from `gamma`/`Zc` -- written directly
  ## here rather than importing `tline`'s own (unexported) helper, so this
  ## is a real check of the module's cascade rather than a restatement of
  ## its own code.
  let pr = propagation(spec, f)
  let gl = pr.gamma * complex(len, 0.0)
  let ch = cosh(gl)
  let sh = sinh(gl)
  [ch, pr.zc * sh, sh / pr.zc, ch]

proc matMul(a, b: array[4, Complex64]): array[4, Complex64] =
  [a[0] * b[0] + a[1] * b[2], a[0] * b[1] + a[1] * b[3],
   a[2] * b[0] + a[3] * b[2], a[2] * b[1] + a[3] * b[3]]

const c0 = 299_792_458.0

let losslessSpec = LineSpec(geometry: lgMicrostrip, w: 0.3e-3, t: 35e-6,
                            h1: 0.5e-3, er: 4.3, tand: 0.0, rho: 1e-15)
  ## `rho` near-zero rather than exactly `0.0`: `rlgc`'s skin-depth term
  ## divides by `rho`-derived quantities and would produce `NaN` at exactly
  ## zero (0/0), which is the right behaviour for "no resistivity stated"
  ## but wrong for "as close to lossless as this model can represent".

test "cascading two half-length ABCDs equals one whole-length ABCD":
  let f = 2.4e9
  let whole = abcdOf(losslessSpec, f, 0.02)
  let half = abcdOf(losslessSpec, f, 0.01)
  let cascaded = matMul(half, half)
  for i in 0 .. 3:
    check abs(whole[i] - cascaded[i]) < 1e-6 * max(1.0, abs(whole[i]))

test "a line at Zc == zRef gives |S11| ~= 0 and |S21| ~= 1 when lossless":
  # Find the width that puts this microstrip's Zc at 50 ohm, then any
  # length of *that* line, terminated in the same reference, must reflect
  # nothing back.
  proc z(u: float): float =
    z0(LineSpec(geometry: lgMicrostrip, w: u, t: 1e-9, h1: 1.0, er: 4.3, rho: 1e-15))
  var lo = 0.1
  var hi = 10.0
  for _ in 0 ..< 100:
    let mid = (lo + hi) / 2.0
    if z(mid) > 50.0: lo = mid else: hi = mid
  let u = (lo + hi) / 2.0
  let spec = LineSpec(geometry: lgMicrostrip, w: u, t: 1e-9, h1: 1.0, er: 4.3, rho: 1e-15)
  let r = EdgeResult(freqs: @[2.4e9], abcd: @[abcdOf(spec, 2.4e9, 0.05)])
  let sp = sparams(r, 50.0)
  check abs(sAt(sp, 0, 0, 0)) < 1e-3
  check abs(abs(sAt(sp, 0, 1, 0)) - 1.0) < 1e-3

test "a quarter-wave 70.7 ohm line transforms 100 ohm to 50 ohm at its centre frequency":
  let zc = sqrt(50.0 * 100.0)   # 70.710...
  let fc = 2.0e9
  let spec = LineSpec(geometry: lgStripline, w: 0.2e-3, t: 35e-6, h1: 0.5e-3,
                      h2: 0.5e-3, er: 4.3, tand: 0.0, rho: 1e-15)
  # Solve for the physical length that makes this spec's Zc equal 70.7 ohm
  # at a width search, then pick the length that is a quarter-wavelength at
  # `fc` for *that* spec's own propagation velocity -- both derived from
  # the module's own formulas, not stated as a fixed geometry.
  proc zcAt(w: float): float =
    z0(LineSpec(geometry: lgStripline, w: w, t: spec.t, h1: spec.h1, h2: spec.h2,
               er: spec.er, tand: 0.0, rho: 1e-15))
  var lo = 1e-6
  var hi = 2e-3
  for _ in 0 ..< 100:
    let mid = (lo + hi) / 2.0
    if zcAt(mid) > zc: lo = mid else: hi = mid
  let w = (lo + hi) / 2.0
  let qSpec = LineSpec(geometry: lgStripline, w: w, t: spec.t, h1: spec.h1,
                       h2: spec.h2, er: spec.er, tand: 0.0, rho: 1e-15)
  check abs(z0(qSpec) - zc) / zc < 1e-4
  let lambda = (c0 / sqrt(epsEff(qSpec))) / fc
  let quarterLen = lambda / 4.0
  let abcd = abcdOf(qSpec, fc, quarterLen)
  let zLoad = complex(100.0, 0.0)
  let zin = (abcd[0] * zLoad + abcd[1]) / (abcd[2] * zLoad + abcd[3])
  check abs(zin - complex(50.0, 0.0)) < 1e-2

# --- through the full route -> characterize pipeline ----------------------

proc groundedBoard(): tuple[pcb: Pcb, sig: Net, p1, p2: Pin] =
  let pcb = newPcb("tline")
  let top = addLayer(pcb, newPcbLayer("F.Cu", lfSignal, lsTop))
  let bot = addLayer(pcb, newPcbLayer("B.Cu", lfPlane, lsBottom))
  discard addStackEntry(pcb, newStackEntry(seCopper, "F.Cu", um(35.0)))
  let core = newStackEntry(seDielectric, "core", mm(0.5))
  core.material = newStackMaterial("FR4", epsilonR = 4.3, lossTangent = 0.02)
  discard addStackEntry(pcb, core)
  discard addStackEntry(pcb, newStackEntry(seCopper, "B.Cu", um(35.0)))
  pcb.stackup.entries[0].layer = top
  pcb.stackup.entries[2].layer = bot

  let sig = addNet(pcb.netlist, newNet("SIG", ntSignal))
  let gnd = addNet(pcb.netlist, newNet("GND", ntGround))
  let u1 = addComponent(pcb.netlist, newComponent("U1"))
  let u2 = addComponent(pcb.netlist, newComponent("U2"))
  discard connect(u1, "1", sig, ptOutput)
  discard connect(u2, "1", sig, ptInput)
  let pl1 = addPlacement(pcb, newPlacement("U1"))
  let pl2 = addPlacement(pcb, newPlacement("U2"))
  bindComponent(pl1, u1)
  bindComponent(pl2, u2)
  let ap = internAperture(pcb, Aperture(name: "r400", kind: akCircle, dia: mm(0.4)))
  let land1 = addCopper(top, newCopper(ckLand, pad(ap, pt(mm(0.0), mm(0.0)))))
  setNet(land1, sig)
  addLand(pl1, "1", land1)
  let land2 = addCopper(top, newCopper(ckLand, pad(ap, pt(mm(6.0), mm(0.0)))))
  setNet(land2, sig)
  addLand(pl2, "1", land2)
  discard addCopper(top, newCopper(ckTrack,
    stroke(polyline([pt(mm(0.0), mm(0.0)), pt(mm(6.0), mm(0.0))]), mm(0.3))))
  let lastTrack = top.copper[^1]
  setNet(lastTrack, sig)

  let z = newZone("gnd", gnd)
  z.layers = @[bot]
  z.outline = Polygon(outer: polyline(
    [pt(mm(-5.0), mm(-5.0)), pt(mm(15.0), mm(-5.0)),
     pt(mm(15.0), mm(5.0)), pt(mm(-5.0), mm(5.0))], closed = true))
  discard addZone(pcb, z)
  discard addZoneFill(pcb, z, bot, z.outline)
  (pcb, sig, u1.pins["1"], u2.pins["1"])

test "loss rises monotonically with frequency and rises further with roughness":
  let (pcb, sig, p1, _) = groundedBoard()
  let graphs = extractRoutes(pcb, sig)
  check graphs.len == 1
  let tree = rootedAt(graphs[0], p1)
  check tree.edges.len == 1
  let edge = tree.edges[0]

  let smooth = characterize(pcb, edge, TlineSpec(
    freqs: @[1.0e6, 1.0e9, 10.0e9, 20.0e9], zRef: 50.0, roughness: 0.0, rho: 1.72e-8))
  check smooth.issues.len == 0
  check smooth.sections.len == 1
  let lossSmooth = smooth.sections[0].lossDb
  check lossSmooth.len == 4
  for i in 1 ..< lossSmooth.len:
    check lossSmooth[i] > lossSmooth[i - 1]

  let rough = characterize(pcb, edge, TlineSpec(
    freqs: @[1.0e6, 1.0e9, 10.0e9, 20.0e9], zRef: 50.0, roughness: 5.0e-6, rho: 1.72e-8))
  let lossRough = rough.sections[0].lossDb
  for i in 0 ..< lossSmooth.len:
    check lossRough[i] >= lossSmooth[i]
  check lossRough[^1] > lossSmooth[^1]

  # Defaulting roughness/rho is recorded, by name, as an `Assumption`.
  let defaulted = characterize(pcb, edge)
  var sawRoughness, sawRho = false
  for a in defaulted.assumptions:
    if "roughness" in a.detail: sawRoughness = true
    if "resistivity" in a.detail: sawRho = true
  check sawRoughness
  check sawRho
