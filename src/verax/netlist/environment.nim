## Where the board lives, and how hot each part runs in it.
##
## Every temperature-dependent answer needs two numbers before it can be
## computed, and neither of them is electrical. The first belongs to the
## *board*: the ambient range it is required to work across, which is a fact
## about an enclosure or a specification and not about any part on it. The
## second belongs to the *part*: how far above that ambient it runs, which
## nothing else can know -- a regulator dropping 1.7 V at 200 mA is 25 degC
## hotter than the capacitor sitting next to it, and the netlist records
## neither figure.
##
## **This module wires those two together and models nothing.** There is no
## temperature coefficient here, no capacitance-versus-temperature curve, no
## ESR-versus-temperature curve. What it provides is the input such a model
## needs: `partTemperatureRange(c, env)` answers "what range does this part
## actually see", and a pass that wants to derate a Class 2 ceramic across
## temperature asks that instead of assuming 25 degC, which is what makes the
## eventual model a statement about *this* board rather than about a bench.
##
## **The board's range and a part's rise are stated separately on purpose.**
## They come from different people at different times: the ambient range is
## fixed when the product is specified and is the same for every part, while
## a rise is a per-part consequence of a circuit that does not exist yet when
## the range is written down. Folding them into one absolute temperature per
## part would mean restating the enclosure spec on every component, and every
## copy would be a place for it to drift.
##
## **Storage is netlist and component annotations**, not fields on
## `netlist/types`. That is not only to keep the core schema clean: `attrs`
## are copied by `graph.clone`, so the range and every rise survive
## `materializeSimNetlist`, `flatten`, `extractSubcircuit` and `isolate` for
## free -- and a fragment cut out for simulation is precisely where a model
## pass will read them.
##
## **A part's rise defaults to 0 and says that it did.** Absent and zero
## genuinely coincide for most parts, which is why the default is safe to
## apply rather than refuse; but they do not coincide for the parts that
## matter, so `temperatureRise` hands back `annDefaulted` and a consumer that
## uses the number can report it as the assumption it is. The pure accessor
## `deltaT` is still there for anything that would rather see the absence.
##
## Deliberately **not** a consumer: the SPICE deck. `.options temp` would make
## every semiconductor in the design behave differently, which is temperature
## *modelling* and a separate decision from stating the range -- and one that
## would silently move every number this repo has already measured.

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
    ## The board-level operating conditions, read back with the provenance of
    ## each figure. Temperature is the only one today; humidity, altitude and
    ## airflow would be added here rather than in a second object, since a
    ## consumer asking for one usually wants the rest in the same breath.
    tAmbientMin*: AnnValue[float]
    tAmbientMax*: AnnValue[float]

proc environmentOf*(nl: Netlist): Environment =
  ## The environment of the board `nl` belongs to.
  ##
  ## Read from the **root** netlist: a subcircuit is part of the same board as
  ## its parent and does not have weather of its own, so a model pass holding
  ## a child does not have to walk up before asking.
  let r = root(nl)
  Environment(tAmbientMin: annotationFloat(r, "t_ambient_min"),
              tAmbientMax: annotationFloat(r, "t_ambient_max"))

proc stated*(env: Environment): bool {.inline.} =
  ## Whether a usable range was given. Half a range is not a range: a worst
  ## case needs both ends, and one end alone cannot be silently doubled up
  ## into the other.
  env.tAmbientMin.has and env.tAmbientMax.has

proc `$`*(env: Environment): string =
  if not env.stated:
    if env.tAmbientMin.has: return "ambient from " & $env.tAmbientMin.value.degC
    if env.tAmbientMax.has: return "ambient to " & $env.tAmbientMax.value.degC
    return "no operating temperature stated"
  "ambient " & $env.tAmbientMin.value.degC & " to " & $env.tAmbientMax.value.degC

proc setOperatingTemperature*(nl: Netlist, tMin, tMax: Celsius,
                              source = annAuthored) =
  ## States the board's ambient range. The runtime counterpart of the DSL's
  ## `environment:` block, and the path a file reader takes.
  if toFloat(tMin) > toFloat(tMax):
    raise newException(NetlistError,
      "operating temperature range is inverted: " & $tMin & " to " & $tMax)
  let r = root(nl)
  setAnnotation(r, "t_ambient_min", tMin, source)
  setAnnotation(r, "t_ambient_max", tMax, source)

# --- per-part rise -------------------------------------------------------

proc deltaT*(c: Component): AnnValue[float] =
  ## The stated rise above ambient, or `annAbsent`. Pure, like every other
  ## accessor in `annotations`: it never invents the 0.
  annotationFloat(c, "delta_t")

