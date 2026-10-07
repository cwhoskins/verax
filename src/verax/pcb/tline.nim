## Joins the route (`pcb/trace`) and the cross-section (`pcb/impedance`):
## per-frequency Z0 and loss, delay, a cascaded ABCD matrix and `SParams`.
##
## `specFor` is the only board -> `LineSpec` step. A section is stripline
## when `reference.opposite` is set, else microstrip --
## `lgCoveredMicrostrip` when the stackup has solder mask directly outside
## the trace layer (read off the board, never assumed).
import std/[math, complex]

import ./units
import ./geometry
import ./types
import ./graph
import ./trace
import ./impedance
import ../netlist/issue
import ../netlist/annotations
import ../touchstone/types as touchstone

export trace, impedance, touchstone

type
  TlineSpec* = object
    freqs*: seq[float]
      ## Hz. Default log sweep 1 MHz .. 20 GHz, 10 points/decade.
    zRef*: float
    roughness*: float
      ## RMS copper roughness, metres. Default `0` (smooth), recorded as an
      ## `Assumption`; loss at `0` is a lower bound.
    rho*: float
      ## Conductor resistivity, ohm-metre. Default annealed copper at 20
      ## degC (`1.72e-8`), recorded as an `Assumption`.

  SectionResult* = object
    spec*: LineSpec
    z0*: seq[float]
      ## `|Zc|` per frequency. Empty when the return path never resolved.
    gamma*: seq[Complex64]
    delay*: float
      ## Seconds, lossless. `NaN` when undetermined (as for `z0`).
    lossDb*: seq[float]
      ## This section's insertion loss per frequency (`alpha * L` in dB).

  EdgeResult* = object
    edge*: RouteEdge
    sections*: seq[SectionResult]
    length*, delay*: float
    freqs*: seq[float]
      ## The frequency axis for `abcd` and every section's results, carried
      ## on the result so `sparams` can fill `SParams.freqs`.
    abcd*: seq[array[4, Complex64]]
      ## Cascaded ABCD per frequency: sections multiplied left to right.
    issues*: seq[Issue]
    assumptions*: seq[Assumption]

proc defaultTlineSpec*(): TlineSpec =
  var freqs: seq[float] = @[]
  const ptsPerDecade = 10
  const step = pow(10.0, 1.0 / ptsPerDecade.float)
  var f = 1.0e6
  while f <= 20.0e9 * 1.0001:
    freqs.add(f)
    f *= step
  TlineSpec(freqs: freqs, zRef: 50.0, roughness: 0.0, rho: 1.72e-8)

# ---------------------------------------------------------------- specFor

proc isMicrostripCovered(pcb: Pcb, l: PcbLayer): bool =
  ## Does solder mask sit directly outside this copper layer? Never for an
  ## inner layer.
  if pcb.stackup == nil or l == nil or l.side == lsInner: return false
  let entries = pcb.stackup.entries
  var idx = -1
  for i, e in entries:
    if e.layer == l:
      idx = i
      break
  if idx < 0: return false
  case l.side
  of lsTop: idx > 0 and entries[idx - 1].kind == seSolderMask
  of lsBottom: idx < entries.high and entries[idx + 1].kind == seSolderMask
  else: false

proc specFor*(pcb: Pcb, s: RouteSection, t: TlineSpec): LineSpec =
  ## The `LineSpec` for one resolved `RouteSection`. An unresolved reference
  ## isn't special-cased: its `NaN` height/er/tand propagate to a `NaN`
  ## `z0`.
  let w = toMetres(s.width)
  var thick = 0.0
  let se = stackEntryFor(pcb, s.layer)
  if se != nil: thick = toMetres(se.thickness)
  let rp = s.reference
  var geometry: LineGeometry
  var h1 = rp.height
  var h2 = 0.0
  var er = rp.er
  var tand = rp.tand
  if rp.opposite != nil:
    let opp = rp.opposite[]
    h2 = opp.height
    let wTotal = h1 + h2
    if wTotal > 0.0 and not (h1.isNaN or h2.isNaN):
    # Both planes clamp the field: weight each dielectric by its share of
    # the gap.
      er = (rp.er * h1 + opp.er * h2) / wTotal
      tand = (rp.tand * h1 + opp.tand * h2) / wTotal
    geometry =
      if h1 > 0.0 and h2 > 0.0 and abs(h1 - h2) <= 0.1 * max(h1, h2): lgStripline
      else: lgAsymStripline
  else:
    geometry = (if isMicrostripCovered(pcb, s.layer): lgCoveredMicrostrip
               else: lgMicrostrip)
  LineSpec(geometry: geometry, w: w, t: thick, h1: h1, h2: h2, s: 0.0,
          er: er, tand: tand, rho: t.rho, roughness: t.roughness)

