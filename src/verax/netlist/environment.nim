## Where the board lives, and how hot each part runs in it.
##
## Temperature-dependent answers need two non-electrical numbers: the
## board's ambient range (an enclosure/spec fact) and each part's rise above
## ambient. **This module wires them together and models nothing** -- no
## temperature coefficients. `partTemperatureRange(c, env)` is the input a
## future derating model needs.
##
## Range and rise are stated separately: they come from different people at
## different times, and folding them per part would copy the spec onto every
## component.
##
## **Stored as annotations**, so they survive clone, flatten and isolation.
##
## **A part's rise defaults to 0 and says so** (`annDefaulted` from
## `temperatureRise`); `deltaT` exposes the absence.
##
## Not passed to SPICE: `.options temp` would be temperature *modelling*, a
## separate decision that would move every existing result.

import std/[math, strutils, tables]

import ./types
import ./graph
import ./annotations
import ./issue
import ../units

export issue

const
  KindTemperatureRangeInverted* = "temperature_range_inverted"
  KindTemperatureRangeHalfStated* = "temperature_range_half_stated"
  KindTemperatureRiseUnusable* = "temperature_rise_unusable"
  KindTemperatureRangeNotAtRoot* = "temperature_range_not_at_root"

type
  Environment* = object
    ## The board's operating conditions, with provenance. Only temperature
    ## today; other conditions belong here too.
    tAmbientMin*: AnnValue[float]
    tAmbientMax*: AnnValue[float]

proc environmentOf*(nl: Netlist): Environment =
  ## The environment of `nl`'s board, read from the **root** (a subcircuit
  ## has no weather of its own).
  let r = root(nl)
  Environment(tAmbientMin: annotationFloat(r, "t_ambient_min"),
              tAmbientMax: annotationFloat(r, "t_ambient_max"))

proc stated*(env: Environment): bool {.inline.} =
  ## Whether both ends of the range were given; half a range isn't one.
  env.tAmbientMin.has and env.tAmbientMax.has

proc `$`*(env: Environment): string =
  if not env.stated:
    if env.tAmbientMin.has: return "ambient from " & $env.tAmbientMin.value.degC
    if env.tAmbientMax.has: return "ambient to " & $env.tAmbientMax.value.degC
    return "no operating temperature stated"
  "ambient " & $env.tAmbientMin.value.degC & " to " & $env.tAmbientMax.value.degC

proc setOperatingTemperature*(nl: Netlist, tMin, tMax: Celsius,
                              source = annAuthored) =
  ## States the ambient range: the runtime form of the DSL's `environment:`.
  if toFloat(tMin) > toFloat(tMax):
    raise newException(NetlistError,
      "operating temperature range is inverted: " & $tMin & " to " & $tMax)
  let r = root(nl)
  setAnnotation(r, "t_ambient_min", tMin, source)
  setAnnotation(r, "t_ambient_max", tMax, source)

# --- per-part rise -------------------------------------------------------

proc deltaT*(c: Component): AnnValue[float] =
  ## The stated rise above ambient, or `annAbsent`. Never invents the 0.
  annotationFloat(c, "delta_t")

proc setDeltaT*(c: Component, rise: Celsius, source = annAuthored) =
  ## States a part's rise above ambient. A future derivation pass (power x
  ## thermal resistance) must write `annDerived` and never overwrite an
  ## `annAuthored` rise -- hence one key with a source, not two keys.
  setAnnotation(c, "delta_t", rise, source)

proc temperatureRise*(c: Component): AnnValue[float] =
  ## The rise to use: 0 degC if unstated, as `annDefaulted` so it's reported
  ## as an assumption. Defaulting here is safe only because an unstated rise
  ## and a zero rise agree for any non-dissipating part.
  let d = deltaT(c)
  if d.has: return d
  AnnValue[float](source: annDefaulted, value: 0.0)

proc riseAssumption*(c: Component): Assumption =
  ## The assumption `temperatureRise` makes, worded once for every consumer.
  assumption(c.designator, "delta_t", 0.0, "degC", annDefaulted,
             "assumed: the part is taken to sit at ambient, which is wrong " &
             "for anything dissipating enough to warm itself")

# --- the join ------------------------------------------------------------

proc partTemperature*(c: Component, ambient: float): float {.inline.} =
  ## What this part sits at, for one ambient temperature.
  ambient + temperatureRise(c).value

