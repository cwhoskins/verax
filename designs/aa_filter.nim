## A 4th-order Butterworth anti-aliasing filter, 20 kHz, split rails.
##
##   nimcir check designs/aa_filter.nim
##
## Two unity-gain Sallen-Key sections in cascade, the standard front end for
## an audio-band ADC. It is here as the deliberate *contrast* to
## `ts808_drive.nim`: that stage is AC coupled, so its gain at DC is unity by
## design and the bandwidth and peaking figures do not mean what their names
## suggest. This one is DC coupled and low-pass, which is the shape those
## quantities were defined for, so `bw_3db` really is the corner and
## `peaking_db` really is peaking.
##
## The design is also a check on whether a *cascade* is measured correctly.
## Neither section is Butterworth on its own -- the first is damped
## (Q = 0.549) and the second is peaky (Q = 1.291) -- and only the product of
## the two is maximally flat. A tool that measured one section and reported
## it as the filter's response would show 3 dB of peaking that the real
## board does not have.
##
## It is also where `without` earns its keep. `opamp_stage` claims a phase
## margin unconditionally, and `analyzeLoopGain` cannot open a Sallen-Key's
## loop -- C1 returns to the output, so a second feedback path stays closed
## across the break. Each stage declines that one claim rather than carrying
## it unchecked in every run.

import nimcir/contract/dsl
import nimcir/verify

import ./lib/opamps

# U1A and U1B are the two halves of one dual op-amp. Nothing about the deck
# changes -- `idealOpAmp` never connected to the rails -- but the board now
# gets one placement and one BoM line, and `validatePackages` checks the two
# sections share their supply pins.
let u1 = packageInstance("OPA1642", "U1")

