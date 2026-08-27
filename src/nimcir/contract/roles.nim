## Roles: named, parameterized bundles of assertions.
##
## A role says what something *is* in a design -- "this net is the 3V3 rail",
## "these two nets are a 400 kHz I2C bus" -- which is the metadata a whole
## family of planned checks is blocked on. The design decision worth stating
## plainly is that **a role is a template, not a tag**.
##
## A bare tag (`kind = "i2c"`) puts the meaning in whatever reads the tag, so
## supporting a new protocol means changing this library. A template puts the
## meaning in the definition, so a user with a niche protocol writes a
## `RoleDef` in their own file and registers it. The built-in roles below use
## **no privileged mechanism** -- they are ordinary `RoleDef`s registered the
## ordinary way -- because a built-in that cheats makes user-defined roles
## second-class and then nobody writes them.
##
## **A role has two halves, and they are deliberately separate procs.**
##
## * `apply` writes annotations onto the netlist. This is the half with a life
##   independent of any checking: `spice/isolate` terminates a cut rail using
##   `Net.attrs["voltage"]`, long before anything asks whether the rail is
##   *correct*. If a role were only a bundle of assertions, `isolate` would
##   have to introspect the assertion list to recover a rail voltage, which is
##   backwards and fragile.
## * `expand` is pure and returns assertions. It never touches the graph.
##
## `RoleDef.expand`/`apply` are **proc values on a data object**, not
## compile-time constructs, so a role built at runtime -- from a config file,
## an MCP call, or a loaded plugin -- registers and behaves identically to one
## written here.

import std/tables
import ../netlist/types
import ../netlist/annotations
import ../units
import ./types as ctypes

export ctypes

type
  RolePart* = object
    name*: string
      ## The part this subject plays: `"rail"`, `"sda"`, `"controller"`.
    kind*: SubjectKind
    optional*: bool
    doc*: string

  RoleInstance* = object
    role*: string
      ## Which `RoleDef`.
    name*: string
      ## This instance: `"vdd_rail"`, `"i2c0"`.
    bindings*: OrderedTable[string, Subject]
    params*: OrderedTable[string, string]
    declined*: seq[string]
      ## Claim suffixes this instance does not make, from the reserved
      ## `without` parameter. A role's *always-claims* are otherwise
      ## unconditional, and some of them do not fit every circuit the role
      ## otherwise describes: `opamp_stage` claims `phase_margin_deg`, and
      ## `analyzeLoopGain` cannot open a Sallen-Key's loop, so the claim can
      ## only ever come back unchecked. Carrying an unmeasurable claim in
      ## every run is its own harm -- `NOT CHECKED` is the section that must
      ## not become background noise -- and the alternative was to fork the
      ## role, which is how a shared vocabulary dies.
      ##
      ## Declining is **not** silence: `explain` still prints what was
      ## declined, and a suffix that matches nothing is an error rather than
      ## a typo that quietly leaves the claim in place.

  RoleExpander* = proc (inst: RoleInstance): seq[Assertion] {.nimcall.}
    ## May raise: `addRole` validates bindings and parameters before an
    ## expander ever sees an instance, so an expander is entitled to assume
    ## its required parts are present rather than defending against it.
  RoleApplier* = proc (inst: RoleInstance, nl: Netlist) {.nimcall.}

  RoleDef* = object
    name*: string
    doc*: string
    parts*: seq[RolePart]
    params*: seq[AnnDef]
      ## Reuses the annotation registry's vocabulary type rather than
      ## inventing a second one: a role parameter and a design annotation are
      ## the same kind of thing (a named, typed, documented value) and should
      ## not be described twice in two ways.
    apply*: RoleApplier
    expand*: RoleExpander

var roleRegistry: OrderedTable[string, RoleDef]

proc registerRole*(def: RoleDef) =
  if def.name.len == 0:
    raise newException(NetlistError, "role name must not be empty")
  if def.expand == nil:
    raise newException(NetlistError, "role '" & def.name & "' has no expander")
  roleRegistry[def.name] = def

proc roleDef*(name: string): RoleDef =
  if not roleRegistry.hasKey(name):
    raise newException(NetlistError, "no such role: " & name)
  roleRegistry[name]

proc isRole*(name: string): bool = roleRegistry.hasKey(name)
proc registeredRoles*(): seq[string] =
  for k in roleRegistry.keys: result.add k

# --- parameter access --------------------------------------------------

proc paramFloat*(inst: RoleInstance, name: string, fallback: float): float =
  ## A role parameter as a number, falling back when unset. Roles apply their
  ## own defaults explicitly rather than the registry carrying them: a
  ## defaulted *design annotation* is a silent-drift hazard worth keeping
  ## visible, and lumping role defaults in with it would blur the two.
  if not inst.params.hasKey(name): return fallback
  parseAnnFloat(name, inst.params[name])

proc hasParam*(inst: RoleInstance, name: string): bool =
  inst.params.hasKey(name)

proc subject*(inst: RoleInstance, part: string): Subject =
  if not inst.bindings.hasKey(part):
    raise newException(NetlistError,
      "role '" & inst.name & "' has no binding for part '" & part & "'")
  inst.bindings[part]

proc hasPart*(inst: RoleInstance, part: string): bool =
  inst.bindings.hasKey(part)

proc assertionId*(inst: RoleInstance, suffix: string): string =
  inst.name & "." & suffix

# --- built-in: power_rail ----------------------------------------------

proc powerRailApply(inst: RoleInstance, nl: Netlist) =
  ## Writes the nominal voltage where every existing consumer already looks
  ## for it. `spice/isolate` needs no knowledge that roles exist.
  let rail = inst.subject("rail")
  if not nl.nets.hasKey(rail.name):
    raise newException(NetlistError, "no such net: " & rail.name)
  if inst.hasParam("voltage"):
    setRailVoltage(nl.nets[rail.name],
                   Volts(paramFloat(inst, "voltage", 0.0)), annAuthored)

proc powerRailExpand(inst: RoleInstance): seq[Assertion] =
  let rail = inst.subject("rail")
  let v = paramFloat(inst, "voltage", 0.0)
  let band = paramFloat(inst, "band", 0.05)
  result.add Assertion(
    id: assertionId(inst, "voltage"),
    subjects: @[rail],
    quantity: "dc_voltage",
    expect: nominal(v, fracTol = band),
    unit: "V",
    severity: sevError,
    rationale: "the rail must actually sit at its nominal voltage; every " &
               "analysis that terminates this rail with an ideal source " &
               "assumes it does",
    origin: inst.name)

  # Also opt-in, and for the same reason as `targetZ`: a derating ceiling is
  # a project rule, not a property of the circuit. Stating one is also the
  # only thing that makes the question answerable at all -- an operating
  # point cannot tell a 6.3 V part from a 50 V one, so a design whose parts
  # carry no `voltage_rating` gets an honest "nothing was checked" rather
  # than a pass.
  if inst.hasParam("maxDerating"):
    result.add Assertion(
      id: assertionId(inst, "derating"),
      subjects: @[rail],
      quantity: "worst_voltage_derating",
      expect: atMost(paramFloat(inst, "maxDerating", 0.8)),
      unit: "",
      severity: sevWarning,
      rationale: "every part on this rail must be working inside its " &
                 "voltage rating with margin; a tantalum over its rating " &
                 "fails short and takes the rail with it",
      origin: inst.name)

  # Only claimed when a target is stated. A decoupling target is a design
  # decision -- it comes from the load's transient current and its tolerated
  # ripple -- and inventing a default here would manufacture a claim the
  # designer never made and then report it as theirs.
  if inst.hasParam("targetZ"):
    var a = Assertion(
      id: assertionId(inst, "impedance"),
      subjects: @[rail],
      quantity: "z_max_in_band",
      expect: atMost(paramFloat(inst, "targetZ", 0.0)),
      unit: "ohm",
      severity: sevWarning,
      rationale: "the decoupling network must hold the rail below its " &
                 "target impedance across the band where the capacitors, " &
                 "rather than the regulator or the planes, are what control it",
      origin: inst.name)
    # The band is bounded at both ends deliberately: below the regulator's
    # crossover the regulator holds the rail up and has been cut away, and
    # above ~100 MHz plane and package parasitics dominate, so a discrete
    # capacitor cannot fix a violation at either end.
    a.condition["f_from"] = $paramFloat(inst, "targetFrom", 1.0e5)
    a.condition["f_to"] = $paramFloat(inst, "targetTo", 1.0e8)
    result.add a

# --- built-in: i2c -----------------------------------------------------

const i2cCornerMargin = 10.0
  ## How far above the bus clock the SDA/SCL RC corner must sit. A pull-up
  ## against bus capacitance is a first-order low-pass; a corner at the clock
  ## frequency would round the edges into the sampling window. Ten times is
  ## the usual rule of thumb, not a figure from the I2C specification, which
  ## states a rise-time limit instead.

proc i2cExpand(inst: RoleInstance): seq[Assertion] =
  let freq = paramFloat(inst, "frequency", 100_000.0)
  for line in ["sda", "scl"]:
    let net = inst.subject(line)
    result.add Assertion(
      id: assertionId(inst, line & ".pullup"),
      subjects: @[net],
      quantity: "pullup_count",
      expect: atLeast(1.0),
      severity: sevError,
      rationale: "I2C is open-drain: with no pull-up the line can be driven " &
                 "low but never returns high",
      origin: inst.name)
    result.add Assertion(
      id: assertionId(inst, line & ".rc_corner"),
      subjects: @[net],
      quantity: "rc_corner",
      expect: atLeast(freq * i2cCornerMargin),
      unit: "Hz",
      severity: sevWarning,
      rationale: "pull-up resistance against bus capacitance must not round " &
                 "the edges into the sampling window at " & $Hertz(freq),
      origin: inst.name)
    # The other side of the same squeeze. `rc_corner` bounds the pull-up from
    # above -- too weak and the edges round off -- and this bounds it from
    # below: an I2C target must hold VOL at or below 0.4 V while sinking
    # 3 mA, so at 3.3 V the pull-up may not go under about 1 kohm. Fixing one
    # limit walks a design toward the other, and until this existed nothing
    # said so.
    #
    # 3 mA is the specification's number rather than a design choice, which
    # is why it is claimed unconditionally with a default. `maxSinkCurrent`
    # overrides it for a bus whose parts all state better.
    result.add Assertion(
      id: assertionId(inst, line & ".sink_current"),
      subjects: @[net],
      quantity: "pullup_sink_current",
      expect: atMost(paramFloat(inst, "maxSinkCurrent", 3.0e-3)),
      unit: "A",
      severity: sevError,
      rationale: "whatever pulls this line low has to sink the pull-up " &
                 "current while holding VOL at or below 0.4 V, and a " &
                 "pull-up stronger than the parts on the bus can sink puts " &
                 "the low level above the receiver's threshold",
      origin: inst.name)
  block:
    let sda = inst.subject("sda")
    result.add Assertion(
      id: assertionId(inst, "controllers"),
      subjects: @[sda],
      quantity: "controller_count",
      expect: nominal(1.0, absTol = 0.0),
      severity: sevWarning,
      rationale: "more than one controller needs multi-controller " &
                 "arbitration, which is rarely intended",
      origin: inst.name)

# --- built-in: regulator -----------------------------------------------

# --- the regulator family ------------------------------------------------
#
# One definition of what a regulator claims, specialised twice rather than
# copied twice. `linear_regulator` and `switching_regulator` both expand
# `regulatorExpand` whole and then add what only their topology is asked, so
# a claim added to the base reaches all three and cannot drift between them.
#
# The parts and params are shared through these `let`s because `RoleDef.params`
# is what `Design.validate` checks a stated parameter against: a specialised
# role that forgot to re-declare `maxDroop` would reject a design using it,
# with a message about an unknown parameter that is in fact perfectly good.

let regulatorParts = @[
  RolePart(name: "regulator", kind: skComponent,
           doc: "the part driving the rail"),
  RolePart(name: "output", kind: skNet, doc: "the net it drives"),
  RolePart(name: "measure", kind: skNet, optional: true,
           doc: "where the rail is judged, when that is past a filter"),
  RolePart(name: "sense", kind: skComponent, optional: true,
           doc: "the part carrying the regulator's output current -- the " &
                "inductor after a converter, the pass element inside a " &
                "linear's loop model. Named because a part that reaches the " &
                "deck as a code model or a subcircuit has no terminal " &
                "current of its own to probe"),
]

