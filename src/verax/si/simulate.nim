## One forward SI run: an `SiNet` and a `Stimulus` in, an `SiResult` out --
## the waveform and current at every die pad and pin, with the decision-6
## status so a failed or unsupported run can never be read as a waveform.
##
## Lossy lines become an RLGC ladder through the linear core. Section count
## rule: each section's delay is at most `ladderFraction * tr` (default
## 1/10); `ladderMultiplier` scales the count for the convergence test
## (doubling it must change the answer by less than the tolerance).

import std/[math, strutils]
import ./topology
import ./drive
import ./engine/transient
import ./engine/ibisdev
import ../netlist/annotations

export topology, drive, transient

type
  SiStatus* = enum
    ssOk             ## simulated; the waveform is valid
    ssUnsupported    ## input/model support missing -> `esNotEvaluable`
    ssSolverFailed   ## Newton gave up -> `esNotEvaluated`

  SiWave* = object
    label*: string
    node*: int
    v*: seq[float]
    i*: seq[float]
      ## Current out of the die into the package (die waves only).

  SiOptions* = object
    tStop*: float
      ## `NaN`: the drive's last change + 10x the total line delay + 3 tr.
    hMax*: float
    newton*: NewtonOptions
    maxHalvings*: int
    lumpFraction*: float
    ladderFraction*: float
    ladderMultiplier*: float

  SiResult* = object
    status*: SiStatus
    reason*: string
    net*: string
    stimulus*: Stimulus
    t*: seq[float]
    driver*, driverPin*: SiWave
    receivers*, receiverPins*: seq[SiWave]
    nodes*: seq[string]
    v*: seq[seq[float]]
      ## Every node, `[node][step]`.
    rails*: Rails
    tr*: float
    hBase*: float
    steps*: int
    ladders*: seq[tuple[label: string, sections: int]]
    lumped*: seq[string]
    assumptions*: seq[Assumption]
    issues*: seq[Issue]

proc defaultSiOptions*(): SiOptions =
  SiOptions(tStop: NaN, hMax: Inf, newton: defaultNewton(), maxHalvings: 10,
            lumpFraction: 0.05, ladderFraction: 0.1, ladderMultiplier: 1.0)

proc totalDelay(n: SiNet): float =
  for e in n.elements:
    case e.kind
    of sekLine: result += e.td
    of sekLossyLine: result += e.length * sqrt(e.l * e.c)
    else: discard

proc simulate*(net: SiNet, stim: Stimulus, o = defaultSiOptions()): SiResult =
  result = SiResult(net: net.name, stimulus: stim, nodes: net.nodes,
                    assumptions: net.assumptions, issues: net.issues,
                    rails: net.driver.rails)
  if net.unsupported.len > 0:
    result.status = ssUnsupported
    result.reason = net.unsupported.join("; ")
    return
  let dw = driveWaves(net.driver, stim)
  result.issues.add dw.issues
  if not dw.supported:
    result.status = ssUnsupported
    result.reason = dw.reason
    return
  result.tr = dw.tr
  var c = newCircuit()
  for k in 1 ..< net.nodes.len: discard c.addNode(net.nodes[k])
  for e in net.elements:
    case e.kind
    of sekResistor: c.resistors.add Res(a: e.a, b: e.b, r: e.value, label: e.label)
    of sekInductor: c.inductors.add Ind(a: e.a, b: e.b, l: e.value, label: e.label)
    of sekCapacitor: c.capacitors.add Cap(a: e.a, b: e.b, c: e.value, label: e.label)
    of sekVoltage: c.vsources.add VSrc(a: e.a, b: e.b, wave: constPwl(e.value), label: e.label)
    of sekLine: c.lines.add Line(a: e.a, b: e.b, z0: e.z0, td: e.td, label: e.label)
    of sekLossyLine:
      let td = e.length * sqrt(e.l * e.c)
      var n =
        if dw.tr.isNaN: 10
        else: max(1, int(ceil(td / (o.ladderFraction * dw.tr))))
      n = max(1, int(ceil(n.float * o.ladderMultiplier)))
      result.ladders.add (e.label, n)
      let dx = e.length / n.float
      var prev = e.a
      for k in 0 ..< n:
        let mid = c.addNode(e.label & ":r" & $k)
        let nxt = if k == n - 1: e.b else: c.addNode(e.label & ":n" & $(k + 1))
        c.resistors.add Res(a: prev, b: mid, r: e.r * dx, label: e.label)
        c.inductors.add Ind(a: mid, b: nxt, l: e.l * dx, label: e.label)
        for nd in [prev, nxt]:
          c.capacitors.add Cap(a: nd, b: 0, c: e.c * dx / 2, label: e.label)
          if e.g > 0: c.resistors.add Res(a: nd, b: 0, r: 2.0 / (e.g * dx), label: e.label)
        prev = nxt
      result.assumptions.add note(e.label,
        "lossy line as a " & $n & "-section RLGC ladder, RLGC taken at one frequency")
  # Buffers.
  let dp = net.driverPort
  c.devices.add driverDevice(net.driver, dp.dieNode, dw.ku, dw.kd, dp.label)
  let dCap = c.capacitors.len
  c.capacitors.add Cap(a: dp.dieNode, b: 0, c: net.driver.cComp, label: dp.label & " C_comp")
  var rCaps: seq[int]
  for k, r in net.receivers:
    let p = net.receiverPorts[k]
    c.devices.add receiverDevice(r, p.dieNode, p.label)
    rCaps.add c.capacitors.len
    c.capacitors.add Cap(a: p.dieNode, b: 0, c: r.cComp, label: p.label & " C_comp")
  # Run.
  var so = defaultSimOptions(o.tStop)
  if so.tStop.isNaN:
    let tr = if dw.tr.isNaN: 1e-9 else: dw.tr
    so.tStop = max(dw.lastChange + 10.0 * totalDelay(net) + 3.0 * tr, 2e-9)
  so.hMax = o.hMax
  so.tr = dw.tr
  so.newton = o.newton
  so.maxHalvings = o.maxHalvings
  so.lumpFraction = o.lumpFraction
  let tr = transient(c, so)
  result.issues.add tr.issues
  result.hBase = tr.hBase
  result.steps = tr.steps
  result.lumped = tr.lumped
  if not tr.ok:
    result.status = ssSolverFailed
    result.reason = tr.failure
    return
  result.status = ssOk
  result.t = tr.t
  result.v = tr.v[0 ..< net.nodes.len]
  proc dieWave(label: string, node, dev, cap: int): SiWave =
    result = SiWave(label: label & ":die", node: node, v: tr.v[node])
    result.i = newSeq[float](tr.t.len)
    for k in 0 ..< tr.t.len: result.i[k] = tr.devI[dev][k] - tr.capI[cap][k]
  result.driver = dieWave(dp.label, dp.dieNode, 0, dCap)
  result.driverPin = SiWave(label: dp.label & ":pin", node: dp.pinNode, v: tr.v[dp.pinNode])
  for k, p in net.receiverPorts:
    result.receivers.add dieWave(p.label, p.dieNode, k + 1, rCaps[k])
    result.receiverPins.add SiWave(label: p.label & ":pin", node: p.pinNode, v: tr.v[p.pinNode])
