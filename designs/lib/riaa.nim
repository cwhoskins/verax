## One RIAA phono equalisation channel, as a reusable subcircuit.
##
## This module exists to be *instantiated twice*. A phono stage is stereo,
## and the two channels are not merely similar -- they must match, because
## the ear hears channel imbalance long before it hears absolute deviation
## from the curve. Writing the network out twice in the design file is how
## the two drift apart: one E96 value gets corrected in one channel and not
## the other, and nothing in the design says they were meant to be the same.
##
## ## The network, and where its values come from
##
## RIAA playback is three time constants -- T1 = 3180 us, T2 = 318 us and
## T3 = 75 us -- giving
##
##     H(s) = (1 + s*T2) / ((1 + s*T1) * (1 + s*T3))
##
## The feedback network here is R7||C5 in series with R8||C6, so
##
##     Zf(s) = R7/(1 + s*R7*C5) + R8/(1 + s*R8*C6)
##
## which puts T1 = R7*C5 and T3 = R8*C6 directly, and the zero falls out of
## the combination:
##
##     T2 = (R7*T3 + R8*T1) / (R7 + R8)
##
## **T2 is therefore not free.** Fix T1 and T3 and it is decided by the
## resistor ratio alone, and the constraint works out to R7/R8 = 11.778, or
## equivalently C5 = 3.6 * C6. That single number is why published phono
## stages carry odd capacitor values instead of round ones: with C6 = 10 nF
## the partner must be 36 nF, which is 33n + 3n3 in parallel, and a designer
## who "tidies" it to 33 nF has moved T2 by 8% and tilted the whole midband.
##
## With C6 = 10 nF, C5 = 36 nF and E96 resistors:
##
##     R8 = 7.50k   -> T3 = 75.0 us    exact
##     R7 = 88.7k   -> T1 = 3193 us    +0.4%
##                  -> T2 = 318.1 us   +0.03%
##
## Measured against the standard curve (ngspice-46, relative to 1 kHz):
##
##     20 Hz    +19.03 dB   against +19.27   -0.24
##     100 Hz   +13.02 dB   against +13.09   -0.07
##     1 kHz      0 dB      reference
##     10 kHz   -13.71 dB   against -13.73   +0.03
##     20 kHz   -19.56 dB   against -19.62   +0.06
##
## Midband gain is 39.8 dB at 1 kHz -- a 5 mV moving-magnet cartridge lands
## at about 480 mV, which is line level.
##
## The 0.24 dB at 20 Hz is not network error: it is the input coupling
## capacitor and the 470 uF across the gain leg rolling the bottom off, and
## both are deliberate. A phono stage with response down to DC amplifies
## warp and rumble by 20 dB more than it amplifies music.

import nimcir/contract/dsl

proc riaaChannel*(): Netlist =
  ## Ports, in instantiation order: `IN`, `OUT`, `VP`, `VN`, `GND`.
  ##
  ## A fresh template per call rather than one shared `let`, so a caller that
  ## wants to vary a value later has somewhere to put the parameter.
  ## `graph.instantiate` deep-clones regardless, so the two channels never
  ## share a `Net` or a `Component` object.
  subckt("RIAA_CHANNEL", [IN, OUT, VP, VN, GND]):
    net GND, kind = ntGround, name = "0"
    net VP,  kind = ntPower
    net VN,  kind = ntPower
    net IN,  kind = ntSignal
    net OUT, kind = ntSignal

    net amp, kind = ntSignal              # op-amp non-inverting input
    net fb,  kind = ntSignal              # inverting node
    net f1,  kind = ntSignal              # R7/C5 to R8/C6 junction
    net ng,  kind = ntSignal              # gain leg, below Rg

    # --- cartridge loading --------------------------------------------
    # 47k is not a choice, it is the standard every moving-magnet cartridge
    # is specified into: the cartridge is an inductor, and its high-frequency
    # response is set by resonance with this resistance and the total
    # capacitance hanging on it. Change it and the cartridge's own top end
    # moves, independently of anything the RIAA network does.
    component RL, kind = "resistor", value = "47k":
      pin "1", IN, kind = ptPassive
      pin "2", GND, kind = ptPassive

    component CIN, kind = "capacitor", value = "100n":
      pin "1", IN, kind = ptPassive
      pin "2", amp, kind = ptPassive
      spec:
        package = "film"
    component RB, kind = "resistor", value = "1meg":
      pin "1", amp, kind = ptPassive
      pin "2", GND, kind = ptPassive

    # --- the amplifier -------------------------------------------------
    # `gbw` is stated, and it is not decoration. The substituted macromodel
    # defaults to 1 MHz; an NE5532 is a 10 MHz part. On a stage of 39.8 dB
    # the loop gain at 1 kHz is Aol(1k)/98, so the default costs 0.7 dB there
    # -- seven times the accuracy this network was designed to, and it would
    # have been reported as the circuit's gain rather than the model's.
    component U1, kind = "opamp", partNumber = "NE5532":
      pin "IN+", amp, kind = ptInput
      pin "IN-", fb,  kind = ptInput
      pin "OUT", OUT, kind = ptOutput
      pin "V+",  VP,  kind = ptPower
      pin "V-",  VN,  kind = ptGround
      spec:
        gbw = 10.MHz

    # --- gain leg -------------------------------------------------------
    # 100 ohm sets the midband gain against the feedback network's ~9.7k at
    # 1 kHz. The 470 uF is not decoupling: it blocks DC so the stage runs at
    # unity gain at 0 Hz and its input offset is not multiplied by 98.
    component RG, kind = "resistor", value = "100":
      pin "1", fb, kind = ptPassive
      pin "2", ng, kind = ptPassive
    component CG, kind = "capacitor", value = "470u":
      pin "1", ng, kind = ptPassive
      pin "2", GND, kind = ptPassive
      spec:
        package = "electrolytic"
        esr = 200.mohm
        esl = 5.nH

    # --- the RIAA network -----------------------------------------------
    # R7 || C5 sets T1 = 3193 us; R8 || C6 sets T3 = 75.0 us; T2 falls out
    # of the ratio. See the module header -- these four values are not
    # independent and none of them may be rounded on its own.
    component R7, kind = "resistor", value = "88.7k":
      pin "1", OUT, kind = ptPassive
      pin "2", f1, kind = ptPassive
    component C5, kind = "capacitor", value = "36n":
      pin "1", OUT, kind = ptPassive
      pin "2", f1, kind = ptPassive
      spec:
        package = "film"
    component R8, kind = "resistor", value = "7.5k":
      pin "1", f1, kind = ptPassive
      pin "2", fb, kind = ptPassive
    component C6, kind = "capacitor", value = "10n":
      pin "1", f1, kind = ptPassive
      pin "2", fb, kind = ptPassive
      spec:
        package = "film"

    # Local decoupling. It belongs in the channel, not in the parent: a
    # bypass capacitor works because it is next to the part that needs it,
    # and a stereo board has two of everything for that reason.
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