let regulatorParams = @[

  AnnDef(key: "voltage", kind: akFloat, unit: "V", scopes: {asNet},
         doc: "nominal regulated output"),
  AnnDef(key: "band", kind: akFloat, scopes: {asNet},
         doc: "acceptance band as a fraction of nominal; default 5%"),
  AnnDef(key: "maxOvershoot", kind: akFloat, unit: "%", scopes: {asNet},
         doc: "tolerated overshoot in percent; default 5"),
  AnnDef(key: "maxInrush", kind: akFloat, unit: "A", scopes: {asNet},
         doc: "peak charging current the supply must deliver; omitted " &
              "means unclaimed"),
  AnnDef(key: "maxRiseTime", kind: akFloat, unit: "s", scopes: {asNet},
         doc: "10-90% rise time of the rail; omitted means unclaimed"),
  AnnDef(key: "maxSettleTime", kind: akFloat, unit: "s", scopes: {asNet},
         doc: "time until the rail stays inside its band; omitted " &
              "means unclaimed"),
  AnnDef(key: "tRun", kind: akFloat, unit: "s", scopes: {asNet},
         doc: "how long to run; omitted derives it from the assumed " &
              "soft-start ramp, which is right for a regulator this " &
              "analysis stands up itself and says nothing about one " &
              "that brought its own model"),
  # --- a load step ---
  AnnDef(key: "iFrom", kind: akFloat, unit: "A", scopes: {asNet},
         doc: "load current before the step; default 0"),
  AnnDef(key: "iTo", kind: akFloat, unit: "A", scopes: {asNet},
         doc: "load current after it. Stating this is what asks for a load " &
              "step at all -- there is no default magnitude, because how " &
              "much current a part takes is a fact about the design"),
  AnnDef(key: "tEdge", kind: akFloat, unit: "s", scopes: {asNet},
         doc: "rise and fall time of the step; default 1 us. Not cosmetic: " &
              "a load's slew decides whether the droop is set by the output " &
              "capacitor's ESR or by the loop's bandwidth"),
  AnnDef(key: "tStepAt", kind: akFloat, unit: "s", scopes: {asNet},
         doc: "when the step lands. Everything before it is simulated and " &
              "discarded, so this is how long the rail is given to arrive"),
  AnnDef(key: "tHold", kind: akFloat, unit: "s", scopes: {asNet},
         doc: "how long the load stays on. 0 holds to the end of the run, " &
              "which means there is no release edge and no overshoot to " &
              "measure"),
  AnnDef(key: "tRecover", kind: akFloat, unit: "s", scopes: {asNet},
         doc: "how long to watch after each edge; default ten times tEdge"),
  AnnDef(key: "stepPoints", kind: akFloat, scopes: {asNet},
         doc: "samples across the recovery window; default 2000. The " &
              "derived print step is also ngspice's ceiling on its own " &
              "timestep, so this sets how well the edge is solved"),
  AnnDef(key: "maxDroop", kind: akFloat, unit: "V", scopes: {asNet},
         doc: "how far the rail may fall when the load arrives; omitted " &
              "means unclaimed"),
  AnnDef(key: "maxDroopPct", kind: akFloat, unit: "%", scopes: {asNet},
         doc: "the same, as a fraction of the rail"),
  AnnDef(key: "minStepV", kind: akFloat, unit: "V", scopes: {asNet},
         doc: "lowest the rail may ever be seen at during the step, as an " &
              "absolute -- an undervoltage lockout does not care what the " &
              "rail was before"),
  AnnDef(key: "maxStepOvershoot", kind: akFloat, unit: "V", scopes: {asNet},
         doc: "how far it may rise when the load is released again"),
  AnnDef(key: "maxRecover", kind: akFloat, unit: "s", scopes: {asNet},
         doc: "how long it may take to come back inside band and stay there"),
  AnnDef(key: "stepBand", kind: akFloat, scopes: {asNet},
         doc: "the band `maxRecover` is measured against, as a fraction of " &
              "where the rail settles under the new load; omitted takes " &
              "1%. State it whenever the droop is smaller than that, or " &
              "the rail never leaves the band and the recovery reads zero"),
  # --- supply rejection ---
  AnnDef(key: "minPsrrDb", kind: akFloat, unit: "dB", scopes: {asNet},
         doc: "least acceptable rejection of input ripple, measured with " &
              "one real tone through a `.tran`. Stating this is what asks " &
              "for the measurement; it needs a `source` to ripple and an " &
              "`input` net to quote against, which the specialised roles " &
              "bind. A tone reaches a switching converter and an XSPICE " &
              "code model, neither of which an `.ac` sweep can see"),
  AnnDef(key: "minPsrrBandDb", kind: akFloat, unit: "dB", scopes: {asNet},
         doc: "least acceptable rejection anywhere in a *swept* band, via " &
              "`.ac`. The cheaper way to ask and the one that finds the " &
              "worst point rather than answering at one frequency -- but an " &
              "`.ac` sees nothing through an XSPICE code model, so a " &
              "switching converter wants `minPsrrDb` instead. Stating both " &
              "is legal and is two runs"),
  AnnDef(key: "psrrAtF", kind: akFloat, unit: "Hz", scopes: {asNet},
         doc: "the frequency. For `minPsrrDb` it is the tone; for " &
              "`minPsrrBandDb` it moves the claim from the band's worst " &
              "point onto that one point. " &
              "Default 120 Hz, which is where a datasheet quotes ripple " &
              "rejection because it is twice the mains frequency"),
  AnnDef(key: "psrrRippleV", kind: akFloat, unit: "V", scopes: {asNet},
         doc: "tone amplitude, zero to peak; default 100 mV. Part of the " &
              "answer for 'tone' and irrelevant for 'ac': a `.tran` is not " &
              "linear, so a tone big enough to move a duty cycle gets a " &
              "different figure"),
  AnnDef(key: "psrrFrom", kind: akFloat, unit: "Hz", scopes: {asNet},
         doc: "low end of the swept band, for 'ac'; default 10 Hz"),
  AnnDef(key: "psrrTo", kind: akFloat, unit: "Hz", scopes: {asNet},
         doc: "high end of it; default 10 MHz"),
  AnnDef(key: "psrrPeriods", kind: akFloat, scopes: {asNet},
         doc: "whole periods of the tone in the window; default 8"),
  AnnDef(key: "psrrPoints", kind: akFloat, scopes: {asNet},
         doc: "samples per period; default 200"),
  # --- what it delivers ---
  AnnDef(key: "tSettle", kind: akFloat, unit: "s", scopes: {asNet},
         doc: "when a steady-state window opens, for the current and " &
              "ripple claims. Distinct from tRun, which is how long the " &
              "start-up run lasts"),
  AnnDef(key: "tWindow", kind: akFloat, unit: "s", scopes: {asNet},
         doc: "how long that window is"),
  AnnDef(key: "maxOutputCurrent", kind: akFloat, unit: "A", scopes: {asNet},
         doc: "peak the regulator may deliver, measured through `sense`"),
  AnnDef(key: "maxOutputAvg", kind: akFloat, unit: "A", scopes: {asNet},
         doc: "average it may deliver continuously"),
  AnnDef(key: "maxOutputDerating", kind: akFloat, scopes: {asNet},
         doc: "fraction of the regulator's *own* stated `current_rating` " &
              "the RMS through `sense` may reach. States no current: the " &
              "rating lives on the part somebody chose"),
]

let linearParams = @[
  AnnDef(key: "vinFrom", kind: akFloat, unit: "V", scopes: {asNet},
         doc: "low end of the input sweep, for dropout and line regulation"),
  AnnDef(key: "vinTo", kind: akFloat, unit: "V", scopes: {asNet},
         doc: "high end of it"),
  AnnDef(key: "vinStep", kind: akFloat, unit: "V", scopes: {asNet},
         doc: "sweep step; omitted takes fifty-one points across the range"),
  AnnDef(key: "maxDropout", kind: akFloat, unit: "V", scopes: {asNet},
         doc: "input-to-output differential at the lowest input still " &
              "holding regulation; omitted means unclaimed"),
  AnnDef(key: "maxLineReg", kind: akFloat, unit: "%", scopes: {asNet},
         doc: "how far the output may move across the whole input sweep"),
  AnnDef(key: "iLoadFrom", kind: akFloat, unit: "A", scopes: {asNet},
         doc: "light-load end of the load sweep, for load regulation"),
  AnnDef(key: "iLoadTo", kind: akFloat, unit: "A", scopes: {asNet},
         doc: "heavy-load end of it"),
  AnnDef(key: "maxLoadReg", kind: akFloat, unit: "%", scopes: {asNet},
         doc: "how far the output may move across that load range"),
  AnnDef(key: "maxZOut", kind: akFloat, unit: "ohm", scopes: {asNet},
         doc: "DC output resistance, which is that movement per amp"),
]

let switchingParams = @[
  AnnDef(key: "maxRipple", kind: akFloat, unit: "V", scopes: {asNet},
         doc: "peak-to-peak output ripple over the settled window; omitted " &
              "means unclaimed"),
  AnnDef(key: "fSw", kind: akFloat, unit: "Hz", scopes: {asNet},
         doc: "switching frequency, read off the bound `switch` node. What " &
              "sets it is a resistor or an internal oscillator, and a " &
              "converter running at the wrong rate has the wrong ripple, " &
              "the wrong inductor current and the wrong EMI signature"),
  AnnDef(key: "fSwBand", kind: akFloat, scopes: {asNet},
         doc: "acceptance band on it, as a fraction; default 10%"),
  AnnDef(key: "maxSwitchCurrent", kind: akFloat, unit: "A", scopes: {asNet},
         doc: "peak through the bound `inductor`, which in a synchronous " &
              "buck's on-time *is* the top switch's current"),
  AnnDef(key: "maxIsatDerating", kind: akFloat, scopes: {asNet},
         doc: "fraction of the inductor's own stated `isat` that peak may " &
              "reach; past the knee the inductance collapses and the ripple " &
              "measured here stops describing the part"),
  AnnDef(key: "iRipple", kind: akFloat, unit: "A", scopes: {asNet},
         doc: "the peak-to-peak the design equations fix -- for a converter " &
              "dI = Vout(1-D)/(L*f). What catches a wrong inductor value by " &
              "something other than the rail looking slightly worse"),
  AnnDef(key: "iRippleBand", kind: akFloat, scopes: {asNet},
         doc: "acceptance band on that, as a fraction; default 15%"),
]

# The three groups a regulator claims beyond the way up. Separate procs
# because `linear_regulator` and `switching_regulator` expand `regulator`
# whole and then add their own -- one definition of what a regulator claims,
# specialised rather than copied.

