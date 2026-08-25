## A parameterized filter builder: say what you want, get the netlist.
##
## `sallenKeyLP(fc = 1.kHz, r = 10.kohm)` returns a `subckt` whose component
## *values* were computed from those arguments. This works because a `subckt`
## block is ordinary runtime code inside a `block` expression -- so it can sit
## in a `proc`, close over its parameters, and use anything computed before it.
## `value = <expr>` and `designator = <expr>` take arbitrary expressions, not
## just literals.
##
## ## The design equations
##
## For a unity-gain Sallen-Key low-pass with equal resistors, writing
## k = sqrt(C1*C2):
##
##     fc = 1 / (2*pi*R*k)        Q = k / (2*C2)
##
## which inverts to
##
##     C1 = 2*Q / (2*pi*fc*R)     C2 = 1 / (2*Q * 2*pi*fc*R)
##
## so C1/C2 = 4*Q^2 -- the ratio *is* the damping, and the geometric mean of
## the two capacitors is what sets the corner. That is the whole reason to
## generate these rather than type them: the two values are not independent,
## and a designer nudging one to an E12 part has changed Q as well as fc
## without being told.
##
## ## Choosing R is the part a builder cannot do for you
##
## `r` is an argument rather than a derived value because nothing in the
## transfer function fixes it -- only the *product* RC matters. What picks it
## is everything the transfer function does not describe: too low and the
## amplifier has to drive it, too high and the resistors' Johnson noise and
## the op-amp's bias current start to matter, and the stray capacitance of the
## board becomes a fraction of C2. 10 k is the usual compromise for audio.
##
## Stated as a limitation rather than hidden: the values returned are exact,
## not rounded to a preferred series. A real build substitutes E96 resistors
## and E12 capacitors, which moves fc and Q by a percent or two -- and the
## right place to see that is a check of the built board, not a builder that
## quietly rounds and reports the number you asked for.

import std/math

import nimcir/contract/dsl
import nimcir/netlist/formats/spice as spiceFormat
import nimcir/parts

proc sallenKeyLP*(fc: Hertz, r = 10.kohm, q = 0.70710678,
                  gbw = 10.MHz, parts = defaultPolicy()): Netlist =
  ## A unity-gain Sallen-Key low-pass section. Ports: `IN`, `OUT`, `VP`, `VN`,
  ## `GND`.
  ##
  ## `q` defaults to 1/sqrt(2), which is Butterworth -- maximally flat, no
  ## peaking. Cascade two sections at q = 0.5412 and q = 1.3066 for a 4th-order
  ## Butterworth; neither is flat alone and only the product is.
  let k = 1.0 / (2.0 * PI * float(fc) * float(r))
  let c1 = 2.0 * q * k
  let c2 = k / (2.0 * q)

  # The module says what these parts are *for*; the policy decides what they
  # are. `cuTiming` is the load-bearing word: it is what makes the default
  # policy return C0G, and C0G is what stops the corner moving. A Class 2
  # ceramic here loses capacitance to DC bias and to temperature, and since
  # fc goes as 1/sqrt(C1*C2), a bank at 65% of nominal moves this filter's
  # corner up by about 24%. The builder cannot know the rail voltage or the
  # temperature range; the board cannot know which capacitor sets the corner.
  # Neither can choose the part alone, which is the whole reason `parts`
  # is a parameter rather than a table in here.
  let c1Choice = parts.capacitor(CapRequest(value: Farads(c1), use: cuTiming))
  let c2Choice = parts.capacitor(CapRequest(value: Farads(c2), use: cuTiming))
  let rChoice = parts.resistor(ResRequest(value: r, use: ruPrecision))

  # The bypass capacitors go through the same policy under a *different*
  # function, and note what is not passed: `working`. The builder does not
  # know what the supply is, and does not need to -- `spice/models` computes
  # the DC across each capacitor from the netlist at simulation time, when
  # the rail voltages are stated. So the policy answers "what kind of part",
  # the netlist answers "what is across it", and neither has to know the
  # other's business.
  let cdChoice = parts.capacitor(CapRequest(value: 100.nF, use: cuDecoupling))

  result = subckt("SALLEN_KEY_LP", [IN, OUT, VP, VN, GND]):
    net GND, kind = ntGround, name = "0"
    net VP,  kind = ntPower
    net VN,  kind = ntPower
    net IN,  kind = ntSignal
    net OUT, kind = ntSignal
    net mid, kind = ntSignal              # R1/R2/C1 junction
    net pos, kind = ntSignal              # non-inverting input

    component R1, kind = "resistor", value = spiceValue(float(r)):
      pin "1", IN, kind = ptPassive
      pin "2", mid, kind = ptPassive
    component R2, kind = "resistor", value = spiceValue(float(r)):
      pin "1", mid, kind = ptPassive
      pin "2", pos, kind = ptPassive

    # C1 returns to the *output*, which is what makes this a Sallen-Key and
    # not two cascaded RC sections: it is a second feedback path, positive at
    # the corner, and it is where the Q comes from. It is also why
    # `analyzeLoopGain` cannot open this stage's loop -- see the `without` in
    # any design that uses one.
    component C1, kind = "capacitor", value = spiceValue(c1):
      pin "1", mid, kind = ptPassive
      pin "2", OUT, kind = ptPassive
    component C2, kind = "capacitor", value = spiceValue(c2):
      pin "1", pos, kind = ptPassive
      pin "2", GND, kind = ptPassive

    component U1, kind = "opamp", partNumber = "OPA1642":
      pin "IN+", pos, kind = ptInput
      pin "IN-", OUT, kind = ptInput      # unity gain: output straight back
      pin "OUT", OUT, kind = ptOutput
      pin "V+",  VP,  kind = ptPower
      pin "V-",  VN,  kind = ptGround
      spec:
        gbw = gbw

    component CD1, kind = "capacitor", value = "100n":
      pin "1", VP, kind = ptPassive
      pin "2", GND, kind = ptPassive
      spec:
        package = "0402"
    component CD2, kind = "capacitor", value = "100n":
      pin "1", VN, kind = ptPassive
      pin "2", GND, kind = ptPassive
      spec:
        package = "0402"

  # Applied after the block rather than inside it, because `spec:` takes
  # `key = value` pairs and this is one call carrying a dozen of them. The
  # result is identical: every field of a `Choice` is a *registered*
  # annotation, so what the policy decided is visible in the netlist exactly
  # as a hand-typed `spec:` block would be.
  applyChoice(findComponent(result, "C1"), c1Choice)
  applyChoice(findComponent(result, "C2"), c2Choice)
  applyChoice(findComponent(result, "R1"), rChoice)
  applyChoice(findComponent(result, "R2"), rChoice)
  applyChoice(findComponent(result, "CD1"), cdChoice)
  applyChoice(findComponent(result, "CD2"), cdChoice)
