## Is every part inside its ratings? (Distinct from `spice/models` using
## `voltage_rating` to place a ceramic on its DC-bias curve.)
##
## Checks `voltage_rating` against DC across each part, and a resistor's
## `power_rating` against V^2/R -- what one `.op` can answer.
## `current_rating` and `isat` aren't in an `.op`; `transient.analyzeCurrent`
## checks them (`current_path` role).
##
## Ceilings are per dielectric family: tantalum is derated to half (it fails
## short), while a ceramic's headroom is mostly capacitance, already modelled
## -- applying the tantalum rule there would double-count.

import std/[math, strutils, tables]

import ../../netlist/types
import ../../netlist/graph
import ../../netlist/annotations

import ../../netlist/formats/spice as spiceFormat
import ../../spice/ngspice
import ../../spice/bench
import ../../spice/transform
import ../../spice/models
import ../../eng
import ../report

export report

const
  KindOverVoltage* = "part_over_voltage_rating"
  KindOverPower* = "part_over_power_rating"
  KindSimulationFailed* = "derating_simulation_failed"

type
  DeratingSpec* = object
    ceilingByFamily*: OrderedTable[string, float]
      ## Fraction of rating a part may reach before it is reported.
    defaultCeiling*: float
    pinModels*: PinModelDefaults
    modelUnmodelledParts*: bool
    flattenHierarchy*: bool
    precomputed*: OrderedTable[string, float]
      ## A shared operating point to reuse; empty solves one here.
    onlyTouching*: string
      ## When set, only parts with a pin on this net are considered -- so a
      ## claim can name a subject ("every part on this rail"). Costs one
      ## `.op` per claimed rail.

proc defaultDeratingSpec*(): DeratingSpec =
  result.defaultCeiling = 0.8
  result.pinModels = defaultPinModels()
  result.modelUnmodelledParts = true
  result.flattenHierarchy = true
  # Tantalums fail short and take the rail with them.
  result.ceilingByFamily["tantalum"] = 0.5
  result.ceilingByFamily["electrolytic"] = 0.8
  result.ceilingByFamily["film"] = 0.6

proc familyOf(c: Component): string =
  let d = annotation(c, "dielectric")
  if d.has:
    let v = d.value.toLowerAscii
    if v in ["tantalum", "electrolytic", "film"]: return v
    return "ceramic"
  let p = package(c)
  if p.has and p.value.toLowerAscii in ["tantalum", "electrolytic", "film", "bulk"]:
    return (if p.value.toLowerAscii == "bulk": "electrolytic" else: p.value.toLowerAscii)
  "ceramic"

proc ceilingFor(c: Component, spec: DeratingSpec): float =
  let fam = familyOf(c)
  if spec.ceilingByFamily.hasKey(fam): spec.ceilingByFamily[fam]
  else: spec.defaultCeiling

proc nodeVoltage(sim: SimResult, pre: OrderedTable[string, float],
                 netName: string): float =
  if netName == "0": return 0.0
  if pre.len > 0:
    if pre.hasKey(netName): return pre[netName]
    return NaN
  try: sim["v(" & netName & ")"][0]
  except CatchableError: NaN

proc analyzeDerating*(nl: Netlist, spec = defaultDeratingSpec()): AnalysisReport =
  ## One `.op` over the whole design, checking every part that states a
  ## rating. **Not isolated**: boundary sources would invent the voltages.
  # Clone, flatten, *then* `simReplace` (not `materializeSimNetlist`), so a
  # nested XSPICE component's ports use post-flatten net names.
  var b = openBench(root(nl), "derating", spOperating, spec.flattenHierarchy)
  if spec.modelUnmodelledParts:
    b.modelUnmodelled(spec.pinModels)
  b.scopeBench ScopeRequest(strategy: "whole")
  result.assumptions.add b.assumptions
  let simNl = b.netlist

  var sim: SimResult
  if spec.precomputed.len == 0:
    try:
      sim = b.run(@[".op"], label = "derating")
    except CatchableError as e:
      result.issues.add newIssue(KindSimulationFailed, sevWarning,
        "the operating point needed to check part ratings did not solve: " & e.msg)
      return

  var worstV = 0.0
  var worstVPart = ""
  var worstP = 0.0
  var worstPPart = ""
  var overCount = 0
  var rated = 0

  for _, c in simNl.components:
    var pins: seq[Pin]
    for _, p in c.pins: pins.add p
    if pins.len != 2: continue
    if spec.onlyTouching.len > 0:
      var touches = false
      for p in pins:
        if p.net != nil and p.net.name == spec.onlyTouching: touches = true
      if not touches: continue
    if pins[0].net == nil or pins[1].net == nil: continue
    let va = nodeVoltage(sim, spec.precomputed, pins[0].net.name)
    let vb = nodeVoltage(sim, spec.precomputed, pins[1].net.name)
    if va.classify == fcNan or vb.classify == fcNan: continue
    let across = abs(va - vb)

    let vrAnn = voltageRating(c)
    let vr = AnnValue[float](source: vrAnn.source, value: float(vrAnn.value))
    if vr.has and vr.value > 0.0:
      inc rated
      let frac = across / vr.value
      if frac > worstV:
        worstV = frac
        worstVPart = c.designator
      let ceil = ceilingFor(c, spec)
      if frac > ceil:
        inc overCount
        result.issues.add newIssue(KindOverVoltage,
          (if frac > 1.0: sevError else: sevWarning),
          c.designator & " sees " & eng(across, "V") & " across a part rated " &
          eng(vr.value, "V") & " -- " & $int(frac * 100.0) & "% of rating, " &
          "above the " & $int(ceil * 100.0) & "% ceiling for a " &
          familyOf(c) & " part" &
          (if frac > 1.0: ". It is over its rating, not merely under-derated."
           else: "."),
          components = @[c])

    let prAnn = powerRating(c)
    let pr = AnnValue[float](source: prAnn.source, value: float(prAnn.value))
    if pr.has and pr.value > 0.0 and c.kind == "resistor":
      var r: float
      if c.attrs.hasKey("value") and
         spiceFormat.parseSpiceMagnitude(c.attrs["value"], r) and r > 0.0:
        let dissipated = across * across / r
        let frac = dissipated / pr.value
        if frac > worstP:
          worstP = frac
          worstPPart = c.designator
        if frac > spec.defaultCeiling:
          inc overCount
          result.issues.add newIssue(KindOverPower,
            (if frac > 1.0: sevError else: sevWarning),
            c.designator & " dissipates " & eng(dissipated, "W") &
            " in a part rated " & eng(pr.value, "W") & " -- " &
            $int(frac * 100.0) & "% of rating.", components = @[c])

  if rated == 0:
    result.assumptions.add note(
      "no part " &
      (if spec.onlyTouching.len > 0: "on net '" & spec.onlyTouching & "' "
       else: "in this design ") &
      "states a `voltage_rating`, so nothing was " &
      "checked against one. A rating is the only thing that makes this " &
      "question answerable -- the operating point alone cannot tell a 6.3 V " &
      "part from a 50 V one")

  result.add("worst_voltage_derating", worstV, "",
             at = (if worstVPart.len > 0: "component '" & worstVPart & "'" else: ""))
  result.add("worst_power_derating", worstP, "",
             at = (if worstPPart.len > 0: "component '" & worstPPart & "'" else: ""))
  result.add("parts_over_derating", float(overCount), "")