proc loadStepClaims(inst: RoleInstance, judged: Subject): seq[Assertion] =
  ## What the rail does when the load jumps, and how long it takes to get
  ## over it.
  ##
  ## **The time-domain twin of `power_rail`'s `targetZ`, and the thing that
  ## target is a proxy for.** An impedance curve answers "how stiff is this
  ## rail across the band", which is real and indirect; what the board has to
  ## do is hold the rail up when the MCU wakes, and getting from one to the
  ## other is an argument the reader has to complete. This states it
  ## directly.
  ##
  ## Each claim is gated on its own limit and nothing is gated on the step
  ## itself, which is `source_sweep`'s shape rather than an oversight: the
  ## magnitude is *setup*, so it rides in the conditions, and a claim stated
  ## without one is refused by the evaluator with a message naming what is
  ## missing rather than silently expanding to nothing. Gating the whole
  ## group on `iTo` also hid it from `claimingRoles`, which expands each
  ## parameter on its own and so never had both a step and a limit at once.
  let iFrom = paramFloat(inst, "iFrom", 0.0)
  let iTo = paramFloat(inst, "iTo", 0.0)

  template stepped(sfx, qty: string, e: Expectation, un, why: string;
                   sev = sevError) =
    var claim = Assertion(
      id: assertionId(inst, sfx),
      subjects: @[judged],
      quantity: qty,
      expect: e,
      unit: un,
      severity: sev,
      rationale: why,
      origin: inst.name)
    # Every one of these changes the run, so every one joins the setup key.
    # The magnitude above all: a rail that holds up under 1 A may not under
    # 3 A, and two claims at two magnitudes must be two runs rather than one
    # run reported twice.
    claim.condition["step_from"] = $iFrom
    claim.condition["step_to"] = $iTo
    claim.condition["step_edge"] = $paramFloat(inst, "tEdge", 0.0)
    claim.condition["step_at"] = $paramFloat(inst, "tStepAt", 0.0)
    claim.condition["step_hold"] = $paramFloat(inst, "tHold", 0.0)
    claim.condition["step_recover"] = $paramFloat(inst, "tRecover", 0.0)
    claim.condition["step_points"] = $paramFloat(inst, "stepPoints", 0.0)
    claim.condition["step_band"] = $paramFloat(inst, "stepBand", 0.0)
    result.add claim

  if hasParam(inst, "maxDroop"):
    stepped("droop", "step_droop_v",
            atMost(paramFloat(inst, "maxDroop", 0.0)), "V",
            "how far the rail falls below where it was sitting when the " &
            "load arrives. Everything downstream has an undervoltage " &
            "threshold, and a rail that dips under it resets a part that " &
            "was working a microsecond earlier -- which looks like a " &
            "firmware fault and is not one")
  if hasParam(inst, "maxDroopPct"):
    stepped("droop_pct", "step_droop_pct",
            atMost(paramFloat(inst, "maxDroopPct", 0.0)), "%",
            "the same excursion as a fraction of the rail, which is how a " &
            "supply tolerance is written down and what a part's operating " &
            "range is quoted against")
  if hasParam(inst, "minStepV"):
    stepped("step_floor", "step_v_min",
            atLeast(paramFloat(inst, "minStepV", 0.0)), "V",
            "the lowest the rail is ever seen at during the step, stated " &
            "as an absolute rather than as an excursion: an undervoltage " &
            "lockout does not care what the rail was before")
  if hasParam(inst, "maxStepOvershoot"):
    stepped("step_overshoot", "step_overshoot_v",
            atMost(paramFloat(inst, "maxStepOvershoot", 0.0)), "V",
            "how far the rail rises above where it was when the load is " &
            "released again -- the half of a load step that is easy to " &
            "forget and that stresses the absolute-maximum rating of " &
            "everything on the rail rather than its undervoltage threshold",
            sevWarning)
  if hasParam(inst, "maxRecover"):
    stepped("recover", "step_recover_s",
            atMost(paramFloat(inst, "maxRecover", 0.0)), "s",
            "how long the rail takes to come back inside band and stay " &
            "there, measured against where it settles *under the new load* " &
            "rather than where it started -- load regulation moves that " &
            "point, and counting the shift as a failure to recover would " &
            "report a correct regulator as an unstable one",
            sevWarning)

proc rejectionClaims(inst: RoleInstance, judged: Subject): seq[Assertion] =
  ## How much of the supply's ripple reaches the rail.
  ##
  ## **Which measurement runs is decided by which limit is stated, not by a
  ## mode string**, and that is worth an extra parameter name. The two are
  ## genuinely different measurements -- different capability, different run,
  ## different meaning -- so they were never going to share a quantity, and
  ## once they do not, a `psrrMethod = "tone" | "ac"` parameter buys nothing
  ## and costs two things. It needs its own value validation, since a typo in
  ## it is otherwise a silently different measurement. And it is invisible to
  ## `verify.claimingRoles`, which works out what a role can claim by
  ## expanding it with every parameter set to a placeholder: a float
  ## placeholder still selects a branch, a string one selects nothing, so
  ## every `.ac` quantity here reported as claimable by no built-in role at
  ## all -- exactly the conflation that column exists to prevent.
  ##
  ##   * `minPsrrDb` runs **one tone** through a `.tran`. The default way to
  ##     ask, because it is the one that reaches everything: a switching
  ##     converter has no meaningful linearisation about an operating point,
  ##     and an XSPICE code model contributes nothing to an AC matrix unless
  ##     it sets `AC_GAIN` -- measured, an `.ac` sweep of
  ##     `designs/lt8640a_buck.nim` reports exactly zero output.
  ##   * `minPsrrBandDb` **sweeps a band** with `.ac`. Cheaper, and it finds
  ##     the worst point across the whole band rather than answering at one
  ##     frequency -- right for anything that linearises, which is most
  ##     linear regulators and every passive filter.
  ##
  ## Stating both is legal and is two runs, which is the honest cost of
  ## asking two questions.
  let atF = paramFloat(inst, "psrrAtF", 0.0)

  if hasParam(inst, "minPsrrDb"):
    var claim = Assertion(
      id: assertionId(inst, "psrr"),
      subjects: @[judged],
      quantity: "psrr_db",
      expect: atLeast(paramFloat(inst, "minPsrrDb", 0.0)),
      unit: "dB",
      severity: sevWarning,
      rationale: "ripple on the input has to be attenuated before it " &
                 "reaches anything that cares -- an ADC's reference, a " &
                 "PLL's supply, an amplifier's rail -- and a regulator that " &
                 "holds its DC value perfectly may pass a hundred " &
                 "millivolts of mains hum straight through. Measured with " &
                 "one real sinusoid rather than a small-signal sweep, so " &
                 "the amplitude is part of the question: a `.tran` is not " &
                 "linear, and a ripple big enough to move a duty cycle gets " &
                 "a different answer",
      origin: inst.name)
    claim.condition["ripple_f"] = $atF
    claim.condition["ripple_v"] = $paramFloat(inst, "psrrRippleV", 0.0)
    claim.condition["t_settle"] = $paramFloat(inst, "tSettle", 0.0)
    claim.condition["ripple_periods"] = $paramFloat(inst, "psrrPeriods", 0.0)
    claim.condition["ripple_points"] = $paramFloat(inst, "psrrPoints", 0.0)
    result.add claim

  if hasParam(inst, "minPsrrBandDb"):
    # `psrrAtF` *redirects* this claim from the band's worst point onto that
    # one point rather than adding a second claim -- the `gain_stage`/`atF`
    # pattern. Claiming both would be two claims about one curve, and the
    # point claim can only ever be the weaker of the two.
    var claim = Assertion(
      id: assertionId(inst, "psrr_swept"),
      subjects: @[judged],
      quantity: (if atF > 0.0: "psrr_at_f" else: "psrr_min_db"),
      expect: atLeast(paramFloat(inst, "minPsrrBandDb", 0.0)),
      unit: "dB",
      severity: sevWarning,
      rationale: "the same rejection, swept: a regulator's is not flat, and " &
                 "its worst point sits where the loop gain has rolled off " &
                 "and the output capacitor has not yet taken over. Quoting " &
                 "either end of the band would miss it -- measured on an " &
                 "LM317 at 62.9 dB at 120 Hz and 7.8 dB at 63 kHz, on the " &
                 "same rail",
      origin: inst.name)
    claim.condition["f_from"] = $paramFloat(inst, "psrrFrom", 0.0)
    claim.condition["f_to"] = $paramFloat(inst, "psrrTo", 0.0)
    if atF > 0.0: claim.condition["at_f"] = $atF
    result.add claim

proc outputCurrentClaims(inst: RoleInstance): seq[Assertion] =
  ## What the regulator is actually delivering, against what it is rated for.
  ##
  ## **The subject is the `sense` part, not the regulator**, and that is
  ## forced rather than chosen: a regulator that reaches the deck as an
  ## XSPICE code model or a subcircuit instance has no terminal current of
  ## its own, so there is nothing to probe on the part itself. What carries
  ## its output current is the inductor after a buck, or the pass element
  ## inside a linear's loop model, and only the design knows which. Binding
  ## it says so once.
  ##
  ## The claims are ordinary `current_path` quantities over the same window,
  ## so a design already claiming an inductor's ripple gets these out of the
  ## *same* `.tran` rather than a second one -- which on a converter
  ## simulated at fifty timepoints a cycle is most of the check.
  if not inst.hasPart("sense"): return
  let sense = inst.subject("sense")

  template carried(sfx, qty: string, e: Expectation, un, why: string;
                   sev = sevError) =
    var claim = Assertion(
      id: assertionId(inst, sfx),
      subjects: @[sense],
      quantity: qty,
      expect: e,
      unit: un,
      severity: sev,
      rationale: why,
      origin: inst.name)
    claim.condition["t_settle"] = $paramFloat(inst, "tSettle", 0.0)
    claim.condition["t_window"] = $paramFloat(inst, "tWindow", 0.0)
    result.add claim

  if hasParam(inst, "maxOutputCurrent"):
    carried("i_out_peak", "i_peak",
            atMost(paramFloat(inst, "maxOutputCurrent", 0.0)), "A",
            "the peak the regulator has to deliver, which is where a " &
            "converter's cycle-by-cycle current limit trips and where its " &
            "inductor saturates -- both of them properties of the top of " &
            "the waveform rather than of its average")
  if hasParam(inst, "maxOutputAvg"):
    carried("i_out_avg", "i_avg",
            atMost(paramFloat(inst, "maxOutputAvg", 0.0)), "A",
            "the DC the part delivers continuously, which is what its " &
            "thermal rating was specified at")
  if hasParam(inst, "maxOutputDerating"):
    carried("i_out_derating", "i_out_derating",
            atMost(paramFloat(inst, "maxOutputDerating", 0.0)), "",
            "how much of the *regulator's own* stated `current_rating` the " &
            "RMS through the sense part uses up. It names no current: the " &
            "rating is a property of the part somebody chose, so a " &
            "substitution changes the limit in one place instead of two -- " &
            "and a regulator that states none reports this as unchecked " &
            "rather than as headroom nobody verified",
            sevWarning)

proc regulatorExpand(inst: RoleInstance): seq[Assertion] =
  ## The rail's *behaviour on the way up*, as opposed to `power_rail`, which
  ## claims only where it settles.
  ##
  ## The subject is the net the rail is *judged* at, which is not always the
  ## one the regulator drives: with a ferrite or an LC between them, the
  ## regulator pin shows a clean ramp while the load end rings. The
  ## `regulator` and `output` parts are what an evaluator reads back to know
  ## what to simulate -- a role knows its own topology, so its claims do not
  ## have to restate it.
  ## `tRun` is a **condition, not a limit**, the same way `settled_rail`'s
  ## window is: it says how long the circuit was run for, and every
  ## measurement here is a function of it. It matters most for exactly the
  ## case the role was extended to reach -- a regulator that brings its own
  ## model soft-starts on its own schedule, and the run length derived from
  ## this analysis's *assumed* ramp has nothing to do with the part's. Left
  ## unstated the derived length stands, which is right for the assumed ramp
  ## and only for that.
  let judged = if inst.hasPart("measure"): inst.subject("measure")
               else: inst.subject("output")
  let target = paramFloat(inst, "voltage", 0.0)
  let band = paramFloat(inst, "band", 0.05)
  let overshoot = paramFloat(inst, "maxOvershoot", 5.0)
  let tRun = paramFloat(inst, "tRun", 0.0)

  if target > 0.0:
    result.add Assertion(
      id: assertionId(inst, "final_v"),
      subjects: @[judged],
      quantity: "final_v",
      expect: nominal(target, fracTol = band),
      unit: "V",
      severity: sevError,
      rationale: "the rail must actually reach its nominal voltage once " &
                 "start-up has settled",
      origin: inst.name)

  result.add Assertion(
    id: assertionId(inst, "overshoot"),
    subjects: @[judged],
    quantity: "overshoot_pct",
    expect: atMost(overshoot),
    unit: "%",
    severity: sevWarning,
    rationale: "a rail that overshoots on the way up can exceed the " &
               "absolute-maximum rating of everything downstream of it, " &
               "even though it settles correctly afterwards",
    origin: inst.name)

  # The rest of what a `.tran` already measured. Each is opt-in, because
  # each is a specification that comes from the system rather than from the
  # rail: what the upstream supply can deliver, when the MCU releases its
  # power-on reset, when anything downstream may be let out of reset.
  #
  # They are here rather than in a role of their own because the analysis
  # is the same one -- `spice.startup` batches every claim sharing a
  # regulator and a judged net into a single run -- and because a quantity
  # no built-in role can claim reads, from `nimcir quantities`, as a
  # quantity nothing can claim.
  if hasParam(inst, "maxInrush"):
    result.add Assertion(
      id: assertionId(inst, "inrush"),
      subjects: @[judged],
      quantity: "inrush_peak",
      expect: atMost(paramFloat(inst, "maxInrush", 0.0)),
      unit: "A",
      severity: sevError,
      rationale: "the current the output capacitors demand while charging, " &
                 "which the upstream supply has to deliver before anything " &
                 "downstream has negotiated a budget",
      origin: inst.name)

  if hasParam(inst, "maxRiseTime"):
    result.add Assertion(
      id: assertionId(inst, "rise_time"),
      subjects: @[judged],
      quantity: "rise_time_10_90",
      expect: atMost(paramFloat(inst, "maxRiseTime", 0.0)),
      unit: "s",
      severity: sevError,
      rationale: "a rail slower than the part's power-on reset release " &
                 "leaves it running below its minimum operating voltage",
      origin: inst.name)

  if hasParam(inst, "maxSettleTime"):
    result.add Assertion(
      id: assertionId(inst, "settle"),
      subjects: @[judged],
      quantity: "settle_time",
      expect: atMost(paramFloat(inst, "maxSettleTime", 0.0)),
      unit: "s",
      severity: sevWarning,
      rationale: "how long the rail rings before it stays inside band, " &
                 "which is the earliest anything downstream may be released " &
                 "from reset",
      origin: inst.name)

  # Stamped in one place at the end rather than at each `add`: this proc has
  # five exits through four `if`s, and a condition applied at four of them is
  # a claim quietly planned into a second run.
  #
  # **Only over the start-up claims**, which is why they are collected here
  # rather than in `result` directly. The three groups below are answered by
  # different analyses over different runs, and `t_run` says nothing about
  # any of them -- stamped across everything it would print `t_run = 8 ms`
  # under a ripple-rejection claim measured over eighty microseconds.
  for a in result.mitems:
    a.condition["t_run"] = $tRun

  result.add loadStepClaims(inst, judged)
  result.add rejectionClaims(inst, judged)
  result.add outputCurrentClaims(inst)

