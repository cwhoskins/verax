## Built-in roles for analog signal-path stages: `opamp_stage` (DC-coupled)
## and `gain_stage` (AC-coupled), judged by `.ac`; `channel_match` (subjects
## are two role instances); `oscillator` (intent is instability);
## `large_signal` (driven, nonlinear).

import std/tables
import ./core

proc opampStageExpand*(inst: RoleInstance): seq[Assertion] =
  ## Closed-loop behaviour and stability of one amplifier stage. Claims both
  ## peaking (low margin as seen from outside) and phase margin (needs the
  ## loop broken); neither substitutes for the other.
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
  ## An amplifier stage judged by its **band**: for a single-supply
  ## AC-coupled stage, DC gain is unity by construction, so `opamp_stage`'s
  ## DC-referenced claims answer nothing. Claims are against the response
  ## maximum. **No stability claim** (`peaking_db` can't tell a band-pass
  ## shape from resonance) -- add `opamp_stage` alongside for margin.
  ##
  ## Every parameter is optional; omitting one claims nothing.
  let outNet = inst.subject("output")
  let atF = paramFloat(inst, "atF", 0.0)

  # A stated frequency redirects the gain claim to `gain_at_f`; otherwise
  # it's the maximum.
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

  # Band edges, referenced to the maximum. `f_lo_3db` is `NaN` (not checked)
  # for a DC-coupled stage.
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
  ## Two stages judged against each other: the channels *agree*, which
  ## neither meeting its own band implies.
  ##
  ## **Subjects are two `skClass` references**: an expander has no `Design`,
  ## so the evaluator resolves them (`subjectRoleBinding`). Each claim is
  ## gated on its own limit; `fFrom`/`fTo`/`atF` are setup (conditions).
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
    # `atF` redirects the gain-delta claim to one frequency rather than
    # adding a second.
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
  ## What an oscillator is specified by: frequency, amplitude, purity.
  ##
  ## Not `opamp_stage`/`gain_stage` with a parameter: those are `.ac`
  ## stability claims, and an `.ac` source on the input would short a Wien
  ## bridge's feedback. The circuit has to be run.
  ##
  ## The subject is the measured net. `kick` optionally sets a starting
  ## voltage for a circuit that won't start itself (otherwise no `uic`).
  ## `tSettle`, `tWindow`, `kick`, `kickV` are conditions, not limits; open
  ## the window late enough that the amplitude has stabilised.
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

  # Every claim opt-in: frequency, amplitude and distortion budget are all
  # the designer's intent.
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
  ## What the stage does when *driven* -- for deliberate nonlinearity, where
  ## `.ac` linearises the clipping away. `driveV`/`driveF` are conditions,
  ## so two drive levels are two runs.
  let outNet = inst.subject("output")
  let driveV = paramFloat(inst, "driveV", 0.0)
  let driveF = paramFloat(inst, "driveF", 1.0e3)

  # Field and parameter names must differ: `quantity: quantity` is
  # ambiguous to the template expander.
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
    # On an overdrive, too *little* distortion is the defect.
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
