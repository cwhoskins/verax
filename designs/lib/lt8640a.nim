## Attaching the LT8640A behavioural models to a design.
##
## The design file declares the **real part** -- `kind = "buck"`,
## `partNumber = "LT8640A"`, with the datasheet's pin names -- and this
## module attaches a simulation-only stand-in beside it. That separation is
## the whole reason `Component.simReplace` exists: the netlist a BoM, a board
## layout or `explain` reads must be the part that gets soldered, not the
## `A` device that models it.
##
## `SimReplacement.build` rather than its `kind`/`pinNets` fields, because a
## code model needs three things that shape cannot express: a `.MODEL` card
## registered in `Netlist.models` (without which `kinds.hasDeviceModel` is
## false, the part is not passive, and `spice/isolate` drops it at the
## boundary), an ordered port binding, and port text rendered from the
## model's own `ModelSpec` so a miscount is caught here rather than as a
## `MIF-ERROR` out of ngspice.
##
## The `.cm` is built on demand into a cache directory and its path is
## recorded on the component as `xspice.cm`, which `spice/ngspice.run`
## collects off whatever fragment finally reaches the simulator.
##
## **Two models, not one.** `useLt8640a` attaches both `lt8640a_avg` and
## `lt8640a_sw` and lets `spice/transform.selectSimModel` choose. The averaged
## one is the default -- it answers the operating point, the rail voltage and
## the start-up ramp, and it does so in a run measured in milliseconds of wall
## clock. The switching one claims `spSteadyState` and answers the one
## question the averaged one is structurally unable to: what the ripple is.
## Reaching for a single model would have meant picking which of those the
## design is allowed to ask.
##
## **`BuckConfig` and the design equations** used to live in their own
## `lt8640a_config.nim`, split out because a `subckt`-returning sheet proc was
## expected to grow alongside them. It didn't for a while, so the two files
## were merged back into this one -- and have now moved again, to
## `designs/lib/buck.nim`: see that module's own doc comment for why a
## *third* split, this time along the part-agnostic/LT8640A-specific line
## rather than the config/sheet-proc line the first two tried.
## `buckSheet` below is `buck`'s computation wrapped in an actual sheet proc,
## and `switchingRegulatorRole` is its contract-layer counterpart: a caller
## instantiates the sheet and attaches its `switching_regulator` role from
## a `BuckConfig` and the board-level output net, never naming `U1`/`L1`/`sw`
## itself.

import std/[os, tables, times]

import verax/units
import verax/contract/dsl
import verax/netlist/graph
import verax/netlist/formats/spice as spiceFormat
import verax/spice/xspice/instance
import verax/spice/xspice/build
import verax/parts

import verax/spice/transform

import ./lt8640a_avg
import ./lt8640a_sw
# `BuckConfig`, `buckConfig` and the ripple-sizing procs live in `buck.nim`
# now; re-exported so every existing `import ../lib/lt8640a` (there is only
# the one, `designs/datalogger/datalogger.nim`) keeps seeing them without
# change.
import ./buck
export buck

proc feedbackPair*(cfg: BuckConfig): tuple[r1, r2: Ohms] =
  ## `V_OUT = 0.970 * (1 + R1/R2)`, the reference every LT8640A design in
  ## this repo reads off the same model (`designs/lt8640a_buck.nim`'s own
  ## header). `r2` is `cfg.r2` and `r1` is solved from it -- exact for
  ## whatever `cfg.voltage` asks for, and neither is snapped to a preferred
  ## series, the same choice `designs/lib/filters.nim` makes and for the
  ## same reason: see that module's own doc comment.
  let ratio = float(cfg.voltage) / 0.970 - 1.0
  doAssert ratio > 0.0,
    "feedbackPair: " & $float(cfg.voltage) & " V is at or below what this " &
    "part's 0.970 V reference can reach with any positive ratio"
  (r1: Ohms(float(cfg.r2) * ratio), r2: cfg.r2)

proc rtForFsw*(freq: Hertz): Ohms =
  ## RT sets the switching frequency through the part's internal gm
  ## oscillator. The only calibration point this codebase has actually
  ## verified against the datasheet is the front-page schematic's own
  ## **41.2 kOhm -> 1 MHz** (`designs/lt8640a_buck.nim`) -- ADI's full
  ## RT-vs-frequency table was not reachable to confirm a second point, so
  ## this is **not** a transcribed datasheet formula. A gm-oscillator's
  ## period against its programming resistor is ordinarily close to
  ## `fSW * RT = constant` over a part's specified range, and that is what
  ## this scales from the one verified point -- exact at 1 MHz, an
  ## assumption everywhere else. State a real RT from ADI's Table 1 where
  ## this matters more than a reasonable board value.
  Ohms(41200.0 * 1.0e6 / float(freq))

