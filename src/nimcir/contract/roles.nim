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
  for a in result.mitems:
    a.condition["t_run"] = $tRun

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
    doc: "A supply that ramps a rail up to a nominal voltage at power-on.",
    parts: @[
      RolePart(name: "regulator", kind: skComponent,
               doc: "the part driving the rail"),
      RolePart(name: "output", kind: skNet, doc: "the net it drives"),
      RolePart(name: "measure", kind: skNet, optional: true,
               doc: "where the rail is judged, when that is past a filter"),
    ],
    params: @[
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
    ],
    apply: nil,
    expand: regulatorExpand))

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

registerBuiltinRoles()
