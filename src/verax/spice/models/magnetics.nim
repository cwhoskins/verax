## Coupled inductors: a transformer or common-mode choke as two windings and
## a SPICE `K` card -- an ideal coupled pair with magnetising inductance per
## winding and a coupling coefficient (leakage is implicit in `k < 1`).
##
## Not modelled: core loss, saturation, interwinding capacitance,
## frequency-dependent permeability. Mutates its netlist; use a clone.

import std/[math, strutils, tables]
import ../../netlist/types
import ../../netlist/graph
import ../../netlist/annotations
import ../../units
import ../../eng
import ../../netlist/formats/spice as spiceFormat
import ./common
import ../provenance

type
  CoupledInductorModel* = object
    k*: float        ## coupling coefficient used when the part states none
    dcr*: Ohms       ## primary winding resistance used when the part states none

proc defaultCoupledInductorModel*(): CoupledInductorModel =
  CoupledInductorModel(k: 0.98, dcr: 50.mohm)

const coupledKinds = ["transformer", "common_mode_choke", "coupled_inductor"]

proc expandCoupledInductors*(nl: Netlist,
                             d = defaultCoupledInductorModel()): seq[Assumption] =
  ## Rewrites every `transformer`/`common_mode_choke`/`coupled_inductor` into
  ## two windings (inductor + DCR resistor) plus a `mutual_inductance`
  ## carrying `K`. Terminals match `common.priDotNames` etc. (`PRI+`/`PRI-`,
  ## `SEC+`/`SEC-`, dotted end first).
  ##
  ## `Ls` comes from `lsec`, else `lpri * turns^2`, else 1:1 (right for a
  ## choke, flagged otherwise). With none of the three the part is **left
  ## alone** with a note: no default magnetising inductance is defensible.
  var parts: seq[Component]
  for _, c in nl.components:
    if c.kind in coupledKinds and c.subNetlist == nil: parts.add c

  for part in parts:
    provenance(nl, part, brStandIn):
      let desig = part.designator
      let pDot = pinNamed(part, priDotNames)
      let pRet = pinNamed(part, priRetNames)
      let sDot = pinNamed(part, secDotNames)
      let sRet = pinNamed(part, secRetNames)
      if pDot == nil or pRet == nil or sDot == nil or sRet == nil or
         pDot.net == nil or pRet.net == nil or sDot.net == nil or sRet.net == nil:
        var names: seq[string]
        for pp in orderedPins(part): names.add pp.name
        result.add note(desig & " (" & part.kind & ") needs two primary and " &
          "two secondary winding terminals -- PRI+/PRI-/SEC+/SEC- -- to be " &
          "modelled; it has " & names.join(", ") & ". Left as it is, which " &
          "SPICE reads as a transmission line.")
        continue

      let lpriA = annotationFloat(part, "lpri")
      let lsecA = annotationFloat(part, "lsec")
      let turnsA = annotationFloat(part, "turns")
      var lp, ls, ratio: float
      if lpriA.has and lpriA.value > 0.0 and lsecA.has and lsecA.value > 0.0:
        lp = lpriA.value
        ls = lsecA.value
        ratio = sqrt(ls / lp)
      elif lpriA.has and lpriA.value > 0.0 and turnsA.has and turnsA.value > 0.0:
        lp = lpriA.value
        ratio = turnsA.value
        ls = lp * ratio * ratio
        result.add assumption(desig, "lsec", ls, "H", annDerived,
          "from `lpri` and `turns` (" & formatFloat(ratio, ffDecimal, 3) &
          ":1): Ls = Lp * turns^2")
      elif lpriA.has and lpriA.value > 0.0:
        lp = lpriA.value
        ls = lp
        ratio = 1.0
        result.add note(desig & ": no `lsec` or `turns`, so the secondary is " &
          "modelled 1:1 with the primary -- right for a common-mode choke, " &
          "wrong for a step transformer. State `turns`.")
      elif lsecA.has and lsecA.value > 0.0:
        ls = lsecA.value
        lp = ls
        ratio = 1.0
        result.add note(desig & ": only `lsec` stated; primary modelled 1:1.")
      else:
        result.add note(desig & " (" & part.kind & ") states no `lpri`, " &
          "`lsec` or `turns`, so its windings cannot be sized and it was left " &
          "unmodelled. There is no defensible default magnetising inductance " &
          "-- state `lpri`, and `turns` for a ratio other than 1:1.")
        continue

      let kA = annotationFloat(part, "k_coupling")
      let k = if kA.has and kA.value > 0.0: min(kA.value, 0.999999) else: d.k
      if not (kA.has and kA.value > 0.0):
        result.add assumption(desig, "k_coupling", k, "", annDefaulted,
          "a tightly wound part; leakage is implicit in k<1 and the answer is " &
          "not sensitive between 0.95 and 0.995. State it for a loosely " &
          "coupled part.")

      let dcrA = annotationFloat(part, "dcr")
      let dcrP = if dcrA.has and dcrA.value > 0.0: dcrA.value else: float(d.dcr)
      # Winding resistance scales with length, i.e. with turns, not with turns^2.
      let dcrS = dcrP * (if ratio > 0.0: ratio else: 1.0)
      if not (dcrA.has and dcrA.value > 0.0):
        result.add assumption(desig, "dcr", dcrP, "ohm", annDefaulted,
          "typical winding resistance; on a supply rail it is a steady IR " &
          "drop and a filter floor, so state it from the datasheet there. The " &
          "secondary's is scaled by the turns ratio.")

      let pA = pDot.net
      let pB = pRet.net
      let sA = sDot.net
      let sB = sRet.net
      removeComponent(nl, desig)

      let midP = addNet(nl, newNet(desig & "_PMID"))
      let midS = addNet(nl, newNet(desig & "_SMID"))

      proc add2(kind, name, v: string, x, y: Net): Component =
        result = addComponent(nl, newComponent(name, kind = kind))
        discard connect(result, "1", x, ptPassive)
        discard connect(result, "2", y, ptPassive)
        result.attrs["value"] = v

      let lPri = add2("inductor", "L" & desig & "_PRI", spiceValue(lp), pA, midP)
      discard add2("resistor", "R" & desig & "_PRI",
                   spiceValue(max(dcrP, 1.0e-6)), midP, pB)
      let lSec = add2("inductor", "L" & desig & "_SEC", spiceValue(ls), sA, midS)
      discard add2("resistor", "R" & desig & "_SEC",
                   spiceValue(max(dcrS, 1.0e-6)), midS, sB)

      # The `K` card has no pins; `formats/spice` renders it from
      # `spice.couples`, resolving names at write time.
      let kc = addComponent(nl, newComponent("K" & desig,
                                             kind = "mutual_inductance"))
      kc.attrs["spice.couples"] = lPri.designator & "," & lSec.designator
      kc.attrs["value"] = formatFloat(k, ffDecimal, 6)

      result.add note(desig & ": " & part.kind & " modelled as " &
        eng(lp, "H") & " and " & eng(ls, "H") & " windings coupled k=" &
        formatFloat(k, ffDecimal, 4) & " (turns " &
        formatFloat(ratio, ffDecimal, 3) & ":1) -- no core loss, no " &
        "saturation, no interwinding capacitance")
