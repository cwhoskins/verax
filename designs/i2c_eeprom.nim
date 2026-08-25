## An I2C EEPROM on a bus, and a controller that actually talks to it.
##
##   nimcir check designs/i2c_eeprom.nim
##
## Every other design here asks what a circuit *is*: where a rail sits, what
## a stage's gain is, how much impedance a decoupling network presents. This
## one asks whether two parts can hold a conversation. A dummy MCU reads the
## 128-bit unique ID out of an M24C64-U's identification page, writes four
## bytes to the memory array, polls the acknowledge through the part's write
## cycle, reads them back, and drives a verdict pin high only if every byte
## matched. That verdict is a claim in the readiness report like any other.
##
## Both parts are Nim-authored XSPICE code models
## (`designs/lib/m24c64.nim`, `designs/lib/dummy_mcu.nim`), attached to the
## real components by `designs/lib/i2c_parts.nim` and never appearing in the
## design netlist itself -- so a BoM, a layout or `nimcir explain` still sees
## an EEPROM and a microcontroller.
##
## ### What is mixed-signal about it
##
## SDA and SCL are **real analog nets**: R1/R2 are the pull-ups, C1/C2 stand
## for the bus capacitance, and a `bidi_bridge` sits between each line and the
## digital node the two models share. When every driver releases, the bridge
## stops driving and the line rises on the RC; when one pulls down, it sits at
## a real VOL. Nothing about the protocol requires that -- the same models run
## on a pure digital bus in `tests/test_xspice_i2c_eeprom.nim`, which is the
## fast regression -- but two things follow from it that a logic simulation
## cannot give:
##
## * the `i2c` role's claims have resistors to find, so `pullup_count`,
##   `rc_corner` and `pullup_sink_current` are about this circuit rather than
##   about an empty net; and
## * the transaction is being carried by a bus with real edges on it, so a
##   pull-up too weak for the capacitance would show up as a failed exchange
##   rather than only as a static arithmetic warning.
##
## ### Why 100 kHz and 1.5k
##
## The `i2c` role asks the RC corner to clear the bus clock by ten times.
## `static.rc_corner` computes it from the pull-ups in parallel against every
## capacitor on the line **plus an assumed 10 pF for each connected pin** --
## four pins a line here, so 40 pF on top of the 47 pF stated. 1.5k against
## 87 pF is 1.22 MHz, which clears 100 kHz by twelve times; and the pull-up
## has to sink (3.3 - 0.4)/1500 = 1.93 mA, inside the specification's 3 mA.
##
## At 400 kHz the same rule wants 4 MHz, which needs a pull-up around 460 R --
## and that sinks 6.3 mA, past what a target is required to be able to pull
## down. This board is 100 kHz because two devices and a 3 mA budget do not
## leave room for more, which is the trade the arithmetic above is for.
##
## **The static figure and the simulated one do not use the same capacitance,
## and that is worth knowing rather than hiding.** Only the 47 pF is in the
## netlist, so ngspice sees 1.5k against 47 pF while the static check sees
## 87 pF. The static one is the conservative of the two, because a netlist
## carries neither trace nor device pin capacitance and `static.rc_corner`
## says out loud that it made that figure up.
##
## Measured on this bus: SCL rises through 0.3 Vdd to 0.7 Vdd in **60 ns**
## against the specification's 1 us limit for standard mode, and a pulled-down
## line bottoms out at **43 mV** against a 400 mV VOL budget. Neither of those
## is claimed, because no registered quantity fits -- `rise_time_10_90`
## belongs to `spice.startup` and wants a regulator binding. That is the
## obvious next thing to want out of this design, and it is what would turn
## `rc_corner`'s invented per-pin capacitance into something measured.
##
## ### What is *not* claimed
##
## No timing claim. The models react to edges and never check that two of them
## were far enough apart, so nothing here would notice a setup or hold
## violation. No claim about the bus while the write cycle is running, because
## the MCU is polling and the line is busy by design rather than settled.
##
## Note this design needs `-d:xspiceSpecOnly` to compile, which `nimcir check`
## passes for you; a bare `nim c -r --path:./src designs/i2c_eeprom.nim` needs
## it spelled out, or it tries to build the code models' FFI against ngspice
## headers it has no reason to need.

import nimcir/contract/dsl
import nimcir/verify
import nimcir/spice/boundary

import ./lib/i2c_parts

const
  partUid = "a1b2c3d4e5f60718293a4b5c6d7e8f90"
    ## What this particular part left the factory with. A unique ID is
    ## per-device by definition, so it is stated here and passed to *both*
    ## models -- the EEPROM returns it, the controller expects it. Give them
    ## different strings and `xact.verdict` fails, which is how the claim was
    ## shown to be capable of failing at all.