# --- built-in: linear_regulator ----------------------------------------

proc linearRegulatorExpand(inst: RoleInstance): seq[Assertion] =
  ## Everything `regulator` claims, plus the three things only a part that
  ## *drops the difference* is asked.
  ##
  ## A linear regulator's whole character is that its input has to stay above
  ## its output by some margin, and that what it does about a moving input is
  ## a slope rather than a value. Neither is a question an operating point
  ## contains, which is why all three go through `.dc`: `dropout_v` is a
  ## threshold crossing on a swept curve, and the two regulation figures are
  ## differences across a range.
  ##
  ## The sweep range joins the setup key, so a line figure quoted over the
  ## part's specified range and one quoted over a wider range are two runs
  ## whose answers are not comparable -- exactly the distinction
  ## `templates/dc_sweep.nim` measures at 1.67% against 41.6% on one Zener.
  result = regulatorExpand(inst)

  let outNet = if inst.hasPart("measure"): inst.subject("measure")
               else: inst.subject("output")

  template swept(sfx, qty, kind: string, e: Expectation, un, why: string;
                 sev = sevError) =
    var claim = Assertion(
      id: assertionId(inst, sfx),
      subjects: @[outNet],
      quantity: qty,
      expect: e,
      unit: un,
      severity: sev,
      rationale: why,
      origin: inst.name)
    claim.condition["sweep"] = kind
    if kind == "source":
      claim.condition["sweep_from"] = $paramFloat(inst, "vinFrom", 0.0)
      claim.condition["sweep_to"] = $paramFloat(inst, "vinTo", 0.0)
      claim.condition["sweep_step"] = $paramFloat(inst, "vinStep", 0.0)
    else:
      claim.condition["sweep_from"] = $paramFloat(inst, "iLoadFrom", 0.0)
      claim.condition["sweep_to"] = $paramFloat(inst, "iLoadTo", 0.0)
    if hasParam(inst, "voltage"):
      claim.condition["v_nominal"] = $paramFloat(inst, "voltage", 0.0)
    result.add claim

  if hasParam(inst, "maxDropout"):
    swept("dropout", "dropout_v", "source",
          atMost(paramFloat(inst, "maxDropout", 0.0)), "V",
          "how little headroom the part still regulates on, measured from " &
          "its own input pin rather than from the supply -- the difference " &
          "is whatever the input wiring and any series protection drop, and " &
          "that is exactly the margin a 12 V rail out of a 15 V supply " &
          "passes on paper and loses on the bench")
  if hasParam(inst, "maxLineReg"):
    swept("line_reg", "line_reg_pct", "source",
          atMost(paramFloat(inst, "maxLineReg", 0.0)), "%",
          "how far the output moves across the whole input range, which is " &
          "a slope and not a bias: an operating point at nominal line says " &
          "nothing about it however precisely it solves")
  if hasParam(inst, "maxLoadReg"):
    swept("load_reg", "load_reg_pct", "load",
          atMost(paramFloat(inst, "maxLoadReg", 0.0)), "%",
          "how far it moves across the load range, measured with a sink " &
          "the analysis injects rather than a resistor -- a resistor's " &
          "current follows the rail, so sweeping one sweeps the load and " &
          "the drive together")
  if hasParam(inst, "maxZOut"):
    swept("z_out", "z_out_dc", "load",
          atMost(paramFloat(inst, "maxZOut", 0.0)), "ohm",
          "that same movement per amp, which is the half of the part's " &
          "output behaviour no node voltage witnesses",
          sevWarning)

# --- built-in: switching_regulator --------------------------------------

proc switchingRegulatorExpand(inst: RoleInstance): seq[Assertion] =
  ## Everything `regulator` claims, plus what only a part that *chops and
  ## filters* is asked.
  ##
  ## Three of them, and every one is a consequence of there being a waveform
  ## where a linear regulator has a level. **Output ripple** is the inductor's
  ## current triangle across the output capacitor's ESR, and it exists at all
  ## only because the part switches. **The switching rate** is what fixes
  ## that triangle's size, so a converter running at the wrong frequency has
  ## the wrong ripple, the wrong inductor current and the wrong EMI
  ## signature, and nothing else in a netlist records it -- it is set by a
  ## resistor or by an internal oscillator. And **the inductor's peak
  ## current**, which in a synchronous buck's on-time *is* the top switch's
  ## current, so it is the measurable proxy for a current limit that lives
  ## inside the part rather than on the board.
  ##
  ## Every one is an existing quantity over an existing evaluator: this role
  ## adds no analysis, it says which parts to point the ones there at.
  result = regulatorExpand(inst)

  let outNet = if inst.hasPart("measure"): inst.subject("measure")
               else: inst.subject("output")
  let tSettle = paramFloat(inst, "tSettle", 0.0)
  let tWindow = paramFloat(inst, "tWindow", 0.0)

  template windowed(sfx, qty: string, subj: Subject, e: Expectation,
                    un, why: string; sev = sevError) =
    var claim = Assertion(
      id: assertionId(inst, sfx),
      subjects: @[subj],
      quantity: qty,
      expect: e,
      unit: un,
      severity: sev,
      rationale: why,
      origin: inst.name)
    claim.condition["t_settle"] = $tSettle
    claim.condition["t_window"] = $tWindow
    result.add claim

  if hasParam(inst, "maxRipple"):
    windowed("ripple", "ripple_pp", outNet,
             atMost(paramFloat(inst, "maxRipple", 0.0)), "V",
             "what is left moving on the rail once it has arrived. A `.op` " &
             "cannot see it -- an operating point has no ripple in it, so a " &
             "converter's rail reads as its own average by construction and " &
             "would pass any ripple claim ever made about it",
             sevWarning)

  if hasParam(inst, "fSw") and inst.hasPart("switch"):
    windowed("fsw", "osc_freq", inst.subject("switch"),
             nominal(paramFloat(inst, "fSw", 0.0),
                     fracTol = paramFloat(inst, "fSwBand", 0.1)), "Hz",
             "the rate the part actually runs at, read off the switch node " &
             "rather than assumed. It is set by a timing resistor or an " &
             "internal oscillator and appears nowhere else in a netlist, " &
             "and everything else here -- the ripple, the inductor's " &
             "triangle, the EMI -- is a function of it")

  if inst.hasPart("inductor"):
    let coil = inst.subject("inductor")
    if hasParam(inst, "maxSwitchCurrent"):
      windowed("i_switch", "i_peak", coil,
               atMost(paramFloat(inst, "maxSwitchCurrent", 0.0)), "A",
               "the peak the inductor carries, which during the on-time is " &
               "the top switch's own current -- so it is where a " &
               "cycle-by-cycle current limit trips, and the measurable " &
               "proxy for a limit that lives inside the part rather than " &
               "on the board")
    if hasParam(inst, "maxIsatDerating"):
      windowed("isat_derating", "i_peak_derating", coil,
               atMost(paramFloat(inst, "maxIsatDerating", 0.0)), "",
               "how much of the inductor's *own* stated saturation current " &
               "that peak reaches. Past the knee the inductance collapses, " &
               "the triangle grows and every other number measured here " &
               "stops describing the part that is fitted",
               sevWarning)
    if hasParam(inst, "iRipple"):
      windowed("i_ripple", "i_pp", coil,
               nominal(paramFloat(inst, "iRipple", 0.0),
                       fracTol = paramFloat(inst, "iRippleBand", 0.15)), "A",
               "the peak-to-peak the design equations fix -- for a buck " &
               "dI = Vout(1-D)/(L*f). Claiming it is what catches a wrong " &
               "inductor value by something other than the rail looking " &
               "slightly worse than it should")

# --- built-in: opamp_stage ---------------------------------------------

proc opampStageExpand(inst: RoleInstance): seq[Assertion] =
  ## Closed-loop behaviour and stability of one amplifier stage.
  ##
  ## Peaking and phase margin are both claimed because they are measured
  ## differently and are wrong in different ways: peaking is what low margin
  ## looks like from outside the loop, while the margin itself is a property
  ## of the loop gain at its own crossing and needs the loop broken to
  ## measure. Neither substitutes for the other.
  let outNet = inst.subject("output")
  let minBw = paramFloat(inst, "minBandwidth", 0.0)
  let minPm = paramFloat(inst, "minPhaseMargin", 45.0)
  let maxPk = paramFloat(inst, "maxPeaking", 1.0)

  if minBw > 0.0:
    result.add Assertion(
      id: assertionId(inst, "bandwidth"),
      subjects: @[outNet],
      quantity: "bw_3db",
      expect: atLeast(minBw),
      unit: "Hz",
      severity: sevError,
      rationale: "the stage must pass the band it was designed for",
      origin: inst.name)

  result.add Assertion(
    id: assertionId(inst, "phase_margin"),
    subjects: @[outNet],
    quantity: "phase_margin_deg",
    expect: atLeast(minPm),
    unit: "deg",
    severity: sevError,
    rationale: "phase margin below roughly 45 degrees rings on a step and " &
               "moves toward oscillation as load capacitance grows",
    origin: inst.name)

  if hasParam(inst, "minGainMargin"):
    result.add Assertion(
      id: assertionId(inst, "gain_margin"),
      subjects: @[outNet],
      quantity: "gain_margin_db",
      expect: atLeast(paramFloat(inst, "minGainMargin", 0.0)),
      unit: "dB",
      severity: sevError,
      rationale: "how far below unity the loop gain has fallen by the time " &
                 "its phase reaches -180; a one- or two-pole loop never " &
                 "gets there and reports no margin, which is the honest " &
                 "answer rather than a large finite number",
      origin: inst.name)

  result.add Assertion(
    id: assertionId(inst, "peaking"),
    subjects: @[outNet],
    quantity: "peaking_db",
    expect: atMost(maxPk),
    unit: "dB",
    severity: sevWarning,
    rationale: "closed-loop peaking is what insufficient phase margin looks " &
               "like from outside the loop, and needs no loop break to see",
    origin: inst.name)