proc cmPathFor(model: string): string =
  ## Builds the named model if it is not already built, and returns the `.cm`
  ## path.
  ##
  ## Lazy, and deliberately not done at module init: importing a parts library
  ## would then run `nim c` and a C compiler, so `verax check --offline` on a
  ## design that never simulates would pay several seconds and fail outright
  ## on a machine with no ngspice source tree. A design must stay inspectable
  ## with no simulator in the build.
  let cache = getEnv("VERAX_CACHE", getCacheDir() / "verax") / "codemodels"
  createDir(cache)
  # Lowercase: ngspice case-folds the lines it pre-parses, including
  # `pre_codemodel`, so a `.cm` whose path has an uppercase character in it
  # can never be loaded from a deck.
  result = cache / (model & ".cm")
  let src = currentSourcePath().parentDir / (model & ".nim")
  if fileExists(result) and getLastModificationTime(result) >=
     getLastModificationTime(src):
    return
  try:
    discard buildCodeModel(src, result)
  except CatchableError:
    # Building a `.cm` needs a *configured ngspice source tree* at
    # $NGSPICE_SRC, which a machine can perfectly well lack while still
    # having ngspice itself. Returning the path anyway is deliberate: the
    # component records it, `spice/ngspice.run` finds it missing, and the
    # reader gets one sentence naming the file and how to build it. Raising
    # here instead would abort the whole design -- including the static
    # checks and every claim that needs no simulator at all -- for a part
    # that may not even be on the path of what they asked about.
    discard

proc partNets(old: Component): seq[Net] =
  ## The nets the model's ports bind to, in the model's own declaration order.
  ##
  ## Pin names are the datasheet's; an `A` line is positional in the order the
  ## code model declares its ports. Mapping between them here, once, is the
  ## point -- a design should never have to know a model's port order. Both
  ## models declare the same seven ports in the same order, deliberately, so
  ## that swapping one for the other is a choice about *fidelity* and not
  ## about wiring.
  const want = ["VIN", "FB", "EN", "TR/SS", "SW", "PG", "BST"]
  for pinName in want:
    if not old.pins.hasKey(pinName):
      raise newException(NetlistError,
        old.designator & " has no pin '" & pinName & "'; the LT8640A models " &
        "need VIN, FB, EN, TR/SS, SW, PG and BST")
    let n = old.pins[pinName].net
    if n == nil:
      raise newException(NetlistError,
        old.designator & "." & pinName & " is not connected, and the models " &
        "have no way to represent an open pin")
    result.add n

proc buildLt8640aAvg(nl: Netlist, old: Component): Component =
  ## Replaces the real part with the averaged `A` device, wired to the same
  ## nets.
  let nets = partNets(old)
  let desig = old.designator
  removeComponent(nl, desig)
  addCodeModelInstance(nl, "A" & desig, lt8640a_avgSpec, nets,
                       cmPath = cmPathFor("lt8640a_avg"))

proc buildLt8640aSw(nl: Netlist, old: Component): Component =
  ## The same, with the switching model.
  ##
  ## `fsw` is the one parameter that has to be passed rather than defaulted:
  ## the board sets the switching frequency with RT, and no model can read a
  ## frequency off a resistor. It is left at the model's own default here and
  ## overridden by `useLt8640a`'s `fsw` argument, so a design that changes RT
  ## says so in one place. `ilim`/`dmax` are the same shape for the two
  ## behaviours this part actually exposes a way to change -- see
  ## `useLt8640a`'s own doc comment for why those two and not a `MODE` pin.
  let nets = partNets(old)
  let desig = old.designator
  removeComponent(nl, desig)
  var params: seq[(string, string)]
  for key in ["fsw", "ilim", "dmax"]:
    let v = old.attrs.getOrDefault("lt8640a." & key, "")
    if v.len > 0: params.add (key, v)
  addCodeModelInstance(nl, "A" & desig, lt8640a_swSpec, nets, params,
                       cmPath = cmPathFor("lt8640a_sw"))

