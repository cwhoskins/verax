## An adjustable regulator, with its datasheet equations attached to it.
##
## ## The problem this is for
##
## A variable regulator is sold as a part plus an equation. The LM317 is a
## three-terminal device whose loop holds 1.25 V between OUT and ADJ; what
## voltage it makes is decided by two resistors and by a page of the
## datasheet:
##
##     Vout = Vref * (1 + rAdj/rSet) + iAdj * rAdj
##
## and by four constraints that are not in that formula at all -- an output
## range, a dropout voltage, a minimum load current, and how hot the package
## gets at the current being asked of it.
##
## Written out in a design file, all of that becomes two resistor values and
## a comment. The values are then the only record that the equation was ever
## applied, so nothing checks the arithmetic, nothing checks the constraints,
## and a later edit that changes the input voltage or the load has no way to
## know it invalidated the calculation. That is not a hypothetical failure
## mode: "swap the 240 R for what I had in the drawer" changes the
## programming current, the minimum load and the ADJ-pin error term at once.
##
## So the part is a **value**, carrying its own numbers, and the equations
## are procs beside it. A design states what it wants -- an input, an output,
## a load -- and gets a network back; anything the part cannot do raises,
## naming the constraint, at the point the network is asked for.
##
## ## What the check actually tests
##
## `buildAdjRegLoop` is the other half, and it is what stops this being an
## arithmetic self-check. The design netlist keeps the LM317 as one part, so
## a BoM and a layout see what gets soldered; for simulation it is replaced
## by the *loop* -- an error amplifier holding Vref between OUT and ADJ, and
## a current source for the ADJ-pin current -- so the simulator solves the
## real divider and reports what the rail actually comes to, with no
## knowledge of what this file computed.
##
## The two therefore have to agree, and they agree only if the equation is
## complete. Drop the `iAdj * rAdj` term from `setResistor` and the resistor
## it picks is 720 R instead of 713 R; the simulated 5 V rail comes out at
## 5.036 V, and a claim stated to 0.5% fails. That is the check having teeth:
## nothing in this file is compared against itself.
##
## ## Rounding to a part that exists
##
## `series` is a `PreferredSeries` from `verax/parts/series` and defaults to
## `exactSeries`, which rounds nothing -- a builder rounds only when asked.
## Pass `e96` and what the design gets back is recomputed from the values that
## will be fitted, never reported back as the voltage that was requested; the
## difference is the design's to accept or to fix.
##
## ## What the loop model is and is not
##
## Stated plainly, because a model that flatters the circuit is worse than no
## model.
##
## The regulator is stood up as an error amplifier holding the reference
## between OUT and ADJ, driving a **pass element in series with the input**.
## That series arrangement is the load-bearing part and is worth reading
## twice: an amplifier whose output drives the rail directly is an ideal
## source, and an ideal source has no input. Its current comes from nowhere,
## so the input draw has to be declared as a constant and cannot follow the
## load; and no input ripple can reach the output by any path whatever, which
## does not read as "this model cannot answer" but as **infinite rejection**.
## In series, `v(pass) = v(in) + v(ea)`, so the load current is drawn out of
## the input node and the closed-loop line response is `1 / (1 + aol)` --
## both consequences of the topology rather than numbers stated anywhere.
##
## So, derived: the input draw, the way rejection rolls off above the
## amplifier's own pole, the output impedance the loop presents at DC
## (`zPass / (1 + aol)`) and the shape of a load-step recovery. Stated:
## `lineReg`, the datasheet's line regulation, which is where low-frequency
## rejection *starts* -- a real part's is set by its bandgap's sensitivity to
## the supply and no topology recovers it. Neither half is dressed as the
## other.
##
## Still absent, and the reasons differ:
##
##   * **No dropout.** Nothing clamps the pass element below the input, so
##     this model regulates from an input beneath its own output. A clamp
##     means a behavioural expression naming a node, and a node name written
##     into `attrs["value"]` does not survive `spice/flatten` renaming the
##     net underneath it -- a real obstacle, not an omission.
##     `checkHeadroom` refuses the design at build time instead, which is a
##     check of stated numbers rather than a measurement, and a `.dc` sweep
##     against a rail built this way reports `dropout_v` as *not evaluated*
##     with an issue saying to sweep lower. That is the honest answer: it
##     never leaves regulation.
##   * **No current limit and no thermal foldback.** The pass element will
##     deliver whatever is asked of it.
##   * **Load regulation is optimistic.** `aol` is chosen high enough that
##     the DC answer is the divider's rather than the amplifier's, which is
##     what the claims in `designs/adj_regulator.nim` are about -- and a loop
##     gain that high divides `zPass` down to microohms. The *transient*
##     shape is right, because a load step happens where the loop gain has
##     already rolled off; the DC figure is not.
##
## And do not run a PDN sweep against a rail built this way. The pass
## element is still a controlled source, so its output is stiff at every
## frequency the loop is still holding -- the sweep would report far too
## little and pass any target that could be set, the same trap
## `spice/models.expandSourceImpedance` exists to stop, one layer up where
## it cannot reach.

