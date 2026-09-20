## Joins the route (`pcb/trace`) and the cross-section (`pcb/impedance`):
## per-frequency Z0 and loss, propagation delay, a cascaded ABCD matrix and
## the `SParams` it converts to.
##
## `specFor` is the only place that turns board data into a `LineSpec` --
## everything numeric past that point is `pcb/impedance`'s pure arithmetic,
## unchanged. It classifies a section as stripline the moment
## `RouteSection.reference.opposite` is set (both sides independently
## cleared `RouteSpec.minCoverage` in `trace.resolveReference`) and as
## microstrip otherwise, `lgCoveredMicrostrip` when the stackup's own solder
## mask entry sits directly outside the trace layer -- "covered" is read off
## the board, never assumed.
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
      ## Hz. Default a log sweep 1 MHz .. 20 GHz, 10 points/decade -- enough
      ## to place a corner without costing seconds on a whole net's worth of
      ## edges (`nimble traces` is what proved that budget against the real
      ## corpus, not a guess).
    zRef*: float
    roughness*: float
      ## RMS copper roughness, metres. No board format states this per-trace
      ## (`pcb/CLAUDE.md`); `0` (smooth) is the default, and `characterize`
      ## records that default as an `Assumption` naming which edge rests on
      ## it, on the same discipline every `spice/models` expander follows
      ## for an invented input -- loss computed at `roughness = 0` is a
      ## lower bound, not a measurement.
    rho*: float
      ## Conductor resistivity, ohm-metre. Defaults to annealed copper at
      ## 20 degC, `1.72e-8` -- also recorded as an `Assumption` when a
      ## caller leaves it at that default, for the same reason.

  SectionResult* = object
    spec*: LineSpec
    z0*: seq[float]
      ## `|Zc|` per frequency in `freqs`. Empty when the section's return
      ## path never resolved (`RouteSection.reference.layer == nil`) --
      ## `NaN` per-sample would still need a caller to check every entry;
      ## an empty `seq` is the same refusal stated once.
    gamma*: seq[Complex64]
    delay*: float
      ## Seconds, lossless (`impedance.delayPerMetre * length`). `NaN` when
      ## undetermined for the same reason `z0` is empty.
    lossDb*: seq[float]
      ## Insertion loss of this section alone, per frequency: `alpha * L`
      ## converted from nepers to dB.

  EdgeResult* = object
    edge*: RouteEdge
    sections*: seq[SectionResult]
    length*, delay*: float
    freqs*: seq[float]
      ## The frequency axis `abcd` (and every `SectionResult.z0`/`gamma`) is
      ## indexed against -- a copy of the `TlineSpec.freqs` that produced
      ## this result, carried on the result itself rather than only on the
      ## input, because `sparams` needs a real axis to hand `SParams.freqs`
      ## and reaches it through `r`, not through a second parameter the
      ## plan's own `sparams*(r: EdgeResult, zRef = 50.0)` signature has no
      ## room for. Deviation from the plan's literal `EdgeResult` field list,
      ## noted here rather than silently: without it `sparams` would have to
      ## either guess a frequency axis or hand back an `SParams` whose
      ## `freqs` lied by repeating one placeholder value, and a wrong axis
      ## is worse than an extra field.
    abcd*: seq[array[4, Complex64]]
      ## Cascaded over every section, per frequency in `freqs` -- the matrix
      ## product in section order, standard two-port cascade convention
      ## (`[A B; C D]` multiplied left to right along the edge).
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
  ## Does a solder-mask stack entry sit directly outside this copper layer?
  ## An inner layer is never "covered" in this sense -- it is either
  ## unresolved or already classified as a stripline family by `specFor`
  ## before this is even asked.
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
  ## Builds the pure-numeric `LineSpec` `pcb/impedance` needs from one
  ## already-resolved `RouteSection`. Deliberately does **not** special-case
  ## an unresolved reference (`s.reference.layer == nil`): `noReferencePath`
  ## already leaves `height`/`er`/`tand` at `NaN`, which propagates through
  ## every `impedance` formula to a `NaN` `z0` on its own -- the house rule
  ## working exactly as intended, with no second refusal path to keep in
  ## sync with the first.
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
      # Both planes clamp the field, so both dielectrics' material figures
      # in proportion to how much of the gap each occupies.
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
  ## `1 Np = 20/ln(10) dB ~= 8.6859 dB` -- the conversion between the natural
  ## attenuation unit `gamma.re` (`alpha`) comes out in from `propagation`
  ## and the dB figure `lossDb` reports.

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
  ## Converts the cascaded ABCD to a 2-port `S` matrix at `zRef`, reusing
  ## `verax/touchstone`'s own type and row-major convention rather than a
  ## second matrix shape -- see this module's doc comment on why that is the
  ## one edge `pcb/` gains to a module outside its own dependency tree
  ## (`touchstone` imports only `std/[complex, math]`, so it stays a leaf).
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
  ## `nSections` equal lumped RLGC subsections at frequency `f`, as plain
  ## data -- deliberately not a `Netlist`: building one would pull in
  ## device-kind and `formats/spice.nim` work this scope excludes (see the
  ## module doc's scope note). Each subsection is `1/nSections` of the
  ## edge's total length; which of the edge's own (possibly several, at
  ## different widths) sections a given subsection falls in is resolved by
  ## walking each section's own physical length -- recovered from
  ## `delay / delayPerMetre(spec)` rather than carried as a separate field,
  ## since `SectionResult` already has everything needed to reconstruct it
  ## and a second length field would be one more thing to keep in sync with
  ## `RouteSection.length`.
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
  ## Delay difference between two paths, seconds -- what `intra_pair_skew`
  ## will call once a differential-pair adapter exists (see the plan's scope
  ## note: this module makes the quantity *computable*, a follow-up makes it
  ## *claimable*). Takes `pcb`/`t` rather than the plan's bare
  ## `skew*(a, b: seq[RouteEdge])`: a `RouteEdge`'s own geometry alone is not
  ## enough to know its propagation velocity -- that needs `specFor`'s
  ## stackup lookup and a frequency sweep is not even required for a
  ## lossless delay figure, but the classification (stripline vs microstrip,
  ## the `epsEff` fringing correction) still is, and inventing that
  ## classification from a `RouteEdge` alone would be exactly the kind of
  ## guess this codebase refuses to make silently.
  proc pathDelay(edges: seq[RouteEdge]): float =
    for e in edges:
      let r = characterize(pcb, e, t)
      if r.delay.isNaN: return NaN
      result += r.delay
  pathDelay(a) - pathDelay(b)

proc delayTo*(pcb: Pcb, tree: RouteTree, p: Pin, t = defaultTlineSpec()): float =
  ## Sum of section delays from `tree.root` to the node carrying pin `p`.
  ## `NaN` when `p` is unreachable (`pathTo` returns `@[]`) or any section
  ## along the way never resolved a return path -- a partial delay figure
  ## that silently omitted the unresolved section would understate every
  ## downstream skew comparison.
  let path = pathTo(tree, p)
  if path.len == 0: return NaN
  for e in path:
    let r = characterize(pcb, e, t)
    if r.delay.isNaN: return NaN
    result += r.delay
