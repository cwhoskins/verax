## DC-bias derating of Class 2 ceramics: the capacitance a part actually has
## under the voltage across it, which is not the capacitance on its label.
##
## Used by `spice/models/capacitor` before it expands the parasitics, because
## a Class 2 ceramic on a rail is not the part its label says it is and every
## impedance computed from the label is wrong by that factor.

import std/[math, strutils, tables]
import ../../netlist/types
import ../../netlist/graph
import ../../netlist/annotations
import ../../netlist/kinds
import ../../eng
import ../../netlist/formats/spice as spiceFormat
import ./common

type
  DeratingDefaults* = object
    ## How much capacitance a Class 2 ceramic loses to DC bias.
    byDielectric*: OrderedTable[string, seq[(float, float)]]
      ## Dielectric -> (V/Vrated, fraction of nominal capacitance remaining),
      ## interpolated linearly and clamped at both ends.
    assumeDielectric*: string
      ## What an un-annotated *ceramic* is taken to be.
    assumeRatingFactor*: float
      ## When no `voltage_rating` is stated, assume the part was rated at this
      ## multiple of the voltage actually across it.
    enabled*: bool

proc defaultDerating*(): DeratingDefaults =
  ## Typical Class 2 behaviour, and **not** vendor data for any part.
  ##
  ## State the size of the error before the numbers: an X5R bank at about two
  ## thirds of its rating measured 1.23 ohm of worst in-band rail impedance
  ## where the same parts at their nominal values said 173 mohm. Seven times.
  ## That is larger than every other correction in this module put together,
  ## which is why this is on by default.
  ##
  ## The honest caveat, which matters when reading any number that came
  ## through here: **real DC-bias loss depends far more on case size and
  ## capacitance density than on the dielectric letter**. A 10 uF 0402 X5R can
  ## be down to a fifth of its label at rated voltage while a 100 nF 1206 X7R
  ## barely moves, and both are "Class 2". These curves are a typical middle,
  ## so a design where the rail impedance is the product should state measured
  ## capacitance rather than lean on them. Class 1 is exact, not typical:
  ## C0G/NP0 is paraelectric and does not depend on applied voltage at all.
  result.assumeDielectric = "X7R"
  result.assumeRatingFactor = 2.0
  result.enabled = true
  let class2 = @[(0.0, 1.0), (0.25, 0.85), (0.5, 0.65), (0.75, 0.45), (1.0, 0.30)]
  let harsh  = @[(0.0, 1.0), (0.25, 0.70), (0.5, 0.35), (0.75, 0.22), (1.0, 0.15)]
  for k in ["X7R", "X5R", "X6S", "X7S"]: result.byDielectric[k] = class2
  for k in ["Y5V", "Z5U"]: result.byDielectric[k] = harsh
  for k in ["C0G", "NP0"]: result.byDielectric[k] = @[(0.0, 1.0), (1.0, 1.0)]

proc deratingFraction*(curve: seq[(float, float)], ratio: float): float =
  ## Linear interpolation on the curve, clamped outside it.
  if curve.len == 0: return 1.0
  if ratio <= curve[0][0]: return curve[0][1]
  if ratio >= curve[^1][0]: return curve[^1][1]
  for i in 1 ..< curve.len:
    if ratio <= curve[i][0]:
      let (x0, y0) = curve[i - 1]
      let (x1, y1) = curve[i]
      if x1 == x0: return y1
      return y0 + (y1 - y0) * (ratio - x0) / (x1 - x0)
  curve[^1][1]