import std/[strutils, tables]

import verax/contract/dsl
import verax/netlist/formats/spice as spiceFormat
import verax/eng
import verax/parts

type
  AdjRegulator* = object
    ## What a datasheet says, in the form the equations need it.
    partNumber*: string
    vref*: Volts
      ## The reference the loop holds -- for an LM317 between OUT and ADJ,
      ## which is why the model below floats it on the ADJ node rather than
      ## referencing it to ground.
    vrefTol*: Fraction
      ## Spread over line, load and temperature. Not applied by anything
      ## here: it is the budget a claim's `band` has to leave room for, and
      ## stating it beside the equation is what makes that arguable.
    iAdj*: Amps
      ## Current out of the ADJ pin, into the bottom resistor. The term
      ## everyone forgets; worth 0.7% on a 5 V rail programmed at 5 mA.
    voutMin*, voutMax*: Volts
    dropout*: Volts
      ## Minimum input-to-output differential at rated current.
    iMinLoad*: Amps
      ## Below this the loop has too little current to regulate with. The
      ## programming divider supplies part of it, which is the real reason
      ## `rSet` is small.
    thetaJA*: float
      ## degC per watt, junction to ambient, for the package **as mounted**.
      ## A property of the board as much as of the part, which is why it is a
      ## field rather than a constant.
    lineReg*: Fraction
      ## How far the output moves per volt of input, as a fraction of the
      ## output. **A datasheet figure**, and the one number in the simulation
      ## model that is: a three-terminal regulator's low-frequency line
      ## rejection is set by its internal bandgap's own sensitivity to the
      ## supply, which no topology recovers. The model stacks it on the
      ## reference, referenced to the nominal input so it contributes nothing
      ## at the operating point and only a slope around it.
    zPass*: Ohms
      ## The pass element's own ohmic resistance, between it and the rail.
      ## A model number: it is what stops the closed-loop output impedance
      ## being exactly zero, and the loop divides it by its own gain, so a
      ## load step sees `zPass` at the instant of the edge and
      ## `zPass / (1 + aol)` once the loop has caught up. The *shape* of a
      ## load-step response is what it sets, and that is what it is for.
    aol*: float
    gbw*: Hertz
      ## The error amplifier's open-loop gain and bandwidth in the simulation
      ## model. Not datasheet figures -- a linear regulator's loop response
      ## is not published in this form -- so they are the model's numbers,
      ## chosen high enough that the DC answer is set by the divider and not
      ## by the amplifier. They do now set something besides the DC error:
      ## the pass element puts the input in series with the output, so the
      ## rejection this model reports rolls off above `gbw / aol` exactly as
      ## the loop gain does.

