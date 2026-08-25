# Authoring a nimcir design

A design is an ordinary Nim file. You state what the circuit *is* and what it
must *do*; `nimcir check` decides what to measure, measures it, and reports.

    nimcir new rail designs/vdd.nim     # start from a template
    nimcir check designs/vdd.nim        # check it

## The shape of a design file

```nim
import nimcir/contract/dsl
import nimcir/verify

let d = design("board_name"):
  net gnd, kind = ntGround, name = "0"
  net vdd, kind = ntPower

  component C1, kind = "capacitor", value = "10u":
    pin "1", vdd, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0805"
      esr = 20.mohm

  role "power_rail", vdd_rail, rail = vdd, voltage = 3.3.V, band = 5.pct

  require z_max_in_band(vdd) <= 100.mohm,
          f_from = 100.kHz, f_to = 100.MHz,
          id = "REQ-PDN-001",
          because = "keeps droop under 10 mV at the MCU's 100 mA di/dt"

quit(verifyMain(d))
```

`gnd` is named `"0"` because that is SPICE's ground node. Bare identifiers
(`vdd`, `C1`) become real Nim `let`s, so a typo is a compile error rather than
a silently-created second net.

## The statements

**`net <name>, kind = ...`** — `ntPower`, `ntGround`, `ntSignal`, `ntUnknown`.
Add `name = "0"` to give the net a different SPICE name from its identifier.

**`component <ref>, kind = "...", value = "...":`** — with nested `pin "name",
<net>, kind = ...` (`ptPassive`, `ptPower`, `ptGround`, `ptInput`, `ptOutput`,
`ptInOut`). The `kind` string drives the SPICE device letter: `resistor`,
`capacitor`, `inductor`, `diode`, `bjt`, `mosfet`, `voltage_source`,
`current_source` are understood; anything else is carried through untouched.

**`spec:`** — typed annotations, checked **at compile time**. A misspelled key
or one used on the wrong kind of entity fails the build rather than being
silently ignored. Run `nimcir annotations` for the live list. Values take unit
literals, and the unit is checked: `esr = 20.nF` will not compile.

**Passive ratings.** `dielectric`, `voltage_rating`, `current_rating`, `isat`
and `power_rating` join the `spec:` vocabulary. `dielectric` is the one that
changes an answer rather than describing a part: a Class 2 ceramic (X7R, X5R,
Y5V) loses capacitance under DC bias, and an unstated one is assumed to be X7R
and derated accordingly. State `dielectric = "C0G"` on a capacitor that sets a
frequency or a time constant — Class 1 does not derate at all, and that is what
keeps a filter corner where you put it. `voltage_rating` feeds both the derating
and `nimcir`'s check that the part is inside it; add `maxDerating` to a
`power_rail` role to claim that.

**Connectors.** Write `kind = "connector"` and give it the pins it has. A
connector has no electrical model of its own — each pin touches exactly one net,
so there is nothing to pass through *to*, and its behaviour is entirely whatever
is plugged in. Say what that is after the `design(...)` block:

```nim
driveConnector(findComponent(d.netlist, "J1"),
               {"VBUS": driveSource(5.0.V, rout = 100.mohm, lout = 2.uH)})
```

An outgoing connector works the same way: `driveLoad(33.ohm)` for a resistive
load, or `driveSink(100.mA)` for something that regulates its own supply. Prefer
the sink for anything with its own converter — a resistor damps the decoupling
network and a constant-current load does not, so a resistive stand-in reports a
lower anti-resonant peak than the board will have.

Without it the pin is stood in with an impedance to ground, which for a power
inlet means the board has no supply at all. `spice/boundary.asSubcircuit` turns
the same connectors into the ports of a reusable `.SUBCKT`.

**Connecting boards together.** `asSubcircuit` turns a board's connectors into
the ports of a reusable `.SUBCKT`, so the same design answers both "what does
this do on the bench" and "what does it do in the product":

```nim
instance XA, asSubcircuit(supplyBoard(), "SUPPLY"), {"vin": usb, "vout": rail}
instance XB, asSubcircuit(sensorBoard(), "SENSOR"), {"vin": rail}
```

Wire ports by name, as above — two boards in one system routinely both call a
port `vin`, and a positional bracket would let you swap them silently. Declare
the system's ground `global = true` so both boards share one reference.