proc attachLt8640a(nl: Netlist, designator: string, fsw = 1.0e6,
                    ilim = 0.0, dmax = 0.0) =
  ## The actual attachment, by *designator* against whatever `Netlist` holds
  ## the part -- the board's own, from `useLt8640a`, or a `buckSheet`
  ## template still being built, before `subckt` has even returned it.
  ##
  ## `fsw` is what RT sets on the board. It reaches the switching model as an
  ## instance parameter and is recorded on the component, so it survives the
  ## clone -> flatten -> model -> isolate path that stands between a design
  ## and a deck.
  ##
  ## `ilim`/`dmax` are the closest this model comes to the real part's
  ## `SYNC/MODE` pin: the real LT8640A has one (Burst Mode vs. pulse-skip vs.
  ## an external sync clock) and `lt8640a_sw`'s port list does not model it
  ## at all -- see that module's own doc comment on what is a datasheet
  ## figure and what is a stand-in. What the model *does* expose as tunable
  ## behaviour is its peak current limit (`ilim`, datasheet-adjacent: this
  ## part's is fixed near 7 A, so a design asking for a different one is
  ## stating a simulation choice, not a strap) and its maximum duty cycle
  ## (`dmax`, which is what a dropout condition runs into). `0.0` for either
  ## means "leave the model's own default" -- neither is written to `attrs`
  ## unless a caller states one, so every existing design that never mentions
  ## them is byte-for-byte unaffected.
  let c = findComponent(nl, designator)
  if c == nil:
    raise newException(NetlistError,
      "no such component: " & designator & " (attaching the LT8640A models)")
  c.attrs["lt8640a.fsw"] = $fsw
  if ilim > 0.0: c.attrs["lt8640a.ilim"] = $ilim
  if dmax > 0.0: c.attrs["lt8640a.dmax"] = $dmax
  addSimModel(c, newSimReplacement(buildLt8640aAvg, name = "averaged"))
  addSimModel(c, newSimReplacement(buildLt8640aSw, name = "switching",
                                   suits = [spSteadyState]))
  # Explicit rather than relying on insertion order: which model answers a
  # question nobody labelled is a decision worth writing down.
  c.simDefault = "averaged"

proc useLt8640a*(d: Design, designator: string, fsw = 1.0e6,
                 ilim = 0.0, dmax = 0.0) =
  ## Attaches both behavioural models to the named part, on a design that
  ## declares the buck flat (`designs/lt8640a_buck.nim`, `designs/xbar_power.nim`).
  ## Call it after the `design(...)` block; it only adds to `simModels` and
  ## touches nothing else, so the design netlist still describes the board.
  ##
  ## By *designator* rather than by `Component`, because the DSL's `let`
  ## bindings are scoped to the macro's own block and a design file imports
  ## no `std/tables` -- so `d.netlist.components["U1"]` does not even
  ## compile. A helper meant to be called from a design has to be reachable
  ## with what a design has.
  attachLt8640a(d.netlist, designator, fsw, ilim, dmax)

