## Resistor dividers stated the way they are specified, not the way they are
## drawn: **a total impedance and a ratio**.
##
## ## Why that parameterization and not two resistor values
##
## A divider's two resistors are not independent, and neither of the two
## things a designer actually cares about is either of them:
##
## * the **ratio** is the answer the circuit gives -- the attenuation, the
##   feedback fraction, the trip point;
## * the **total** is everything the ratio does not describe -- how much
##   current the divider burns, how hard it loads whatever drives it, how
##   much Johnson noise and bias-current error it contributes, and how much
##   stray capacitance it takes to move its corner.
##
## Write the two resistors instead and every edit couples the two: nudging
## one leg to a preferred value changes the ratio *and* the total, and
## nothing says which of them you meant to keep. Say `rTotal` and `ratio` and
## the builder derives the legs, so the thing that moves is the thing you
## moved.
##
## ## The equations
##
## For a **voltage** divider -- two resistors in series, the tap between
## them, `ratio` the fraction of the input that appears at the tap:
##
##     rTop = rTotal * (1 - ratio)      rBot = rTotal * ratio
##
## with `rTop + rBot = rTotal` and `ratio = rBot / rTotal` exactly, unloaded.
##
## For a **current** divider -- two resistors in parallel from a common node,
## `split` the fraction of the incoming current that leaves through branch A:
##
##     rA = rTotal / split              rB = rTotal / (1 - split)
##
## with `rA || rB = rTotal` and `split = G_A / (G_A + G_B)` exactly, when both
## branches return to the same potential.
##
## The two are duals: a voltage divider *adds* resistance and divides voltage
## by the ratio of a part to the whole; a current divider *adds conductance*
## and divides current the same way. `rTotal` means the same thing in both --
## the impedance the block presents at its input node -- and that shared
## meaning is what makes them composable.
##
## ## Composing them
##
## Because a current divider's input impedance is `rTotal` by construction, it
## is a drop-in replacement for any resistor of that value -- including a
## voltage divider's bottom leg. That gives the three-resistor network
## `splitTapDivider` builds: one series resistor setting the tap, and two
## parallel legs that both realise the bottom-leg impedance the tap needs
## *and* split the tap current in a stated proportion.
##
## `splitTapDivider` instances `currentDivider` for that bottom leg and sizes
## its own top resistor with `voltageDividerLegs` -- the same equation proc
## the standalone `voltageDivider` uses. It does not instance `voltageDivider`
## as well, and that is arithmetic rather than taste: a whole voltage divider
## plus a whole current divider is four resistors, because the bottom leg
## would be built twice. Three resistors means one of the two blocks
## contributes its equation and not its parts.
##
## ## What a check of the composed network actually tests
##
## The tap voltage tests both halves at once. It is right only if the top
## resistor is right *and* the two parallel legs really do present the
## bottom-leg impedance they claim -- get `currentDividerLegs` wrong and
## `rA || rB` is not `rTotal`, so the tap moves. That is the composition
## property, measured rather than asserted.
##
## The split itself has no such witness: both branches return to the same
## node, so no node voltage in the network reveals how the current divided.
## `sense` is the way to see it -- part of leg A is realised as a separate
## small resistor, so the junction sits at `I_A * sense` volts. It is *part
## of* the leg rather than added to it (`rA - sense` in series with `sense`),
## so the leg impedance and therefore the split are unchanged; this is the
## bench technique, and it is exact rather than a perturbation.
##
## ## Stated limits
##
## The values returned are exact, not rounded to a preferred series -- the
## same position `designs/lib/filters.nim` takes, and for the same reason: a
## builder that quietly rounds reports back the number you asked for while
## building something else. `designs/lib/adjreg.nim` shows the other half of
## that, where rounding is asked for explicitly and the achieved result is
## recomputed from the rounded parts.
##
## Nothing here knows the voltage across the divider, so nothing here can
## state a resistor's dissipation -- exactly as `filters.nim` cannot state a
## bypass capacitor's working voltage. The board knows; the block does not.