proc gainStageExpand(inst: RoleInstance): seq[Assertion] =
  ## An amplifier stage judged by its **band**, not by its behaviour at DC.
  ##
  ## `opamp_stage` describes a DC-coupled stage and asks DC-referenced
  ## questions, which is right for a filter or a sensor front end and wrong
  ## for anything single-supply. There the gain-setting leg is capacitively
  ## coupled -- that is what makes one supply work -- so the gain at DC is
  ## unity *by construction*, `gain_dc_db` reports 0 dB for a stage with 32
  ## of them, and `bw_3db` reports where the response falls 3 dB below unity
  ## on the far side of its own passband. Neither is wrong arithmetically and
  ## neither answers a question anyone asks about a guitar pedal or a
  ## microphone preamp.
  ##
  ## So this role claims against the response's maximum instead. It also
  ## makes **no stability claim**: `peaking_db` cannot tell an intentional
  ## band-pass shape from resonance, and a margin belongs to `opamp_stage`,
  ## which can be stated alongside this one on the same stage when the loop
  ## is one `analyzeLoopGain` can actually open.
  ##
  ## Every parameter is optional and omitting one claims nothing, the same
  ## rule `power_rail`'s `targetZ` follows: a gain specification comes from
  ## what the stage is for, and inventing a default would manufacture a
  ## requirement the designer never made.
  let outNet = inst.subject("output")
  let atF = paramFloat(inst, "atF", 0.0)

  # Pinning a frequency changes which quantity the gain claim is about: at a
  # stated frequency it is `gain_at_f`, otherwise the response's maximum.
  # Same claim, said two ways, and the unit and rationale do not change.
  let gainQuantity = if atF > 0.0: "gain_at_f" else: "gain_max_db"
  let gainWhere =
    if atF > 0.0: " at " & $atF & " Hz"
    else: " at the response's maximum"

  template gainClaim(suffix: string, e: Expectation, why: string) =
    var a = Assertion(
      id: assertionId(inst, suffix),
      subjects: @[outNet],
      quantity: gainQuantity,
      expect: e,
      unit: "dB",
      severity: sevError,
      rationale: why & gainWhere,
      origin: inst.name)
    if atF > 0.0: a.condition["at_f"] = $atF
    result.add a

  if hasParam(inst, "minGain"):
    gainClaim("min_gain", atLeast(paramFloat(inst, "minGain", 0.0)),
              "the stage must reach the gain it was designed for")
  if hasParam(inst, "maxGain"):
    gainClaim("max_gain", atMost(paramFloat(inst, "maxGain", 0.0)),
              "gain above what the stage was designed for is headroom spent " &
              "on noise, and on a single supply it is clipping")

  # The band edges, each referenced to that same maximum. `f_lo_3db` is
  # `NaN` for a DC-coupled stage, which has no lower edge -- that reads as
  # "could not check" rather than as a pass.
  if hasParam(inst, "fLoMax"):
    result.add Assertion(
      id: assertionId(inst, "low_corner"),
      subjects: @[outNet],
      quantity: "f_lo_3db",
      expect: atMost(paramFloat(inst, "fLoMax", 0.0)),
      unit: "Hz",
      severity: sevError,
      rationale: "the stage must still be passing at the bottom of its band; " &
                 "a coupling capacitor sized by habit rather than by the " &
                 "impedance it works into is what moves this",
      origin: inst.name)

  if hasParam(inst, "fHiMin"):
    result.add Assertion(
      id: assertionId(inst, "high_corner"),
      subjects: @[outNet],
      quantity: "f_hi_3db",
      expect: atLeast(paramFloat(inst, "fHiMin", 0.0)),
      unit: "Hz",
      severity: sevError,
      rationale: "the stage must still be passing at the top of its band",
      origin: inst.name)

proc channelMatchExpand(inst: RoleInstance): seq[Assertion] =
  ## Two stages judged against each other, rather than each against a band.
  ##
  ## `gain_stage` claims each channel reaches its gain; this claims the two
  ## *agree*, and neither implies the other -- two channels 3 dB apart can
  ## each sit inside its own band, and a stereo image that shifts with level
  ## is the most audible fault a two-channel stage has.
  ##
  ## **The subjects are the two `skClass` references, not nets.** A
  ## `RoleExpander` is pure and has no `Design`, so it cannot turn
  ## `roleRef("left")` into an amplifier and two nets; the evaluator does
  ## that (`subjectRoleBinding`). Same asymmetry `originRole` exists for --
  ## an expander states the claim, an evaluator recovers the topology.
  ##
  ## Every claim is `hasParam`-gated on its own limit, the rule the regulator
  ## roles established. `fFrom`/`fTo`/`atF` are **setup**: they say what was
  ## swept, ride in `Assertion.condition`, and never gate a claim.
  let a = inst.subject("a")
  let b = inst.subject("b")
  let atF = paramFloat(inst, "atF", 0.0)

  template withSetup(x: var Assertion) =
    if paramFloat(inst, "fFrom", 0.0) > 0.0:
      x.condition["f_from"] = $paramFloat(inst, "fFrom", 0.0)
    if paramFloat(inst, "fTo", 0.0) > 0.0:
      x.condition["f_to"] = $paramFloat(inst, "fTo", 0.0)
    if atF > 0.0: x.condition["at_f"] = $atF

  if hasParam(inst, "maxGainDelta"):
    # `atF` **redirects** the gain-delta claim onto the single frequency
    # rather than adding a second one -- the `gain_stage`/`atF` pattern. Two
    # claims about one pair of curves would be one claim that can only ever
    # be the weaker.
    let q = if atF > 0.0: "gain_delta_at_f" else: "gain_delta_max_db"
    var x = Assertion(
      id: assertionId(inst, "gain_delta"),
      subjects: @[a, b],
      quantity: q,
      expect: atMost(paramFloat(inst, "maxGainDelta", 0.0)),
      unit: "dB",
      severity: sevError,
      rationale: (if atF > 0.0:
                    "the two channels' gain must match at the frequency the " &
                    "stage is specified at"
                  else:
                    "the two channels' gain must match across the band -- " &
                    "the worst point, since an imbalance anywhere in the " &
                    "audio range moves the stereo image there"),
      origin: inst.name)
    withSetup(x)
    result.add x

  if hasParam(inst, "maxEdgeRatio"):
    for suffix in ["f_lo_ratio", "f_hi_ratio"]:
      var x = Assertion(
        id: assertionId(inst, suffix),
        subjects: @[a, b],
        quantity: suffix,
        expect: atMost(paramFloat(inst, "maxEdgeRatio", 1.0)),
        unit: "",
        severity: sevError,
        rationale: "the two channels' band edges must track: a coupling or " &
                   "feedback capacitor out of tolerance on one channel tilts " &
                   "its response relative to the other. The figure is " &
                   "max/min, so it is >= 1 whichever channel is faster",
        origin: inst.name)
      withSetup(x)
      result.add x

proc oscillatorExpand(inst: RoleInstance): seq[Assertion] =
  ## What a circuit whose intent is *instability* is specified by: what it
  ## runs at, how big it is, and how clean.
  ##
  ## **Why this cannot be `opamp_stage` or `gain_stage` with a parameter.**
  ## Both of those are backed by an `.ac` sweep, and every claim they make is
  ## about how far the stage is from oscillating -- a phase margin, a bounded
  ## peak, a flat passband. An oscillator is specified the other way round:
  ## the loop gain must be *exactly* 1 at *exactly* 0 degrees, and everything
  ## a stability claim would call a defect is here the product. Worse, the
  ## measurement itself does not survive the change of intent: a swept
  ## measurement drives an ideal source onto the stage input, and a Wien
  ## bridge returns its positive feedback to that very node, so the source
  ## holds it and the bridge is shorted out of the circuit. There is no
  ## version of an `.ac` that answers this. The circuit has to be run.
  ##
  ## **What binds, and what does not.** The subject is the net the
  ## oscillation is measured on, and nothing else is needed to *measure*.
  ## `kick` is optional and binds the node given a stated starting voltage,
  ## which is what a circuit sitting at an operating point it never leaves
  ## on its own needs to start at all. A circuit that starts by itself omits
  ## it, and gets no `uic` and no assumption about unbiased nodes with it.
  ##
  ## `tSettle`, `tWindow`, `kick` and `kickV` are **conditions, not limits**,
  ## for the reason `settled_rail`'s window is and `large_signal`'s drive
  ## level is: they say what was run, and the answer is a function of them.
  ## An amplitude-stabilised oscillator settles to a level rather than to a
  ## time constant, so a window opened too early reports the envelope as
  ## distortion.
  let outNet = inst.subject("output")
  let tSettle = paramFloat(inst, "tSettle", 0.0)
  let tWindow = paramFloat(inst, "tWindow", 0.0)
  let kickV = paramFloat(inst, "kickV", 0.1)

  template running(sfx, qty: string, e: Expectation, un, why: string;
                   sev = sevError) =
    var claim = Assertion(
      id: assertionId(inst, sfx),
      subjects: @[outNet],
      quantity: qty,
      expect: e,
      unit: un,
      severity: sev,
      rationale: why,
      origin: inst.name)
    claim.condition["t_settle"] = $tSettle
    claim.condition["t_window"] = $tWindow
    claim.condition["kick_v"] = $kickV
    result.add claim

  # Every claim is opt-in and the role makes none of its own, the same rule
  # `settled_rail` follows. There is no default frequency for an oscillator
  # -- the network sets it and only the designer knows what it was meant to
  # be -- and no default amplitude or distortion budget either, since both
  # are consequences of a stabilisation scheme rather than of the topology.
  if hasParam(inst, "freq"):
    running("freq", "osc_freq",
            nominal(paramFloat(inst, "freq", 0.0),
                    fracTol = paramFloat(inst, "band", 0.05)), "Hz",
            "the frequency is the whole specification of an oscillator, and " &
            "it is set by the timing network alone -- a part substitution " &
            "in that network moves it with nothing else to say so")
  if hasParam(inst, "minSwing"):
    running("swing", "swing_pp",
            atLeast(paramFloat(inst, "minSwing", 0.0)), "V",
            "an oscillator that starts but does not reach its level is a " &
            "loop whose gain is barely above one, and it will stop over " &
            "temperature or with a part at the other end of its tolerance")
  if hasParam(inst, "maxSwing"):
    running("swing_max", "swing_pp",
            atMost(paramFloat(inst, "maxSwing", 0.0)), "V",
            "swing beyond this is an amplitude-stabilising network that has " &
            "stopped stabilising, and what is left is the amplifier clipping")
  if hasParam(inst, "maxThd"):
    running("thd", "osc_thd_pct",
            atMost(paramFloat(inst, "maxThd", 0.0)), "%",
            "distortion is what the amplitude-stabilising network costs, and " &
            "it is the one figure that says whether the loop is being held " &
            "at a gain of three or being clipped back to it", sevWarning)

proc largeSignalExpand(inst: RoleInstance): seq[Assertion] =
  ## What the stage does when it is *driven*, which for anything with
  ## deliberate nonlinearity in it is the only question that matters.
  ##
  ## Every other amplifier role here is small-signal: `.ac` linearises about
  ## the operating point, so a clipping diode is whatever conductance it has
  ## at rest and never clips. That is the right model for gain and stability
  ## and it is the wrong one for an overdrive, where the clipping *is* the
  ## product.
  ##
  ## `driveV` and `driveF` are **conditions, not limits** -- they say what
  ## the stage was driven with, and the answer is a function of them, so two
  ## instances at two levels are two measurements rather than one measured
  ## twice. They ride in `Assertion.condition`, which is the only channel an
  ## assertion has for a setup parameter, and the evaluator's setup key reads
  ## them back so the planner keeps the runs apart.
  let outNet = inst.subject("output")
  let driveV = paramFloat(inst, "driveV", 0.0)
  let driveF = paramFloat(inst, "driveF", 1.0e3)

  # Field names and parameter names must differ here: `quantity: quantity`
  # inside an object constructor is ambiguous to the template expander.
  template driven(sfx, qty: string, e: Expectation, un, why: string;
                  sev = sevError) =
    var claim = Assertion(
      id: assertionId(inst, sfx),
      subjects: @[outNet],
      quantity: qty,
      expect: e,
      unit: un,
      severity: sev,
      rationale: why,
      origin: inst.name)
    claim.condition["drive_v"] = $driveV
    claim.condition["drive_f"] = $driveF
    result.add claim

  if hasParam(inst, "maxThd"):
    driven("thd", "thd_pct", atMost(paramFloat(inst, "maxThd", 0.0)), "%",
           "distortion at the level the stage is actually driven at")
  if hasParam(inst, "minThd"):
    # Deliberately available: on an overdrive, too *little* distortion is
    # the defect. A clipping stage that measures clean has lost its diodes.
    driven("thd_min", "thd_pct", atLeast(paramFloat(inst, "minThd", 0.0)), "%",
           "a stage whose distortion is what it is for must actually produce it")
  if hasParam(inst, "minSwing"):
    driven("swing", "output_swing",
           atLeast(paramFloat(inst, "minSwing", 0.0)), "V",
           "the stage must deliver the output swing it was designed for")
  if hasParam(inst, "maxSwing"):
    driven("swing_max", "output_swing",
           atMost(paramFloat(inst, "maxSwing", 0.0)), "V",
           "swing beyond this runs into whatever the stage feeds")