proc dcAcrossCapacitor(cap: Component,
                       bias: OrderedTable[string, float]): float =
  ## The DC voltage a capacitor sits at.
  ##
  ## `bias` is a solved operating point, node name -> volts, and it is tried
  ## first because it *knows*: it covers a capacitor on any node, not just one
  ## with a stated rail on one plate. That blind spot was not academic -- a
  ## 10 uF rated 6.3 V on a 12 V divider's midpoint sits at 95% of its rating
  ## and came through completely underated, because `mid` carried no `voltage`
  ## annotation and nothing else could see it.
  ##
  ## There is no circularity in consulting it: at DC a capacitor is an open
  ## circuit, so the operating point does not depend on capacitance and the
  ## chain is a straight line rather than a fixed point. Verified -- `v(mid)`
  ## on that divider is bit-identical with 100 pF and with 1000 uF.
  ##
  ## Without a bias, the fallback is the one case that is unambiguous from the
  ## netlist alone: one plate on the reference, the other on a rail whose
  ## nominal voltage is stated. Everything else returns 0, meaning *not known
  ## here*, and no derating is applied.
  let pins = orderedPins(cap)
  if pins.len != 2: return 0.0

  if bias.len > 0 and pins[0].net != nil and pins[1].net != nil:
    let a = pins[0].net.name
    let b = pins[1].net.name
    let va = (if a == "0": 0.0 elif bias.hasKey(a): bias[a] else: NaN)
    let vb = (if b == "0": 0.0 elif bias.hasKey(b): bias[b] else: NaN)
    if va.classify != fcNan and vb.classify != fcNan:
      return abs(va - vb)
  for i in 0 .. 1:
    let a = pins[i].net
    let b = pins[1 - i].net
    if a == nil or b == nil: continue
    if not isGround(a): continue
    let v = annotations.railVoltage(b)
    if v.has: return abs(v.value)
  0.0

proc derateCapacitor*(cap: Component, d: DeratingDefaults,
                      bias: OrderedTable[string, float]): seq[Assumption] =
  ## Rewrites `cap`'s value to the capacitance it actually has under bias.
  if not d.enabled: return
  if cap.attrs.getOrDefault("derating.applied", "") == "true": return

  var nominal: float
  if not cap.attrs.hasKey("value") or
     not spiceFormat.parseSpiceMagnitude(cap.attrs["value"], nominal):
    return                      # not a bare magnitude; nothing to scale
  if nominal <= 0.0: return

  let working = dcAcrossCapacitor(cap, bias)
  if working <= 0.0: return     # no DC across it, or not knowable here

  # Dielectric: stated, else inferred. A part whose package names a
  # non-ceramic family does not bias-derate at all and must not be guessed
  # into a ceramic.
  let stated = annotations.annotation(cap, "dielectric")
  var dielectric = stated.value
  if not stated.has:
    let pkg = annotations.package(cap)
    if pkg.has and pkg.value.toLowerAscii in
       ["tantalum", "electrolytic", "film", "bulk"]:
      return
    dielectric = d.assumeDielectric
  if not d.byDielectric.hasKey(dielectric.toUpperAscii): return
  let curve = d.byDielectric[dielectric.toUpperAscii]

  let ratedAnn = annotations.annotationFloat(cap, "voltage_rating")
  let rated =
    if ratedAnn.has and ratedAnn.value > 0.0: ratedAnn.value
    else: working * d.assumeRatingFactor
  if rated <= 0.0: return

  let frac = deratingFraction(curve, working / rated)
  if frac >= 0.999: return      # Class 1, or so lightly biased it is noise

  cap.attrs["value"] = spiceValue(nominal * frac)
  cap.attrs["derating.applied"] = "true"

  if not stated.has:
    result.add note(cap.designator, "dielectric assumed " &
      d.assumeDielectric & " for a ceramic that states none. C0G/NP0 does " &
      "not bias-derate at all, so stating it is the difference between " &
      eng(nominal, "F") & " and " & eng(nominal * frac, "F") & " here")
  if not (ratedAnn.has and ratedAnn.value > 0.0):
    result.add assumption(cap.designator, "voltage_rating", rated, "V",
      annDefaulted,
      "assumed as " & $d.assumeRatingFactor & "x the " & eng(working, "V") &
      " across the part")
  result.add note(cap.designator, eng(nominal, "F") & " derates to " &
    eng(nominal * frac, "F") & " (" & $int(frac * 100.0) & "% of nominal) at " &
    eng(working, "V") & " on a " & dielectric & " part rated " &
    eng(rated, "V") & "; DC-bias loss depends more on case size than on the " &
    "dielectric letter, so state a measured capacitance where this matters")