**Ferrite beads.** Write `kind = "ferrite_bead"` and give it the three numbers a
datasheet quotes: `value` (or `z_peak`) as the peak impedance in ohms, `f_peak`
where it peaks, and `dcr` for the DC resistance. The model built from them peaks
exactly where you said. Do not model a bead as an inductor — an inductor's
impedance climbs forever, a bead's peaks and falls, and an inductor has no DC
resistance to damp the capacitor bank behind it.

Derating uses the DC each capacitor actually sits at, taken from an operating
point solved once for the whole design — so a capacitor on a divider midpoint or
a mid-rail bias node is derated too, not just one across an annotated rail. It
falls back to the stated rail voltage when there is no operating point. One
caveat: that DC is the one at t = 0, so a node whose bias moves during a
transient — a charge pump's flying capacitor, a rail still soft-starting — is
derated from a number that does not describe it.

`current_rating` and `isat` are accepted and **checked by nothing yet** — a
branch current is not in an operating point, and an inductor's peak needs a
transient run.

**`role "<name>", <instance>, part = <net-or-component>, param = <value>`** —
a role is a parameterized bundle of assertions, and some roles also *write*
annotations onto the netlist. Run `nimcir roles` and `nimcir role <name>`.

`without = "<claim>"` declines one of a role's claims, comma-separated for
several. Use it when a claim cannot be measured on your topology — a
Sallen-Key's phase margin, say — rather than carrying it unchecked in every
run. It is not a way to hide a claim: the expansion still prints what was
declined, and naming a claim the role does not make is an error listing the
ones it does.

**`environment:`** — the board-level operating conditions, stated once for the
whole design:

```nim
environment:
  t_ambient_min = 0.degC
  t_ambient_max = 70.degC
```

It is `spec:` at netlist scope and is checked the same way at compile time.
Temperature is what it carries today, and it is a **range** rather than a
figure because every temperature-dependent answer has to hold across both
ends: a Class 2 ceramic loses capacitance at the hot end and an
electrolytic's ESR climbs at the cold one.

A part that runs hotter than the air around it says so in its own `spec:`
block, as a rise rather than as a temperature:

```nim
component U1, kind = "regulator":
  ...
  spec:
    delta_t = 16.degC     # (5 - 3.3) V x 150 mA x 62 degC/W
```

`delta_t` defaults to 0 — an ordinary part sits at ambient — and is worth
stating for the few that do not: a linear regulator, a sense resistor,
anything downwind of them. It is added to **both** ends of the ambient range,
because a dissipating part is above the air whatever the air is doing. State a
rise with no `environment:` block and the report says so: a rise on its own is
not a temperature.

Be clear about what this buys today, which is plumbing rather than physics.
**Nothing here is temperature-dependent yet** — no capacitance-versus-
temperature curve, no ESR-versus-temperature curve, and the figures are not
passed to the simulator as `.options temp` either, which would change how
every semiconductor in the design behaves. What the block does is put the two
numbers such a model needs where it can read them, so that when one arrives it
describes *your* board instead of a bench at 25 degC. The report reads the
range back, and names the hottest part in it.

**`model "<name>", "<card>"`** — a `.MODEL` card, passed through verbatim.
See *Device models* below for why it changes more than the deck.

**`for` / `if` / `case` / `when`** — the ordinary Nim the block accepts, and it
accepts all four the same way: as control flow *over these statements*. A branch
body may hold `net`/`component`/`instance`/`model` and nothing else, so `echo`
inside one is still an error. `designator =`, `name =`, `value =` and `spec:`
values all take expressions, so each iteration or branch can differ:

```nim
for (ref, val, pkg) in decoupling:
  component C, designator = ref, kind = "capacitor", value = val:
    pin "1", vdd, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = pkg

if populateBulk:
  component C1, kind = "capacitor", value = "220u": ...
else:
  discard
```

`for` is for a repeated block — a decoupling bank, a channel per lane, a ladder
— rather than N nearly-identical lines, which is where a value gets corrected in
one copy and not the others. `if`/`case`/`when` are for build variants, which
otherwise become two files that drift apart or one file with the unused half
commented out. A bare `discard` is an empty branch; `discard <expression>` is
not accepted, being arbitrary code wearing a keyword.

Nothing about the strictness changes inside one: `spec:` keys are still checked
at compile time and an identifier typo is still a compile error, because neither
depends on whether the branch runs.

Two things do not fit inside one. The `let` that a `net` or `component`
statement binds is scoped to the **branch or iteration**, so nothing generated
there can be referred to by identifier afterwards — address it by name instead.
And `role`/`require` are rejected: claims are attached once the netlist is
complete, so build the parts conditionally and state the claims after.