proc settledRailExpand(inst: RoleInstance): seq[Assertion] =
  ## What a node does once it has stopped changing: where it sits, and what
  ## is left moving on it.
  ##
  ## **Why this is not `power_rail` with another parameter, and not
  ## `regulator` with one either.** `power_rail`'s `dc_voltage` is an
  ## operating point, and an operating point has no ripple in it -- a `.op`
  ## solves one instant of a circuit that is not moving, so a switching
  ## converter's rail reads as its average by construction and would pass any
  ## ripple claim ever made about it. `regulator` is about the *way up*, and
  ## binds a driving part to stand up as a ramp. This role binds nothing: it
  ## names a net, a time by which the circuit should have settled, and what
  ## it must then be doing. That is what makes it reach the circuits the
  ## other two cannot -- a charge pump, an oscillator's envelope, a converter
  ## measured cycle by cycle.
  ##
  ## `tSettle` and `tWindow` are **conditions, not limits**, exactly as
  ## `large_signal`'s drive level is: they say what was run, the answer is a
  ## function of them, and two claims at two windows are two runs. They ride
  ## in `Assertion.condition`, and the evaluator's setup key reads them back
  ## so the planner keeps those runs apart.
  let rail = inst.subject("rail")
  let tSettle = paramFloat(inst, "tSettle", 0.0)
  let tWindow = paramFloat(inst, "tWindow", 0.0)

  template settled(sfx, qty: string, e: Expectation, un, why: string;
                   sev = sevError) =
    var claim = Assertion(
      id: assertionId(inst, sfx),
      subjects: @[rail],
      quantity: qty,
      expect: e,
      unit: un,
      severity: sev,
      rationale: why,
      origin: inst.name)
    claim.condition["t_settle"] = $tSettle
    claim.condition["t_window"] = $tWindow
    result.add claim

  # Both claims are opt-in, and the role makes none of its own. A settling
  # voltage without a stated value is not a claim, and a ripple budget is a
  # system decision -- what the rail feeds and how much of it that load can
  # reject -- rather than anything the circuit implies. Defaulting either
  # would manufacture a claim nobody made and report it as theirs.
  if hasParam(inst, "voltage"):
    settled("settled", "settled_v",
            nominal(paramFloat(inst, "voltage", 0.0),
                    fracTol = paramFloat(inst, "band", 0.05)), "V",
            "once it has settled, the rail has to sit where it was " &
            "specified to sit -- measured over a window rather than at an " &
            "operating point, so a rail that is still moving cannot pass by " &
            "being sampled at the right instant")
  if hasParam(inst, "maxRipple"):
    settled("ripple", "ripple_pp",
            atMost(paramFloat(inst, "maxRipple", 0.0)), "V",
            "what is left on the rail after it has settled is what every " &
            "load on it has to reject; a switching converter's ripple is " &
            "invisible to an operating point and to any averaged model of " &
            "the part", sevWarning)

proc currentPathExpand(inst: RoleInstance): seq[Assertion] =
  ## What is flowing **through a part** once the circuit has settled.
  ##
  ## **The one built-in role whose subject is a component rather than a net.**
  ## Every other quantity this library measures is a voltage, and that is not
  ## a stylistic accident -- a branch current is not in an operating point for
  ## anything but a voltage source, so until there was a `.tran` reading
  ## device currents there was nothing for a current claim to be checked
  ## against. `current_rating` and `isat` were registered and set by the part
  ## policy the whole time and read by nobody, which is the shape of gap that
  ## looks like coverage from the outside.
  ##
  ## **Why the part and not the net it feeds.** A net has one voltage and
  ## every part on it shares it; a net has no current at all, only the several
  ## different currents of the parts hanging off it. An inductor's peak, an
  ## input capacitor's RMS and a sense resistor's average are three claims
  ## about three parts on two nets, and naming the net could not tell them
  ## apart.
  ##
  ## `tSettle` and `tWindow` are **conditions, not limits**, exactly as
  ## `settled_rail`'s are and for the same reason: they say what was run, the
  ## answer is a function of them, and two claims at two windows are two runs.
  let part = inst.subject("part")
  let tSettle = paramFloat(inst, "tSettle", 0.0)
  let tWindow = paramFloat(inst, "tWindow", 0.0)

  template carried(sfx, qty: string, e: Expectation, un, why: string;
                   sev = sevError) =
    var claim = Assertion(
      id: assertionId(inst, sfx),
      subjects: @[part],
      quantity: qty,
      expect: e,
      unit: un,
      severity: sev,
      rationale: why,
      origin: inst.name)
    claim.condition["t_settle"] = $tSettle
    claim.condition["t_window"] = $tWindow
    result.add claim

  # Every claim is opt-in and the role makes none of its own, the same rule
  # `settled_rail` and `oscillator` follow. There is no default current for a
  # part: what an inductor may carry is a property of the part somebody chose,
  # and what it *does* carry is a property of the circuit -- neither implies a
  # budget, and inventing one would manufacture a claim and report it as the
  # designer's.
  if hasParam(inst, "isat"):
    carried("isat", "i_peak",
            atMost(paramFloat(inst, "isat", 0.0)), "A",
            "past saturation an inductor's inductance collapses, so every " &
            "figure that depends on it -- the ripple, the crossover, the " &
            "efficiency -- stops describing the part on the board. It is a " &
            "peak rather than an average because saturation happens at the " &
            "top of the triangle, not at its middle")
  if hasParam(inst, "iRmsMax"):
    carried("i_rms", "i_rms",
            atMost(paramFloat(inst, "iRmsMax", 0.0)), "A",
            "RMS is what heats the part, so this is the figure a continuous " &
            "rating and a temperature rise are both quoted against -- and " &
            "the one a peak-only claim misses on a waveform that spends most " &
            "of its time near zero")
  if hasParam(inst, "iAvgMax"):
    carried("i_avg", "i_avg",
            atMost(paramFloat(inst, "iAvgMax", 0.0)), "A",
            "the DC component the part carries, which is what a fuse, a " &
            "trace width and a connector contact are sized by")
  if hasParam(inst, "iRipple"):
    carried("ripple", "i_pp",
            nominal(paramFloat(inst, "iRipple", 0.0),
                    fracTol = paramFloat(inst, "band", 0.05)), "A",
            "the peak-to-peak the design equations fix -- for a converter " &
            "dI = Vout(1-D)/(Lf), which sets the output ripple, the current " &
            "limit headroom and whether the part saturates. Claiming it is " &
            "how a wrong inductor value is caught by something other than " &
            "the rail looking slightly worse")
  # The two claims that read the *part's own* rating rather than restating it
  # in the design file. That is the point of `isat` and `current_rating`
  # having been registered: the number is a property of the part somebody
  # chose, so a design that states it again has two copies to drift apart.
  if hasParam(inst, "maxIsatDerating"):
    carried("isat_derating", "i_peak_derating",
            atMost(paramFloat(inst, "maxIsatDerating", 0.0)), "",
            "how much of the part's *own* stated saturation current the peak " &
            "reaches -- nobody runs an inductor to its knee, and this is the " &
            "headroom stated once rather than copied out of the datasheet " &
            "into the design file", sevWarning)
  if hasParam(inst, "maxRmsDerating"):
    carried("rms_derating", "i_rms_derating",
            atMost(paramFloat(inst, "maxRmsDerating", 0.0)), "",
            "the same headroom against the part's stated continuous rating, " &
            "which is what its temperature rise was specified at", sevWarning)

# --- built-in: source_sweep / load_sweep -------------------------------

proc sourceSweepExpand(inst: RoleInstance): seq[Assertion] =
  ## What a node does as a source in the design is swept.
  ##
  ## **Why the sweep is a condition and not a claim.** `vFrom`/`vTo`/`vStep`
  ## say what was run: every quantity below is a difference taken across that
  ## range, so two claims over two ranges are two runs and the answers are not
  ## comparable. They ride in `Assertion.condition` exactly as
  ## `settled_rail`'s window does, and the evaluator's setup key reads them
  ## back so the planner keeps the runs apart.
  ##
  ## **Why `ratio` and `maxLineReg` are both here.** They are the same
  ## measurement asked by two opposite circuits. A regulator's specification
  ## is that the output does *not* follow its input, which is quoted as a
  ## percentage of the output and wants to be small; a divider's is that it
  ## follows exactly, by a stated ratio, which is quoted as a slope and wants
  ## to be right. A role offering only one would make the other state its
  ## specification as its counterpart's failure.
  let outNet = inst.subject("output")
  let vFrom = paramFloat(inst, "vFrom", 0.0)
  let vTo = paramFloat(inst, "vTo", 0.0)
  let vStep = paramFloat(inst, "vStep", 0.0)

  template swept(sfx, qty: string, e: Expectation, un, why: string;
                 sev = sevError) =
    var claim = Assertion(
      id: assertionId(inst, sfx),
      subjects: @[outNet],
      quantity: qty,
      expect: e,
      unit: un,
      severity: sev,
      rationale: why,
      origin: inst.name)
    claim.condition["sweep"] = "source"
    claim.condition["sweep_from"] = $vFrom
    claim.condition["sweep_to"] = $vTo
    claim.condition["sweep_step"] = $vStep
    if hasParam(inst, "nominal"):
      claim.condition["v_nominal"] = $paramFloat(inst, "nominal", 0.0)
    result.add claim

  # Every claim is opt-in and the role makes none of its own. A sweep with no
  # claim on it is a curve nobody asked a question about, and there is no
  # default answer for what a node should do as its supply moves: for a
  # regulator the right answer is "nothing", for a divider it is "follow", and
  # inventing either would manufacture a claim and report it as the
  # designer's.
  if hasParam(inst, "ratio"):
    swept("transfer", "dc_transfer",
          nominal(paramFloat(inst, "ratio", 0.0),
                  fracTol = paramFloat(inst, "band", 0.05)), "",
          "the output has to follow the input by the ratio the design " &
          "equations computed -- measured as a slope across the whole swept " &
          "range rather than as one node voltage at one bias, which a wrong " &
          "network can still get right")
  if hasParam(inst, "maxLineReg"):
    swept("line_reg", "line_reg_pct",
          atMost(paramFloat(inst, "maxLineReg", 0.0)), "%",
          "how far the output moves across the whole input range, as a " &
          "percentage of the output -- which is what a supply's own " &
          "tolerance has to be budgeted against")
  if hasParam(inst, "maxLineRegPerV"):
    swept("line_reg_per_v", "line_reg_pct_per_v",
          atMost(paramFloat(inst, "maxLineRegPerV", 0.0)), "%/V",
          "the datasheet form of the same figure, which unlike the total " &
          "does not change with how wide the sweep was")
  if hasParam(inst, "maxDropout"):
    swept("dropout", "dropout_v",
          atMost(paramFloat(inst, "maxDropout", 0.0)), "V",
          "the input-to-output differential the part still regulates at; " &
          "below it the rail follows the supply down and every claim made " &
          "about the rail stops holding")
  if hasParam(inst, "minOut"):
    swept("out_min", "dc_out_min",
          atLeast(paramFloat(inst, "minOut", 0.0)), "V",
          "the lowest the output reaches anywhere in the swept range, which " &
          "is what anything downstream has to tolerate")
  if hasParam(inst, "maxOut"):
    swept("out_max", "dc_out_max",
          atMost(paramFloat(inst, "maxOut", 0.0)), "V",
          "the highest the output reaches anywhere in the swept range, " &
          "which is what anything downstream has to survive")
  if hasParam(inst, "maxDelta"):
    swept("delta", "dc_out_delta",
          atMost(paramFloat(inst, "maxDelta", 0.0)), "V",
          "how far the output moves across the whole range, in volts -- the " &
          "same figure `maxLineReg` states as a percentage, for a node that " &
          "has a budget rather than a nominal to be a fraction of")