const
  lm317* = AdjRegulator(
    partNumber: "LM317",
    vref: Volts(1.25), vrefTol: Fraction(0.04),
    iAdj: Amps(50.0e-6),
    voutMin: Volts(1.25), voutMax: Volts(37.0),
    dropout: Volts(2.0),
    iMinLoad: Amps(10.0e-3),
    thetaJA: 50.0,
    lineReg: Fraction(1.0e-4), zPass: Ohms(1.0),
    aol: 1.0e5, gbw: Hertz(1.0e6))
    ## The classic three-terminal adjustable positive regulator, in the form
    ## every vendor's datasheet states it: 1.25 V reference (1.20 - 1.30 over
    ## the full range, hence 4%), 50 uA typical ADJ current, 1.25 V to 37 V
    ## out, about 2 V of dropout at rated current, and a minimum load taken
    ## at the datasheet's *maximum* of 10 mA rather than its 3.5 mA typical --
    ## a minimum load met only on a typical part is not met.
    ##
    ## `thetaJA` is 50 degC/W, which is a TO-220 standing in free air with no
    ## heatsink. Bolt it to something and this is the number to change; it is
    ## the only figure here that describes the board rather than the part.
    ##
    ## `lineReg` is the datasheet's 0.01%/V typical, and it is what a ripple
    ## rejection measured through this part's model rests on at low
    ## frequency: 1e-4 of the output per volt in is 80 dB, against the 65 dB
    ## the datasheet quotes at 120 Hz with no ADJ bypass. Optimistic, and the
    ## right order -- state a measured figure where it matters.

# --- the design equations ---------------------------------------------------

proc programmingCurrent*(part: AdjRegulator, rSet: Ohms): Amps =
  ## What the reference resistor draws: `Vref / rSet`. It flows through the
  ## bottom resistor as well, which is why it -- and not the load -- is what
  ## makes the divider's ratio hold, and why it counts towards the part's
  ## minimum load.
  Amps(float(part.vref) / float(rSet))

proc setResistor*(part: AdjRegulator, vout: Volts, rSet: Ohms): Ohms =
  ## The bottom (ADJ-to-ground) resistor for a wanted output, inverting
  ##
  ##     Vout = Vref*(1 + rAdj/rSet) + iAdj*rAdj
  ##
  ## into
  ##
  ##     rAdj = (Vout - Vref) / (Vref/rSet + iAdj)
  ##
  ## The `iAdj` term in the denominator is the whole difference between this
  ## and the formula on the back of an envelope. It is small -- 50 uA against
  ## a 5 mA programming current, so 1% of the divider current -- and it lands
  ## directly on the output, where 1% is more than most rails are specified
  ## to.
  Ohms((float(vout) - float(part.vref)) /
       (float(programmingCurrent(part, rSet)) + float(part.iAdj)))

proc outputFor*(part: AdjRegulator, rSet, rAdj: Ohms): Volts =
  ## The forward equation: what a *built* divider gives. This is what makes
  ## rounding honest -- the resistors are chosen, then the output is
  ## recomputed from the resistors that were chosen, never reported back as
  ## the output that was asked for.
  Volts(float(part.vref) * (1.0 + float(rAdj) / float(rSet)) +
        float(part.iAdj) * float(rAdj))

proc dissipation*(part: AdjRegulator, vin, vout: Volts, iLoad: Amps,
                  rSet: Ohms): Watts =
  ## A linear regulator burns the difference, at everything it passes.
  ##
  ## `rSet` is here because the programming current comes through the pass
  ## element exactly as the load does -- the divider is a load like any other,
  ## and on a lightly loaded rail it is most of one. Small on this design and
  ## not always: a rail drawing 10 mA programmed at 5 mA has half again the
  ## dissipation the load alone accounts for.
  Watts((float(vin) - float(vout)) *
        (float(iLoad) + float(programmingCurrent(part, rSet))))

proc temperatureRise*(part: AdjRegulator, pd: Watts): Celsius =
  ## Above ambient, at `thetaJA`. This is what a design states as `delta_t`
  ## on the part, and `netlist/environment` shifts the board's ambient range
  ## by it at both ends.
  Celsius(float(pd) * part.thetaJA)

proc checkHeadroom*(part: AdjRegulator, vin, vout: Volts) =
  ## Dropout, as a static check of stated numbers. Nothing simulated here can
  ## find it: the loop model's output is an ideal source and will hold its
  ## target from an input below it, which is exactly the failure a real board
  ## has and this model does not.
  if float(vin) - float(vout) < float(part.dropout):
    raise newException(ValueError,
      part.partNumber & " needs " & eng(float(part.dropout), "V") &
      " of headroom at rated current; " & eng(float(vin), "V") & " in for " &
      eng(float(vout), "V") & " out leaves " &
      eng(float(vin) - float(vout), "V") & ". Nothing simulated will report " &
      "this -- the loop model has no dropout -- so it is refused here.")