# ---------------------------------------------------------------- characterize

proc nodeLabel(n: RouteNode): string =
  if n == nil: return "?"
  if n.pin != nil and n.pin.component != nil:
    return n.pin.component.designator & "." & n.pin.name
  case n.kind
  of rnVia: "via"
  of rnPour: "pour"
  of rnEnd: "open end"
  of rnPin: "pin"
  of rnJunction: "junction"

proc matMul(a, b: array[4, Complex64]): array[4, Complex64] =
  [a[0] * b[0] + a[1] * b[2], a[0] * b[1] + a[1] * b[3],
   a[2] * b[0] + a[3] * b[2], a[2] * b[1] + a[3] * b[3]]

proc identityAbcd(): array[4, Complex64] =
  [complex(1.0, 0.0), complex(0.0, 0.0), complex(0.0, 0.0), complex(1.0, 0.0)]

const NepersToDb = 20.0 / ln(10.0)
  ## `1 Np = 20/ln(10) dB ~= 8.6859 dB`.

proc characterize*(pcb: Pcb, e: RouteEdge, t = defaultTlineSpec()): EdgeResult =
  var issues: seq[Issue] = @[]
  var assumptions: seq[Assumption] = @[]
  let label = nodeLabel(e.a) & " -> " & nodeLabel(e.b)

  if e.a.kind == rnPour or e.b.kind == rnPour:
    issues.add(newIssue("route_through_pour", sevInfo,
      "edge " & label & " terminates in a copper pour, which is not a " &
      "transmission line and is not characterized"))
    return EdgeResult(edge: e, length: e.length, delay: NaN, freqs: t.freqs,
                      issues: issues, assumptions: assumptions)

  if t.roughness == 0.0:
    assumptions.add(note("edge " & label,
      "roughness defaulted to 0 (smooth) -- loss is a lower bound"))
  if t.rho == 1.72e-8:
    assumptions.add(note("edge " & label,
      "conductor resistivity defaulted to annealed copper at 20 degC " &
      "(1.72e-8 ohm-m)"))

  var secResults: seq[SectionResult] = @[]
  var chain: seq[array[4, Complex64]] = @[]
  for _ in t.freqs: chain.add(identityAbcd())
  var totalDelay = 0.0
  var usedCoveredMask = false

  for sec in e.sections:
    let spec = specFor(pcb, sec, t)
    if spec.geometry == lgCoveredMicrostrip: usedCoveredMask = true
    if sec.reference.layer == nil:
      let refLayerName = (if sec.layer != nil: sec.layer.name else: "?")
      issues.add(newIssue("route_no_reference", sevWarning,
        "edge " & label & ": section on " & refLayerName & " has no " &
        "resolved return path -- Z0 and loss are not computed"))
      secResults.add(SectionResult(spec: spec, delay: NaN))
      continue
    var z0s, lossDbs: seq[float] = @[]
    var gammas: seq[Complex64] = @[]
    for fi, f in t.freqs:
      let pr = propagation(spec, f)
      z0s.add(abs(pr.zc))
      gammas.add(pr.gamma)
      lossDbs.add(pr.gamma.re * sec.length * NepersToDb)
      let gl = pr.gamma * complex(sec.length, 0.0)
      let coshGl = cosh(gl)
      let sinhGl = sinh(gl)
      let secAbcd = [coshGl, pr.zc * sinhGl, sinhGl / pr.zc, coshGl]
      chain[fi] = matMul(chain[fi], secAbcd)
    let secDelay = delayPerMetre(spec) * sec.length
    totalDelay += secDelay
    secResults.add(SectionResult(spec: spec, z0: z0s, gamma: gammas,
                                 delay: secDelay, lossDb: lossDbs))

  if usedCoveredMask:
    assumptions.add(note("edge " & label,
      "solder-mask permittivity assumed at " & $impedance.TypicalSolderMaskEr &
      " (impedance.TypicalSolderMaskEr) -- the stackup states a mask " &
      "material but not this module's specific correction input"))

  EdgeResult(edge: e, sections: secResults, length: e.length, delay: totalDelay,
            freqs: t.freqs, abcd: chain, issues: issues, assumptions: assumptions)

