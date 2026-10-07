## Closed-form via model: barrel inductance, pad/antipad capacitance and the
## **stub** (barrel beyond the layers the signal uses) as an open-ended line,
## so its quarter-wave resonance appears in a transient. Beside
## `pcb/impedance`, and like it pure numeric at the core (`viaModel` takes
## plain metres); `viaGeometryFor` is the one board -> geometry step.
##
## Formulas (H. Johnson & M. Graham, *High-Speed Digital Design*, 1993,
## chapter 7, "Vias"):
##
## - `C = 1.41 * er * T * D1 / (D2 - D1)` pF, `T` barrel length, `D1` pad
##   and `D2` antipad (clearance) diameter, all in inches.
## - `L = 5.08 * h * (ln(4h / d) + 1)` nH, `h` length and `d` drill, inches.
##
## Quasi-static and lumped, a few tens of percent from a field solve; every
## result carries that as an `Assumption` (`fem/` can replace it later).
## The stub is a line with the barrel's own per-length `L'`/`C'`.
##
## **A via whose two layers reference different planes is an `Issue`**
## (`via_reference_change`) -- the return-current transition is often as
## consequential as the barrel and is not modelled here.

import std/math
import ./units
import ./types
import ../netlist/issue
import ../netlist/annotations

type
  ViaGeometry* = object
    ## Plain metres. Depths are from the top of the barrel's span.
    drillDia*, padDia*, antipadDia*: float
    barrelLength*: float
    er*: float
    entryDepth*, exitDepth*: float
      ## Where the signal joins the barrel; order does not matter.
    backdrillResidual*: float
      ## Remaining bottom stub after backdrill, metres; `< 0` = not drilled.
    entryRef*, exitRef*: string
      ## Reference plane names for the two layers; differing is an issue.

  ViaModel* = object
    totalL*, totalC*: float
      ## Whole barrel.
    usedLength*: float
    usedL*, usedC*: float
      ## The part between entry and exit: series L, shunt C (split as a pi).
    stubTop*, stubBottom*: float
      ## Barrel above the shallower and below the deeper layer, metres.
    stubZ0*, stubTdPerM*: float
      ## Line parameters of the barrel as a stub.
    stubResonance*: float
      ## Quarter-wave frequency of the longer stub, Hz; `Inf` with none.
    referenceChange*: bool
    assumptions*: seq[Assumption]
    issues*: seq[Issue]

const InchM = 0.0254

proc viaCapacitance*(er, length, padDia, antipadDia: float): float =
  ## Johnson's pad-to-plane estimate, farads (inputs in metres).
  if antipadDia <= padDia: return NaN
  1.41e-12 * er * (length / InchM) * padDia / (antipadDia - padDia)

proc viaInductance*(length, drillDia: float): float =
  ## Johnson's barrel inductance, henries (inputs in metres).
  if length <= 0.0: return 0.0
  5.08e-9 * (length / InchM) * (ln(4.0 * length / drillDia) + 1.0)

proc viaModel*(g: ViaGeometry): ViaModel =
  let totC = viaCapacitance(g.er, g.barrelLength, g.padDia, g.antipadDia)
  let totL = viaInductance(g.barrelLength, g.drillDia)
  result.totalC = totC
  result.totalL = totL
  let top = min(g.entryDepth, g.exitDepth)
  let bot = max(g.entryDepth, g.exitDepth)
  result.usedLength = bot - top
  result.stubTop = max(top, 0.0)
  result.stubBottom = max(g.barrelLength - bot, 0.0)
  if g.backdrillResidual >= 0.0:
    result.stubBottom = min(result.stubBottom, g.backdrillResidual)
  # Per-length parameters, taken from the whole barrel.
  let lp = totL / g.barrelLength
  let cp = totC / g.barrelLength
  result.usedL = lp * result.usedLength
  result.usedC = cp * result.usedLength
  result.stubZ0 = sqrt(lp / cp)
  result.stubTdPerM = sqrt(lp * cp)
  let longest = max(result.stubTop, result.stubBottom)
  result.stubResonance =
    if longest > 0.0: 1.0 / (4.0 * longest * result.stubTdPerM) else: Inf
  result.assumptions.add note("via",
    "closed-form barrel L / pad C (Johnson & Graham) -- quasi-static, " &
    "a field solve may differ by tens of percent")
  if g.entryRef != g.exitRef:
    result.referenceChange = true
    result.issues.add newIssue("via_reference_change", sevError,
      "via changes return reference from '" & g.entryRef & "' to '" &
      g.exitRef & "'; the return transition is not modelled")

proc copperDepth(st: Stackup, l: PcbLayer): tuple[ok: bool, depth: float] =
  ## Centre of a copper layer, metres from the top of the stack.
  var z = 0.0
  for e in st.entries:
    let t = e.thickness.toMm / 1000.0
    if e.kind == seCopper and e.layer == l:
      return (true, z + t / 2)
    z += t
  (false, NaN)

proc viaGeometryFor*(pcb: Pcb, h: Hole, entry, exit: PcbLayer,
                     entryRef = "", exitRef = "",
                     antipadDia = NaN): tuple[g: ViaGeometry, notes: seq[Assumption], issues: seq[Issue]] =
  ## A hole's geometry off the board. Missing stack-up data is an issue and a
  ## `NaN` field, never a guess; a defaulted antipad is an `Assumption`.
  var g = ViaGeometry(backdrillResidual: -1.0, entryRef: entryRef, exitRef: exitRef)
  g.drillDia = (if h.finishedDia.raw > 0: h.finishedDia else: h.drillDia).toMm / 1000.0
  var pad = 0.0
  for c in h.pads: pad = max(pad, max(c.box.width, c.box.height).toMm / 1000.0)
  if pad <= 0.0:
    result.issues.add newIssue("via_geometry", sevWarning, "via has no pad copper")
    pad = NaN
  g.padDia = pad
  if antipadDia.isNaN:
    g.antipadDia = pad + 0.5e-3
    result.notes.add assumption("via", "antipad", g.antipadDia, "m", annDerived,
      "(pad + 0.5 mm: no plane clearance read off the board)")
  else:
    g.antipadDia = antipadDia
  let st = pcb.stackup
  let (okA, dTop) = copperDepth(st, h.fromLayer)
  let (okB, dBot) = copperDepth(st, h.toLayer)
  let (okE, dE) = copperDepth(st, entry)
  let (okX, dX) = copperDepth(st, exit)
  if not (okA and okB and okE and okX):
    result.issues.add newIssue("via_geometry", sevError,
      "stack-up does not place every layer of the via; length unknown")
    g.barrelLength = NaN
  else:
    g.barrelLength = dBot - dTop
    g.entryDepth = dE - dTop
    g.exitDepth = dX - dTop
    var wsum, tsum: float
    var z = 0.0
    for e in st.entries:
      let t = e.thickness.toMm / 1000.0
      if e.kind == seDielectric and z >= dTop and z + t <= dBot + 1e-12 and
         e.material != nil and e.material.epsilonR > 0:
        wsum += e.material.epsilonR * t
        tsum += t
      z += t
    if tsum > 0: g.er = wsum / tsum
    else:
      g.er = 4.3
      result.notes.add assumption("via", "er", 4.3, "", annDerived,
        "(no dielectric constant in the stack-up)")
  result.g = g