proc partTemperatureRange*(c: Component, env: Environment):
    tuple[tMin, tMax: float] =
  ## The range this part sees: the ambient range shifted up by its rise at
  ## **both** ends (a dissipating part is warmer than the air even at the
  ## cold end). `(NaN, NaN)` when no range is stated.
  if not env.stated: return (NaN, NaN)
  let rise = temperatureRise(c).value
  (env.tAmbientMin.value + rise, env.tAmbientMax.value + rise)

proc hottestPart*(nl: Netlist, env: Environment):
    tuple[comp: Component, temperature: float] =
  ## The hottest part at top-of-range ambient, and its temperature. `(nil,
  ## NaN)` when no rise or no range is stated.
  result = (nil, NaN)
  if not env.stated: return
  for _, c in nl.components:
    let d = deltaT(c)
    if not d.has or d.value <= 0.0: continue
    let t = env.tAmbientMax.value + d.value
    if result.comp == nil or t > result.temperature:
      result = (c, t)
  for _, child in nl.children:
    let inner = hottestPart(child, env)
    if inner.comp != nil and
       (result.comp == nil or inner.temperature > result.temperature):
      result = inner

proc describeHottest*(nl: Netlist, env: Environment): string =
  ## The hottest part, phrased for a report (with the `+` on `delta_t`); `""`
  ## when there's nothing to report.
  let hot = hottestPart(nl, env)
  if hot.comp == nil: return ""
  hot.comp.designator & " at " & $hot.temperature.degC & " (+" &
    $deltaT(hot.comp).value.degC & " at the top of that range)"

# --- validation ----------------------------------------------------------

proc validateEnvironment*(nl: Netlist): seq[Issue] =
  ## Problems with what was *stated* (not what's missing): a reversed range,
  ## half a range, or a part rise with no range.
  let r = root(nl)
  let env = environmentOf(r)

  if env.tAmbientMin.has and env.tAmbientMax.has:
    if env.tAmbientMin.value > env.tAmbientMax.value:
      result.add newIssue(KindTemperatureRangeInverted, sevError,
        "the board's operating temperature range runs from " &
        $env.tAmbientMin.value.degC & " down to " & $env.tAmbientMax.value.degC &
        ": the ends are the wrong way round, so every worst case taken from " &
        "it is inverted too.")
  elif env.tAmbientMin.has or env.tAmbientMax.has:
    let stated = if env.tAmbientMin.has: "t_ambient_min" else: "t_ambient_max"
    let missing = if env.tAmbientMin.has: "t_ambient_max" else: "t_ambient_min"
    result.add newIssue(KindTemperatureRangeHalfStated, sevWarning,
      "the board states " & stated & " but not " & missing & ". A worst case " &
      "needs both ends -- a ceramic loses capacitance at the hot end and an " &
      "electrolytic's ESR climbs at the cold one -- so half a range is read " &
      "as no range at all and nothing will use it.")

  # A range stated on a child is never read (`environmentOf` uses the root),
  # so it looks used but isn't -- report it.
  var strays: seq[string]
  var scanRange: proc (n: Netlist) {.closure.}
  scanRange = proc (n: Netlist) =
    for _, child in n.children:
      if child.attrs.hasKey("t_ambient_min") or
         child.attrs.hasKey("t_ambient_max"):
        strays.add child.name
      scanRange(child)
  scanRange(r)
  if strays.len > 0:
    result.add newIssue(KindTemperatureRangeNotAtRoot, sevWarning,
      "an operating temperature range is stated inside " &
      strays.join(", ") & ", which nothing reads: the range belongs to the " &
      "board, so it is taken from the top-level design and a subcircuit " &
      "does not have one of its own. State it in the design's own " &
      "`environment:` block instead.")

  if not env.stated:
    var risen: seq[Component]
    var scan: proc (n: Netlist) {.closure.}
    scan = proc (n: Netlist) =
      for _, c in n.components:
        if deltaT(c).has: risen.add c
      for _, child in n.children: scan(child)
    scan(r)
    if risen.len > 0:
      var names: seq[string]
      for c in risen: names.add c.designator
      result.add newIssue(KindTemperatureRiseUnusable, sevWarning,
        (if names.len == 1: names[0] & " states a delta_t"
         else: names.join(", ") & " state a delta_t") &
        ", but the board states no ambient range for it to be a rise above. " &
        "A rise on its own is not a temperature: state `t_ambient_min` and " &
        "`t_ambient_max` in an `environment:` block, or the figure will sit " &
        "there unread.",
        components = risen)
