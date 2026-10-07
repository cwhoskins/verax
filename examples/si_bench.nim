## The stage-3 timing benchmark of docs/ibis_simulator_plan.md: one edge on
## a point-to-point net and on a three-drop daisy chain, best of 10. A
## documented benchmark, not a CI assertion (CI hardware varies).
##
##   nim c -d:release -r --path:./src examples/si_bench.nim
##
## Recorded 2026-10-07 on an i7-13700H, `-d:release`: 0.74 ms (512 steps,
## 6 nodes) and 2.35 ms (562 steps, 15 nodes) against a ~10 ms target.

import std/[streams, times, monotimes, strutils]
import verax/ibis
import verax/si/simulate
import ../tests/fixtures/ibis/synthetic

var d = defaultLinearDriver()
d.cComp = 2e-12
d.samples = 201
let b = driverBehaviour(readIbis(newStringStream(d.toIbs())).model(d.name))
let rx = receiverBehaviour(readIbis(newStringStream(linearReceiverIbs())).model("lin_rx"))
let pkg = PackageRlc(r: 0.2, l: 2e-9, c: 0.5e-12)
proc tmpl(n: int, topo: TemplateTopology): SiTemplate =
  result = SiTemplate(name: "b", driver: b, topology: topo,
                      driverPort: TemplatePort(label: "U1.1", pkg: pkg), line: idealLine(50.0, 6.67e-9))
  for k in 0 ..< n:
    result.receivers.add rx
    result.receiverPorts.add TemplatePort(label: "U" & $(k+2) & ".1", pkg: pkg)
for (name, t, p) in [("single edge, point-to-point 150 mm", tmpl(1, ttPointToPoint), templateParams(0.15)),
                     ("single edge, three-drop daisy chain 150 mm", tmpl(3, ttDaisyChain), templateParams(0.15, stubLength = 0.01))]:
  let net = t.build(p)
  var best = Inf
  var steps = 0
  for _ in 0 ..< 10:
    let t0 = getMonoTime()
    let r = simulate(net, edgeStimulus(edRising))
    let dt = (getMonoTime() - t0).inNanoseconds.float / 1e6
    best = min(best, dt)
    steps = r.steps
  echo name, ": ", formatFloat(best, ffDecimal, 2), " ms (", steps, " steps, ", net.nodes.len - 1, " nodes)"
