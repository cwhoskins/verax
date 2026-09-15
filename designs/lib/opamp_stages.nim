## Non-inverting and inverting op-amp gain stages, factored so the topology
## never has to know which op-amp, whether the board is single- or
## dual-supply, what pins beyond IN+/IN-/OUT/V+/V- the chosen part has, or
## what physically implements each gain-setting leg.
##
## Four separate invariances, four separate mechanisms:
##
## * **Single vs. dual supply** -- a `REF` port, not a hardcoded `GND`. The
##   gain-setting resistor's return leg (and, in `invertingAmp`, the
##   non-inverting input itself) lands on `REF` rather than on true ground.
##   Wire `REF` to `GND` on a dual-supply board; wire it to a synthesised
##   bias rail on a single-supply one (see `ts808_drive`'s `vref`). Neither
##   proc here reads which case it is -- `REF` is declared `ntSignal`
##   because it genuinely is either, and asserting one would be a claim this
##   module cannot back up.
## * **Arbitrary op-amp part** -- an `OpAmpPart` (partNumber + gbw) instead
##   of a hardcoded `partNumber = "..."` string.
## * **Extra pins** (a shutdown, an offset-null, a bias-current-set pin) --
##   an `extra: seq[OpAmpExtra]` parameter. The factory cannot decide how to
##   wire one -- an EN pin wired wrong disables the whole amplifier, and only
##   the board knows whether an instance is meant to be always-on or a real
##   power-down, the same "neither can choose alone" split `parts/types.nim`
##   draws for a capacitor's dielectric -- so it does the one thing it *can*
##   do generically: promote each extra pin to a port under its own logical
##   name. Because two calls can produce differently-shaped templates
##   (a plain part has 6 ports, one with a shutdown pin has 7), wire a
##   template that used `extra` with `instance`'s **named** port form
##   (`{"IN": ..., "SHDN": ...}`) rather than the positional bracket form --
##   see `netlist/dsl.handleInstance`. An extra pin that only ever needs an
##   *internal* tie-off (SHDN permanently held enabled, say) does not need
##   this mechanism at all: wire it inside `instance ..., with = proc(nl:
##   Netlist) = connect(findComponent(nl, "U1"), "SHDN", findNet(nl, "VP"),
##   ptInput)` against the instance's own clone instead, exactly the way
##   `packages.nim`'s section tagging runs against an instance's own clone.
## * **What implements each gain-setting leg.** `FeedbackNetwork` is a
##   two-terminal black box: the `dcValue` a gain formula needs to see, and
##   a `build` closure that does the actual wiring. `resistorNetwork` is the
##   plain case; `parallelRCNetwork` and `resistorTeeNetwork` are two more
##   shapes for the same slot -- picked by frequency/impedance or by a
##   target feedback ratio respectively, never by the factory. One level
##   above that, *which pair* of legs a given `gain` turns into is itself
##   injected as a `NonInvertingGainFn`/`InvertingGainFn` closure: the
##   factory calls it with `(gain, parts)` and wires back whatever two
##   `FeedbackNetwork`s come out, never seeing what is inside them or what
##   else the closure captured -- a target corner frequency, an external
##   impedance budget, anything that is not the factory's business.
##   `defaultNonInvertingGain`/`defaultInvertingGain` implement the textbook
##   `1 + Rf/Rg` / `-Rf/Rin` formulas as plain resistors; a caller replacing
##   the whole function is trusted to still honor `gain` -- the factory has
##   no way to check that once the function is swapped out, the same trust
##   boundary `extra` and `PartPolicy` already draw elsewhere in this module.
##
## **Multi-channel packaging is not this module's concern.** Each proc here
## builds one channel; a dual/quad part is two/four calls whose `U1`
## instances get tagged into one `PackageDef`'s sections by the design, via
## `packageInstance(...).section(...)` -- see `riaa_preamp.nim`/
## `aa_filter.nim`. Nothing here needs to know a package exists.

import std/math
import std/tables
import verax/contract/dsl
import verax/netlist/formats/spice as spiceFormat
import verax/parts

