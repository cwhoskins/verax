## The annotation vocabulary: which `attrs` keys mean something, what type
## and unit each carries, and where each value came from.
##
## `attrs: OrderedTable[string, string]` is deliberately open-ended so that a
## file format never has to extend the core schema. The cost of that openness
## is that **a typo in a key is indistinguishable from an absent key** --
## write `ESL` instead of `esl` and `spice/models` silently falls back to a
## package default *and reports that default as an assumption*, so it looks
## like it worked. Units have the same hazard: `esr` is ohms by convention
## alone, so `"20m"` and `"0.02"` differ by a thousand and look equally
## plausible.
##
## This module closes both holes without changing how anything is stored.
## Storage stays `attrs`, which matters more than it looks: `graph.clone`
## copies `attrs` at every level, so annotations survive `extractSubcircuit`,
## `materializeSimNetlist` and `spice/isolate` for free -- including
## `isolate`'s rename of the ground net to `"0"`, which a name-keyed side-car
## store would not.
##
## **Naming rule: bare means registered, dotted means owned.** A canonical
## key is a bare word declared here (`value`, `voltage`, `esr`). Anything
## belonging to a module, a file format or a user is namespaced
## (`xspice.ports`, `parasitics.expanded`, `kicad.Value`, `acme.foo`), and is
## never validated or flagged -- whoever owns the namespace owns its meaning.
## The codebase already followed this informally; here it is enforced.
##
## **Provenance.** Every read reports where the value came from. Analyses
## already needed this and hand-rolled it in prose; making it part of the
## accessor's return type is what lets `AnalysisReport.assumptions` be
## generated rather than remembered.

import std/[math, strutils, tables]
import ./types
import ./issue
import ../eng
import ../units

export issue

type
  AnnKind* = enum
    akString    ## opaque text; never parsed (e.g. a SPICE device value)
    akFloat
    akInt
    akBool
    akEnum

  AnnScope* = enum
    asNetlist, asNet, asComponent, asPin

  AnnDef* = object
    key*: string
      ## Canonical, bare.
    kind*: AnnKind
    unit*: string
      ## SI base unit symbol -- "V", "ohm", "F", "H", "Hz", "s", "A" -- or ""
      ## for dimensionless and opaque values. Matches `units.unitOf`.
    scopes*: set[AnnScope]
    doc*: string
      ## The documentation for this key. It lives here, in data, so the DSL's
      ## compile-time check, runtime validation and generated docs all read
      ## the same source.
    aliases*: seq[string]
      ## Foreign spellings a normalization pass may promote from. Declared
      ## now because the design needs the field; no producer exists until a
      ## KiCad reader does, and its `Value` property is *not* our `value`.
    allowed*: seq[string]
      ## `akEnum` only.

  AnnSource* = enum
    annAbsent     ## not present
    annAuthored   ## stated by the designer
    annImported   ## read from a design file
    annDefaulted  ## invented from a defaults table by a consumer
    annDerived    ## inferred from the graph

  AnnValue*[T] = object
    source*: AnnSource
    value*: T

const srcPrefix = "ann.src."
  ## Provenance marker namespace, owned by this module. Only written when the
  ## source is something other than `annAuthored`, so an ordinary hand-written
  ## annotation costs no extra key.

proc has*[T](v: AnnValue[T]): bool {.inline.} =
  v.source != annAbsent

type
  Assumption* = object
    ## A record that some value a result rests on was not stated by the
    ## designer. Produced by whatever invented the value, carried up through
    ## `spice/isolate` and `spice/models` into `analysis.AnalysisReport`.
    ##
    ## This lives here, next to `AnnSource`, rather than in `analysis` --
    ## `spice` produces assumptions and cannot import `analysis`, which
    ## depends on it. It is also the right home conceptually: an assumption is
    ## a provenance record.
    entity*: string
      ## What it is about: `"C1"`, `"rail 'vdd'"`. Free text, for reading.
    key*: string
      ## The annotation key, when there is one. Empty for a narrative
      ## assumption that is not about a single key -- "these components were
      ## cut at the boundary" is a real thing a result rests on and has no
      ## key or magnitude.
    value*: float
    unit*: string
    source*: AnnSource
    detail*: string
      ## The rest of the sentence, in the words of whoever chose the value --
      ## it is appended after the magnitude, so it carries its own connective:
      ## `"from package default (0402)"`, `"tied to ground for a DC
      ## reference"`. Producers phrase their own explanation because a single
      ## fixed connective cannot fit both "where this number came from" and
      ## "what this number is doing here".