**`require <quantity>(<subjects>) <op> <value>`** — `==`, `>=`, `<=`, with
optional `id = "..."`, `because = "..."`, and condition keys such as
`f_from` / `f_to` / `at_t`. Run `nimcir quantities` for what can be measured.

## Writing a role of your own

`nimcir quantities` marks each quantity with how it can be claimed:

| marker | meaning |
|---|---|
| `` `require` `` | a bare `require` reaches it — its subjects are all the evaluator needs |
| `role: X` | a built-in role expands it |
| `-- needs a role binding ...` | reachable, but by no built-in role |

That last group needs topology an assertion does not carry. `overshoot_pct(vdd)`
names the rail but not the regulator driving it, and nothing in a netlist
recovers that — so the evaluator reads it back off the role that expanded the
claim, and a bare `require` reports `not evaluable` however correctly it is
spelled.

Writing a role is the way in, and the built-ins use no mechanism yours cannot.
A role is plain data with two proc fields, so it registers from your design
file:

```nim
proc bandExpand(inst: RoleInstance): seq[Assertion] =
  let outNet = inst.subject("output")
  if hasParam(inst, "minGain"):
    result.add Assertion(
      id: inst.name & ".min_gain",
      subjects: @[outNet],
      quantity: "gain_max_db",
      expect: atLeast(paramFloat(inst, "minGain", 0.0)),
      unit: "dB",
      severity: sevError,
      rationale: "why this limit and not another",
      origin: inst.name)          # <- what the evaluator reads bindings from

registerRole(RoleDef(
  name: "my_stage",
  doc: "One amplifier stage, judged my way.",
  parts: @[
    RolePart(name: "opamp", kind: skComponent, doc: "the amplifier"),
    RolePart(name: "input", kind: skNet, doc: "where it is driven"),
    RolePart(name: "output", kind: skNet, doc: "its output")],
  params: @[
    AnnDef(key: "minGain", kind: akFloat, unit: "dB",
           doc: "lowest acceptable gain")],
  expand: bandExpand))
```

Three things carry the weight:

- **`origin: inst.name`** on every assertion. That is the only channel an
  evaluator has for the bindings, and without it the claim comes back
  `not evaluable`.
- **The `parts` names must match what the evaluator looks for** — the column
  in `nimcir quantities` tells you which (`opamp/input`, `regulator/output`,
  `controller`).
- **Claim only what was stated.** `if hasParam(...)` is the convention, so
  omitting a parameter claims nothing rather than inventing a default the
  designer never asked for.

Prefer a built-in where one fits, and `without` (above) where a built-in fits
except for one claim. Write a role when neither does.

## Units

Write `3.3.V`, `20.mohm`, `600.pH`, `400.kHz`, `10.uF`, `5.pct`. This is not
decoration: `"20m"` and `"0.02"` differ by a thousand and look equally
plausible, and a unit literal cannot be misread. Available suffixes —
`V mV uV kV`, `ohm uohm mohm kohm Mohm Gohm`, `F mF uF nF pF`,
`H mH uH nH pH`, `Hz kHz MHz GHz`, `s ms us ns ps`, `A mA uA nA`, `W mW kW`,
`deg`, `dB`, `degC`, `pct`, `ppm`.

`degC` carries both an absolute temperature (`t_ambient_max = 70.degC`) and a
temperature difference (`delta_t = 16.degC`, a rise above ambient). Which one
a figure is comes from the key it is stated under, and it is the one place
where the same suffix means two things that must not be added together
carelessly — `netlist/environment` is the only code that adds them.

## Reading the report

Sections appear in order of how much they undermine everything below them:

- **STRUCTURE** — annotation typos, output conflicts, missing DC paths. A
  misspelled `esr` makes every impedance number under it meaningless.
- **CHECKS** — the body of the report: one block per *test*, where a test is
  one analysis run. Fewer tests than claims means claims are being batched
  into shared runs, which is the intent.
- **FAILED** — checked, and the claim does not hold. A digest of the same
  claims the check blocks already showed, with the diagnosis attached.
- **NOT CHECKED** — *read this as carefully as the failures.* An assertion
  nobody evaluated is not one that passed. `[????]` means nothing can
  produce that quantity (usually a misspelling — the report suggests near
  matches); `[----]` means an evaluator exists but its capability was
  withheld or the simulation did not return a number.

### A check block

