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
## `series` is a `PreferredSeries` from `nimcir/parts/series` and defaults to
## `exactSeries`, which rounds nothing -- a builder rounds only when asked.
## Pass `e96` and what the design gets back is recomputed from the values that
## will be fitted, never reported back as the voltage that was requested; the
## difference is the design's to accept or to fix.
##
## ## What the loop model is not
##
## Stated plainly, because a model that flatters the circuit is worse than no
## model. The error amplifier's output is an ideal source, so there is
## **no dropout, no current limit, no thermal foldback and no load
## regulation** -- the rail will hold its target however hard it is loaded
## and however low the input goes. `checkHeadroom` is what stands in for
## dropout, and it is a static check of stated numbers, not a measurement.
##
## Input current does not follow the load either: nothing here is a pass
## element, so the input draw is stated once, from the load current the
## design declared, as a constant-current sink. That makes an input-side IR
## drop appear where there is series resistance to drop it, and it is an
## open circuit at AC, which is the right shape for a regulated draw -- the
## same distinction `spice/boundary` draws between `driveLoad` and
## `driveSink`. It is right at the operating point and nowhere else.
##
## And do not run a PDN sweep against a rail built this way. The error
## amplifier's output is an ideal source: it is a dead short at AC, so the
## sweep would report 0 ohm at every frequency and pass any target that could
## be set -- the same trap `spice/models.expandSourceImpedance` exists to
## stop, one layer up where it cannot reach.

import std/[strutils, tables]

import nimcir/contract/dsl
import nimcir/netlist/formats/spice as spiceFormat
import nimcir/eng
import nimcir/parts

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
    aol*: float
    gbw*: Hertz
      ## The error amplifier's open-loop gain and bandwidth in the simulation
      ## model. Not datasheet figures -- a linear regulator's loop response
      ## is not published in this form -- so they are the model's numbers,
      ## chosen high enough that the DC answer is set by the divider and not
      ## by the amplifier.

const
  lm317* = AdjRegulator(
    partNumber: "LM317",
    vref: Volts(1.25), vrefTol: Fraction(0.04),
    iAdj: Amps(50.0e-6),
    voutMin: Volts(1.25), voutMax: Volts(37.0),
    dropout: Volts(2.0),
    iMinLoad: Amps(10.0e-3),
    thetaJA: 50.0,
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
  iInAttr = "adjreg.iin"
  aolAttr = "adjreg.aol"
  gbwAttr = "adjreg.gbw"
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
  let iIn = attrFloat(old, iInAttr, 0.0)
  let aol = attrFloat(old, aolAttr, 1.0e5)
  let gbw = attrFloat(old, gbwAttr, 1.0e6)
  let des = old.designator

  removeComponent(nl, des)

  # The reference, floating on ADJ. `rout`/`lout` are pinned to zero: this is
  # a stimulus rather than a supply, and `expandSourceImpedance`'s default
  # 10 mohm + 1 uH would otherwise sit between the reference and the node it
  # references. Nothing draws current through it -- the amplifier's inputs
  # are a VCVS's -- so it costs nothing at DC either way, and saying so is
  # cheaper than rediscovering it.
  let refNet = addNet(nl, newNet(des & "_REF", ntSignal))
  let vsrc = addComponent(nl, newComponent("V" & des & "_REF",
                                           kind = "voltage_source"))
  discard connect(vsrc, "+", refNet, ptPassive)
  discard connect(vsrc, "-", adjNet, ptPassive)
  vsrc.attrs["value"] = "DC " & spiceValue(vref)
  vsrc.attrs["rout"] = "0"
  vsrc.attrs["lout"] = "0"

  # The error amplifier. It is emitted as an ordinary `opamp`, so
  # `spice/models.opampModel` gives it the same single-pole macromodel every
  # other unmodelled amplifier gets -- one model of an amplifier in the
  # build, not two.
  let ea = addComponent(nl, newComponent("U" & des & "_EA", kind = "opamp"))
  discard connect(ea, "IN+", refNet, ptInput)
  discard connect(ea, "IN-", outNet, ptInput)
  discard connect(ea, "OUT", outNet, ptOutput)
  ea.attrs["gain"] = $aol
  ea.attrs["gbw"] = $gbw

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

  # What the input rail actually loses. There is no pass element here, so
  # this does not follow the load -- it is the draw the design declared,
  # stated once. A constant-current sink rather than a resistor, because a
  # regulator's input current does not follow its input voltage.
  if iIn > 0.0 and inNet != nil and inNet != gnd:
    let ii = addComponent(nl, newComponent("I" & des & "_IN",
                                           kind = "current_source"))
    discard connect(ii, "+", inNet, ptPassive)
    discard connect(ii, "-", gnd, ptPassive)
    ii.attrs["value"] = "DC " & spiceValue(iIn)

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
  u1.attrs[iInAttr] = $(float(iLoad) + float(iQuiescent))
  u1.attrs[aolAttr] = $part.aol
  u1.attrs[gbwAttr] = $float(part.gbw)
  u1.simReplace = newSimReplacement(buildAdjRegLoop)

  applyChoice(findComponent(result, "RSET"), rChoice)
  applyChoice(findComponent(result, "RADJ"), rChoice)
  applyChoice(findComponent(result, "COUT"), coutChoice)
  applyChoice(findComponent(result, "CIN"), cinChoice)