proc assumption*(entity, key: string, value: float, unit: string,
                 source: AnnSource, detail = ""): Assumption =
  Assumption(entity: entity, key: key, value: value, unit: unit,
             source: source, detail: detail)

proc note*(detail: string): Assumption =
  ## A narrative assumption with no single key or magnitude behind it.
  Assumption(key: "", source: annDerived, detail: detail, value: NaN)

proc note*(entity, detail: string): Assumption =
  ## The same, about a named part.
  ##
  ## Reads identically to `note(entity & ": " & detail)` and is worth the
  ## second proc because the part stays a *field*: a consumer can then group
  ## the eight capacitors that were all derated the same way onto one line,
  ## which it cannot do once the designator is inside the sentence.
  Assumption(entity: entity, key: "", source: annDerived, detail: detail,
             value: NaN)

proc `$`*(a: Assumption): string =
  if a.key.len == 0:
    return (if a.entity.len > 0: a.entity & ": " & a.detail else: a.detail)
  result = a.entity & ": " & a.key & " " & eng(a.value, a.unit)
  if a.detail.len > 0:
    result &= " " & a.detail

# The keys already load-bearing in the codebase. Everything here is read by
# something *today* -- with one deliberate exception, `tolerance`, which is
# registered so it is at least typed and validated while the analysis that
# would consume it is still unwritten. If that analysis does not arrive,
# delete the key rather than leave a slot nobody fills.
#
# A `const`, not a proc returning a seq, so the DSL macro can read it while
# it expands: that is what turns a misspelled key inside a `spec:` block
# into a compile error rather than a value nothing ever reads.
const builtinAnnotations* = [
  AnnDef(key: "value", kind: akString, scopes: {asComponent},
    doc: "SPICE device value, passed through verbatim to the deck writer " &
         "(e.g. \"1k\", \"100n\", \"DC 0 AC 1\"). Never parsed as a number: " &
         "it may carry a whole source specification, not just a magnitude."),
  AnnDef(key: "voltage", kind: akFloat, unit: "V", scopes: {asNet, asComponent},
    doc: "On a net: nominal rail voltage, read by spice/isolate to " &
         "terminate a cut rail with an ideal source. On a component: the " &
         "voltage that part *produces* -- a regulator's output. The two are " &
         "deliberately separate: the rail's nominal is what you require, " &
         "the part's output is what you chose, and a check is only " &
         "meaningful while they are stated independently."),
  AnnDef(key: "esr", kind: akFloat, unit: "ohm", scopes: {asComponent},
    doc: "Equivalent series resistance. Sets the impedance floor of a " &
         "decoupling capacitor."),
  AnnDef(key: "esl", kind: akFloat, unit: "H", scopes: {asComponent},
    doc: "Equivalent series inductance. Without it a capacitor has no " &
         "self-resonance and a PDN sweep is meaningless above a megahertz."),
  AnnDef(key: "package", kind: akString, scopes: {asComponent},
    doc: "Case size or package family (\"0402\", \"tantalum\"). Keys the " &
         "parasitic defaults table in spice/models."),
  AnnDef(key: "zin", kind: akFloat, unit: "ohm", scopes: {asComponent, asPin},
    doc: "Impedance this pin presents to the net it sits on. Overrides the " &
         "per-pin-kind default spice/models substitutes for a part that " &
         "carries no model. On a component it applies to every pin of that " &
         "component that has no zin of its own."),
  AnnDef(key: "rout", kind: akFloat, unit: "ohm", scopes: {asComponent, asPin},
    doc: "Series output resistance of a source or regulator: the flat, " &
         "low-frequency part of its output impedance. Without it spice/" &
         "models substitutes a default, because an ideal source is a dead " &
         "short at AC and reports every rail as 0 ohm."),
  AnnDef(key: "lout", kind: akFloat, unit: "H", scopes: {asComponent, asPin},
    doc: "Series output inductance of a source or regulator. Stands in for " &
         "both the supply wiring and the rise in output impedance above the " &
         "regulation loop's bandwidth, which is what makes decoupling the " &
         "thing that holds the rail up at high frequency."),
  AnnDef(key: "gain", kind: akFloat, scopes: {asComponent},
    doc: "Voltage gain of a part that passes a signal through, as a plain " &
         "ratio. Read by spice/models when standing in for a buffer or " &
         "driver that carries no model; unity is assumed for a part whose " &
         "kind means unity, and reported as an assumption."),
  AnnDef(key: "gbw", kind: akFloat, unit: "Hz", scopes: {asComponent},
    doc: "Gain-bandwidth product of an amplifier that carries no model. " &
         "Read by spice/models and analysis/opamp when substituting the " &
         "single-pole macromodel; without it a package default is used and " &
         "reported as an assumption. It is worth stating: the default is " &
         "1 MHz, and on a stage of 40 dB that costs 0.7 dB of gain at " &
         "1 kHz against a 10 MHz part, which is more than the whole " &
         "accuracy budget of an equalisation network."),
  AnnDef(key: "dcr", kind: akFloat, unit: "ohm", scopes: {asComponent},
    doc: "DC resistance of a ferrite bead or inductor. On a supply rail it " &
         "is the part of the impedance that never goes away: it costs a " &
         "steady IR drop and sets the floor a decoupling network can reach."),
  AnnDef(key: "z_peak", kind: akFloat, unit: "ohm", scopes: {asComponent},
    doc: "Peak impedance of a ferrite bead, at `f_peak`. This is the number " &
         "a bead is sold by -- a \"600 ohm bead\" means 600 ohm at 100 MHz " &
         "-- and `spice/models` builds the part's whole model from it."),
  AnnDef(key: "f_peak", kind: akFloat, unit: "Hz", scopes: {asComponent},
    doc: "Frequency at which a ferrite bead reaches `z_peak`. 100 MHz is " &
         "the industry convention and the default, because that is where " &
         "datasheets quote the headline number."),
  AnnDef(key: "dielectric", kind: akString, scopes: {asComponent},
    doc: "Capacitor dielectric class (\"C0G\", \"NP0\", \"X7R\", \"X5R\", " &
         "\"Y5V\", \"film\", \"tantalum\", \"electrolytic\"). Read by " &
         "spice/models, and it changes the answer rather than describing it: " &
         "a Class 2 ceramic loses capacitance under DC bias, and an X5R bank " &
         "at two thirds of its rating measured 1.23 ohm of rail impedance " &
         "where its nominal values said 173 mohm. Class 1 (C0G/NP0) does not " &
         "derate at all, which is why a timing capacitor must be one."),
  AnnDef(key: "voltage_rating", kind: akFloat, unit: "V", scopes: {asComponent},
    doc: "Maximum working voltage of the part. Two consumers: the DC-bias " &
         "derating above needs it to know where on the curve the part sits, " &
         "and analysis/derating checks the voltage actually across the part " &
         "against it. NOT the voltage the part produces -- that is `voltage`."),
  AnnDef(key: "current_rating", kind: akFloat, unit: "A", scopes: {asComponent},
    doc: "Maximum continuous current. For an inductor see `isat` as well: " &
         "they are different limits and the smaller one governs."),
  AnnDef(key: "isat", kind: akFloat, unit: "A", scopes: {asComponent},
    doc: "Inductor saturation current -- where the core stops behaving " &
         "linearly and inductance collapses. Distinct from `current_rating`, " &
         "which is a thermal limit: a part can be well inside its thermal " &
         "rating and deeply saturated, and the ripple current a converter " &
         "sees is set by the inductance it actually has, not the one printed " &
         "on it."),
  AnnDef(key: "power_rating", kind: akFloat, unit: "W", scopes: {asComponent},
    doc: "Maximum dissipation. Checked against I^2*R by analysis/derating."),
  AnnDef(key: "t_ambient_min", kind: akFloat, unit: "degC", scopes: {asNetlist},
    doc: "Lowest ambient temperature the board is required to work at. " &
         "Stated on the netlist because it is a property of where the board " &
         "lives, not of any part on it -- see netlist/environment, which " &
         "reads it together with `t_ambient_max` and a part's `delta_t`."),
  AnnDef(key: "t_ambient_max", kind: akFloat, unit: "degC", scopes: {asNetlist},
    doc: "Highest ambient temperature the board is required to work at. " &
         "The pair bounds the range every temperature-dependent answer has " &
         "to hold across; a single figure would make the worst case " &
         "unstatable, since a ceramic loses capacitance at both ends and an " &
         "electrolytic's ESR rises at the cold one."),
  AnnDef(key: "delta_t", kind: akFloat, unit: "degC", scopes: {asComponent},
    doc: "How far above ambient this part runs, in degrees. Defaults to 0 " &
         "-- an ordinary part at ambient -- and is stated only for one that " &
         "is not: a regulator dropping a rail, a sense resistor, anything " &
         "downwind of them. It is a temperature *difference*, so it is added " &
         "to each end of the board's ambient range rather than replacing it. " &
         "Authored today; a later pass may derive it from a dissipation and " &
         "a thermal resistance, at which point this key stays the override."),
  AnnDef(key: "tolerance", kind: akFloat, scopes: {asComponent},
    doc: "PART tolerance as a fraction: how far this component's actual " &
         "value may stray from its nominal one. Accepts a trailing '%'. " &
         "NOT an acceptance band -- a requirement's +-5% is a property of " &
         "the requirement, not of any part, and conflating the two " &
         "produces confidently wrong pass/fail windows."),
]

