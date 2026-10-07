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
  AnnDef(key: "footprint", kind: akString, scopes: {asComponent},
    doc: "Land pattern this part solders to, as \"Lib:Name\" or a path to a " &
         ".kicad_mod file. Distinct from `package`, which is a case size " &
         "keying parasitic defaults; two parts may share a case size and " &
         "need different land patterns (hand-solder vs. reflow). Read by " &
         "pcb/assemble.nim, in resolution order: this key, then a multi-" &
         "channel package's PackageDef.footprint, then unresolved."),
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
  AnnDef(key: "ron", kind: akFloat, unit: "ohm", scopes: {asComponent},
    doc: "On-resistance of a switch, analog mux or relay contact. Read by " &
         "spice/models when it stands the part up as a voltage-controlled " &
         "`.MODEL SW` switch; a typical is used and reported as an " &
         "assumption otherwise. For an absorptive RF mux this is the through " &
         "path's series resistance against the 50 ohm ports."),
  AnnDef(key: "roff", kind: akFloat, unit: "ohm", scopes: {asComponent},
    doc: "Off-resistance of a switch or mux -- the leakage path of an open " &
         "throw. Defaults to 1 Gohm, reported as an assumption; state it " &
         "from the datasheet's off-isolation where that is what is being " &
         "studied."),
  AnnDef(key: "vt", kind: akFloat, unit: "V", scopes: {asComponent},
    doc: "Control-input threshold of a switch: the voltage on the control " &
         "pin at which it changes state. Defaults to half the control " &
         "rail. Paired with `vh`."),
  AnnDef(key: "vh", kind: akFloat, unit: "V", scopes: {asComponent},
    doc: "Control-input hysteresis of a switch, as passed to `.MODEL SW`. " &
         "Defaults to a tenth of the control rail."),
  AnnDef(key: "k_coupling", kind: akFloat, scopes: {asComponent},
    doc: "Coupling coefficient between the windings of a transformer or " &
         "common-mode choke, 0..1, emitted as the value of a SPICE `K` " &
         "card. Leakage inductance is implicit in `k < 1`. Defaults to " &
         "0.98 and says so: every real wound part is 0.95..0.995 and the " &
         "answer is not sensitive to which."),
  AnnDef(key: "turns", kind: akFloat, scopes: {asComponent},
    doc: "Secondary-to-primary turns ratio Ns/Np of a transformer. With " &
         "`lpri` it fixes the secondary inductance (Ls = Lp * turns^2), " &
         "which is how a flyback datasheet specifies one. Ignored when " &
         "`lsec` is stated directly."),
  AnnDef(key: "lpri", kind: akFloat, unit: "H", scopes: {asComponent},
    doc: "Primary (or first-winding) inductance of a transformer or " &
         "coupled inductor. spice/models needs this or `lsec` to build the " &
         "part at all -- there is no defensible default magnetising " &
         "inductance, so an unstated one leaves the part unmodelled with a " &
         "note rather than a guess."),
  AnnDef(key: "lsec", kind: akFloat, unit: "H", scopes: {asComponent},
    doc: "Secondary-winding inductance of a transformer. Stated directly, " &
         "or derived from `lpri` and `turns`."),

  # --- RF datasheet vocabulary --------------------------------------------
  # `parts/Choice` is a procurement record and carries none of this -- an
  # amplifier's gain, noise figure and linearity are electrical performance
  # the way `gbw` and `esr` are, not part-selection metadata, so they belong
  # in the same vocabulary as those rather than in a second one. None of
  # these is read by anything yet: `analysis/rf_chain.nim` and
  # `analysis/cascade.nim` (Friis, cascaded IP3, dynamic range) are a later
  # phase's work, and registering the keys first is what lets a design state
  # a datasheet number today without namespacing it as `rf.gain_db` and
  # rewriting the design once the reader arrives -- the same reason
  # `tolerance` was registered ahead of its consumer.
  AnnDef(key: "gain_db", kind: akFloat, unit: "dB", scopes: {asComponent},
    doc: "Small-signal voltage or power gain of an RF stage (an LNA, a PA, " &
         "a VGA, a mixer's conversion gain), datasheet-typical rather than " &
         "measured. A budget walk sums these along a chain (Friis, run in " &
         "reverse for gain); a `.sp`/`.ac` sweep of the same stage produces " &
         "`s21_db` or `gain_at_f_db` instead, and the two are named " &
         "differently on purpose -- see `psrr_db`/`psrr_min_db` for the " &
         "precedent that keeps a datasheet claim and a simulated one from " &
         "being written to the same key and read back as if they agreed."),
  AnnDef(key: "nf_db", kind: akFloat, unit: "dB", scopes: {asComponent},
    doc: "Noise figure of an RF stage, datasheet-typical. Feeds Friis's " &
         "cascade noise figure the same way `gain_db` feeds cascade gain. " &
         "`.noise` measures a passive or S-parameter network faithfully but " &
         "cannot see a behavioural or vendor-supplied block's own noise " &
         "contribution -- confirmed empirically: a gain-10 VCVS chain " &
         "reported exactly the source resistor's thermal noise times ten " &
         "and nothing else -- which is why a simulated `nf_sim_db` carries " &
         "its own provenance rather than silently disagreeing with this."),
  AnnDef(key: "oip3_dbm", kind: akFloat, unit: "dBm", scopes: {asComponent},
    doc: "Output third-order intercept point: the extrapolated power at " &
         "which a stage's fundamental and its third-order intermodulation " &
         "product would cross, in dBm. The datasheet linearity figure a " &
         "cascade's dynamic range is budgeted from before anything is " &
         "simulated; `oip3_sim_dbm` is the two-tone `.tran` measurement of " &
         "the same number and is a different key for the same reason " &
         "`nf_db`/`nf_sim_db` are."),
  AnnDef(key: "iip3_dbm", kind: akFloat, unit: "dBm", scopes: {asComponent},
    doc: "Input third-order intercept point -- `oip3_dbm` referred to the " &
         "stage's input (IIP3 = OIP3 - gain). Datasheets state one or the " &
         "other and rarely both; keep whichever the datasheet gives rather " &
         "than back-computing, since that only moves where an unstated " &
         "gain figure's error lands."),
  AnnDef(key: "p1db_dbm", kind: akFloat, unit: "dBm", scopes: {asComponent},
    doc: "1 dB compression point, output-referred: the power at which the " &
         "stage's gain has dropped 1 dB from its small-signal value -- the " &
         "practical upper edge of the linear region a gain/OIP3 budget " &
         "assumes. `p1db_sim_dbm` is the swept-power measurement of the " &
         "same thing."),
  AnnDef(key: "psat_dbm", kind: akFloat, unit: "dBm", scopes: {asComponent},
    doc: "Saturated output power: the ceiling a power amplifier's output " &
         "cannot be driven past regardless of input, well beyond `p1db_dbm`. " &
         "Sets the hard limit for a transmit chain's maximum output claim " &
         "the way `voltage_rating` sets one for a part's working voltage."),
  AnnDef(key: "il_db", kind: akFloat, unit: "dB", scopes: {asComponent},
    doc: "Insertion loss of a passive part (a filter, a coupler's through " &
         "arm, a switch's on-state) at its stated frequency -- positive, " &
         "the conventional sign for a loss rather than a raw negative S21 " &
         "dB reading. `insertion_loss_db` is the simulated counterpart, " &
         "read off a `.sp` S21 through `touchstone.insertionLossDb`, which " &
         "shares this sign convention so the two can be compared directly."),
  AnnDef(key: "isolation_db", kind: akFloat, unit: "dB", scopes: {asComponent},
    doc: "Isolation between two paths that should not couple -- an off " &
         "switch throw, a coupler's isolated port, a circulator's reverse " &
         "path -- positive, larger is better. `isolation_sim_db` is the " &
         "measured counterpart once a `.sp` model exists to sweep it; " &
         "`spice/models/switch`'s `off_termination` already gives a " &
         "behavioural switch a real (frequency-flat) isolation floor, which " &
         "this key does not yet feed."),
  AnnDef(key: "return_loss_db", kind: akFloat, unit: "dB", scopes: {asComponent},
    doc: "Datasheet return loss at the part's rated impedance -- positive, " &
         "larger is a better match, matching `touchstone.returnLossDb`'s " &
         "sign (the opposite sign from a raw S11 dB reading). The simulated " &
         "counterpart is `s11_db`/`return_loss_db` produced by a `.sp` run, " &
         "named identically on purpose since a port match is the one RF " &
         "figure here where a stated and a measured value are meant to be " &
         "compared directly rather than kept apart by name -- there is no " &
         "cascaded arithmetic that combines several parts' return losses " &
         "into one number the way Friis combines gain and noise figure."),
  AnnDef(key: "z0", kind: akFloat, unit: "ohm", scopes: {asComponent, asPin},
    doc: "Reference impedance a port is designed against -- almost always " &
         "50 ohm, sometimes 75. `rf_port` (a later phase's role) reads this " &
         "to know what a `.sp` port card should carry and what `sAt`/" &
         "`gammaOf` should compare a simulated or measured impedance " &
         "against; a component-scope value applies to every pin of that " &
         "part with no `z0` of its own, the same fallback `zin`/`rout` use."),
  AnnDef(key: "sparams", kind: akString, scopes: {asComponent},
    doc: "Path to a Touchstone `.s1p`/`.s2p`/`.sNp` file describing this " &
         "part's measured or vendor-simulated S-parameters. Free text, " &
         "never parsed here -- same pattern as `dielectric` and `value` -- " &
         "because reading and interpreting the file is `verax/touchstone`'s " &
         "job and turning it into a runnable device is a later phase's " &
         "`sparam_block` XSPICE model, neither of which this module may " &
         "depend on without `netlist` gaining an edge it must not have."),
  AnnDef(key: "er", kind: akFloat, scopes: {asComponent},
    doc: "Substrate relative permittivity (dielectric constant) for a " &
         "microstrip or stripline component. Dimensionless by definition, " &
         "so no unit is checked -- feeds a closed-form Z0 calculation " &
         "(Hammerstad-Jensen or IPC-2141) the way `pcb/types.StackMaterial` " &
         "already carries it for a board's own stackup; authored here " &
         "because a transmission-line *component* in phase 0 has no `Pcb` " &
         "to read a stackup from."),
  AnnDef(key: "tand", kind: akFloat, scopes: {asComponent},
    doc: "Substrate loss tangent, dimensionless. Paired with `er`; the pair " &
         "is exactly what ngspice's `mlin` microstrip model (verified " &
         "present in the installed ngspice 46 build) takes alongside " &
         "`trace_width`/`substrate_h`/`copper_t`/`roughness`."),
  AnnDef(key: "trace_width", kind: akFloat, scopes: {asComponent},
    doc: "Trace width, in **metres** -- there is no `Metres` type in " &
         "`verax/units` yet (board geometry lives in `pcb/units.Nm`, a " &
         "deliberately different tier per `verax/CLAUDE.md`, and adding a " &
         "third geometry representation for one annotation set is a bigger " &
         "decision than this phase warrants), so this is registered " &
         "unit-less and documented here instead -- the same unenforced-but-" &
         "documented convention `dielectric`'s free-text values and " &
         "`tolerance`'s bare fraction already use. State it in metres " &
         "(`0.2e-3` for a 0.2 mm trace), not millimetres."),
  AnnDef(key: "trace_length", kind: akFloat, scopes: {asComponent},
    doc: "Trace length, in metres -- see `trace_width` for why this is " &
         "unit-less rather than typed, and state it the same way."),
  AnnDef(key: "substrate_h", kind: akFloat, scopes: {asComponent},
    doc: "Substrate (dielectric) height under the trace, in metres -- see " &
         "`trace_width`. The `h` in ngspice's `mlin` model and in the " &
         "Hammerstad-Jensen closed form alike."),
  AnnDef(key: "copper_t", kind: akFloat, scopes: {asComponent},
    doc: "Copper thickness, in metres -- see `trace_width`. Standard " &
         "1 oz copper is about 35e-6 m; state the actual weight rather " &
         "than assuming it, since `mlin` and IPC-2141 both use it directly " &
         "in the impedance formula rather than as a second-order term."),
  AnnDef(key: "roughness", kind: akFloat, scopes: {asComponent},
    doc: "Copper surface roughness, in metres RMS -- see `trace_width`. " &
         "Matters more at the frequencies this vocabulary exists for than " &
         "it does anywhere else in this library: roughness loss rises with " &
         "frequency and can dominate a microstrip's total loss well before " &
         "the skin-effect term does."),
  AnnDef(key: "antenna_gain_dbi", kind: akFloat, unit: "dB", scopes: {asComponent},
    doc: "Antenna gain relative to an isotropic radiator, in dBi. " &
         "Registered in unit `\"dB\"` rather than a fourth logarithmic " &
         "type: dBi and dB are the same logarithmic ratio, differing only " &
         "in what they are referred to (isotropic vs. nothing stated), so " &
         "`setAnnotation(c, \"antenna_gain_dbi\", x.dB)` round-trips " &
         "correctly and a `DBi` type would buy nothing a fourth near-" &
         "identical type doesn't already cost. Feeds `eirp_dbm` (a later " &
         "phase's budget quantity) together with a transmit chain's output " &
         "power; stating neither this nor `antenna_efficiency` still " &
         "leaves the chain's conducted power at the port checkable, per " &
         "this area's graceful-degradation rule."),
  AnnDef(key: "antenna_efficiency", kind: akFloat, scopes: {asComponent},
    doc: "Radiation efficiency as a fraction 0..1 (dimensionless, like " &
         "`tolerance` -- accepts a trailing '%' through the same " &
         "`parseAnnFloat` path). An antenna that is a good 50 ohm match " &
         "can still radiate a small fraction of what it accepts, and " &
         "`return_loss_db` alone cannot see the difference between power " &
         "radiated and power lost as heat in the element -- this is the " &
         "other half of the number an EIRP claim needs."),

  # --- BOM vocabulary ------------------------------------------------------
  # `docs/bom_compiler_plan.md`'s fact 2: `Component.partNumber` is already
  # overloaded four ways (a real MPN, an internal house part number, a
  # subcircuit template name, and -- confirmed live in ~20 design sites -- a
  # free-text descriptive label like "USB-C receptacle"). A BOM compiler
  # cannot treat `partNumber` as the MPN without presenting every one of
  # those free-text sites as a confident, wrong part number, so `mpn` is its
  # own key rather than a second meaning layered onto an already-overloaded
  # one -- and the labels moved to `description`, so `partNumber` holds
  # part numbers and nothing else. A key is free; a field with two meanings
  # costs every reader forever.
  AnnDef(key: "mpn", kind: akString, scopes: {asComponent},
    doc: "Manufacturer part number, authorable as `spec: mpn = \"...\"`. " &
         "Distinct from `Component.partNumber`, which may be an MPN or an " &
         "internal/house part number -- a BOM resolver treats this key as " &
         "authoritative and falls back to `partNumber`, unverified and " &
         "said so, only when this is absent. A descriptive label belongs " &
         "in `description`."),
  AnnDef(key: "description", kind: akString, scopes: {asComponent},
    doc: "What the part is, in words: `\"USB-C 2.0 receptacle\"`, " &
         "`\"2-pin 0.1in header\"`. A label, never ordered by -- the BOM " &
         "prints it when no catalogue describes the part, and " &
         "`Component.partNumber` stays a part number."),
  AnnDef(key: "manufacturer", kind: akString, scopes: {asComponent},
    doc: "Pairs with `mpn` -- an MPN is only unique within a manufacturer " &
         "(two vendors can and do reuse the same part number for unrelated " &
         "parts)."),
  AnnDef(key: "part_use", kind: akEnum, scopes: {asComponent},
    allowed: @["timing", "coupling", "decoupling", "bulk", "precision",
               "general", "power", "filter"],
    doc: "What this part is *for* -- the union of `parts.CapUse`/`ResUse`/" &
         "`IndUse`, spelled without the enum prefixes, so a BOM compiler " &
         "reading a finished netlist can tell a timing capacitor from a " &
         "bypass one. `parts/annotate.applyChoice` writes this from " &
         "whichever request the module stated; a hand-authored part states " &
         "it directly. Without it, the distinction `parts/CLAUDE.md` exists " &
         "for -- a Class 2 dielectric in a filter moving the corner by tens " &
         "of percent -- is visible in `dielectric` but not in *why* that " &
         "dielectric was chosen, which is what a reviewer actually needs to " &
         "confirm a policy decision was the right one for this part."),
  AnnDef(key: "dnp", kind: akBool, scopes: {asComponent},
    doc: "Do not populate: the part is on the board and on the BOM, but " &
         "not fitted at assembly. Still a real BOM line -- a DNP part keeps " &
         "its own line rather than vanishing, because dropping it hides an " &
         "assembly decision -- and one that needs no orderable MPN."),
  AnnDef(key: "bom_exclude", kind: akBool, scopes: {asComponent},
    doc: "Leave this part off the bill of materials entirely -- a part that " &
         "is not bought (a net tie, a board-edge connector that is just " &
         "copper, a fiducial). Distinct from `dnp`, which keeps the line. " &
         "Simulation-only kinds (sources, controlled sources, couplings) " &
         "need no flag: `verax/bom` leaves them out by kind."),
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
      "use a verax/units literal or a bare number in base units)")

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
  ## `verax/eng` and passes anything else through untouched.
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