let d = design("i2c_eeprom"):
  environment:
    t_ambient_min = -20.degC
    t_ambient_max = 70.degC

  net gnd, kind = ntGround, name = "0"
  net vdd, kind = ntPower:
    spec:
      voltage = 3.3.V
  net sda, kind = ntSignal
  net scl, kind = ntSignal
  net xact_done, kind = ntSignal
  net xact_pass, kind = ntSignal

  # --- supply -----------------------------------------------------------
  # A header, declared as one. What is plugged into it is stated at the
  # bottom of this file: a connector has no electrical behaviour of its own,
  # since each pin touches exactly one net and what it does is entirely
  # whatever is on the other side.
  component J1, kind = "connector", partNumber = "2p-header":
    pin "VDD", vdd, kind = ptPower
    pin "GND", gnd, kind = ptGround

  component C3, kind = "capacitor", value = "100n":
    pin "1", vdd, kind = ptPassive
    pin "2", gnd, kind = ptGround
    spec:
      package = "0402"
      dielectric = "X7R"
      voltage_rating = 16.0.V

  # --- the bus ----------------------------------------------------------
  # 1.5k rather than the reflexive 4.7k: see the arithmetic in the header.
  # Both values are load-bearing and neither is a default.
  component R1, kind = "resistor", value = "1.5k":
    pin "1", vdd, kind = ptPassive
    pin "2", sda, kind = ptPassive
    spec:
      tolerance = 1.pct
  component R2, kind = "resistor", value = "1.5k":
    pin "1", vdd, kind = ptPassive
    pin "2", scl, kind = ptPassive
    spec:
      tolerance = 1.pct

  # The bus capacitance, lumped. Not a part anybody buys -- it stands for the
  # traces and the two devices' pin capacitance, which is why it is stated
  # rather than left to `static.rc_corner`'s per-pin assumption alone. C0G
  # because the point of it is to be a known capacitance: a Class 2 dielectric
  # would be derated against its DC bias by `spice/models` and would move the
  # very number this part exists to state.
  component C1, kind = "capacitor", value = "47p":
    pin "1", sda, kind = ptPassive
    pin "2", gnd, kind = ptGround
    spec:
      package = "0402"
      dielectric = "C0G"
      voltage_rating = 50.0.V
  component C2, kind = "capacitor", value = "47p":
    pin "1", scl, kind = ptPassive
    pin "2", gnd, kind = ptGround
    spec:
      package = "0402"
      dielectric = "C0G"
      voltage_rating = 50.0.V

  # --- the two talkers --------------------------------------------------
  component U1, kind = "mcu", partNumber = "dummy-i2c-controller":
    pin "VDD", vdd, kind = ptPower
    pin "VSS", gnd, kind = ptGround
    pin "SDA", sda, kind = ptInOut
    pin "SCL", scl, kind = ptInOut
    pin "DONE", xact_done, kind = ptOutput
    pin "PASS", xact_pass, kind = ptOutput

  component U2, kind = "eeprom", partNumber = "M24C64-U":
    pin "VCC", vdd, kind = ptPower
    pin "VSS", gnd, kind = ptGround
    pin "SDA", sda, kind = ptInOut
    pin "SCL", scl, kind = ptInOut
    # Tied low: this board uses device select 000 and never write-protects.
    # Declared even though the model ignores WC, because the netlist should
    # describe the part that gets soldered.
    pin "E0", gnd, kind = ptInput
    pin "E1", gnd, kind = ptInput
    pin "E2", gnd, kind = ptInput
    pin "WC", gnd, kind = ptInput

  # --- where the verdict lands ------------------------------------------
  # Test points, pulled down so they read as "not yet" rather than as
  # whatever the board powered up into. They are also what gives each node a
  # DC path: the `dac_bridge` that carries the controller's flags out of the
  # digital domain is a simulation-only part, and a node with nothing else on
  # it would be one the solver has no equation for.
  component R3, kind = "resistor", value = "100k":
    pin "1", xact_done, kind = ptPassive
    pin "2", gnd, kind = ptGround
  component R4, kind = "resistor", value = "100k":
    pin "1", xact_pass, kind = ptPassive
    pin "2", gnd, kind = ptGround

  # --- claims -----------------------------------------------------------
  role "power_rail", core, rail = vdd, voltage = 3.3.V, band = 5.pct

  # `controller` is what tells the check which part drives the bus: every
  # device on I2C has an inout data pin and nothing in a netlist
  # distinguishes the controller from a target.
  role "i2c", bus, sda = sda, scl = scl, pullupRail = vdd,
       controller = U1, frequency = 100.kHz

  # The window opens at 9 ms because the exchange finishes at about 8.26 --
  # roughly 2 ms of protocol at 100 kHz either side of the 5 ms the part
  # spends on its write cycle, which the controller spends acknowledge-polling
  # through. Everything before 9 ms is simulated and discarded.
  role "i2c_transaction", xact,
       done = xact_done, verdict = xact_pass,
       tSettle = 9.0.ms, tWindow = 1.0.ms,
       rail = 3.3.V, band = 10.pct

# The bus is analog, so each line reaches the device models through a
# `bidi_bridge` rather than being driven as a digital node. Said about the
# *nets* rather than passed to either device, because it is a property of the
# bus and both devices on it have to agree.
markAnalogBus(d, "sda", "scl")

useM24C64(d, "U2", uid = partUid)
useDummyMcu(d, "U1", uid = partUid)

driveConnector(findComponent(d.netlist, "J1"),
               {"VDD": driveSource(3.3.V, rout = 50.mohm, lout = 1.uH)})

quit(verifyMain(d))