var registry: OrderedTable[string, AnnDef]
  ## A runtime table, not a `const`: a role, a plugin or an application must
  ## be able to add a key without recompiling this module. The built-in seed
  ## is what the DSL macro can see at compile time and check against.

proc registerAnnotation*(def: AnnDef) =
  if def.key.len == 0:
    raise newException(NetlistError, "annotation key must not be empty")
  registry[def.key] = def

for d in builtinAnnotations:
  registry[d.key] = d

proc builtinDef*(key: string): AnnDef =
  ## Lookup restricted to the compile-time-known built-ins, usable from a
  ## macro body. Returns an `AnnDef` with an empty `key` when there is no
  ## match. Runtime-registered keys are deliberately invisible here: a macro
  ## cannot see them, so the DSL checks what it can and leaves the rest to
  ## `validateAnnotations`.
  for d in builtinAnnotations:
    if d.key == key: return d
  AnnDef()

proc isNamespaced*(key: string): bool {.inline.} =
  ## Dotted keys belong to a module, format or user and are never validated.
  '.' in key

proc isRegistered*(key: string): bool {.inline.} =
  registry.hasKey(key)

proc annDef*(key: string): AnnDef =
  if not registry.hasKey(key):
    raise newException(NetlistError, "no such annotation: " & key)
  registry[key]

