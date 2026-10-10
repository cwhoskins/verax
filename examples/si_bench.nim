## The SI timing benchmarks of docs/ibis_simulator_plan.md (stages 3 and 7),
## best of 10. Documented benchmarks, not CI assertions (CI hardware
## varies).
##
##   nim c -d:release -r --path:./src examples/si_bench.nim
##
## Recorded 2026-10-07 on an i7-13700H, `-d:release` (stage 3 figures,
## before stage 7, in brackets):
##
## - one edge, point-to-point: 0.44 ms [0.74 ms]
## - one edge, three-drop daisy chain: 1.11 ms [2.35 ms]
## - 3 corners x 3 receivers, both edges + ISI patterns at 10 ns: 10.9 ms
##   (15.9 ms running every pattern instead of only where an edge does not
##   settle within the UI)
## - 0.3 m lossy line: ladder 4.80 ms (23 sections), recursive convolution
##   1.67 ms

import std/[streams, times, monotimes, strutils]
import verax/ibis
import verax/pcb/impedance
import verax/si/simulate
import verax/si/sweep
import ../tests/fixtures/ibis/synthetic

proc best(f: proc()): float =
  result = Inf
  for _ in 0 ..< 10:
    let t0 = getMonoTime()
    f()
    result = min(result, (getMonoTime() - t0).inNanoseconds.float / 1e6)

proc ms(x: float): string = formatFloat(x, ffDecimal, 2) & " ms"

var d = defaultLinearDriver()
d.cComp = 2e-12
d.samples = 201
let b = driverBehaviour(readIbis(newStringStream(d.toIbs())).model(d.name))
let rx = receiverBehaviour(readIbis(newStringStream(linearReceiverIbs())).model("lin_rx"))
let pkg = PackageRlc(r: 0.2, l: 2e-9, c: 0.5e-12)
proc tmpl(n: int, topo: TemplateTopology, drv = b, line = idealLine(50.0, 6.67e-9)): SiTemplate =
  result = SiTemplate(name: "b", driver: drv, topology: topo,
                      driverPort: TemplatePort(label: "U1.1", pkg: pkg), line: line)
  for k in 0 ..< n:
    result.receivers.add rx
    result.receiverPorts.add TemplatePort(label: "U" & $(k+2) & ".1", pkg: pkg)

for (name, t, p) in [("single edge, point-to-point 150 mm", tmpl(1, ttPointToPoint), templateParams(0.15)),
                     ("single edge, three-drop daisy chain 150 mm", tmpl(3, ttDaisyChain), templateParams(0.15, stubLength = 0.01))]:
  let net = t.build(p)
  var r: SiResult
  let x = best(proc() = r = simulate(net, edgeStimulus(edRising)))
  echo name, ": ", ms(x), " (", r.steps, " steps, ", net.nodes.len - 1,
    " nodes, ", r.factorizations, " LU factorisations for ", r.solves, " solves)"

# Stage 7 exit: 3 corners x 3 receivers.
const corners3 = """
[IBIS Ver] 3.2
[Component] C
[Pin] signal_name model_name
1 OUT drv
[Model] drv
Model_type Output
C_comp 1p 0.8p 1.2p
Vmeas = 1.65
Rref = 50
[Voltage Range] 3.3 3.0 3.6
[Pulldown]
-3.3 -0.066 -0.06  -0.072
 6.6  0.132  0.12   0.144
[Pullup]
-3.3  0.066  0.06   0.072
 6.6 -0.132 -0.12  -0.144
[Ramp]
dV/dt_r 1.98/0.6n 1.8/0.9n 2.16/0.3n
dV/dt_f 1.98/0.6n 1.8/0.9n 2.16/0.3n
[End Model]
[End]
"""
let m3 = readIbis(newStringStream(corners3)).model("drv")
var cs: seq[SweepCorner]
for c in [coTyp, coMin, coMax]:
  cs.add SweepCorner(corner: c, net: tmpl(3, ttDaisyChain, driverBehaviour(m3, c)).build(
    templateParams(0.15, stubLength = 0.01)))
for (label, skip) in [("patterns where needed", true), ("patterns always", false)]:
  var o = defaultSweepOptions()
  o.skipSettledPatterns = skip
  var sw: SiSweep
  let x = best(proc() = sw = sweepNet(cs, sweepStimuli(10e-9), o))
  var runs, steps = 0
  for r in sw.runs:
    if not r.skipped: inc runs
    steps += r.steps
  echo "3 corners x 3 receivers, edges + ISI at 10 ns (", label, "): ", ms(x), " (", runs,
    " runs, ", steps, " steps)"

# Lossy line: ladder vs recursive convolution.
let spec = LineSpec(geometry: lgMicrostrip, w: 0.1e-3, t: 35e-6, h1: 0.1e-3, er: 4.3,
                    tand: 0.02, rho: 1.72e-8)
let lossy = tmpl(1, ttPointToPoint, line = lineSection(spec, lossy = true)).build(templateParams(0.3))
for (label, lm) in [("ladder", lmLadder), ("recursive convolution", lmConvolution)]:
  var o = defaultSiOptions()
  o.lossyModel = lm
  var r: SiResult
  let x = best(proc() = r = simulate(lossy, edgeStimulus(edRising), o))
  echo "0.3 m lossy line, ", label, ": ", ms(x), " (", r.steps, " steps",
    (if r.ladders.len > 0: ", " & $r.ladders[0].sections & " sections" else: ""), ")"
