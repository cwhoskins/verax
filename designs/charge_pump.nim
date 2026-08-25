## A single-stage Dickson charge pump: 5 V in, about 9.6 V out, no inductor.
##
##   nimcir check designs/charge_pump.nim
##
## The circuit that generates a gate-drive rail, an EEPROM programming rail
## or a bias for an op-amp that needs a little headroom above its supply,
## on a board that cannot afford a magnetic. Two diodes and two capacitors.
##
## It is here because it is unlike everything else under `designs/`. There is
## no op-amp, no feedback and no small-signal anything: a charge pump has no
## meaningful operating point, because the whole circuit *is* the switching.
## Linearise it about any instant and you get either a diode that conducts
## and one that does not, which is a different circuit each half cycle.
##
## How it works, and why the diode is the specification:
##
##   * When CLK is low, D1 conducts and C1 charges to VIN - Vf.
##   * When CLK goes high, C1's bottom plate is lifted by the full clock
##     swing, so node A sits at VIN - Vf + Vclk, D1 reverse-biases, D2
##     conducts and dumps the difference into COUT.
##
## So VOUT = VIN + Vclk - 2*Vf, and *nothing else sets it*. There is no
## regulation loop, no reference and no feedback -- the output is the input
## plus the clock swing minus exactly two forward drops. That is why this
## design uses Schottkys and says so: 1N4148s in the same sockets would give
## 5 + 5 - 2*0.7 = 8.6 V instead of 9.6 V, an 11% error introduced by a part
## substitution that looks harmless on a BoM.
##
## What it cannot claim, and why that is the point of including it: see the
## note above the requirements at the bottom of this file.

import nimcir/contract/dsl
import nimcir/verify

import ./lib/parts

let d = design("charge_pump"):
  net gnd,  kind = ntGround, name = "0"
  net vin,  kind = ntPower:                # the 5 V rail being pumped
    spec:
      voltage = 5.0.V
  net clk,  kind = ntSignal                # 100 kHz square drive
  net a,    kind = ntSignal                # pump node: C1 / D1 / D2 junction
  net vout, kind = ntPower:                # pumped output
    spec:
      voltage = 9.52.V

  # --- the 5 V rail it pumps from ---------------------------------------
  component V1, kind = "voltage_source", value = "DC 5":
    pin "+", vin, kind = ptPower
    pin "-", gnd, kind = ptGround
    spec:
      voltage = 5.0.V

  component C10, kind = "capacitor", value = "10u":
    pin "1", vin, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0805"
  component C11, kind = "capacitor", value = "100n":
    pin "1", vin, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0402"

  # --- the clock --------------------------------------------------------
  # 100 kHz, 0 to 5 V, 10 ns edges. On a real board this is an MCU timer pin
  # or a spare gate; here it is a source, because what the pump does with the
  # edge is the subject and what makes the edge is not.
  #
  # `value` reaches the deck verbatim -- the annotation registry documents
  # this key as never parsed as a number for exactly this reason, since
  # "PULSE(...)" is a whole source spec and not a magnitude.
  component V2, kind = "voltage_source", value = "PULSE(0 5 0 10n 10n 4.99u 10u)":
    pin "+", clk, kind = ptOutput
    pin "-", gnd, kind = ptGround

  # --- the pump ---------------------------------------------------------
  model d1N5819, d1N5819Card

  # C1 is the pump capacitor and its value sets the *available current*, not
  # the voltage: each cycle moves C1*(Vclk - ripple) coulombs, so 1 uF at
  # 100 kHz carries about 0.5 A of theoretical maximum. Undersize it and the
  # output sags under load rather than reading low at no load, which is the
  # failure that looks like a bad diode and is not.
  component C1, kind = "capacitor", value = "1u":
    pin "1", clk, kind = ptPassive
    pin "2", a, kind = ptPassive
    spec:
      package = "0805"

  component D1, kind = "diode", partNumber = d1N5819, value = d1N5819:
    pin "A", vin, kind = ptPassive
    pin "K", a, kind = ptPassive
  component D2, kind = "diode", partNumber = d1N5819, value = d1N5819:
    pin "A", a, kind = ptPassive
    pin "K", vout, kind = ptPassive

  # COUT sets the ripple and nothing else: the load draws continuously and
  # is replenished once per cycle, so dV = I/(f*C). At 9.4 mA, 100 kHz and
  # 10 uF that is 9.4 mV.
  component C2, kind = "capacitor", value = "10u":
    pin "1", vout, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "1206"

  component R1, kind = "resistor", value = "1k":
    pin "1", vout, kind = ptPassive
    pin "2", gnd, kind = ptPassive

  # --- claims -----------------------------------------------------------

  role "power_rail", supply, rail = vin,
       voltage = 5.0.V, band = 5.pct

  # And there the claims stop, which is the finding.
  #
  # VOUT is VIN plus the clock swing minus two Schottky drops. Measured with
  # a .tran and left to settle (ngspice-46, 20 ms) it is **9.518 V with
  # 5.1 mV of ripple**, which is the 5 + 5 - 2*0.24 the topology predicts.
  #
  # The obvious claim is `require dc_voltage(vout) == 9.52.V`. Do not write
  # it. `dc_voltage` is backed by a **.op**, and a .op takes a PULSE source
  # at its DC value -- 0 V. So nothing pumps, D1 and D2 sit in series from
  # VIN, and the tool reports **4.64 V**. That figure is not noise and it is
  # not a refusal: it is exactly 5 - 2*0.18, a perfectly correct answer to a
  # question nobody asked, delivered as a FAIL against a real number. A
  # designer who trusts the machinery widens the band until it passes and
  # ships a rail 51% low.
  #
  # The gap is structural: **every .tran-backed quantity is reachable only
  # through a role that binds a driving part.** `regulator` wants a regulator
  # component to stand up as a soft-start ramp; `large_signal` wants an
  # op-amp and an input to drive. A charge pump has neither, so nothing can
  # ask "run this circuit and tell me what this node settles to".
  #
  # `designs/wien_osc.nim` reaches the same wall from the other side: an
  # oscillator's frequency, amplitude and THD are all .tran quantities and it
  # has no driving part to bind either. Two circuits, one missing piece --
  # see docs/findings.md for the shape it should take.
  #
  # No claim is made rather than one that reports NOT CHECKED on every run:
  # that section is the one that must not become background noise.

quit(verifyMain(d))