proc registeredKeys*(): seq[string] =
  for k in registry.keys: result.add k

# --- scope -------------------------------------------------------------

proc `$`*(s: AnnScope): string =
  ## Reads in an error message: "does not apply to a net", not "to a asNet".
  case s
  of asNetlist: "netlist"
  of asNet: "net"
  of asComponent: "component"
  of asPin: "pin"

proc scopeOf*(e: Net): AnnScope {.inline.} = asNet
proc scopeOf*(e: Component): AnnScope {.inline.} = asComponent
proc scopeOf*(e: Pin): AnnScope {.inline.} = asPin
proc scopeOf*(e: Netlist): AnnScope {.inline.} = asNetlist

# --- parsing -----------------------------------------------------------

proc parseAnnFloat*(key, raw: string): float =
  ## Canonical storage is a plain decimal or scientific literal, optionally
  ## with a trailing `%`. A SPICE-style magnitude suffix (`20m`, `1k`, `4u7`)
  ## is **rejected**, not interpreted: this vocabulary is SI base units, and
  ## silently reading `"20m"` as either 20 or 0.02 is precisely the failure
  ## these types exist to prevent. Author it as `20.mohm` instead.
  var s = raw.strip()
  var scale = 1.0
  if s.endsWith("%"):
    s = s[0 ..< s.high]
    scale = 0.01
  try:
    result = parseFloat(s.strip()) * scale
  except ValueError:
    raise newException(NetlistError,
      "annotation '" & key & "' is not a plain SI value: " & raw.escape() &
      " (a SPICE magnitude suffix such as 'm' or 'k' is not accepted here; " &
      "use a nimcir/units literal or a bare number in base units)")