proc setDeltaT*(c: Component, rise: Celsius, source = annAuthored) =
  ## States a part's rise above ambient.
  ##
  ## `source` is the hinge for the pass that does not exist yet. A rise is
  ## authored today, but it is derivable -- dissipation times a thermal
  ## resistance, both of which a datasheet gives -- and when that pass
  ## arrives it must write `annDerived` and must **not** overwrite a rise
  ## somebody stated: an author who measured a part on the bench, or who
  ## knows about the airflow, outranks an arithmetic estimate. The test is
  ## `deltaT(c).source == annAuthored`, which is exactly what this provenance
  ## field is for, and it is why the rise is one key with a source rather
  ## than a `delta_t` and a `delta_t_derived` that would have to be given a
  ## precedence rule of their own.
  setAnnotation(c, "delta_t", rise, source)

proc temperatureRise*(c: Component): AnnValue[float] =
  ## The rise to actually use, with the documented default applied: 0 degC,
  ## reported as `annDefaulted` so a consumer can carry it out as an
  ## assumption rather than passing it off as something the designer said.
  ##
  ## This is the one place in the library where a default is applied *by* an
  ## accessor rather than by the consumer, and it is defensible for a reason
  ## that does not generalise: an unstated ESR and a zero ESR are different
  ## claims about a part, whereas an unstated rise and a zero rise agree for
  ## every part that is not dissipating anything.
  let d = deltaT(c)
  if d.has: return d
  AnnValue[float](source: annDefaulted, value: 0.0)

proc riseAssumption*(c: Component): Assumption =
  ## The assumption `temperatureRise` makes when a part states nothing --
  ## phrased for a report, and produced here so that every consumer words it
  ## the same way.
  assumption(c.designator, "delta_t", 0.0, "degC", annDefaulted,
             "assumed: the part is taken to sit at ambient, which is wrong " &
             "for anything dissipating enough to warm itself")

# --- the join ------------------------------------------------------------

proc partTemperature*(c: Component, ambient: float): float {.inline.} =
  ## What this part sits at, for one ambient temperature.
  ambient + temperatureRise(c).value

proc partTemperatureRange*(c: Component, env: Environment):
    tuple[tMin, tMax: float] =
  ## The range this part actually sees: the board's ambient range shifted up
  ## by the part's rise, at **both** ends.
  ##
  ## Shifting both ends rather than only the top is the honest reading of a
  ## rise, and it matters at the cold end: a part that dissipates is warmer
  ## than the air around it whatever the air is doing, so a board specified
  ## to -40 degC does not have to hold a self-heating regulator's ratings at
  ## -40. What it does have to hold at -40 is everything that does *not*
  ## dissipate -- which is why the ambient minimum is not simply discarded.
  ##
  ## `(NaN, NaN)` when the board states no range, in keeping with the rest of
  ## the library: a measurement that could not be made is not a zero.
  if not env.stated: return (NaN, NaN)
  let rise = temperatureRise(c).value
  (env.tAmbientMin.value + rise, env.tAmbientMax.value + rise)

proc hottestPart*(nl: Netlist, env: Environment):
    tuple[comp: Component, temperature: float] =
  ## The part that runs hottest at the top of the board's ambient range, and
  ## how hot. `(nil, NaN)` when nothing states a rise or no range is stated --
  ## a design where every part is at ambient has no hottest part worth naming.
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
  ## The hottest part and how hot, phrased for a report; `""` when nothing
  ## states a rise or no ambient range was given.
  ##
  ## Rendered here rather than by the reporter so that the one place that
  ## knows a `delta_t` is a *difference* is also the place that writes the
  ## `+` in front of it.
  let hot = hottestPart(nl, env)
  if hot.comp == nil: return ""
  hot.comp.designator & " at " & $hot.temperature.degC & " (+" &
    $deltaT(hot.comp).value.degC & " at the top of that range)"

# --- validation ----------------------------------------------------------

proc validateEnvironment*(nl: Netlist): seq[Issue] =
  ## What is wrong with what was *stated*, as distinct from what is missing.
  ##
  ## A board that says nothing about temperature is not reported: nothing
  ## consumes the range yet, and a design that never asks a temperature
  ## question does not need one. What is reported is a statement that cannot
  ## do its job -- a range with its ends the wrong way round, half a range,
  ## or a part rise with no range to add it to. Each of those looks exactly
  ## like a working specification from the design file, which is the whole
  ## reason to say so.
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

  # A range stated on a *child* is read by nothing: `environmentOf` goes to
  # the root, because a subcircuit is part of the same board as its parent
  # and does not have weather of its own. That is the right rule and it makes
  # a range written inside a `subckt` invisible the moment it is instanced --
  # indistinguishable, from the design file, from one that is being used.
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