proc buckSheet*(cfg: BuckConfig): Netlist =
  ## The buck converter as one sheet: `VIN`/`VOUT`/`GND` in, out and return,
  ## plus `PG` (the part's power-good output) exposed as a fourth port for a
  ## caller that wants to sense it -- a design that doesn't is free to leave
  ## it unwired (`{"PG": open}` on the `instance` statement), and the models
  ## already attached, built from a `BuckConfig` a caller gets
  ## from `buckConfig` -- see `designs/lib/buck.nim`'s own doc comment for
  ## why that lives separately now. Takes the config whole, not its fields
  ## separately, so a caller states the design once
  ## (`let cfg = buckConfig(voltage = ..., freq = ...)`) and passes the same
  ## value here and to `switchingRegulatorRole` below -- two call sites
  ## reading one `let` rather than two argument lists that can drift apart.
  ##
  ## **This did not use to work.** `Component.simReplace` (what attaches the
  ## LT8640A's XSPICE behavioural models) bakes its device's node list into a
  ## string attribute (`xspice.ports`, see `spice/probes.nim`'s own doc
  ## comment) at *model-pass* time, and every analysis used to run that pass
  ## **before** `spice/flatten.nim` had resolved a nested instance's internal
  ## nets back to their board-level names -- measured: nesting the LT8640A
  ## one level deep under an `instance` put the literal template-local names
  ## `VIN`, `fb`, `EN`, `trss`, `sw`, `pg`, `bst` into the deck's `A` line
  ## instead of the resolved ones, floating every one of those nodes and
  ## failing the `.op` outright ("Timestep too small" on a *DC* solve, from a
  ## genuinely singular matrix). No other design in this repository had ever
  ## nested an XSPICE-modelled part inside a subcircuit instance, so this was
  ## a real, previously unexercised limit rather than a design mistake, and
  ## is why `designs/datalogger/datalogger.nim` originally declared the
  ## buck's components flat, exactly where `designs/lt8640a_buck.nim`'s
  ## always have.
  ##
  ## **Fixed**: every one of the nine analysis call sites (`analyses/*.nim`)
  ## now clones, flattens, and only *then* calls
  ## `spice/transform.applySimReplacements` -- three explicit steps in place
  ## of the combined `materializeSimNetlist` (clone+replace) followed by
  ## flatten -- so a code model's ports are rendered from post-flatten net
  ## names, which still exist, rather than child-template-local ones flatten
  ## is about to rename out from under them. See `spice/flatten.nim`'s module
  ## doc and `spice/transform.applySimReplacements`'s own doc comment for the
  ## detail. `buckSheet` is the housekeeping that fix left open, now done.
  ##
  ## `EN` is a fifth port rather than tied to `VIN` inside the sheet, so a
  ## caller states its own shutdown control -- `designs/datalogger/datalogger.nim`
  ## ties it to `vbus` through a resistor rather than wiring it straight to
  ## `VIN`, the same board-input net `buckSheet`'s own `VIN` port lands on.
  let r1 = feedbackPair(cfg).r1
  let rt = rtForFsw(cfg.freq)
  # L1/COUT/CB1 are sized from the config's ripple targets rather than
  # stated as component values -- see `buck.inductorForRipple`,
  # `buck.outputCapForRipple` and `buck.inputCapForRipple`'s own doc
  # comments.
  let inductor = inductorForRipple(cfg.vin, cfg.voltage, cfg.freq,
                                   cfg.inductorRipple)
  let outCap = outputCapForRipple(cfg.inductorRipple, cfg.freq,
                                  cfg.outputRipple)
  let inCap = inputCapForRipple(cfg.loadCurrent, cfg.vin, cfg.voltage,
                                cfg.freq, cfg.inputRipple)
  # CB1/COUT's ripple-sized totals become real banks here, not one
  # oversized part -- see `capbank.capBank`'s own doc comment for why the
  # split and the bias correction are separate concerns done together. The
  # bank's *effective* (post-bias) total is what meets the ripple target,
  # which is why `dielectric`/`voltage_rating` are stated on every part
  # below rather than left for `spice/models/derating` to assume.
  let inBank = capBank(inCap, cfg.vin, cfg.inputBank)
  let outBank = capBank(outCap, cfg.voltage, cfg.outputBank)

  result = subckt("LT8640A_BUCK", [VIN, VOUT, GND, PG, EN]):
    net VIN,  kind = ntPower
    net VOUT, kind = ntPower:
      spec:
        voltage = cfg.voltage
    net GND,  kind = ntGround, name = "0"
    net sw,   kind = ntSignal
    net fb,   kind = ntSignal
    net trss, kind = ntSignal
    net PG,   kind = ntSignal
    net EN,   kind = ntSignal
    net bst,  kind = ntSignal
    net vcc,  kind = ntPower

    for i, p in inBank.parts:
      component kind = "capacitor", designator = "CB1_" & $(i + 1),
                value = spiceValue(float(p.value)):
        pin "1", VIN, kind = ptPassive
        pin "2", GND, kind = ptPassive
        spec:
          package = p.package
          dielectric = p.dielectric
          voltage_rating = p.voltageRating
    component CB2, kind = "capacitor", value = "1u":
      pin "1", VIN, kind = ptPassive
      pin "2", GND, kind = ptPassive
      spec:
        package = smallestCeramicPackage(1.0.uF, cfg.vin)

    component U1, kind = "buck", partNumber = "LT8640A":
      pin "VIN",    VIN,  kind = ptPower
      pin "SW",     sw,   kind = ptOutput
      pin "FB",     fb,   kind = ptInput
      pin "EN",     EN,   kind = ptInput
      pin "TR/SS",  trss, kind = ptPassive
      pin "PG",     PG,   kind = ptOutput
      pin "BST",    bst,  kind = ptPassive
      pin "INTVCC", vcc,  kind = ptPower
      pin "GND",    GND,  kind = ptGround
      spec:
        voltage = cfg.voltage
        current_rating = cfg.loadCurrent

    component CBST, kind = "capacitor", value = "100n":
      pin "1", bst, kind = ptPassive
      pin "2", sw,  kind = ptPassive
      spec:
        package = "0402"
    component CVCC, kind = "capacitor", value = "1u":
      pin "1", vcc, kind = ptPassive
      pin "2", GND, kind = ptPassive
      spec:
        package = "0603"
    component CSS, kind = "capacitor", value = "10n":
      pin "1", trss, kind = ptPassive
      pin "2", GND,  kind = ptPassive
      spec:
        package = "0402"

    component L1, kind = "inductor", value = spiceValue(float(inductor)):
      pin "1", sw,   kind = ptPassive
      pin "2", VOUT, kind = ptPassive
      spec:
        isat = cfg.isat
        current_rating = cfg.inductorRating

    for i, p in outBank.parts:
      component kind = "capacitor", designator = "COUT_" & $(i + 1),
                value = spiceValue(float(p.value)):
        pin "1", VOUT, kind = ptPassive
        pin "2", GND,  kind = ptPassive
        spec:
          package = p.package
          dielectric = p.dielectric
          voltage_rating = p.voltageRating

    component COUT2, kind = "capacitor", value = "100n":
      pin "1", VOUT, kind = ptPassive
      pin "2", GND,  kind = ptPassive
      spec:
        package = smallestCeramicPackage(100.nF, cfg.voltage)

    component R1, kind = "resistor", value = spiceValue(float(r1)):
      pin "1", VOUT, kind = ptPassive
      pin "2", fb,   kind = ptPassive
      spec:
        tolerance = 1.pct
    component R2, kind = "resistor", value = spiceValue(float(cfg.r2)):
      pin "1", fb,  kind = ptPassive
      pin "2", GND, kind = ptPassive
      spec:
        tolerance = 1.pct
    component CFF, kind = "capacitor", value = "10p":
      pin "1", VOUT, kind = ptPassive
      pin "2", fb,   kind = ptPassive
      spec:
        package = "0402"

    component RT, kind = "resistor", value = spiceValue(float(rt)):
      pin "1", vcc, kind = ptPassive
      pin "2", GND, kind = ptPassive

  attachLt8640a(result, "U1", fsw = float(cfg.freq), ilim = float(cfg.ilim),
                dmax = cfg.dmax)