# --- reading -----------------------------------------------------------

proc sourceOf[E](e: E, key: string): AnnSource =
  if not e.attrs.hasKey(key): return annAbsent
  let marker = srcPrefix & key
  if not e.attrs.hasKey(marker): return annAuthored
  case e.attrs[marker]
  of "imported": annImported
  of "defaulted": annDefaulted
  of "derived": annDerived
  else: annAuthored

proc prettyValue*(text: string): string =
  ## A stored annotation rendered for a human. Values are stored canonically
  ## (`4.000000000e+05`) so a deck writer and a parser never disagree, which
  ## is exactly wrong for reading: this renders a numeric one through
  ## `nimcir/eng` and passes anything else through untouched.
  try:
    eng(parseAnnFloat("", text))
  except CatchableError:
    text

proc annotation*[E](e: E, key: string): AnnValue[string] =
  ## Raw stored text plus its provenance. Never defaults -- an absent key is
  ## `annAbsent`, and inventing a stand-in is a policy decision belonging to
  ## the consumer that knows what a sensible stand-in would be.
  if not e.attrs.hasKey(key):
    return AnnValue[string](source: annAbsent)
  AnnValue[string](source: sourceOf(e, key), value: e.attrs[key])

proc annotationFloat*[E](e: E, key: string): AnnValue[float] =
  let raw = annotation(e, key)
  if not raw.has:
    return AnnValue[float](source: annAbsent)
  AnnValue[float](source: raw.source, value: parseAnnFloat(key, raw.value))

# --- writing -----------------------------------------------------------

proc putRaw[E](e: E, key, text: string, source: AnnSource) =
  e.attrs[key] = text
  let marker = srcPrefix & key
  case source
  of annAuthored, annAbsent: e.attrs.del(marker)
  of annImported: e.attrs[marker] = "imported"
  of annDefaulted: e.attrs[marker] = "defaulted"
  of annDerived: e.attrs[marker] = "derived"

proc checkKey[E](e: E, key: string) =
  if isNamespaced(key): return
  if not isRegistered(key):
    raise newException(NetlistError,
      "unknown annotation '" & key & "': register it with registerAnnotation, " &
      "or namespace it (e.g. \"mine." & key & "\") if it is your own")
  let def = registry[key]
  if scopeOf(e) notin def.scopes:
    raise newException(NetlistError,
      "annotation '" & key & "' does not apply to a " & $scopeOf(e))

proc setRawAnnotation*[E](e: E, key, text: string) =
  ## Stores text with no validation at all -- the escape hatch the DSL's
  ## permissive `key = value` path uses, and what a file reader wants for a
  ## foreign key it is passing through untouched.
  ##
  ## It exists as a proc rather than leaving callers to write `e.attrs[k] = v`
  ## so that neither the DSL's expansion nor a reader has to make the caller
  ## `import std/tables` for the privilege.
  e.attrs[key] = text

proc setAnnotation*[E](e: E, key: string, v: string, source = annAuthored) =
  ## Validates the text against the key's declared type before storing it.
  checkKey(e, key)
  if not isNamespaced(key) and registry[key].kind == akFloat:
    discard parseAnnFloat(key, v)   # raises if it is not a plain SI value
  putRaw(e, key, v, source)