proc annotationBool*[E](e: E, key: string): AnnValue[bool] =
  ## `"true"` is true; anything else stated reads as false. Only
  ## `validateAnnotations` reports a value that is neither, the way every
  ## other accessor here stays pure and total.
  let raw = annotation(e, key)
  if not raw.has:
    return AnnValue[bool](source: annAbsent)
  AnnValue[bool](source: raw.source, value: raw.value == "true")

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
  ##
  ## `akEnum` is checked here too, not only by `validateAnnotations` at
  ## `readiness` -- `part_use` is this registry's first `akEnum` builtin, and
  ## leaving it unchecked at write time would mean a typo'd
  ## `part_use = "timming"` sits silently in `attrs` until the next full
  ## check runs, the exact gap an `akFloat` typo never has (`parseAnnFloat`
  ## already raises immediately, below). Checking here instead closes that
  ## gap for every future `akEnum` key too, not just this one.
  checkKey(e, key)
  if not isNamespaced(key):
    let def = registry[key]
    if def.kind == akFloat:
      discard parseAnnFloat(key, v)   # raises if it is not a plain SI value
    elif def.kind == akBool and v notin ["true", "false"]:
      raise newException(NetlistError,
        "annotation '" & key & "' = " & v.escape() & " is not true or false")
    elif def.kind == akEnum and def.allowed.len > 0 and v notin def.allowed:
      raise newException(NetlistError,
        "annotation '" & key & "' = " & v.escape() & " is not one of " &
        def.allowed.join(", "))
  putRaw(e, key, v, source)