import nimcir/contract/dsl
import nimcir/netlist/formats/spice as spiceFormat
import nimcir/parts
import nimcir/eng

type
  VoltageDividerLegs* = tuple[top, bot: Ohms]
    ## The series legs of a voltage divider: `top` from IN to the tap, `bot`
    ## from the tap to the return.
  CurrentDividerLegs* = tuple[a, b: Ohms]
    ## The parallel branches of a current divider, in the order the `split`
    ## refers to: `split` is the fraction of the input current that leaves
    ## through `a`.

proc checkFraction(f: Fraction, name: string) =
  ## A ratio of exactly 0 or 1 is not a divider -- one leg goes to zero and
  ## the other to infinity, and there is no resistor either way. Refused here
  ## rather than emitted as a `0` or an `inf` device value, which ngspice
  ## reads as a short or a syntax error several steps from the cause.
  let v = float(f)
  if not (v > 0.0 and v < 1.0):
    raise newException(ValueError,
      name & " must be strictly between 0 and 1; got " & $(v * 100.0) &
      "%. A divider needs both legs to exist.")

proc voltageDividerLegs*(rTotal: Ohms, ratio: Fraction): VoltageDividerLegs =
  ## `rTop = rTotal*(1 - ratio)`, `rBot = rTotal*ratio`, so the unloaded tap
  ## sits at `ratio` of the input and the string draws `V / rTotal`.
  checkFraction(ratio, "ratio")
  let total = float(rTotal)
  (top: Ohms(total * (1.0 - float(ratio))), bot: Ohms(total * float(ratio)))

proc currentDividerLegs*(rTotal: Ohms, split: Fraction): CurrentDividerLegs =
  ## `rA = rTotal/split`, `rB = rTotal/(1 - split)`, so `rA || rB = rTotal`
  ## and the fraction `split` of the input current leaves through A.
  ##
  ## Note the asymmetry with the voltage divider that trips people up: the
  ## branch carrying the *larger* share of the current is the *smaller*
  ## resistor, so `split` divides rather than multiplies.
  checkFraction(split, "split")
  let total = float(rTotal)
  (a: Ohms(total / float(split)), b: Ohms(total / (1.0 - float(split))))

proc dividerRatio*(legs: VoltageDividerLegs): Fraction =
  ## The inverse of `voltageDividerLegs`, for reporting what a pair of real
  ## parts actually gives.
  Fraction(float(legs.bot) / (float(legs.top) + float(legs.bot)))

proc dividerSplit*(legs: CurrentDividerLegs): Fraction =
  ## The inverse of `currentDividerLegs`.
  Fraction(float(legs.b) / (float(legs.a) + float(legs.b)))

proc parallel*(a, b: Ohms): Ohms =
  ## What the pair presents at the common node, which is the number that has
  ## to match the leg it stands in for.
  Ohms(1.0 / (1.0 / float(a) + 1.0 / float(b)))

proc voltageDivider*(rTotal: Ohms, ratio: Fraction,
                     parts = defaultPolicy()): Netlist =
  ## Two resistors in series. Ports: `IN`, `TAP`, `BOT`.
  ##
  ## `BOT` is a port rather than an internal ground because a divider's return
  ## is not always ground -- it is the bottom of whatever the ratio is taken
  ## against, which for a level shifter or a bridge leg is another rail.
  let legs = voltageDividerLegs(rTotal, ratio)
  let rChoice = parts.resistor(ResRequest(value: rTotal, use: ruPrecision))

  result = subckt("VDIV", [IN, TAP, BOT]):
    net IN,  kind = ntSignal
    net TAP, kind = ntSignal
    net BOT, kind = ntSignal

    component RTOP, kind = "resistor", value = spiceValue(float(legs.top)):
      pin "1", IN,  kind = ptPassive
      pin "2", TAP, kind = ptPassive
    component RBOT, kind = "resistor", value = spiceValue(float(legs.bot)):
      pin "1", TAP, kind = ptPassive
      pin "2", BOT, kind = ptPassive

  applyChoice(findComponent(result, "RTOP"), rChoice)
  applyChoice(findComponent(result, "RBOT"), rChoice)

