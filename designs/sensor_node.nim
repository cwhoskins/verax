## A USB-powered environmental sensor node.
##
##   verax check designs/sensor_node.nim
##
## The shape most open-hardware sensor breakouts take: USB 5 V in, a linear
## regulator down to 3.3 V, an MCU and an I2C sensor across it, and a
## ferrite-filtered analog supply for the MCU's ADC. Everything here is a
## pattern that recurs on hundreds of boards, which is what makes it worth
## having as a worked example.
##
## Four independent things are claimed: that both rails sit where they
## should, that the 3.3 V rail's decoupling meets an impedance target, that
## the rail comes up cleanly at power-on without overshooting past the MCU's
## absolute maximum, and that the I2C bus can actually run at the clock it
## is configured for.

import verax/contract/dsl
import verax/verify
import verax/spice/boundary

let d = design("sensor_node"):
  # Where the board has to work. Stated on the board because it is a fact
  # about the enclosure rather than about any part in it, and every
  # temperature-dependent answer has to hold across the whole range: a
  # ceramic loses capacitance at the hot end and an electrolytic's ESR
  # climbs at the cold one. Nothing here is temperature-dependent *yet* --
  # `netlist/environment` wires the figures up and models nothing -- so this
  # is a premise the report reads back rather than a number anything divides
  # by today.
  environment:
    t_ambient_min = 0.degC
    t_ambient_max = 70.degC

  net gnd,  kind = ntGround, name = "0"
  net vbus, kind = ntPower:                # USB VBUS
    spec:
      voltage = 5.0.V
  net vdd,  kind = ntPower:                # regulated 3.3 V
    spec:
      voltage = 3.3.V
  net vdda, kind = ntPower:                # filtered analog supply
    spec:
      voltage = 3.3.V
  net sda,  kind = ntSignal
  net scl,  kind = ntSignal

  # --- USB input --------------------------------------------------------
  # A connector, declared as one. It used to be `kind = "voltage_source"`
  # with `rout`/`lout`, which modelled what is *behind* the connector rather
  # than the connector -- the only way to say it before `spice/boundary`
  # existed, and a fair description of the host supply, but it put a part on
  # the BoM that nobody solders and left no way to say the board has an edge
  # here at all.
  #
  # A connector has no electrical model of its own: each pin touches exactly
  # one net, so there is nothing to pass through *to*, and its behaviour is
  # entirely whatever is plugged in. So the part stays a connector and what
  # is plugged into it is stated separately, at the bottom of this file.
  component J1, kind = "connector", partNumber = "USB-C":
    pin "VBUS", vbus, kind = ptPower
    pin "GND",  gnd,  kind = ptGround

  component C1, kind = "capacitor", value = "10u":
    pin "1", vbus, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0805"
  component C2, kind = "capacitor", value = "100n":
    pin "1", vbus, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0402"

  # --- regulator --------------------------------------------------------
  # `voltage` here is what this *part* puts out, which is deliberately a
  # different statement from the 3.3 V required of the `vdd` net above.
  # Fit a 5 V part by mistake and the two disagree, which is the whole
  # reason the check is worth running.
  component U1, kind = "regulator", partNumber = "AMS1117-3.3":
    pin "IN",  vbus, kind = ptPower
    pin "OUT", vdd,  kind = ptPower
    pin "GND", gnd,  kind = ptGround
    spec:
      voltage = 3.3.V
      # A linear regulator burns the difference: (5 - 3.3) V at the ~150 mA
      # this board draws is 0.26 W, and an SOT-223 on a small pour is about
      # 62 degC/W, so the part sits some 16 degC above whatever the air is.
      # Every other part on the board defaults to a rise of 0 and sits at
      # ambient; this one is stated because it does not.
      delta_t = 16.degC

  # The AMS1117 needs >= 22 uF of output capacitance to be stable. That is
  # a datasheet requirement about the regulator's *own* loop, which nothing
  # here can check -- see the note at the foot of this file.
  component C3, kind = "capacitor", value = "22u":
    pin "1", vdd, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "tantalum"
      esr = 100.mohm
      esl = 3.nH
  component C4, kind = "capacitor", value = "100n":
    pin "1", vdd, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0402"

  # --- decoupling at the loads -----------------------------------------
  component C5, kind = "capacitor", value = "100n":
    pin "1", vdd, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0402"
  component C6, kind = "capacitor", value = "1u":
    pin "1", vdd, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0603"
  component C7, kind = "capacitor", value = "100n":
    pin "1", vdd, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0402"

  # --- filtered analog supply ------------------------------------------
  # A ferrite bead, declared as one. It used to be `kind = "inductor",
  # value = "600n"` -- the inductance a 600 ohm bead has well below its
  # resonance -- because SPICE has no bead device and something had to reach
  # the deck. `spice/models.expandFerriteBeads` now builds the real
  # three-element model from the three numbers a datasheet gives, so the
  # design can say what the part *is*.
  #
  # The difference is not cosmetic. An inductor's impedance climbs without
  # limit; a bead's peaks where the core goes lossy and falls again, and that
  # peak is the whole reason a bead is here instead of an inductor. The
  # inductor model also has no DC resistance, and on a rail that is a steady
  # IR drop and a floor the filter can never get below.
  #
  # `value` is read the way a bead is sold -- 600 ohm, at the 100 MHz
  # datasheets quote -- and `dcr` is stated because this rail is one of the
  # things being checked and a defaulted DC resistance would be inventing
  # part of the answer.
  #
  # This is also why the `regulator` role below names a separate `measure`
  # net: a series impedance into a capacitor bank is a resonant circuit, and
  # judging the rail at the regulator pin would show a clean ramp and miss
  # whatever this node does.
  component FB1, kind = "ferrite_bead", value = "600":
    pin "1", vdd,  kind = ptPassive
    pin "2", vdda, kind = ptPassive
    spec:
      dcr = 350.mohm
      f_peak = 100.MHz
  component C8, kind = "capacitor", value = "1u":
    pin "1", vdda, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0603"
  component C9, kind = "capacitor", value = "100n":
    pin "1", vdda, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0402"

  # --- loads ------------------------------------------------------------
  # `zin` on the supply pins is how a part with no model states what it
  # draws: 33 ohm at 3.3 V is 100 mA. Without it every unmodelled pin is
  # stood in for at 1 Mohm and the rail is effectively unloaded, which
  # flatters both the start-up ramp and the impedance sweep.
  component U2, kind = "mcu", partNumber = "STM32G071":
    pin "VDD",  vdd,  kind = ptPower, zin = "47"
    pin "VDDA", vdda, kind = ptPower, zin = "330"
    pin "VSS",  gnd,  kind = ptGround
    pin "SDA",  sda,  kind = ptInOut
    pin "SCL",  scl,  kind = ptInOut

  component U3, kind = "sensor", partNumber = "BME280":
    pin "VDD", vdd, kind = ptPower, zin = "8250"
    pin "GND", gnd, kind = ptGround
    pin "SDA", sda, kind = ptInOut
    pin "SCL", scl, kind = ptInOut

  # --- I2C pull-ups -----------------------------------------------------
  # 2.2k is the reflexive choice and it does not survive 400 kHz against
  # the bus capacitance assumed for four pins; nor does 1.5k, which lands
  # at 3.5 MHz against the 4 MHz the role wants. 1.2k does.
  #
  # Note what bounds this from the *other* side and is not checked here: an
  # I2C target must pull the line to 0.4 V while sinking 3 mA, so at 3.3 V
  # the pull-up may not go below about 1.1k. 1.2k is deliberately close to
  # that floor, and nothing in this build will tell you when you cross it.
  component R1, kind = "resistor", value = "1.2k":
    pin "1", vdd, kind = ptPassive
    pin "2", sda, kind = ptPassive
  component R2, kind = "resistor", value = "1.2k":
    pin "1", vdd, kind = ptPassive
    pin "2", scl, kind = ptPassive

  # --- claims -----------------------------------------------------------

  role "power_rail", usb, rail = vbus, voltage = 5.0.V, band = 5.pct

  role "power_rail", core, rail = vdd,
       voltage = 3.3.V, band = 5.pct,
       targetZ = 200.mohm, targetFrom = 100.kHz, targetTo = 100.MHz

  # One `.tran` answers all five of these: the planner batches every claim
  # sharing a regulator and a judged net into a single run.
  #
  # `measure = vdda` is what makes them mean anything. The rail is judged
  # past FB1, not at the regulator pin -- an inductance into a capacitor
  # bank is a resonant circuit, and the pin would show a clean ramp while
  # the load end rings. It also decides the isolation's seed set: name the
  # regulator's own output instead and `vdda` stops being a seed, gets
  # stood up as a stiff 3.3 V source, and drives current backwards through
  # FB1 into a rail still at zero -- 2.8 kA of reported inrush against a
  # real 163 mA.
  role "regulator", ramp, regulator = U1, output = vdd, measure = vdda,
       voltage = 3.3.V, band = 5.pct, maxOvershoot = 10.0,
       maxInrush = 2.0.A, maxRiseTime = 10.ms, maxSettleTime = 20.ms

  role "i2c", bus, sda = sda, scl = scl, pullupRail = vdd,
       controller = U2, frequency = 400.kHz

  require dc_voltage(vdda) == 3.3.V, band = 2.pct,
          id = "REQ-SN-VDDA-001",
          because = "the ferrite carries the ADC supply current, and any " &
                    "drop across it lands directly on the ADC reference"


# What is on the other side of the USB connector. A host port is not a bench
# supply: 100 mohm of cable and connector resistance is optimistic for a metre
# of bus-powered cable, and the inductance is what makes C1 necessary rather
# than decorative. Stated here rather than as a fake part on the board, and
# recorded on the pin itself -- so the design netlist still describes what
# gets soldered while the simulation sees the supply behind it.
driveConnector(findComponent(d.netlist, "J1"),
               {"VBUS": driveSource(5.0.V, rout = 100.mohm, lout = 2.uH)})

quit(verifyMain(d))