proc setAnnotation*[E](e: E, key: string, v: bool, source = annAuthored) =
  ## `spec: dnp = true` lands here. Stored as `"true"`/`"false"`, the
  ## spelling `annotationBool` and `validateAnnotations` both accept.
  checkKey(e, key)
  if not isNamespaced(key) and registry[key].kind != akBool:
    raise newException(NetlistError,
      "annotation '" & key & "' is not a true/false key, but was given " & $v)
  putRaw(e, key, $v, source)

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
proc footprint*(c: Component): AnnValue[string] = annotation(c, "footprint")
proc deviceValue*(c: Component): AnnValue[string] = annotation(c, "value")
proc mpn*(c: Component): AnnValue[string] = annotation(c, "mpn")
proc manufacturer*(c: Component): AnnValue[string] = annotation(c, "manufacturer")
proc description*(c: Component): AnnValue[string] = annotation(c, "description")
proc partUse*(c: Component): AnnValue[string] = annotation(c, "part_use")
proc dnp*(c: Component): AnnValue[bool] = annotationBool(c, "dnp")
proc bomExclude*(c: Component): AnnValue[bool] = annotationBool(c, "bom_exclude")

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
    elif def.kind == akBool and raw notin ["true", "false"]:
      issues.add newIssue("annotation_unparseable", sevError,
        label & ": annotation '" & key & "' = " & raw.escape() &
        " is not true or false",
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