proc currentDivider*(rTotal: Ohms, split: Fraction, sense = 0.ohm,
                     parts = defaultPolicy()): Netlist =
  ## Two resistors in parallel from a common input node. Ports: `IN`, `A`,
  ## `B`; `split` is the fraction of the current into `IN` that leaves
  ## through `A`, and holds while `A` and `B` sit at the same potential.
  ##
  ## `sense` makes the split observable: leg A becomes `rA - sense` in series
  ## with a `sense` resistor, and their junction -- the net `sns`, reachable
  ## from a design as `XI.innerNet("sns")` -- sits at `I_A * sense`. The leg
  ## total is unchanged, so this measures the split without altering it.
  let legs = currentDividerLegs(rTotal, split)
  let senseR = float(sense)
  if senseR < 0.0 or senseR >= float(legs.a):
    raise newException(ValueError,
      "sense must be a part of leg A, not the whole of it: it is " &
      eng(senseR, "ohm") & " against a leg of " & eng(float(legs.a), "ohm"))
  let rChoice = parts.resistor(ResRequest(value: rTotal, use: ruPrecision))

  result = subckt("IDIV", [IN, A, B]):
    net IN, kind = ntSignal
    net A,  kind = ntSignal
    net B,  kind = ntSignal

    if senseR > 0.0:
      net sns, kind = ntSignal
      component RA, kind = "resistor",
                value = spiceValue(float(legs.a) - senseR):
        pin "1", IN,  kind = ptPassive
        pin "2", sns, kind = ptPassive
      component RSNS, kind = "resistor", value = spiceValue(senseR):
        pin "1", sns, kind = ptPassive
        pin "2", A,   kind = ptPassive
    else:
      component RA, kind = "resistor", value = spiceValue(float(legs.a)):
        pin "1", IN, kind = ptPassive
        pin "2", A,  kind = ptPassive

    component RB, kind = "resistor", value = spiceValue(float(legs.b)):
      pin "1", IN, kind = ptPassive
      pin "2", B,  kind = ptPassive

  applyChoice(findComponent(result, "RA"), rChoice)
  applyChoice(findComponent(result, "RB"), rChoice)

proc splitTapDivider*(rTotal: Ohms, ratio: Fraction, split: Fraction,
                      sense = 0.ohm, parts = defaultPolicy()): Netlist =
  ## The composition: a voltage divider whose bottom leg is a current
  ## divider. Three resistors. Ports: `IN`, `TAP`, `A`, `B`.
  ##
  ## `rTotal` and `ratio` mean exactly what they mean for `voltageDivider` --
  ## the tap sits at `ratio` of the input, and the string draws `V/rTotal`
  ## when A and B return to the input's reference. `split` then says how the
  ## tap current divides between the two legs that make up the bottom.
  let legs = voltageDividerLegs(rTotal, ratio)
  let rChoice = parts.resistor(ResRequest(value: rTotal, use: ruPrecision))

  result = subckt("VIDIV", [IN, TAP, A, B]):
    net IN,  kind = ntSignal
    net TAP, kind = ntSignal
    net A,   kind = ntSignal
    net B,   kind = ntSignal

    component RTOP, kind = "resistor", value = spiceValue(float(legs.top)):
      pin "1", IN,  kind = ptPassive
      pin "2", TAP, kind = ptPassive

    # The bottom leg, realised as a pair. `legs.bot` is what the pair has to
    # present, and `currentDividerLegs` is what guarantees it does -- so the
    # tap voltage is a check of that guarantee as much as of this file's
    # own arithmetic.
    instance XI, currentDivider(legs.bot, split, sense, parts), [TAP, A, B]

  applyChoice(findComponent(result, "RTOP"), rChoice)