proc checkRange*(part: AdjRegulator, vout: Volts) =
  if float(vout) < float(part.voutMin) or float(vout) > float(part.voutMax):
    raise newException(ValueError,
      part.partNumber & " adjusts over " & eng(float(part.voutMin), "V") &
      " .. " & eng(float(part.voutMax), "V") & "; " &
      eng(float(vout), "V") & " is outside it.")

proc checkMinimumLoad*(part: AdjRegulator, rSet: Ohms, iLoad: Amps) =
  ## The divider is part of the load, and on a lightly loaded rail it is
  ## most of it. Refused rather than warned about, because the symptom is a
  ## rail that drifts *up* off-target with nothing wrong on the schematic.
  let iProg = float(programmingCurrent(part, rSet))
  if iProg + float(iLoad) < float(part.iMinLoad):
    raise newException(ValueError,
      part.partNumber & " needs at least " &
      eng(float(part.iMinLoad), "A") & " of load to regulate; " &
      eng(float(rSet), "ohm") & " programs " & eng(iProg, "A") &
      " and the design states " & eng(float(iLoad), "A") & " of load, " &
      eng(iProg + float(iLoad), "A") & " together. Lower rSet, or state the " &
      "bleeder the rail actually has.")

# --- the simulation model ---------------------------------------------------

const
  vrefAttr = "adjreg.vref"
  iAdjAttr = "adjreg.iadj"
  iqAttr = "adjreg.iq"
  aolAttr = "adjreg.aol"
  gbwAttr = "adjreg.gbw"
  lineRegAttr = "adjreg.linereg"
  zPassAttr = "adjreg.zpass"
  vinNomAttr = "adjreg.vinnom"
    ## Dotted, so the annotation registry never validates them -- these are
    ## this module's own, exactly as `spice/boundary` namespaces `boundary.*`.
    ## They are attributes rather than a captured closure because
    ## `SimReplacement.build` is `{.nimcall.}` and has nothing to capture
    ## into; the better property comes free, which is that the numbers ride
    ## through `clone`, `flatten` and every transform, and can be read back.

proc attrFloat(c: Component, key: string, fallback: float): float =
  if c.attrs.hasKey(key):
    try: return parseFloat(c.attrs[key])
    except ValueError: discard
  fallback

