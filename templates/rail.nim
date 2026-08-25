## A decoupled power rail, checked against an impedance target.
##
##   nimcir check <this file>
##
## What it claims: the rail sits at its nominal voltage, and its decoupling
## keeps the supply impedance under target across the band where capacitors
## are what set it. Below ~100 kHz the regulator holds the rail up and it was
## cut away at the boundary; above ~100 MHz plane capacitance and via
## inductance dominate and a netlist carries neither.

import nimcir/contract/dsl
import nimcir/verify

let d = design("rail"):
  net gnd, kind = ntGround, name = "0"
  net vdd, kind = ntPower

  # The supply. It is not simulated as ideal: `spice/models` puts a finite
  # `rout`/`lout` in series with it, because an ideal source is a dead short
  # at AC and would report this rail as 0 ohm at every frequency and pass any
  # target. The stand-in is reported as an assumption; annotate `rout`/`lout`
  # from the regulator's datasheet when the supply is what you are studying.
  component V1, kind = "voltage_source", value = "DC 3.3":
    pin "+", vdd, kind = ptPower
    pin "-", gnd, kind = ptGround

  # Bulk. `esr` and `esl` are stated rather than left to a package default,
  # because a bulk capacitor's ESR is what sets the impedance floor and
  # substituting a typical value for it invents the answer.
  component C1, kind = "capacitor", value = "22u":
    pin "1", vdd, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "tantalum"
      dielectric = "tantalum"
      voltage_rating = 10.0.V
      esr = 80.mohm
      esl = 2.5.nH

  # Ceramics. Their self-resonance is what covers the decade above the bulk
  # cap's, and their ESL is what ends it.
  component C2, kind = "capacitor", value = "10u":
    pin "1", vdd, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0805"

  component C3, kind = "capacitor", value = "100n":
    pin "1", vdd, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0402"

  component C4, kind = "capacitor", value = "100n":
    pin "1", vdd, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0402"

  # `power_rail` claims two things: that the rail sits at its nominal voltage
  # (measured with a .op) and that its decoupling holds the impedance under
  # target across the band (measured with a .ac). Omit `targetZ` and the
  # second claim is simply not made -- a decoupling target follows from the
  # load's transient current, and inventing one would manufacture a
  # requirement you never stated.
  role "power_rail", vdd_rail, rail = vdd,
       voltage = 3.3.V, band = 5.pct,
       targetZ = 250.mohm, targetFrom = 100.kHz, targetTo = 100.MHz,
       maxDerating = 0.5

quit(verifyMain(d))
