## A single-stage Dickson charge pump: 5 V in, about 9.6 V out, no inductor.
##
##   verax check designs/charge_pump.nim
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
## Measured (ngspice-46, 20 ms to settle, then a 100 us window):
##
##   VOUT      9.5185 V   against the 5 + 5 - 2*0.24 the topology predicts
##   ripple    403 mV     of which 7.9 mV is the droop the arithmetic gives
##                        and the rest is an edge spike across COUT's ESR
##                        and ESL -- see the note above the claim below
##
## Both come from `settled_rail`, the role that binds no driving part. This
## design is where the need for one was found: there is no regulator here to
## stand up as a ramp and no amplifier to drive, so every other .tran-backed
## claim in the library was out of reach, and the .op behind `dc_voltage`
## answers a question nobody asked. See the note above the claim.

import verax/contract/dsl
import verax/verify

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

  # COUT sets the droop, and only the droop: the load draws continuously and
  # is replenished once per cycle, so dV = I*t/C over the half cycle D2 is
  # not conducting. At 9.5 mA and 5 us that is 7.3 mV against the 6.5 uF
  # this part has at 9.5 V -- measured 7.9 mV. Note both halves of that
  # arithmetic: the discharge is half a period rather than a whole one, and
  # the capacitance is the derated figure rather than the label. Using
  # I/(f*C) with the nominal 10 uF gives 9.4 mV, which is right by accident
  # -- the two errors are in opposite directions and nearly cancel.
  #
  # What COUT does *not* set is the 403 mV spike at each clock edge, which
  # is its ESR and ESL rather than its capacitance. See the claim below.
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

  # The claim the pump exists for, and the reason it took a new role to make.
  #
  # **Do not write `require dc_voltage(vout) == 9.52.V`.** `dc_voltage` is
  # backed by a **.op**, and a .op takes a PULSE source at its DC value --
  # 0 V. So nothing pumps, D1 and D2 sit in series from VIN, and the tool
  # reports **4.64 V**. That figure is not noise and it is not a refusal: it
  # is exactly 5 - 2*0.18, a perfectly correct answer to a question nobody
  # asked, delivered as a FAIL against a real number. A designer who trusts
  # the machinery widens the band until it passes and ships a rail 51% low.
  #
  # `settled_rail` asks the other question -- run the circuit, and once it
  # has stopped changing, tell me what this node is doing. It binds no
  # driving part, which is why it reaches a circuit that has none: there is
  # no regulator here to stand up as a ramp and no amplifier to drive.
  #
  # `tSettle` is 20 ms, which is what COUT takes to charge through two diode
  # drops at this pump current. It is a **condition** on the claim rather
  # than a limit -- the answer is a function of it -- and so is the 100 us
  # window, ten whole clock cycles, so the peak-to-peak is taken over whole
  # periods of the thing that makes the ripple.
  role "settled_rail", pumped, rail = vout,
       tSettle = 20.0.ms, tWindow = 100.0.us,
       voltage = 9.52.V, band = 2.pct, maxRipple = 500.0.mV

  # 500 mV, against the 9.4 mV the arithmetic above predicts, and the gap is
  # the finding rather than a slack budget.
  #
  # Measured over the window the rail sits at 9.5185 V and does two separate
  # things on top of it:
  #
  #   * it droops and recharges by **7.9 mV** once per clock cycle, which is
  #     the I*t/C of the note above COUT and is the only part of this figure
  #     the topology predicts; and
  #   * it takes a **403 mV** spike a couple of nanoseconds wide at each
  #     clock edge, one up and one down. A spike that narrow is sampling-
  #     sensitive by nature -- the same deck printed at 1 ns rather than the
  #     100 ns this window derives reads 387 mV -- which is another reason
  #     the budget is not set at the measured figure.
  #
  # The spike is fifty times the droop and it is entirely the output
  # capacitor's parasitics: C1's plate is stepped 5 V in 10 ns, so the pump
  # current is limited only by the diodes' RS and the two ESRs -- about
  # 100 mohm all told, tens of amps for a few nanoseconds -- and that current
  # crosses COUT's 10 mohm ESR and 1.2 nH ESL on its way in. An ideal
  # capacitor has neither, which is why a hand-run of this same deck with
  # nominal capacitors reports 5.1 mV and reports nothing about the spike.
  #
  # What it would take to make the smaller number the true one is a clock
  # with a real driver behind it. A 10 ns edge into 1 uF is not something an
  # MCU pin or a logic gate can do: 25 ohm of output impedance stretches the
  # edge to a microsecond and the spike goes with it. That impedance is not
  # in this netlist because the design states the clock as an ideal source
  # and says so above -- which was a fair simplification for the question
  # "what does VOUT settle to" and turns out to *set the answer* to "what is
  # still moving on it". The claim is stated against the circuit as authored.

quit(verifyMain(d))