proc buildAdjRegLoop*(nl: Netlist, old: Component): Component {.nimcall.} =
  ## Replaces the regulator with the loop it closes.
  ##
  ## Three parts, and each one is a sentence of the datasheet:
  ##
  ## * a source of `vref` **sitting on top of the ADJ node**, so the
  ##   reference floats with the divider tap exactly as the real part's does;
  ## * an error amplifier comparing the output against it and driving the
  ##   output, which is what "the loop holds 1.25 V between OUT and ADJ"
  ##   means once it is something a simulator can solve;
  ## * a current source injecting `iAdj` into the ADJ node.
  ##
  ## What comes out is not asserted anywhere in this file. The simulator
  ## solves the divider it finds in the netlist, and the design's claim is
  ## what compares that to the rail it wanted.
  let outPin = old.pins.getOrDefault("OUT")
  let adjPin = old.pins.getOrDefault("ADJ")
  let inPin = old.pins.getOrDefault("IN")
  if outPin == nil or adjPin == nil or outPin.net == nil or adjPin.net == nil:
    raise newException(NetlistError,
      old.designator & " needs OUT and ADJ pins to be stood up as an " &
      "adjustable regulator loop")
  let outNet = outPin.net
  let adjNet = adjPin.net
  let inNet = if inPin != nil: inPin.net else: nil
  let gnd = findNet(nl, "0")
  if gnd == nil:
    raise newException(NetlistError,
      "no ground node '0' in scope for " & old.designator & "'s loop model")

  let vref = attrFloat(old, vrefAttr, 1.25)
  let iAdj = attrFloat(old, iAdjAttr, 0.0)
  let iQ = attrFloat(old, iqAttr, 0.0)
  let aol = attrFloat(old, aolAttr, 1.0e5)
  let gbw = attrFloat(old, gbwAttr, 1.0e6)
  let lineReg = attrFloat(old, lineRegAttr, 0.0)
  let zPass = attrFloat(old, zPassAttr, 1.0)
  let vinNom = attrFloat(old, vinNomAttr, 0.0)
  let des = old.designator

  removeComponent(nl, des)

  # The nominal input, as a node. It exists only so the line-sensitivity
  # amplifier below has something to measure the input *against*: line
  # regulation is a slope about an operating point, and referencing it to
  # ground instead would put a constant offset on the reference and move the
  # DC answer this whole file exists to check.
  let vnomNet = addNet(nl, newNet(des & "_VNOM", ntSignal))
  let vnom = addComponent(nl, newComponent("V" & des & "_VNOM",
                                           kind = "voltage_source"))
  discard connect(vnom, "+", vnomNet, ptPassive)
  discard connect(vnom, "-", gnd, ptPassive)
  vnom.attrs["value"] = "DC " & spiceValue(vinNom)
  vnom.attrs["rout"] = "0"
  vnom.attrs["lout"] = "0"

  # The reference, floating on ADJ. `rout`/`lout` are pinned to zero: this is
  # a stimulus rather than a supply, and `expandSourceImpedance`'s default
  # 10 mohm + 1 uH would otherwise sit between the reference and the node it
  # references. Nothing draws current through it -- the amplifier's inputs
  # are a VCVS's -- so it costs nothing at DC either way, and saying so is
  # cheaper than rediscovering it.
  let refaNet = addNet(nl, newNet(des & "_REFA", ntSignal))
  let vsrc = addComponent(nl, newComponent("V" & des & "_REF",
                                           kind = "voltage_source"))
  discard connect(vsrc, "+", refaNet, ptPassive)
  discard connect(vsrc, "-", adjNet, ptPassive)
  vsrc.attrs["value"] = "DC " & spiceValue(vref)
  vsrc.attrs["rout"] = "0"
  vsrc.attrs["lout"] = "0"

  # How far the reference itself moves with the input, stacked on top of it.
  #
  # **This is the one number here that is a datasheet figure rather than a
  # consequence of the topology, and it is worth being plain about which is
  # which.** The pass element below gives the loop a real path from IN to
  # OUT, so a line or ripple figure measured through this model rolls off
  # with the amplifier exactly as a regulator's does -- that shape is
  # derived. Where it *starts* is not: a real three-terminal regulator's
  # low-frequency line rejection is set by its internal bandgap's own
  # sensitivity to the supply, which no amount of topology recovers, and
  # which every datasheet states directly as line regulation. So it is
  # stated, once, on the part.
  #
  # `lineReg` is a fractional output shift per volt of input, so the gain
  # that produces it is `lineReg * vref`: the loop holds `vref` across the
  # programming resistor, and the divider multiplies whatever sits on the
  # reference by `vout / vref` on its way to the rail.
  let refNet = addNet(nl, newNet(des & "_REF", ntSignal))
  let eline = addComponent(nl, newComponent("E" & des & "_LINE",
                                            kind = "vcvs"))
  discard connect(eline, "OUT+", refNet, ptOutput)
  discard connect(eline, "OUT-", refaNet, ptPassive)
  discard connect(eline, "IN+", (if inNet != nil: inNet else: gnd), ptInput)
  discard connect(eline, "IN-", vnomNet, ptInput)
  eline.attrs["value"] = spiceValue(lineReg * vref)

  # The error amplifier. It is emitted as an ordinary `opamp`, so
  # `spice/models.opampModel` gives it the same single-pole macromodel every
  # other unmodelled amplifier gets -- one model of an amplifier in the
  # build, not two. Its output is now an internal node rather than the rail:
  # what drives the rail is the pass element below.
  let eaNet = addNet(nl, newNet(des & "_EA", ntSignal))
  let ea = addComponent(nl, newComponent("U" & des & "_EA", kind = "opamp"))
  discard connect(ea, "IN+", refNet, ptInput)
  discard connect(ea, "IN-", outNet, ptInput)
  discard connect(ea, "OUT", eaNet, ptOutput)
  ea.attrs["gain"] = $aol
  ea.attrs["gbw"] = $gbw

  # --- the pass element -----------------------------------------------
  #
  # A **floating** controlled source, in series with the input rather than
  # referenced to ground, and that is the whole point of it. An amplifier
  # whose output drives the rail directly is an ideal source: its current
  # comes from nowhere, so the input draw has to be declared as a constant
  # and cannot follow the load, and no input ripple can reach the output by
  # any path at all -- which reads as infinite rejection rather than as a
  # model that cannot answer.
  #
  # In series, `v(PASSO) = v(IN) + v(EA)`, so the load current is drawn
  # through it out of the input node and two things fall out rather than
  # being asserted. The draw follows the load. And the closed-loop line
  # response is `1 / (1 + aol)`, since `vout = (vin + aol * vref') /
  # (1 + aol)` -- which rolls off above the amplifier's own pole exactly as
  # a regulator's rejection does, because it *is* the same loop gain.
  #
  # What it still does not do is run out of headroom: there is no clamp
  # holding `v(PASSO)` below `v(IN)`, so this model regulates from an input
  # below its output and reports no dropout. A clamp means a behavioural
  # expression naming a node, and a node name written into `attrs["value"]`
  # does not survive `spice/flatten` renaming the net underneath it -- so
  # that is a real obstacle rather than an omission. `checkHeadroom` refuses
  # the design at build time instead, which is where it belongs.
  if inNet == nil or inNet == gnd:
    raise newException(NetlistError,
      old.designator & " needs an IN pin on a rail to be stood up as a " &
      "regulator loop: the pass element draws its output current through it")
  let passNet = addNet(nl, newNet(des & "_PASSO", ntSignal))
  let epass = addComponent(nl, newComponent("E" & des & "_PASS",
                                            kind = "vcvs"))
  discard connect(epass, "OUT+", passNet, ptOutput)
  discard connect(epass, "OUT-", inNet, ptPassive)
  discard connect(epass, "IN+", eaNet, ptInput)
  discard connect(epass, "IN-", gnd, ptInput)
  epass.attrs["value"] = spiceValue(1.0)

  # The pass device's own ohmic resistance, between it and the rail. Small,
  # and it is what stops the output impedance being exactly zero: the loop
  # divides it by its own gain, so what a load sweep or a load step sees is
  # `zPass / (1 + aol)` at DC and `zPass` again above the loop's bandwidth,
  # which is the shape that matters for a transient.
  let rpass = addComponent(nl, newComponent("R" & des & "_PASS",
                                            kind = "resistor"))
  discard connect(rpass, "1", passNet, ptPassive)
  discard connect(rpass, "2", outNet, ptPassive)
  rpass.attrs["value"] = spiceValue(max(zPass, 1.0e-3))

  # The ADJ pin's own current, flowing out of the device and down the bottom
  # resistor. `+` on ground and `-` on ADJ is what injects it: SPICE runs
  # positive current from `+` through the source to `-`, so it leaves at the
  # ADJ node and into the divider.
  if iAdj > 0.0:
    let ia = addComponent(nl, newComponent("I" & des & "_ADJ",
                                           kind = "current_source"))
    discard connect(ia, "+", gnd, ptPassive)
    discard connect(ia, "-", adjNet, ptPassive)
    ia.attrs["value"] = "DC " & spiceValue(iAdj)

  # The part's **quiescent** draw, and only that. What the load takes now
  # comes through the pass element above, so this is the ground-pin current
  # the datasheet quotes and nothing else -- where before it was the whole
  # declared draw, load included, because there was no path for the load
  # current to take.
  if iQ > 0.0:
    let ii = addComponent(nl, newComponent("I" & des & "_IQ",
                                           kind = "current_source"))
    discard connect(ii, "+", inNet, ptPassive)
    discard connect(ii, "-", gnd, ptPassive)
    ii.attrs["value"] = "DC " & spiceValue(iQ)

  nil