proc characterize*(pcb: Pcb, tree: RouteTree, t = defaultTlineSpec()): seq[EdgeResult] =
  for e in tree.edges:
    result.add(characterize(pcb, e, t))

# ---------------------------------------------------------------- S-parameters

proc sparams*(r: EdgeResult, zRef = 50.0): SParams =
  ## The cascaded ABCD as a 2-port `S` matrix at `zRef`, using
  ## `verax/touchstone`'s type (a leaf module, so the dependency is safe).
  result.nPorts = 2
  result.z0 = zRef
  result.freqs = r.freqs
  result.points = @[]
  let z0c = complex(zRef, 0.0)
  for abcd in r.abcd:
    let a = abcd[0]
    let b = abcd[1]
    let c = abcd[2]
    let d = abcd[3]
    let denom = a + b / z0c + c * z0c + d
    let s11 = (a + b / z0c - c * z0c - d) / denom
    let s12 = (complex(2.0, 0.0) * (a * d - b * c)) / denom
    let s21 = complex(2.0, 0.0) / denom
    let s22 = (-a + b / z0c - c * z0c + d) / denom
    result.points.add(@[s11, s12, s21, s22])

proc ladder*(r: EdgeResult, f: float, nSections: int): seq[tuple[r, l, g, c: float]] =
  ## `nSections` equal lumped RLGC subsections at `f`, as plain data (not a
  ## `Netlist`). Each subsection's owning section is found by walking
  ## section lengths, recovered from `delay / delayPerMetre`.
  if nSections <= 0 or r.length <= 0.0: return
  let subLen = r.length / nSections.float
  var lens: seq[float] = @[]
  var totalLen = 0.0
  for s in r.sections:
    let len = (if s.delay.isNaN or s.z0.len == 0: 0.0 else: s.delay / delayPerMetre(s.spec))
    lens.add(len)
    totalLen += len
  if totalLen <= 0.0: return
  for i in 0 ..< nSections:
    let atLen = (i.float + 0.5) * subLen
    var walked = 0.0
    var chosen = 0
    for si, len in lens:
      if atLen <= walked + len or si == lens.high:
        chosen = si
        break
      walked += len
    let spec = r.sections[chosen].spec
    let rl = rlgc(spec, f)
    result.add((r: rl.r * subLen, l: rl.l * subLen, g: rl.g * subLen, c: rl.c * subLen))

proc skew*(pcb: Pcb, a, b: seq[RouteEdge], t = defaultTlineSpec()): float =
  ## Delay difference between two paths, seconds (for a future
  ## `intra_pair_skew`). Needs `pcb`/`t` because velocity depends on
  ## `specFor`'s stripline/microstrip classification.
  proc pathDelay(edges: seq[RouteEdge]): float =
    for e in edges:
      let r = characterize(pcb, e, t)
      if r.delay.isNaN: return NaN
      result += r.delay
  pathDelay(a) - pathDelay(b)

proc delayTo*(pcb: Pcb, tree: RouteTree, p: Pin, t = defaultTlineSpec()): float =
  ## Sum of section delays from `tree.root` to pin `p`. `NaN` if `p` is
  ## unreachable or any section lacks a return path (a partial sum would
  ## understate skew).
  let path = pathTo(tree, p)
  if path.len == 0: return NaN
  for e in path:
    let r = characterize(pcb, e, t)
    if r.delay.isNaN: return NaN
    result += r.delay
