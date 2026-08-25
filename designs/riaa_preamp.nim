## A stereo RIAA phono preamplifier: two identical channels, +-15 V.
##
##   nimcir check designs/riaa_preamp.nim
##
## The first design here that is not one file. The equalisation network lives
## in `designs/lib/riaa.nim` as a `subckt` and is instantiated twice, which is
## what a stereo board is: not two similar circuits, but one circuit built
## twice. That distinction is the entire reason this design exists.
##
## Channel matching is the specification that matters. A phono stage that is
## 0.5 dB off the RIAA curve sounds like a tone control; one whose channels
## differ by 0.5 dB sounds like the image has moved, which is far more
## audible. Two copies of one `subckt` cannot drift, because there is only
## one set of values. Two copies of the same netlist statements can, and do:
## somebody corrects an E96 value in the left channel at 2am.
##
## What each channel does, and where the numbers come from, is documented in
## `designs/lib/riaa.nim` -- including why C5 must be 3.6 times C6 and why
## that is the constraint that makes published phono stages carry odd
## capacitor values.
##
## Measured (relative to 1 kHz, midband gain 39.8 dB):
##
##     20 Hz    +19.03 dB   against the RIAA standard's +19.27
##     100 Hz   +13.02 dB                               +13.09
##     10 kHz   -13.71 dB                               -13.73
##     20 kHz   -19.56 dB                               -19.62

import nimcir/contract/dsl
import nimcir/verify

import ./lib/riaa

let d = design("riaa_preamp"):
  # `global = true` so both instances share this one object rather than each
  # cloning a private ground -- the same reason SPICE reserves node "0".
  net gnd, kind = ntGround, name = "0", global = true

  net vp, kind = ntPower:
    spec:
      voltage = 15.0.V
  net vn, kind = ntPower:
    spec:
      voltage = -15.0.V

  net inL,  kind = ntSignal
  net outL, kind = ntSignal
  net inR,  kind = ntSignal
  net outR, kind = ntSignal

  # --- supplies ---------------------------------------------------------
  component V1, kind = "voltage_source", value = "DC 15":
    pin "+", vp, kind = ptPower
    pin "-", gnd, kind = ptGround
    spec:
      voltage = 15.0.V
  component V2, kind = "voltage_source", value = "DC -15":
    pin "+", vn, kind = ptPower
    pin "-", gnd, kind = ptGround
    spec:
      voltage = -15.0.V

  # Bulk reservoirs, shared. The per-channel 100 n bypasses live inside the
  # channel, next to the amplifier that needs them.
  component C1, kind = "capacitor", value = "220u":
    pin "1", vp, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "electrolytic"
      esr = 150.mohm
      esl = 6.nH
  component C2, kind = "capacitor", value = "220u":
    pin "1", vn, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "electrolytic"
      esr = 150.mohm
      esl = 6.nH

  # --- the two channels -------------------------------------------------
  # Port order is the order `riaaChannel`'s `subckt` declares: IN, OUT, VP,
  # VN, GND. It is positional, and a miscount raises at instantiation rather
  # than producing a quietly miswired board.
  instance XL, riaaChannel(), [inL, outL, vp, vn, gnd]
  instance XR, riaaChannel(), [inR, outR, vp, vn, gnd]

  # --- claims -----------------------------------------------------------

  role "power_rail", pos, rail = vp, voltage = 15.0.V, band = 5.pct,
       targetZ = 500.mohm, targetFrom = 100.kHz, targetTo = 10.MHz
  role "power_rail", neg, rail = vn, voltage = -15.0.V, band = 5.pct

  # What a phono stage is specified by: the gain at 1 kHz, and the curve
  # either side of it. `gain_stage`'s `atF` moves the gain claim onto
  # `gain_at_f`, which is the only quantity that answers "what is the gain at
  # exactly this frequency" -- and which nothing in this repository has ever
  # used, because until there was a circuit specified that way there was no
  # reason to.
  #
  # The op-amp being bound here lives *inside* the instance.
  role "gain_stage", left, opamp = XL.innerComponent("U1"),
       input = inL, output = outL,
       atF = 1.kHz, minGain = 39.0.dB, maxGain = 40.5.dB
  role "gain_stage", right, opamp = XR.innerComponent("U1"),
       input = inR, output = outR,
       atF = 1.kHz, minGain = 39.0.dB, maxGain = 40.5.dB

quit(verifyMain(d))