type
  OpAmpExtra* = object
    ## One physical pin beyond IN+/IN-/OUT/V+/V-: a shutdown, an
    ## offset-null, a compensation or bias-current-set pin.
    logical*: string   ## "SHDN", "OFFSET", "COMP", "IBIAS", ...
    kind*: PinType      ## ptInput, ptOutput, ptPassive, ...

  OpAmpPart* = object
    ## What a factory needs to know about the physical part. Nothing here
    ## says single/dual supply or how many channels the package has --
    ## those are facts about the board, not the die.
    partNumber*: string
    gbw*: Hertz

  FeedbackNetwork* = object
    ## A two-terminal network for one gain-setting leg, plus the one fact a
    ## gain formula needs from it regardless of internal shape: the DC
    ## resistance it presents. `build` runs post-`subckt`, against the raw
    ## graph -- the same reason `exposeExtraPins` does: which components a
    ## leg needs is runtime data, not macro syntax.
    dcValue*: Ohms
    build*: proc(nl: Netlist, prefix: string, a, b: Net) {.closure.}

  NonInvertingLegs* = tuple[rf, rg: FeedbackNetwork]
  NonInvertingGainFn* = proc(gain: float, parts: PartPolicy): NonInvertingLegs {.closure.}

  InvertingLegs* = tuple[rin, rf: FeedbackNetwork]
  InvertingGainFn* = proc(gain: float, parts: PartPolicy): InvertingLegs {.closure.}

proc defaultOpAmp*(partNumber = "OPA1642", gbw = 10.MHz): OpAmpPart =
  OpAmpPart(partNumber: partNumber, gbw: gbw)

proc exposeExtraPins(nl: Netlist, u: Component, extra: seq[OpAmpExtra]) =
  ## Runs after the `subckt` macro block, using the raw graph API, because
  ## `extra`'s length is runtime data and the macro's port list is not. One
  ## port per extra pin, under its own logical name -- the caller wires each
  ## one from the parent netlist by instancing with the named
  ## `{"port": net, ...}` form, not a positional bracket (see the module
  ## doc comment).
  for xp in extra:
    let n = addNet(nl, Net(name: xp.logical, kind: ntSignal))
    addPort(nl, xp.logical, n)
    discard connect(u, xp.logical, n, xp.kind)

# --- feedback-leg building blocks -------------------------------------------
# Each of these builds a `FeedbackNetwork`: a `dcValue` for the gain formula
# to see, plus a `build` closure that wires whatever it actually is between
# two nets handed to it later. `nonInvertingAmp`/`invertingAmp` never call
# these directly -- a `NonInvertingGainFn`/`InvertingGainFn` does, so they
# read as building blocks for *that*, not as factory parameters themselves.

proc resistorNetwork*(value: Ohms, parts = defaultPolicy()): FeedbackNetwork =
  ## The plain case: a single, policy-priced resistor.
  let choice = parts.resistor(ResRequest(value: value, use: ruPrecision))
  FeedbackNetwork(
    dcValue: value,
    build: proc(nl: Netlist, prefix: string, a, b: Net) =
      let r = addComponent(nl, Component(designator: prefix, kind: "resistor"))
      r.attrs["value"] = spiceValue(float(value))
      discard connect(r, "1", a, ptPassive)
      discard connect(r, "2", b, ptPassive)
      applyChoice(r, choice))

proc parallelRCNetwork*(r: Ohms, corner: Hertz, parts = defaultPolicy()): FeedbackNetwork =
  ## `r` in parallel with a capacitor sized from `corner` -- rolls the
  ## closed-loop gain off above `corner` instead of letting it ride the
  ## op-amp's open-loop curve all the way to the GBW corner. Same DC value
  ## as `resistorNetwork(r)`, chosen by frequency and impedance rather than
  ## by a bare capacitance.
  let c = Farads(1.0 / (2.0 * PI * float(r) * float(corner)))
  let rc = parts.resistor(ResRequest(value: r, use: ruPrecision))
  let cc = parts.capacitor(CapRequest(value: c, use: cuTiming))
  FeedbackNetwork(
    dcValue: r,
    build: proc(nl: Netlist, prefix: string, a, b: Net) =
      let rr = addComponent(nl, Component(designator: prefix & "R", kind: "resistor"))
      rr.attrs["value"] = spiceValue(float(r))
      discard connect(rr, "1", a, ptPassive)
      discard connect(rr, "2", b, ptPassive)
      applyChoice(rr, rc)
      let cx = addComponent(nl, Component(designator: prefix & "C", kind: "capacitor"))
      cx.attrs["value"] = spiceValue(float(c))
      discard connect(cx, "1", a, ptPassive)
      discard connect(cx, "2", b, ptPassive)
      applyChoice(cx, cc))

