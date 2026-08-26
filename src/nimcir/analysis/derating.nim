## Is every part inside its ratings?
##
## The other half of what a rating is for. `spice/models` uses
## `voltage_rating` to work out where on the DC-bias curve a ceramic sits,
## which changes the answer; this asks the separate question of whether the
## part is being *used* within what it can take, which does not change any
## answer but is the difference between a board that works and one that fails
## in the field.
##
## It needs an operating point, so it is opt-in per import like every other
## simulation-backed analysis here.
##
## **Scope, stated rather than discovered.** Two ratings are checked:
##
##   * `voltage_rating`, against the DC voltage actually across the part. The
##     `.op` gives every node voltage, so this needs nothing extra.
##   * `power_rating` on a resistor, against V^2/R.
##
## `current_rating` and `isat` are registered keys that the part policy sets
## and that **nothing checks yet**, because a branch current is not in a `.op`
## for anything but a voltage source: getting one needs a probe inserted per
## part, and getting an inductor's peak needs a `.tran`. That is a real gap
## and it is the one that matters for a converter, where saturation is the
## failure mode.
##
## Ceilings are per dielectric family because the reason to derate differs:
## a tantalum is derated to half because it fails *short* and takes the rail
## with it, whereas a ceramic's headroom is mostly about capacitance, which
## `spice/models` already models directly -- so applying the tantalum rule to
## ceramics would double-count it.

import std/[math, strutils, tables]

import ../netlist/types
import ../netlist/graph
import ../netlist/annotations

import ../netlist/formats/spice as spiceFormat
import ../spice/ngspice
import ../spice/transform
import ../spice/flatten
import ../spice/models
import ../eng
import ./report

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
      ## A shared operating point to use instead of solving another. Empty
      ## means solve one here.
    onlyTouching*: string
      ## When set, only parts with a pin on this net are considered.
      ##
      ## A rating is a property of a part, not of a net, so a design-global
      ## answer is the honest one -- but a *claim* needs a subject the
      ## contract layer can name, and "every part on this rail is inside its
      ## ratings" is both expressible and the question a designer actually
      ## asks. The cost is one `.op` per claimed rail rather than one for the
      ## design; a `.op` is the cheapest run there is, and a design claiming
      ## more than two or three rails is unusual.

proc defaultDeratingSpec*(): DeratingSpec =
  result.defaultCeiling = 0.8
  result.pinModels = defaultPinModels()
  result.modelUnmodelledParts = true
  result.flattenHierarchy = true
  # Tantalums fail short, and a shorted bulk capacitor takes the rail down
  # with it -- which is why the 50% rule for them is an order of magnitude
  # more insisted-upon than the equivalent for a ceramic.
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
  ## Runs one `.op` over the whole design and checks every part that states a
  ## rating against what it is actually seeing.
  ##
  ## Like `contract_eval`'s `dc_voltage`, this **does not isolate**: a rating
  ## check is about the design as built, and a fragment terminated with ideal
  ## sources would be checking parts against voltages the boundary invented.
  var globalNets: OrderedTable[string, Net]
  let simNl = materializeSimNetlist(root(nl), globalNets, purpose = spOperating)
  if spec.flattenHierarchy: discard flatten(simNl)
  if spec.modelUnmodelledParts:
    result.assumptions.add expandPinModels(simNl, spec.pinModels)

  var sim: SimResult
  if spec.precomputed.len == 0:
    try:
      sim = run(simNl, @[".op"], label = "derating")
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

    let vr = annotationFloat(c, "voltage_rating")
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

    let pr = annotationFloat(c, "power_rating")
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