proc loadSweepExpand(inst: RoleInstance): seq[Assertion] =
  ## What a node does as current is drawn out of it.
  ##
  ## **This role binds no part, and that is the point.** The stimulus is a
  ## constant-current sink the analysis injects at the measured node; there is
  ## deliberately nothing in the design to bind, because a test load is not a
  ## part anybody solders and putting one in the netlist would put it on the
  ## BoM and in the layout. So the role names a node, a current range, and
  ## what the node must then do -- which is also what lets it reach a network
  ## that has no load port at all, where `z_out_dc` is the Thevenin
  ## resistance the design equations computed and the netlist never states.
  let outNet = inst.subject("output")
  let iFrom = paramFloat(inst, "iFrom", 0.0)
  let iTo = paramFloat(inst, "iTo", 0.0)
  let iStep = paramFloat(inst, "iStep", 0.0)

  template swept(sfx, qty: string, e: Expectation, un, why: string;
                 sev = sevError) =
    var claim = Assertion(
      id: assertionId(inst, sfx),
      subjects: @[outNet],
      quantity: qty,
      expect: e,
      unit: un,
      severity: sev,
      rationale: why,
      origin: inst.name)
    claim.condition["sweep"] = "load"
    claim.condition["sweep_from"] = $iFrom
    claim.condition["sweep_to"] = $iTo
    claim.condition["sweep_step"] = $iStep
    if hasParam(inst, "nominal"):
      claim.condition["v_nominal"] = $paramFloat(inst, "nominal", 0.0)
    result.add claim

  if hasParam(inst, "maxLoadReg"):
    swept("load_reg", "load_reg_pct",
          atMost(paramFloat(inst, "maxLoadReg", 0.0)), "%",
          "how far the output sags across the whole load range, as a " &
          "percentage of the output at light load")
  if hasParam(inst, "zOut"):
    swept("z_out", "z_out_dc",
          nominal(paramFloat(inst, "zOut", 0.0),
                  fracTol = paramFloat(inst, "band", 0.05)), "ohm",
          "the resistance looking back into the node, which for anything " &
          "built from a stated total and a stated ratio is a number the " &
          "design equations fix and no component value in the file says")
  if hasParam(inst, "maxZOut"):
    swept("z_out_max", "z_out_dc",
          atMost(paramFloat(inst, "maxZOut", 0.0)), "ohm",
          "how stiff the node has to be: everything hung on it sees this " &
          "resistance in series with whatever it draws")
  # The same three the source sweep offers, and the natural way to state a
  # load claim: what the node must still be at when the heaviest load in the
  # range is drawn from it.
  if hasParam(inst, "minOut"):
    swept("out_min", "dc_out_min",
          atLeast(paramFloat(inst, "minOut", 0.0)), "V",
          "the lowest the node reaches at the heaviest load in the range, " &
          "which is the voltage everything on it has to keep working at")
  if hasParam(inst, "maxOut"):
    swept("out_max", "dc_out_max",
          atMost(paramFloat(inst, "maxOut", 0.0)), "V",
          "the highest the node reaches anywhere in the load range")
  if hasParam(inst, "maxDelta"):
    swept("delta", "dc_out_delta",
          atMost(paramFloat(inst, "maxDelta", 0.0)), "V",
          "how far the node sags across the whole load range, in volts -- " &
          "the same figure `maxLoadReg` states as a percentage")