proc resistorTeeNetwork*(ratio: Ohms, r2 = 10.kohm, r3 = 1.kohm,
                         parts = defaultPolicy()): FeedbackNetwork =
  ## a --r1-- mid --r2-- b, mid --r3-- ground. Backs out r1 so that
  ## `r1 + r2 + r1*r2/r3 == ratio`, chosen by the desired feedback ratio
  ## rather than by three individual resistor values -- gets a large
  ## effective ratio out of three moderate resistors instead of one
  ## impractically large one. `mid` is internal: the closure makes its own
  ## net, never a port, the same way a package section's internal wiring
  ## never needs one.
  ##
  ## **That formula assumes `b` is held at virtual ground by the loop** --
  ## true of `invertingAmp`'s RF (OUT to fb, and fb sits at REF because the
  ## loop forces it there), false of `nonInvertingAmp`'s RF or RG (fb sits
  ## at `Vout/gain`, not at REF, so the third leg bleeds current the
  ## formula never accounted for). Measured on the wrong leg this comes out
  ## reading a higher gain than requested, silently -- there is nothing in
  ## the types here that catches it, the same way nothing catches a
  ## `PartPolicy` returning a `Choice` too small for its `dissipating`.
  let r1 = Ohms((float(ratio) - float(r2)) / (1.0 + float(r2) / float(r3)))
  doAssert float(r1) > 0.0,
    "resistorTeeNetwork: ratio " & $float(ratio) & " is not reachable with r2=" &
    $float(r2) & " r3=" & $float(r3) & " (would need a negative r1)"
  let c1 = parts.resistor(ResRequest(value: r1, use: ruPrecision))
  let c2 = parts.resistor(ResRequest(value: r2, use: ruPrecision))
  let c3 = parts.resistor(ResRequest(value: r3, use: ruPrecision))
  FeedbackNetwork(
    dcValue: ratio,
    build: proc(nl: Netlist, prefix: string, a, b: Net) =
      let mid = addNet(nl, Net(name: prefix & "_mid", kind: ntSignal))
      let gnd = findNet(nl, "0")  # ground's net *name* is "0", set via
                                  # `net GND, ..., name = "0"` below --
                                  # addNet/findNet key on that string, not
                                  # the DSL ident "GND".
      for leg in [(prefix & "1", r1, c1, a, mid),
                  (prefix & "2", r2, c2, mid, b),
                  (prefix & "3", r3, c3, mid, gnd)]:
        let (d, val, ch, x, y) = leg
        let rr = addComponent(nl, Component(designator: d, kind: "resistor"))
        rr.attrs["value"] = spiceValue(float(val))
        discard connect(rr, "1", x, ptPassive)
        discard connect(rr, "2", y, ptPassive)
        applyChoice(rr, ch))

# --- gain-to-legs policy -----------------------------------------------------
# What turns a `gain` into a pair of `FeedbackNetwork`s. The factory below
# calls this and wires back whatever it returns; it never computes a
# resistor value itself.

proc defaultNonInvertingGain*(rfNominal = 100.kohm): NonInvertingGainFn =
  ## The textbook `gain = 1 + Rf/Rg`, both legs plain resistors.
  result = proc(gain: float, parts: PartPolicy): NonInvertingLegs =
    let rgF = float(rfNominal) / (gain - 1.0)
    (rf: resistorNetwork(rfNominal, parts), rg: resistorNetwork(Ohms(rgF), parts))

proc defaultInvertingGain*(rinNominal = 10.kohm): InvertingGainFn =
  ## The textbook `gain = -Rf/Rin`, both legs plain resistors.
  result = proc(gain: float, parts: PartPolicy): InvertingLegs =
    (rin: resistorNetwork(rinNominal, parts),
     rf: resistorNetwork(Ohms(float(rinNominal) * abs(gain)), parts))

proc teeInvertingGain*(rin = 10.kohm, r2 = 10.kohm, r3 = 1.kohm): InvertingGainFn =
  ## `gain = -Rf/Rin`, RF realized as a resistor tee instead of one
  ## (likely impractically large) resistor. Valid specifically because
  ## `invertingAmp`'s fb node is virtual ground -- see `resistorTeeNetwork`'s
  ## doc comment for why the same swap in `defaultNonInvertingGain` would be
  ## wrong. `gain` still determines the tee's target resistance the same way
  ## it determines a plain RF in `defaultInvertingGain`; only `r2`/`r3`
  ## are free choices, the same two `resistorTeeNetwork` itself takes.
  result = proc(gain: float, parts: PartPolicy): InvertingLegs =
    let rfTarget = Ohms(float(rin) * abs(gain))
    (rin: resistorNetwork(rin, parts),
     rf: resistorTeeNetwork(rfTarget, r2, r3, parts))