proc switchingRegulatorRole*(d: Design, designator, instanceName: string,
                              cfg: BuckConfig, output: Net, band = 3.pct,
                              tRun = 8.0.ms, maxRiseTime = 10.0.ms,
                              maxOvershoot = 5.0, tSettle = 0.0.us,
                              tWindow = 0.0.us): RoleInstance {.discardable.} =
  ## The `switching_regulator` role for a `buckSheet` instance, wired to that
  ## sheet's own internal parts -- `U1`/`L1`/`sw` -- so a caller does not have
  ## to know a `buckSheet` names its part, its output inductor and its switch
  ## node the way it does. Call it after the `design(...)` block, exactly
  ## like `useLt8640a`, and for the same reason: the DSL's `role` statement
  ## only expands inside that block, so attaching a role to an instance from
  ## outside it is an ordinary call to `contract/design.addRole` instead.
  ##
  ## By *designator* rather than by `Component`, for the same reason
  ## `useLt8640a` is: the `instance` statement's own binding does not survive
  ## past the end of the `design(...)` block.
  ##
  ## `output` is the one thing this cannot know on its own -- which
  ## board-level net the sheet's `VOUT` was instantiated onto is a fact about
  ## the *caller*, not about the sheet, the same way `voltage`/`band` on a
  ## `power_rail` role naming that net are. `voltage` itself does not need
  ## restating: it is `cfg.voltage`, the same value the sheet was built with.
  let inst = findComponent(d.netlist, designator)
  if inst == nil:
    raise newException(NetlistError,
      "no such instance: " & designator & " (attaching the switching_regulator role)")
  addRole(d, "switching_regulator", instanceName,
    [("regulator", innerComponent(inst, "U1")),
     ("output", subjectOf(output)),
     ("switch", innerNet(inst, "sw")),
     ("inductor", innerComponent(inst, "L1")),
     ("sense", innerComponent(inst, "L1"))],
    [("voltage", annText(cfg.voltage)), ("band", annText(band)),
     ("tRun", annText(tRun)), ("maxRiseTime", annText(maxRiseTime)),
     ("maxOvershoot", annText(maxOvershoot)), ("tSettle", annText(tSettle)),
     ("tWindow", annText(tWindow))])