proc registerBuiltinRoles*() =
  ## Called at module init. Exposed so a test can prove that re-registering
  ## is idempotent, and so an application that clears the registry can put
  ## the built-ins back.
  registerRole(RoleDef(
    name: "power_rail",
    doc: "A regulated supply net at a stated nominal voltage.",
    parts: @[RolePart(name: "rail", kind: skNet, doc: "the supply net")],
    params: @[
      AnnDef(key: "voltage", kind: akFloat, unit: "V", scopes: {asNet},
             doc: "nominal rail voltage"),
      AnnDef(key: "band", kind: akFloat, scopes: {asNet},
             doc: "acceptance band as a fraction of nominal; default 5%"),
      AnnDef(key: "targetZ", kind: akFloat, unit: "ohm", scopes: {asNet},
             doc: "decoupling target impedance; omitted means unclaimed"),
      AnnDef(key: "targetFrom", kind: akFloat, unit: "Hz", scopes: {asNet},
             doc: "low end of the band targetZ applies to; default 100 kHz"),
      AnnDef(key: "targetTo", kind: akFloat, unit: "Hz", scopes: {asNet},
             doc: "high end of the band targetZ applies to; default 100 MHz"),
      AnnDef(key: "maxDerating", kind: akFloat, scopes: {asNet},
             doc: "highest fraction of its voltage rating any part on this " &
                  "rail may reach; omitted means unclaimed"),
    ],
    apply: powerRailApply,
    expand: powerRailExpand))

  registerRole(RoleDef(
    name: "i2c",
    doc: "A two-wire open-drain bus at a stated clock frequency.",
    parts: @[
      RolePart(name: "sda", kind: skNet, doc: "data line"),
      RolePart(name: "scl", kind: skNet, doc: "clock line"),
      RolePart(name: "pullupRail", kind: skNet, optional: true,
               doc: "rail the pull-ups terminate to"),
      RolePart(name: "controller", kind: skComponent, optional: true,
               doc: "the bus controller, when there is a single known one"),
    ],
    params: @[
      AnnDef(key: "frequency", kind: akFloat, unit: "Hz", scopes: {asNet},
             doc: "bus clock frequency; default 100 kHz standard mode"),
      AnnDef(key: "maxSinkCurrent", kind: akFloat, unit: "A", scopes: {asNet},
             doc: "most current a target must sink to pull a line low; " &
                  "default 3 mA, which is the I2C specification's figure"),
    ],
    apply: nil,
    expand: i2cExpand))

  registerRole(RoleDef(
    name: "regulator",
    doc: "A supply: how it comes up, how it holds up, and what it delivers.",
    parts: regulatorParts,
    params: regulatorParams,
    apply: nil,
    expand: regulatorExpand))

  registerRole(RoleDef(
    name: "linear_regulator",
    doc: "A regulator that drops the difference, plus what only a linear " &
         "one is asked: headroom and how well it holds against the line.",
    parts: regulatorParts & @[
      RolePart(name: "source", kind: skComponent, optional: true,
               doc: "the supply to sweep for a line figure"),
      RolePart(name: "input", kind: skNet, optional: true,
               doc: "the regulator's own input pin -- what a dropout is " &
                    "measured *from*, and where ripple is quoted at"),
    ],
    params: regulatorParams & linearParams,
    apply: nil,
    expand: linearRegulatorExpand))

  registerRole(RoleDef(
    name: "switching_regulator",
    doc: "A regulator that chops and filters, plus what only a switcher is " &
         "asked: output ripple, switching rate and inductor current.",
    parts: regulatorParts & @[
      RolePart(name: "switch", kind: skNet, optional: true,
               doc: "the switch node, where the switching rate is read"),
      RolePart(name: "inductor", kind: skComponent, optional: true,
               doc: "the output inductor, which carries the switch current"),
      RolePart(name: "source", kind: skComponent, optional: true,
               doc: "the supply whose ripple the part has to reject"),
      RolePart(name: "input", kind: skNet, optional: true,
               doc: "the regulator's own input pin, where that ripple is " &
                    "quoted at"),
    ],
    params: regulatorParams & switchingParams,
    apply: nil,
    expand: switchingRegulatorExpand))

  registerRole(RoleDef(
    name: "opamp_stage",
    doc: "One amplifier stage: an op-amp, its input and its output.",
    parts: @[
      RolePart(name: "opamp", kind: skComponent, doc: "the amplifier"),
      RolePart(name: "input", kind: skNet, doc: "where the stage is driven"),
      RolePart(name: "output", kind: skNet, doc: "the stage output"),
    ],
    params: @[
      AnnDef(key: "minBandwidth", kind: akFloat, unit: "Hz", scopes: {asNet},
             doc: "required -3 dB bandwidth; omitted means unclaimed"),
      AnnDef(key: "minPhaseMargin", kind: akFloat, unit: "deg", scopes: {asNet},
             doc: "required phase margin in degrees; default 45"),
      AnnDef(key: "maxPeaking", kind: akFloat, unit: "dB", scopes: {asNet},
             doc: "tolerated closed-loop peaking in dB; default 1"),
      AnnDef(key: "minGainMargin", kind: akFloat, unit: "dB", scopes: {asNet},
             doc: "required gain margin in dB; omitted means unclaimed"),
    ],
    apply: nil,
    expand: opampStageExpand))

  registerRole(RoleDef(
    name: "gain_stage",
    doc: "One amplifier stage judged by its passband, for a stage that is " &
         "AC coupled and so has no meaningful gain at DC.",
    parts: @[
      RolePart(name: "opamp", kind: skComponent, doc: "the amplifier"),
      RolePart(name: "input", kind: skNet, doc: "where the stage is driven"),
      RolePart(name: "output", kind: skNet, doc: "the stage output"),
    ],
    params: @[
      AnnDef(key: "minGain", kind: akFloat, unit: "dB", scopes: {asNet},
             doc: "lowest acceptable gain in dB; omitted means unclaimed"),
      AnnDef(key: "maxGain", kind: akFloat, unit: "dB", scopes: {asNet},
             doc: "highest acceptable gain in dB; omitted means unclaimed"),
      AnnDef(key: "atF", kind: akFloat, unit: "Hz", scopes: {asNet},
             doc: "frequency the gain claims are made at; omitted means " &
                  "they are made at the response's maximum"),
      AnnDef(key: "fLoMax", kind: akFloat, unit: "Hz", scopes: {asNet},
             doc: "the lower -3 dB edge must be at or below this; omitted " &
                  "means unclaimed"),
      AnnDef(key: "fHiMin", kind: akFloat, unit: "Hz", scopes: {asNet},
             doc: "the upper -3 dB edge must be at or above this; omitted " &
                  "means unclaimed"),
    ],
    apply: nil,
    expand: gainStageExpand))

  registerRole(RoleDef(
    name: "channel_match",
    doc: "Two amplifier stages judged against each other: do the channels " &
         "of a stereo board actually match?",
    parts: @[
      RolePart(name: "a", kind: skClass,
               doc: "the first stage, as `roleRef(\"<name>\")`"),
      RolePart(name: "b", kind: skClass,
               doc: "the second stage, as `roleRef(\"<name>\")` -- declare " &
                    "both stages before this instance"),
    ],
    params: @[
      AnnDef(key: "maxGainDelta", kind: akFloat, unit: "dB", scopes: {asNet},
             doc: "largest gain difference between the channels, in dB; " &
                  "omitted means unclaimed"),
      AnnDef(key: "maxEdgeRatio", kind: akFloat, scopes: {asNet},
             doc: "largest ratio (max/min, so >= 1) between the two " &
                  "channels' -3 dB corners; omitted means unclaimed"),
      AnnDef(key: "atF", kind: akFloat, unit: "Hz", scopes: {asNet},
             doc: "frequency the gain-delta claim is made at; omitted means " &
                  "it is the worst over the swept band"),
      AnnDef(key: "fFrom", kind: akFloat, unit: "Hz", scopes: {asNet},
             doc: "low end of the compared band; sets the sweep, never " &
                  "gates a claim"),
      AnnDef(key: "fTo", kind: akFloat, unit: "Hz", scopes: {asNet},
             doc: "high end of the compared band; sets the sweep"),
    ],
    apply: nil,
    expand: channelMatchExpand))

  registerRole(RoleDef(
    name: "settled_rail",
    doc: "A node judged over a window at the end of a transient run: where " &
         "it settles, and what is still moving on it.",
    parts: @[
      RolePart(name: "rail", kind: skNet, doc: "the net to measure"),
    ],
    params: @[
      AnnDef(key: "tSettle", kind: akFloat, unit: "s", scopes: {asNet},
             doc: "how long the circuit is given to settle before the " &
                  "measurement window opens; everything before it is " &
                  "simulated and discarded"),
      AnnDef(key: "tWindow", kind: akFloat, unit: "s", scopes: {asNet},
             doc: "length of the measurement window; omitted takes a fifth " &
                  "of tSettle"),
      AnnDef(key: "voltage", kind: akFloat, unit: "V", scopes: {asNet},
             doc: "what the node must settle to; omitted means unclaimed"),
      AnnDef(key: "band", kind: akFloat, scopes: {asNet},
             doc: "acceptance band as a fraction of nominal; default 5%"),
      AnnDef(key: "maxRipple", kind: akFloat, unit: "V", scopes: {asNet},
             doc: "peak-to-peak the node may still be moving over the " &
                  "window; omitted means unclaimed"),
    ],
    apply: nil,
    expand: settledRailExpand))

  registerRole(RoleDef(
    name: "current_path",
    doc: "A part carrying current, judged over a window at the end of a " &
         "transient run: peak, RMS and average, against what the part can " &
         "take.",
    parts: @[
      RolePart(name: "part", kind: skComponent,
               doc: "the part the current flows through"),
    ],
    params: @[
      AnnDef(key: "tSettle", kind: akFloat, unit: "s", scopes: {asComponent},
             doc: "how long the circuit is given to settle before the " &
                  "measurement window opens; everything before it is " &
                  "simulated and discarded"),
      AnnDef(key: "tWindow", kind: akFloat, unit: "s", scopes: {asComponent},
             doc: "length of the measurement window; omitted takes a fifth " &
                  "of tSettle. Make it several switching cycles"),
      AnnDef(key: "isat", kind: akFloat, unit: "A", scopes: {asComponent},
             doc: "highest peak the part may reach -- an inductor's " &
                  "saturation current; omitted means unclaimed"),
      AnnDef(key: "iRmsMax", kind: akFloat, unit: "A", scopes: {asComponent},
             doc: "highest RMS the part may carry, which is what heats it; " &
                  "omitted means unclaimed"),
      AnnDef(key: "iAvgMax", kind: akFloat, unit: "A", scopes: {asComponent},
             doc: "highest DC component the part may carry; omitted means " &
                  "unclaimed"),
      AnnDef(key: "iRipple", kind: akFloat, unit: "A", scopes: {asComponent},
             doc: "peak-to-peak the current must swing, when that is a " &
                  "number the design equations fix; omitted means unclaimed"),
      AnnDef(key: "band", kind: akFloat, scopes: {asComponent},
             doc: "acceptance band on `iRipple`, as a fraction; default 5%"),
      AnnDef(key: "maxIsatDerating", kind: akFloat, scopes: {asComponent},
             doc: "highest fraction of the part's *own* stated `isat` the " &
                  "peak may reach; unchecked when the part states none"),
      AnnDef(key: "maxRmsDerating", kind: akFloat, scopes: {asComponent},
             doc: "highest fraction of the part's *own* stated " &
                  "`current_rating` the RMS may reach; unchecked when the " &
                  "part states none"),
    ],
    apply: nil,
    expand: currentPathExpand))

  registerRole(RoleDef(
    name: "oscillator",
    doc: "A circuit whose intent is instability: what it runs at, how big " &
         "it is, and how clean.",
    parts: @[
      RolePart(name: "output", kind: skNet,
               doc: "the net the oscillation is measured on"),
      RolePart(name: "kick", kind: skNet, optional: true,
               doc: "a node given a stated starting voltage, for a circuit " &
                    "that sits at its operating point and will not leave it " &
                    "without a disturbance"),
    ],
    params: @[
      AnnDef(key: "tSettle", kind: akFloat, unit: "s", scopes: {asNet},
             doc: "how long the circuit is given to reach its steady " &
                  "amplitude before the measurement window opens; an " &
                  "amplitude-stabilised loop is slow and this is usually " &
                  "what sets it, not the period"),
      AnnDef(key: "tWindow", kind: akFloat, unit: "s", scopes: {asNet},
             doc: "length of the measurement window; make it several whole " &
                  "periods, since the distortion figure integrates over them"),
      AnnDef(key: "kickV", kind: akFloat, unit: "V", scopes: {asNet},
             doc: "the starting voltage put on the `kick` node; default " &
                  "100 mV. Unused when no `kick` part is bound"),
      AnnDef(key: "freq", kind: akFloat, unit: "Hz", scopes: {asNet},
             doc: "the frequency it must run at; omitted means unclaimed"),
      AnnDef(key: "band", kind: akFloat, scopes: {asNet},
             doc: "acceptance band on the frequency, as a fraction; " &
                  "default 5%"),
      AnnDef(key: "minSwing", kind: akFloat, unit: "V", scopes: {asNet},
             doc: "smallest acceptable peak-to-peak output swing"),
      AnnDef(key: "maxSwing", kind: akFloat, unit: "V", scopes: {asNet},
             doc: "largest acceptable peak-to-peak output swing"),
      AnnDef(key: "maxThd", kind: akFloat, unit: "%", scopes: {asNet},
             doc: "most distortion tolerated on the output"),
    ],
    apply: nil,
    expand: oscillatorExpand))

  registerRole(RoleDef(
    name: "large_signal",
    doc: "One amplifier stage driven with a real signal: distortion and " &
         "swing, for a stage whose nonlinearity is the point.",
    parts: @[
      RolePart(name: "opamp", kind: skComponent, doc: "the amplifier"),
      RolePart(name: "input", kind: skNet, doc: "where the stage is driven"),
      RolePart(name: "output", kind: skNet, doc: "the stage output"),
    ],
    params: @[
      AnnDef(key: "driveV", kind: akFloat, unit: "V", scopes: {asNet},
             doc: "peak amplitude of the sine the stage is driven with; " &
                  "the answer is a function of this, so it is required"),
      AnnDef(key: "driveF", kind: akFloat, unit: "Hz", scopes: {asNet},
             doc: "frequency of that sine; default 1 kHz"),
      AnnDef(key: "maxThd", kind: akFloat, unit: "%", scopes: {asNet},
             doc: "most distortion tolerated at that drive; omitted means " &
                  "unclaimed"),
      AnnDef(key: "minThd", kind: akFloat, unit: "%", scopes: {asNet},
             doc: "least distortion required -- for a stage whose clipping " &
                  "is the product, too little is the defect"),
      AnnDef(key: "minSwing", kind: akFloat, unit: "V", scopes: {asNet},
             doc: "smallest acceptable peak-to-peak output swing"),
      AnnDef(key: "maxSwing", kind: akFloat, unit: "V", scopes: {asNet},
             doc: "largest acceptable peak-to-peak output swing"),
    ],
    apply: nil,
    expand: largeSignalExpand))

  registerRole(RoleDef(
    name: "source_sweep",
    doc: "A source in the design swept at DC: what the output does across " &
         "the whole input range, rather than at one bias.",
    parts: @[
      RolePart(name: "source", kind: skComponent,
               doc: "the voltage source to sweep"),
      RolePart(name: "output", kind: skNet, doc: "the net to measure"),
      RolePart(name: "input", kind: skNet, optional: true,
               doc: "the node the part actually works from, when that is " &
                    "past a lead resistance or a filter -- the differential " &
                    "a dropout figure is measured across"),
    ],
    params: @[
      AnnDef(key: "vFrom", kind: akFloat, unit: "V", scopes: {asNet},
             doc: "low end of the swept input range"),
      AnnDef(key: "vTo", kind: akFloat, unit: "V", scopes: {asNet},
             doc: "high end of the swept input range"),
      AnnDef(key: "vStep", kind: akFloat, unit: "V", scopes: {asNet},
             doc: "sweep step; omitted takes fifty-one points across the " &
                  "range, which is a cheap curve -- a .dc is one operating " &
                  "point per step"),
      AnnDef(key: "nominal", kind: akFloat, unit: "V", scopes: {asNet},
             doc: "the output the percentage figures are quoted against; " &
                  "omitted takes the output at the high-line end"),
      AnnDef(key: "ratio", kind: akFloat, scopes: {asNet},
             doc: "the slope the output must follow the input by, in V/V; " &
                  "omitted means unclaimed"),
      AnnDef(key: "band", kind: akFloat, scopes: {asNet},
             doc: "acceptance band on `ratio`, as a fraction; default 5%"),
      AnnDef(key: "maxLineReg", kind: akFloat, unit: "%", scopes: {asNet},
             doc: "most the output may move across the whole range, as a " &
                  "percentage of nominal; omitted means unclaimed"),
      AnnDef(key: "maxLineRegPerV", kind: akFloat, unit: "%/V", scopes: {asNet},
             doc: "the same figure per volt of input, which is how a " &
                  "datasheet quotes it; omitted means unclaimed"),
      AnnDef(key: "maxDropout", kind: akFloat, unit: "V", scopes: {asNet},
             doc: "largest input-to-output differential the part may need " &
                  "to still regulate; omitted means unclaimed. Reported as " &
                  "unchecked when the sweep never went low enough to find " &
                  "one, which is not the same as a small dropout"),
      AnnDef(key: "minOut", kind: akFloat, unit: "V", scopes: {asNet},
             doc: "lowest the output may reach anywhere in the range; " &
                  "omitted means unclaimed"),
      AnnDef(key: "maxOut", kind: akFloat, unit: "V", scopes: {asNet},
             doc: "highest the output may reach anywhere in the range; " &
                  "omitted means unclaimed"),
      AnnDef(key: "maxDelta", kind: akFloat, unit: "V", scopes: {asNet},
             doc: "most the output may move across the range, in volts -- " &
                  "`maxLineReg` in absolute terms, for a node with a budget " &
                  "rather than a nominal; omitted means unclaimed"),
    ],
    apply: nil,
    expand: sourceSweepExpand))

  registerRole(RoleDef(
    name: "load_sweep",
    doc: "A node loaded by a swept current sink the analysis injects: how " &
         "far it sags, and how stiff it is.",
    parts: @[
      RolePart(name: "output", kind: skNet,
               doc: "the net the load is drawn from and measured at"),
    ],
    params: @[
      AnnDef(key: "iFrom", kind: akFloat, unit: "A", scopes: {asNet},
             doc: "light-load end of the swept range; usually zero, since " &
                  "the percentage figure is quoted against the output there"),
      AnnDef(key: "iTo", kind: akFloat, unit: "A", scopes: {asNet},
             doc: "heaviest load the node is specified to hold up under"),
      AnnDef(key: "iStep", kind: akFloat, unit: "A", scopes: {asNet},
             doc: "sweep step; omitted takes fifty-one points"),
      AnnDef(key: "nominal", kind: akFloat, unit: "V", scopes: {asNet},
             doc: "the output the percentage figure is quoted against; " &
                  "omitted takes the output at the light-load end"),
      AnnDef(key: "maxLoadReg", kind: akFloat, unit: "%", scopes: {asNet},
             doc: "most the output may sag across the load range, as a " &
                  "percentage of nominal; omitted means unclaimed"),
      AnnDef(key: "zOut", kind: akFloat, unit: "ohm", scopes: {asNet},
             doc: "the resistance looking back into the node, when it is a " &
                  "number the design fixes rather than a limit; omitted " &
                  "means unclaimed"),
      AnnDef(key: "band", kind: akFloat, scopes: {asNet},
             doc: "acceptance band on `zOut`, as a fraction; default 5%"),
      AnnDef(key: "maxZOut", kind: akFloat, unit: "ohm", scopes: {asNet},
             doc: "highest output resistance tolerated; omitted means " &
                  "unclaimed"),
      AnnDef(key: "minOut", kind: akFloat, unit: "V", scopes: {asNet},
             doc: "lowest the node may reach at the heaviest load in the " &
                  "range; omitted means unclaimed"),
      AnnDef(key: "maxOut", kind: akFloat, unit: "V", scopes: {asNet},
             doc: "highest the node may reach anywhere in the load range; " &
                  "omitted means unclaimed"),
      AnnDef(key: "maxDelta", kind: akFloat, unit: "V", scopes: {asNet},
             doc: "most the node may sag across the range, in volts -- " &
                  "`maxLoadReg` in absolute terms; omitted means unclaimed"),
    ],
    apply: nil,
    expand: loadSweepExpand))

registerBuiltinRoles()