let d = design("aa_filter"):
  net gnd, kind = ntGround, name = "0"
  net vcc, kind = ntPower:
    spec:
      voltage = 5.0.V
  net vee, kind = ntPower:
    spec:
      voltage = -5.0.V

  net vin,  kind = ntSignal                # filter input
  net na,   kind = ntSignal                # section 1, R1/R2/C1 junction
  net nb,   kind = ntSignal                # section 1, + input
  net vo1,  kind = ntSignal                # section 1 output
  net nc,   kind = ntSignal                # section 2, R3/R4/C3 junction
  net nd,   kind = ntSignal                # section 2, + input
  net vout, kind = ntSignal                # filter output

  # --- supplies ---------------------------------------------------------
  component V1, kind = "voltage_source", value = "DC 5":
    pin "+", vcc, kind = ptPower
    pin "-", gnd, kind = ptGround
    spec:
      voltage = 5.0.V
  component V2, kind = "voltage_source", value = "DC -5":
    pin "+", vee, kind = ptPower
    pin "-", gnd, kind = ptGround
    spec:
      voltage = -5.0.V

  component C10, kind = "capacitor", value = "10u":
    pin "1", vcc, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0805"
  component C11, kind = "capacitor", value = "100n":
    pin "1", vcc, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0402"
  component C12, kind = "capacitor", value = "10u":
    pin "1", vee, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0805"
  component C13, kind = "capacitor", value = "100n":
    pin "1", vee, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0402"

  # --- input bias -------------------------------------------------------
  # Split rails mean the signal is referenced to ground and the whole chain
  # is DC coupled. This resistor is what gives the input a DC path when
  # nothing is plugged in; without it the + input floats.
  component R9, kind = "resistor", value = "100k":
    pin "1", vin, kind = ptPassive
    pin "2", gnd, kind = ptPassive

  # --- section 1: f0 = 21.3 kHz, Q = 0.549 ------------------------------
  component R1, kind = "resistor", value = "10k":
    pin "1", vin, kind = ptPassive
    pin "2", na, kind = ptPassive
  component R2, kind = "resistor", value = "10k":
    pin "1", na, kind = ptPassive
    pin "2", nb, kind = ptPassive
  component C1, kind = "capacitor", value = "820p":
    pin "1", na, kind = ptPassive
    pin "2", vo1, kind = ptPassive
    spec:
      package = "0402"
  component C2, kind = "capacitor", value = "680p":
    pin "1", nb, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0402"

  component U1A, kind = "opamp", partNumber = "OPA1642":
    pin "IN+", nb,  kind = ptInput
    pin "IN-", vo1, kind = ptInput
    pin "OUT", vo1, kind = ptOutput
    pin "V+",  vcc, kind = ptPower
    pin "V-",  vee, kind = ptPower

  # --- section 2: f0 = 18.7 kHz, Q = 1.291 ------------------------------
  component R3, kind = "resistor", value = "10k":
    pin "1", vo1, kind = ptPassive
    pin "2", nc, kind = ptPassive
  component R4, kind = "resistor", value = "10k":
    pin "1", nc, kind = ptPassive
    pin "2", nd, kind = ptPassive
  component C3, kind = "capacitor", value = "2.2n":
    pin "1", nc, kind = ptPassive
    pin "2", vout, kind = ptPassive
    spec:
      package = "0402"
  component C4, kind = "capacitor", value = "330p":
    pin "1", nd, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0402"

  component U1B, kind = "opamp", partNumber = "OPA1642":
    pin "IN+", nd,   kind = ptInput
    pin "IN-", vout, kind = ptInput
    pin "OUT", vout, kind = ptOutput
    pin "V+",  vcc,  kind = ptPower
    pin "V-",  vee,  kind = ptPower

  # --- claims -----------------------------------------------------------

  role "power_rail", pos, rail = vcc, voltage = 5.0.V, band = 5.pct
  role "power_rail", neg, rail = vee, voltage = -5.0.V, band = 5.pct

  # Every stage below declines `phase_margin`, and the reason is a property
  # of Sallen-Key rather than of this board. `analyzeLoopGain` breaks the
  # loop at the amplifier's inverting input, which opens the only feedback
  # path a plain amplifier has. A Sallen-Key has two: C1 returns to the
  # *output*, and that positive path is what produces the section's Q. It
  # stays closed across the break, so the sweep is not a loop transmission
  # and the tool says so and withholds the margin -- correctly. Carrying
  # three claims that can only ever come back unchecked would put permanent
  # noise in the one section that must stay worth reading.
  #
  # What is left is measured, and for this filter it is the right question:
  # unlike an AC-coupled audio stage, this one is DC coupled, so `bw_3db`
  # and `peaking_db` mean exactly what their names say.

  # The filter end-to-end. This is the claim worth making, and it needs
  # every amplifier in the path to be modelled -- an analysis names one, and
  # any other op-amp used to fall through to per-pin impedances, which
  # destroyed the path through U1A and reported 82 dB of peaking against a
  # response that is flat to 20 kHz.
  #
  # 19.7 kHz and flat to well under a dB, which is the alignment: neither
  # section is Butterworth alone and only their product is maximally flat.
  role "opamp_stage", filt, opamp = U1B, input = vin, output = vout,
       minBandwidth = 18.kHz, maxPeaking = 1.dB,
       without = "phase_margin"

  # The sections on their own, which is where a mis-stuffed capacitor shows
  # up. Section 1 is damped: Q = 0.549 puts its own -3 dB corner at 15.6 kHz
  # and it cannot peak at all, because Q is below 0.707.
  role "opamp_stage", sec1, opamp = U1A, input = vin, output = vo1,
       minBandwidth = 15.kHz, maxPeaking = 0.2.dB,
       without = "phase_margin"

  # Section 2 is the peaky one: Q = 1.291 peaks about 2.9 dB, and that is
  # the alignment rather than a fault -- section 1's roll-off is what
  # cancels it. Its bandwidth is deliberately unclaimed, because a section's
  # own corner in a cascade is not a specification, only the pair's is.
  role "opamp_stage", sec2, opamp = U1B, input = vo1, output = vout,
       maxPeaking = 3.5.dB,
       without = "phase_margin"

u1.assign(d.netlist, "A", "U1A")
u1.assign(d.netlist, "B", "U1B")

quit(verifyMain(d))
