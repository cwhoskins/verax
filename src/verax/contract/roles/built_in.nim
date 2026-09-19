## Registration of the built-in roles.
##
## `roles/core.nim` is the machinery -- the `RoleDef`/`RoleInstance` types and the
## registry -- and the built-in `RoleDef`s themselves are split by category
## across `power`, `analog` and `digital`. This module is where they are
## assembled into `RoleDef`s and handed to `registerRole`, and it calls
## `registerBuiltinRoles()` at init.
##
## Importing this module (rather than `roles/core.nim` directly) is what a program
## does when it wants the built-ins registered -- the `contract` hub and
## `contract/dsl` both do. It re-exports `roles`, so the core API comes with
## it.

import ../../netlist/annotations
import ./core
import ./power
import ./analog
import ./digital
import ./interconnect

export core

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
    expects: "i2c",
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

  registerInterconnectRoles()

registerBuiltinRoles()