```
  spice.pdn  [.ac]  --  1 claim(s): 1 missed
    ran: `.ac` sweep of net 'vdd' with 1 A injected, so the node voltage *is*
         the impedance. Everything on the rail is isolated and the supply cut
         away -- an ideal source is a dead short at AC and would read 0 ohm
         everywhere. Judged over 100 kHz .. 100 MHz
    assuming 39 value(s) nobody stated:
      - C4, C5, C7: esr 30.0 mohm from package default (0402)
      - VU1_OUT, V_vbus, V_vdda: rout 10.0 mohm typical for a voltage_source
      ...
    [FAIL]  core.impedance   z_max_in_band(net 'vdd')   over 100 kHz .. 100 MHz
             expect <= 20.0 mohm   measured 125 mohm
             because the decoupling network must hold the rail below its
               target impedance across the band where the capacitors control it
```

Three parts, and each answers a different question:

- **`ran:`** — what was actually simulated, in words. The fragment handed to
  ngspice is *derived* — isolated, terminated, model-substituted — so it is
  never the netlist you wrote, and this is what says which analysis produced
  the number and what it does and does not cover. (`NIMCIR_KEEP_DECKS=<dir>`
  writes out the decks themselves.)
- **`assuming:`** — numbers the design does not contain and the tool invented
  anyway: a package-typical ESR, an assumed pin capacitance, a leak resistor
  on an open net. They sit **under the run that rests on them**, because which
  number an invented value moved is the whole question — a single pooled list
  at the foot of the report answers it for none of them. Parts assumed the
  same thing are folded onto one line, and every one of them is named.
- **the claims** — one line of identity (id, quantity, subjects, and the band
  or drive level it is judged under), one line of comparison (`expect` against
  `measured`, both numbers together), and `because …` — the rationale you gave
  the limit — whenever the claim did not pass.

A claim appears in exactly one check block. Claims that reached no test at all
are counted at the end of CHECKS and listed in full under NOT CHECKED.

## AC-coupled stages

A single-supply amplifier's gain-setting leg is capacitively coupled, so its
gain **at DC is unity by construction**. That is what makes one supply work,
not a fault — but it means the DC-referenced figures describe something you
did not build:

| quantity | TS808 drive stage | |
|---|---|---|
| `gain_dc_db` | 0.001 dB | true, and useless — the stage has 36 dB |
| `bw_3db` | 710 kHz | 3 dB below *unity*, past a passband ending at 7 kHz |
| `peaking_db` | 31.6 dB | the intentional mid hump, not resonance |

So the same sweep also reports the **band-referenced** set, measured against
the response's maximum: `gain_max_db`, `f_gain_max`, `f_lo_3db`, `f_hi_3db`,
and `gain_at_f` for a gain at one stated frequency. On a DC-coupled stage the
two sets agree, and `f_lo_3db` is `NaN` because such a stage has no lower
edge — that reads as "could not check", never as a pass.

Claim them with `gain_stage`, which claims only what you state:

```nim
  role "gain_stage", voicing, opamp = U1A, input = vamp, output = vout,
       minGain = 33.0, maxGain = 38.0,
       fLoMax = 800.Hz, fHiMin = 5.kHz
```

Add `atF = 1.kHz` and the gain claims move onto `gain_at_f` at that
frequency instead of onto the maximum.

`gain_stage` makes **no stability claim**, deliberately: `peaking_db` cannot
tell an intentional band-pass shape from resonance. State `opamp_stage`
alongside it when you want a phase margin as well — the two compose, and
`designs/ts808_drive.nim` uses both.

## Driven, not just swept

`.ac` linearises the circuit about its operating point, so a clipping diode
is whatever conductance it has at rest and never clips. That is the right
model for gain, bandwidth and stability — and the wrong one for anything
whose nonlinearity is the point.

`large_signal` drives a sine and measures what comes out:

```nim
  role "large_signal", overdrive, opamp = U1A, input = vamp, output = vout,
       driveV = 50.mV, driveF = 1.kHz,
       minThd = 10.0, maxThd = 45.0,
       minSwing = 0.6.V, maxSwing = 1.2.V
```

`driveV` and `driveF` are **conditions, not limits** — they say what the
stage was driven with, and the answer is a function of them, so two
instances at two levels are two measurements. Quantities: `thd_pct`,
`output_swing`, `clip_high`, `clip_low`, `gain_compressed_db`.

`minThd` is not a slip. On an overdrive too *little* distortion is the
defect: a stage measuring clean has lost its clippers.

This needs the nonlinear parts to have models. A diode with no `.MODEL` card
is stood in for by resistors to ground and cannot clip — see below.