# --- the builder ------------------------------------------------------------

proc adjustableRegulator*(part: AdjRegulator, vin, vout: Volts, iLoad: Amps,
                          rSet = 240.ohm, iQuiescent = 5.mA,
                          series: PreferredSeries = exactSeries,
                          parts = defaultPolicy()): Netlist =
  ## An adjustable regulator and its programming network. Ports: `VIN`,
  ## `VOUT`, `GND`.
  ##
  ## `rSet` is the reference resistor, from OUT to ADJ. It is an argument
  ## rather than a derived value for the same reason `sallenKeyLP`'s `r` is:
  ## nothing in the output equation fixes it, only the *ratio* matters to the
  ## voltage. What picks it is everything the equation does not describe --
  ## too large and the programming current stops meeting the part's minimum
  ## load and the ADJ current's error term grows; too small and the divider
  ## burns current the design may not have. 240 R is the datasheet's own
  ## choice and programs 5.2 mA.
  ##
  ## Everything the part cannot do raises here, at the point the network is
  ## asked for, rather than being discovered as a rail that reads wrong.
  checkRange(part, vout)
  checkHeadroom(part, vin, vout)
  checkMinimumLoad(part, rSet, iLoad)

  # `rSet` is used as given. The series is applied to what this builder
  # *computes*, not to what the design stated -- rounding a number the
  # designer chose would be answering a question nobody asked, and 240 R is
  # not an E96 value, so a naive pass would silently move the reference
  # resistor to 243 R and take the ratio with it.
  let rAdjExact = setResistor(part, vout, rSet)
  let rAdj = series(rAdjExact)
  # Recomputed from the parts that will be fitted, never from what was asked
  # for. With `exactSeries` the two agree; with `e96` they do not, and the
  # difference is the design's to accept or to fix.
  let achieved = outputFor(part, rSet, rAdj)

  let pd = dissipation(part, vin, vout, iLoad, rSet)
  let rise = temperatureRise(part, pd)

  # Both resistors set a ratio, so both are precision parts -- and unlike a
  # filter's, this ratio is a DC one, so the tolerance is the whole story and
  # there is no dielectric to argue about.
  let rChoice = parts.resistor(ResRequest(value: rSet, use: ruPrecision))
  # The datasheet's own output network: a bulk capacitor for the loop's
  # stability and transient response, and a small ceramic at the input
  # because the regulator is generally not next to whatever filters the
  # supply. `working` is stated for both -- unlike a filter's bypass
  # capacitors, this builder does know what is across them.
  let coutChoice = parts.capacitor(
    CapRequest(value: 10.uF, use: cuBulk, working: vout))
  let cinChoice = parts.capacitor(
    CapRequest(value: 100.nF, use: cuDecoupling, working: vin))

  result = subckt("ADJREG", [VIN, VOUT, GND]):
    net GND,  kind = ntGround, name = "0"
    net VIN,  kind = ntPower
    net VOUT, kind = ntPower
    net adj,  kind = ntSignal        # the divider tap; the ADJ pin sits here

    component U1, kind = "regulator", partNumber = part.partNumber:
      pin "IN",  VIN,  kind = ptPower
      pin "OUT", VOUT, kind = ptPower
      pin "ADJ", adj,  kind = ptInput
      spec:
        # What this *part* puts out, as the equations predict it from the
        # resistors that will be fitted -- deliberately a different
        # statement from what the rail is required to be. The simulation
        # never reads this; it solves the divider. The two sitting side by
        # side in the report is the point.
        voltage = achieved
        delta_t = rise

    component RSET, kind = "resistor", value = spiceValue(float(rSet)):
      pin "1", VOUT, kind = ptPassive
      pin "2", adj,  kind = ptPassive
    component RADJ, kind = "resistor", value = spiceValue(float(rAdj)):
      pin "1", adj, kind = ptPassive
      pin "2", GND, kind = ptPassive

    component COUT, kind = "capacitor", value = "10u":
      pin "1", VOUT, kind = ptPassive
      pin "2", GND,  kind = ptPassive
    component CIN, kind = "capacitor", value = "100n":
      pin "1", VIN, kind = ptPassive
      pin "2", GND, kind = ptPassive

  let u1 = findComponent(result, "U1")
  u1.attrs[vrefAttr] = $float(part.vref)
  u1.attrs[iAdjAttr] = $float(part.iAdj)
  u1.attrs[iqAttr] = $float(iQuiescent)
  u1.attrs[aolAttr] = $part.aol
  u1.attrs[gbwAttr] = $float(part.gbw)
  u1.attrs[lineRegAttr] = $float(part.lineReg)
  u1.attrs[zPassAttr] = $float(part.zPass)
  u1.attrs[vinNomAttr] = $float(vin)
  u1.simReplace = newSimReplacement(buildAdjRegLoop)

  applyChoice(findComponent(result, "RSET"), rChoice)
  applyChoice(findComponent(result, "RADJ"), rChoice)
  applyChoice(findComponent(result, "COUT"), coutChoice)
  applyChoice(findComponent(result, "CIN"), cinChoice)