proc setAnnotation*[E](e: E, key: string, v: SomeNumber, source = annAuthored) =
  checkKey(e, key)
  putRaw(e, key, formatFloat(float(v), ffScientific, 9), source)

proc setAnnotation*[E](e: E, key: string, v: Quantity, source = annAuthored) =
  ## Also checks the unit: `esr = 20.nF` is rejected, because the registry
  ## says `esr` is ohms.
  checkKey(e, key)
  if not isNamespaced(key):
    let def = registry[key]
    if def.unit.len > 0 and unitOf(v) != def.unit:
      raise newException(NetlistError,
        "annotation '" & key & "' is in " & def.unit & ", but was given " &
        unitOf(v) & " (" & $v & ")")
  putRaw(e, key, formatFloat(toFloat(v), ffScientific, 9), source)

# --- named accessors for the keys with real consumers ------------------

proc railVoltage*(n: Net): AnnValue[float] = annotationFloat(n, "voltage")
proc setRailVoltage*(n: Net, v: Volts, source = annAuthored) =
  setAnnotation(n, "voltage", v, source)

proc esr*(c: Component): AnnValue[float] = annotationFloat(c, "esr")
proc esl*(c: Component): AnnValue[float] = annotationFloat(c, "esl")
proc package*(c: Component): AnnValue[string] = annotation(c, "package")
proc deviceValue*(c: Component): AnnValue[string] = annotation(c, "value")

# --- validation --------------------------------------------------------

proc checkEntity[E](e: E, label: string, net: Net, comp: Component,
                    pin: Pin, issues: var seq[Issue]) =
  for key, raw in e.attrs:
    if key.startsWith(srcPrefix): continue
    if isNamespaced(key): continue
    if not isRegistered(key):
      issues.add newIssue("unknown_annotation", sevWarning,
        label & " has unregistered annotation '" & key & "'. A bare key is " &
        "meant to be part of the shared vocabulary, so this is most likely a " &
        "misspelling -- an unrecognised key is silently ignored by every " &
        "consumer, which looks identical to the value being absent. " &
        "Namespace it if it is deliberately your own.",
        net = net, pins = (if pin != nil: @[pin] else: @[]),
        components = (if comp != nil: @[comp] else: @[]))
      continue
    let def = registry[key]
    if scopeOf(e) notin def.scopes:
      issues.add newIssue("annotation_wrong_scope", sevError,
        label & ": annotation '" & key & "' does not apply to a " & $scopeOf(e),
        net = net, pins = (if pin != nil: @[pin] else: @[]),
        components = (if comp != nil: @[comp] else: @[]))
      continue
    if def.kind == akFloat:
      try:
        discard parseAnnFloat(key, raw)
      except NetlistError as err:
        issues.add newIssue("annotation_unparseable", sevError,
          label & ": " & err.msg,
          net = net, pins = (if pin != nil: @[pin] else: @[]),
          components = (if comp != nil: @[comp] else: @[]))
    elif def.kind == akEnum and def.allowed.len > 0 and raw notin def.allowed:
      issues.add newIssue("annotation_not_allowed", sevError,
        label & ": annotation '" & key & "' = " & raw.escape() &
        " is not one of " & def.allowed.join(", "),
        net = net, pins = (if pin != nil: @[pin] else: @[]),
        components = (if comp != nil: @[comp] else: @[]))

proc validateAnnotations*(nl: Netlist, recursive = true): seq[Issue] =
  ## Reports misspelled bare keys, keys used on the wrong kind of entity, and
  ## values that do not parse as their declared type. Namespaced keys are
  ## never reported.
  checkEntity(nl, "netlist '" & nl.name & "'", nil, nil, nil, result)
  for _, n in nl.nets:
    checkEntity(n, "net '" & n.name & "'", n, nil, nil, result)
  for _, c in nl.components:
    checkEntity(c, "component " & c.designator, nil, c, nil, result)
    for _, p in c.pins:
      checkEntity(p, "pin " & c.designator & "." & p.name, nil, c, p, result)
  if recursive:
    for _, child in nl.children:
      result.add validateAnnotations(child, recursive = true)