**Headroom.** The substituted macromodel saturates at the amplifier's rails
when the design states them — so annotate `voltage` on the supply nets, or a
stage that runs out of swing measures clean. `vsatHeadroom` backs the limit
off each rail; at its default of 0 the model clips exactly at the supply,
which no real part does, so it bounds the swing rather than predicting it.

**What it still does not model.** No slew rate and no output current limit,
so a stage that runs out of *speed* rather than voltage reads as clean.

## Settled, and what is left moving

Every role above binds a driving part — an amplifier, a regulator — and that
excludes a whole class of circuit. A charge pump has no regulator, an
oscillator has no input, and a switching converter's rail does not settle so
much as arrive at a limit cycle. `settled_rail` binds nothing: a net, a time
by which the circuit should have settled, and what it must then be doing.

```nim
  role "settled_rail", ripple, rail = vout,
       tSettle = 300.us, tWindow = 20.us,
       voltage = 4.962.V, band = 2.pct, maxRipple = 10.mV
```

Quantities: `settled_v` (the window mean), `ripple_pp` (its peak-to-peak),
`settled_min`, `settled_max`. Both claims are opt-in — state neither and the
role claims nothing.

`tSettle` and `tWindow` are **conditions, not limits**, like `large_signal`'s
drive. Everything before `tSettle` is simulated and then discarded, and the
time is *stated rather than detected* on purpose: what counts as settled is a
judgement about your circuit, and a detector that guessed wrong would report
a start-up transient as ripple.

Why this is not `power_rail` with another parameter: `dc_voltage` is an
operating point, and an operating point has no ripple in it. A switching
converter's rail reads as its average by construction there and would pass
any ripple claim you could write.

The design is run **as authored, with no isolation** — nothing terminates the
measured node with an ideal source at the value you are asking about.

**Not yet**: no `.ic` and no initial conditions, so a circuit that will not
start from its own operating point (an oscillator at its unstable
equilibrium) is still out of reach.

## More than one model for one part

`simReplace` says how a part should be simulated. A part may carry **several**,
because which model is right depends on what you are asking:

```nim
  component U1, kind = "buck", simDefault = "averaged":
    pin "SW", sw
    ...
    simReplace kind = "voltage_source", name = "averaged":
      pin "+", vout
      pin "-", gnd
    simReplace kind = "vcvs", name = "switching", suits = "steady_state":
      ...
```

`suits` names the *purposes* a model is preferred for, and the analysis picks:
`op`, `ac`, `startup`, `steady_state`, `large_signal`. That vocabulary is
**what is being asked, not which SPICE card gets written** — an averaged and a
switching model of a regulator are both `.tran` models, and naming the card
would not tell them apart.

- A model naming the purpose wins.
- No match falls back to `simDefault` (or the first added). `suits` is a
  preference, never a refusal: a model declared for `steady_state` only must
  not make a `.op` on the same design impossible.
- Two models naming one purpose **raises**, listing both. That is an
  ambiguity, not a preference, and guessing would silently decide which
  analysis your design gets.

`designs/lt8640a_buck.nim` is the worked example: an averaged LT8640A model
answers `dc_voltage` from a `.op`, and a switching one answers `ripple_pp`
from a `.tran`, in the same check.

## Device models

`model "<name>", "<card>"` registers a `.MODEL` card, passed through verbatim:

```nim
  model "1N4148", "D(IS=2.52n RS=0.568 N=1.752 CJO=4p M=0.4 VJ=0.4 " &
                  "BV=110 IBV=100u TT=20n)"

  component D1, kind = "diode", partNumber = "1N4148", value = "1N4148":
    pin "A", vfb, kind = ptPassive
    pin "K", vout, kind = ptPassive
```

The `value` is what binds the part to the card, as in a real deck. A part
with a model is no longer *unmodelled*, so it stops being stood in for by
per-pin impedances and analyses will traverse it.

That substitution is not a small thing to avoid: without a card, a pair of
clipping diodes across a feedback network becomes four resistors to ground,
whose 500 kΩ shunt on the inverting node acts as a second gain leg.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | clean |
| 1 | an assertion failed |
| 2 | a structural problem in the netlist |
| 3 | a claim nothing can check |
| 4 | a requested capability is unavailable here (e.g. no `ngspice`) |

`3` is deliberately non-zero: a requirement nobody checks must not exit like
one that passed.

## Flags