# --- non-inverting: gain = 1 + Rf/Rg, gain >= 1 (1.0 is a unity buffer) -----

proc nonInvertingAmp*(part: OpAmpPart, gain: float, extra: seq[OpAmpExtra] = @[],
                      gainNetworks: NonInvertingGainFn = defaultNonInvertingGain(),
                      parts = defaultPolicy()): Netlist =
  ## Ports: `IN`, `OUT`, `VP`, `VN`, `REF`, `GND`, then one port per `extra`
  ## pin, in declaration order. `IN` drives the non-inverting input
  ## directly -- any input coupling/biasing network is the caller's
  ## business, the way `riaa.riaaChannel` builds its own CIN/RB ahead of the
  ## amplifier rather than folding them into a generic stage.
  doAssert gain >= 1.0,
    "non-inverting gain is >= 1 (1.0 is a unity buffer); use invertingAmp " &
    "for a negative gain"

  let buffer = gain == 1.0

  result = subckt("NONINV_GAIN", [IN, OUT, VP, VN, REF, GND]):
    net GND, kind = ntGround, name = "0"
    net VP,  kind = ntPower
    net VN,  kind = ntPower
    net REF, kind = ntSignal
    net IN,  kind = ntSignal
    net OUT, kind = ntSignal
    net fb,  kind = ntSignal

    component U1, kind = "opamp", partNumber = part.partNumber:
      pin "IN+", IN,  kind = ptInput
      pin "IN-", fb,  kind = ptInput
      pin "OUT", OUT, kind = ptOutput
      pin "V+",  VP,  kind = ptPower
      pin "V-",  VN,  kind = ptGround
      spec:
        gbw = part.gbw

    component CD1, kind = "capacitor", value = "100n":
      pin "1", VP, kind = ptPassive
      pin "2", GND, kind = ptPassive
    component CD2, kind = "capacitor", value = "100n":
      pin "1", VN, kind = ptPassive
      pin "2", GND, kind = ptPassive

  if buffer:
    mergeNets(findNet(result, "OUT"), findNet(result, "fb"))
  else:
    let legs = gainNetworks(gain, parts)
    legs.rf.build(result, "RF", findNet(result, "OUT"), findNet(result, "fb"))
    legs.rg.build(result, "RG", findNet(result, "fb"), findNet(result, "REF"))

  exposeExtraPins(result, findComponent(result, "U1"), extra)

# --- inverting: gain = -Rf/Rin, gain < 0 ------------------------------------

proc invertingAmp*(part: OpAmpPart, gain: float, extra: seq[OpAmpExtra] = @[],
                   gainNetworks: InvertingGainFn = defaultInvertingGain(),
                   parts = defaultPolicy()): Netlist =
  ## Ports: `IN`, `OUT`, `VP`, `VN`, `REF`, `GND`, then one port per `extra`
  ## pin. `gain` is negative (e.g. `-10.0`). `IN+` ties straight to `REF`,
  ## which is the whole trick that makes this invariant to single vs. dual
  ## supply -- `REF` is ground on one board and a bias rail on the other,
  ## and this proc never asks which.
  doAssert gain < 0.0,
    "inverting gain is negative; use nonInvertingAmp for a positive gain"

  result = subckt("INV_GAIN", [IN, OUT, VP, VN, REF, GND]):
    net GND, kind = ntGround, name = "0"
    net VP,  kind = ntPower
    net VN,  kind = ntPower
    net REF, kind = ntSignal
    net IN,  kind = ntSignal
    net OUT, kind = ntSignal
    net fb,  kind = ntSignal

    component U1, kind = "opamp", partNumber = part.partNumber:
      pin "IN+", REF, kind = ptInput
      pin "IN-", fb,  kind = ptInput
      pin "OUT", OUT, kind = ptOutput
      pin "V+",  VP,  kind = ptPower
      pin "V-",  VN,  kind = ptGround
      spec:
        gbw = part.gbw

    component CD1, kind = "capacitor", value = "100n":
      pin "1", VP, kind = ptPassive
      pin "2", GND, kind = ptPassive
    component CD2, kind = "capacitor", value = "100n":
      pin "1", VN, kind = ptPassive
      pin "2", GND, kind = ptPassive

  let legs = gainNetworks(gain, parts)
  legs.rin.build(result, "RIN", findNet(result, "IN"), findNet(result, "fb"))
  legs.rf.build(result, "RF", findNet(result, "OUT"), findNet(result, "fb"))

  exposeExtraPins(result, findComponent(result, "U1"), extra)
