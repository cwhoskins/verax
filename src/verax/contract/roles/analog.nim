## Built-in roles for analog signal-path stages.
##
## `opamp_stage` and `gain_stage` are a DC-coupled / AC-coupled pair judged by
## `.ac`; `channel_match` is the first role whose subjects are two other role
## instances rather than nets; `oscillator` is the counterpart for a circuit
## whose intent is instability; `large_signal` is the driven, nonlinear one.
## The reasoning for each -- and why none is a parameter on another -- is in
## `contract/CLAUDE.md`.

import std/tables
import ./core

proc opampStageExpand*(inst: RoleInstance): seq[Assertion] =
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

proc gainStageExpand*(inst: RoleInstance): seq[Assertion] =
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

proc channelMatchExpand*(inst: RoleInstance): seq[Assertion] =
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

proc oscillatorExpand*(inst: RoleInstance): seq[Assertion] =
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

proc largeSignalExpand*(inst: RoleInstance): seq[Assertion] =
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