`--offline` (graph walks only, no simulator), `--caps=op,ac,tran` (offer a
specific subset), `--verbose` (show the full plan and the passing assertions),
`--strict` (promote warnings and un-evaluated claims to failures).

## Numbers the tool invents for you

A netlist does not carry everything a simulation needs, so some values are
substituted — and every substitution is reported under the check that rests on
it, with where the number came from. Three matter most:

- **Capacitor ESR and ESL**, from `package` or a global fallback. Without
  them a capacitor has no self-resonance and a PDN sweep means nothing above
  a megahertz. Override with `esr` / `esl`.
- **Supply output impedance** (`rout`, `lout`). An ideal source is a dead
  short at AC, so a rail carrying its own regulator would otherwise read
  `0 ohm` and pass any target. A stand-in of 10 mΩ in series with 1 µH is
  substituted instead. The exact figures matter little — the supply is in
  *parallel* with the decoupling, so once it is well above the capacitors the
  answer barely moves — but being finite matters enormously. Annotate
  `rout` / `lout` when the supply is what you are studying.
- **Parts with no model** — an MCU, a sensor, anything a simulator cannot
  evaluate. Each pin is stood in for by an impedance chosen from its
  `Pin.kind`: high for inputs, in-out pins, supply pins and passives; low for
  outputs. Override per pin, or for a whole part, with `zin`:

```nim
  component U1, kind = "mcu":
    pin "VDD", vdd, kind = ptPower, zin = "33"   # a known 100 mA load at 3.3 V
    pin "SDA", sda, kind = ptInOut
```

  Two caveats worth stating. An output is modelled as a low impedance **to
  ground**, because a netlist does not record which state it is driving — it
  is a small-signal stand-in, not a logic level. And an open-drain or
  open-emitter output is genuinely high-impedance but is indistinguishable
  from a push-pull one by `Pin.kind` alone: tag it `ptInOut`, or give it a
  `zin`.

  This substitution **destroys any path through the part** — every pin is
  tied to the reference independently. That is right for asking what a part
  loads a rail or a bus with, and wrong for anything a signal must pass
  through.

- **Parts that carry a path through them**, such as a regulator, are handled
  separately for exactly that reason. Tying an LDO's input and output to
  ground independently would report its rail at 0 V — a confident wrong
  answer. Instead a regulator is modelled as an ideal source at the output
  voltage **the part states**:

```nim
  component U1, kind = "regulator", partNumber = "AMS1117-3.3":
    pin "IN",  vin, kind = ptPower
    pin "OUT", vdd, kind = ptPower
    pin "GND", gnd, kind = ptGround
    spec:
      voltage = 3.3.V        # what this part outputs
```

  Note the two `voltage`s are deliberately different things. On the **net**
  it is what the rail is *required* to be; on the **part** it is what you
  *chose*. Keeping them separate is what makes the check worth running — fit
  a 5 V regulator on a 3.3 V rail and you get `measured 5.00 V, expected
  3.30 V ±5.00%`. Read the output off the net instead and the check would
  measure its own assumption back and pass every time.

  A regulator that states no `voltage` is **left unmodelled**, and the report
  says so and says what to state. There is no defensible default for what a
  regulator outputs, and the failure mode of guessing is a rail that silently
  reads whatever the tool made up. You will get "could not check" rather than
  a wrong number.

  What the model is not: an ideal source has no load regulation, no dropout,
  no current limit and no start-up ramp. A rail that is wrong here is wrong;
  one that is right here can still misbehave for reasons this cannot see.

- **Parts that pass a signal through** — a `buffer`, `voltage_follower`,
  `line_driver`, `level_shifter` — become an ideal gain stage from input to
  output. Unity is assumed, because that is what those words mean; annotate
  `gain` if the part is not unity. This matters most inside a feedback loop:
  tie a buffer's pins to ground independently and the loop is *open*, and a
  phase-margin figure measured over an open loop is a confident number about
  a different circuit.

For all of these, the part the analysis is *about* is never stood in for
generically — a start-up analysis stands its regulator up as a soft-start
ramp, and an op-amp analysis substitutes a macromodel. Only the parts around
it are.

## What this does not do

Simulation-backed answers are measurements of a *fragment* the tool cut out of
your design, with rails terminated by ideal sources and unmodellable parts cut
away at the boundary. Each check's `ran:` and `assuming:` lines say which. A
start-up analysis
has no control loop, no current limit and no dropout; a PDN sweep knows
nothing about plane capacitance or via inductance. These are stated limits,
not surprises — but a clean report is evidence, not proof.
