## A minimal RF transmit/receive front end: an antenna SMA, a 50 ohm
## microstrip, an SPDT T/R switch, and a gain block on the receive side.
##
##   verax check designs/rf_trx.nim
##
##   J1 (ANT) -- TL1 -- C_ANT -- U1 RFC
##                                U1 RF1 (RX) -- C_IN -- U2 gain block -- C_OUT -- J3 (RX OUT)
##                                U1 RF2 (TX) -- C_TX -- J2 (TX IN)
##
## The gain block is a 50 ohm Darlington MMIC biased through its own output:
## 5 V through a load switch (U3, on only in receive), a ferrite bead (FB1),
## the bias resistor and an RF choke (L_CHOKE). The board takes 5 V through a
## common-mode choke (L1) at its DC input.
##
## ## What this design is for
##
## It carries the RF annotation vocabulary on the parts it describes, each
## where a datasheet would put it: `z0`/`return_loss_db` on the connectors;
## the microstrip's geometry and substrate (`er`, `tand`, `substrate_h`,
## `copper_t`, `roughness`, `trace_width`, `trace_length`) on TL1; a T/R
## switch's `il_db`/`isolation_db`/`iip3_dbm` and `ron`/`roff`; a gain
## block's `gain_db`/`nf_db`/`oip3_dbm`/`p1db_dbm`/`psat_dbm` and its
## Touchstone file (`sparams`); a ferrite bead's `z_peak`/`f_peak`; a load
## switch's control `vt`/`vh`; a choke's `lpri`/`lsec`/`k_coupling`. The
## numbers are representative of each part class, not one vendor's part,
## which is why nothing carries a `partNumber`.
##
## ## What is checked, and what only rides along
##
## Today a figure in dB or dBm is *data*: nothing in verax reads a gain,
## noise figure, intercept or insertion loss yet (a cascade/budget evaluator
## and a `.sp` run are later phases -- see each key's own doc), and the
## microstrip has no simulation model, so TL1 reaches a deck as per-pin
## impedances. What *is* read: `spice/models` builds the switch from
## `ron`/`roff`, the load switch's `.MODEL SW` from `ron`/`roff`/`vt`/`vh`,
## the bead from `z_peak`/`f_peak`/`dcr`, and the choke from
## `lpri`/`lsec`/`k_coupling`/`dcr`. So the claims are about the DC operating
## point that all four set -- the one thing on this board a simulator can
## answer -- plus the DC barriers a graph walk can prove.
##
## `turns` is the one magnetics key left out: a choke is 1:1, and `lsec` is
## stated directly, which takes precedence over a turns ratio anyway.

import std/[os, tables]
import verax/contract/dsl
import verax/verify
import verax/spice/boundary

const here = currentSourcePath().parentDir

# The gain block's operating point, from its datasheet class: a Darlington
# MMIC wants a fixed current and settles its own device voltage.
const
  vd = 4.0.V           ## device voltage at the rated current
  id = 50.mA           ## rated bias current
  vSupply = 5.0.V

let d = design("rf_trx"):
  net gnd, kind = ntGround, name = "0"
  net gnd_in, kind = ntSignal       # the DC input's return, before the choke
  net vin_raw, kind = ntPower:      # the DC input, before the choke
    spec:
      voltage = vSupply
  net vcc5, kind = ntPower:
    spec:
      voltage = vSupply
  net vlna, kind = ntPower:         # switched supply, receive only
    spec:
      voltage = vSupply
  net vbead, kind = ntSignal
  net vbias, kind = ntSignal
  net ant, kind = ntSignal          # SMA centre pin
  net ant_sw, kind = ntSignal       # far end of the microstrip
  net rfc, kind = ntSignal
  net rx_sw, kind = ntSignal
  net tx_sw, kind = ntSignal
  net lna_in, kind = ntSignal
  net lna_out, kind = ntSignal
  net rx_out, kind = ntSignal
  net tx_in, kind = ntSignal
  net tr, kind = ntSignal           # T/R select: low = receive
  net rx_en, kind = ntSignal        # gain-block supply enable

  # --- connectors ----------------------------------------------------------
  # Edge-launch SMAs. `z0` is what each port is designed against;
  # `return_loss_db` is the connector's own match through its launch, which
  # bounds the best the whole port can do.
  component J1, kind = "connector", description = "SMA edge-launch, antenna":
    pin "SIG", ant, kind = ptPassive
    pin "GND", gnd, kind = ptGround
    spec:
      z0 = 50.ohm
      return_loss_db = 25.dB
  component J2, kind = "connector", description = "SMA edge-launch, TX in":
    pin "SIG", tx_in, kind = ptPassive
    pin "GND", gnd, kind = ptGround
    spec:
      z0 = 50.ohm
      return_loss_db = 25.dB
  component J3, kind = "connector", description = "SMA edge-launch, RX out":
    pin "SIG", rx_out, kind = ptPassive
    pin "GND", gnd, kind = ptGround
    spec:
      z0 = 50.ohm
      return_loss_db = 25.dB

  # DC in and control. J4's return is its own net so the choke's second
  # winding sits in it; J5 carries the two control lines from the radio.
  component J4, kind = "connector", description = "2-pin DC input":
    pin "VIN", vin_raw, kind = ptPower
    pin "GND", gnd_in, kind = ptPassive
  component J5, kind = "connector", description = "3-pin control header":
    # The radio drives both lines: a connector's pin kinds state what is
    # plugged in (`netlist/kinds.connectorKinds`).
    pin "TR", tr, kind = ptOutput
    pin "RX_EN", rx_en, kind = ptOutput
    pin "GND", gnd, kind = ptGround

  # --- the antenna feed ------------------------------------------------------
  # 50 ohm microstrip on 0.2 mm of FR-4 over the first plane: 0.36 mm wide
  # for 50 ohm at er 4.3 with 1 oz copper. 12 mm is the run from the SMA's
  # launch to the switch. It is copper end to end, so it conducts at DC --
  # which `traverse` says, since a `transmission_line` kind alone does not.
  component TL1, kind = "transmission_line", description = "50 ohm microstrip":
    traverse:
      "1" <-> "2"
    pin "1", ant, kind = ptPassive
    pin "2", ant_sw, kind = ptPassive
    spec:
      z0 = 50.ohm
      er = 4.3
      tand = 0.02
      substrate_h = 0.2e-3
      copper_t = 35.0e-6
      roughness = 1.0e-6
      trace_width = 0.36e-3
      trace_length = 12.0e-3

  # GaAs switches want their RF ports at 0 V: DC blocks on every port.
  component C_ANT, kind = "capacitor", value = "100p":
    pin "1", ant_sw, kind = ptPassive
    pin "2", rfc, kind = ptPassive
    spec:
      package = "0402"
      dielectric = "C0G"
      voltage_rating = 50.0.V

  # --- the T/R switch ----------------------------------------------------------
  # SPDT, reflective, CTRL low = RF1 (receive). The datasheet's on-state
  # loss, its off-state isolation, its match and its linearity -- a switch
  # states its intercept at the input, so `iip3_dbm` here and `oip3_dbm` on
  # the gain block, each as its own datasheet gives it.
  component U1, kind = "rf_switch", description = "SPDT T/R switch":
    traverse:
      "RFC" <-> ["RF1", "RF2"]
    pin "RFC", rfc, kind = ptPassive
    pin "RF1", rx_sw, kind = ptPassive
    pin "RF2", tx_sw, kind = ptPassive
    pin "CTRL", tr, kind = ptInput
    pin "VDD", vcc5, kind = ptPower
    pin "GND", gnd, kind = ptGround
    spec:
      ron = 2.5.ohm
      roff = 100.kohm
      il_db = 0.4.dB
      isolation_db = 30.dB
      return_loss_db = 20.dB
      iip3_dbm = 55.dBm

  # Every RF port of the switch sits between DC blocks, so nothing else sets
  # its DC level. 10 k from RFC to ground holds all three at 0 V (through
  # `ron` to the selected throw, through `roff` to the other) and bleeds off
  # charge a block would otherwise trap; against 50 ohm it costs 0.02 dB.
  component R_RFC, kind = "resistor", value = "10k":
    pin "1", rfc, kind = ptPassive
    pin "2", gnd, kind = ptPassive

  component C_TX, kind = "capacitor", value = "100p":
    pin "1", tx_sw, kind = ptPassive
    pin "2", tx_in, kind = ptPassive
    spec:
      package = "0402"
      dielectric = "C0G"
      voltage_rating = 50.0.V

  # Power-up into receive: with nothing driving TR the switch routes the
  # antenna to the gain block, never a transmitter into an open port.
  component R_TR, kind = "resistor", value = "100k":
    pin "1", tr, kind = ptPassive
    pin "2", gnd, kind = ptPassive

  # --- the gain block ----------------------------------------------------------
  component C_IN, kind = "capacitor", value = "100p":
    pin "1", rx_sw, kind = ptPassive
    pin "2", lna_in, kind = ptPassive
    spec:
      package = "0402"
      dielectric = "C0G"
      voltage_rating = 50.0.V

  # A Darlington MMIC: RF in, RF out (which is also its supply), ground.
  # RF_OUT's `zin` (set after the block -- a pin takes no `spec:`) is the DC
  # stand-in at its operating point, Vd/Id = 80 ohm: the only thing about
  # the die a `.op` needs, stated as what it is.
  # The rest is its datasheet: gain, noise figure, output intercept, output
  # compression and saturation, input/output match, and the measured
  # S-parameters it would be simulated from once a `.sp` model exists.
  component U2, kind = "lna", description = "50 ohm MMIC gain block":
    pin "RF_IN", lna_in, kind = ptInput
    pin "RF_OUT", lna_out, kind = ptOutput
    pin "GND", gnd, kind = ptGround
    spec:
      gain_db = 15.0.dB
      nf_db = 1.2.dB
      oip3_dbm = 38.dBm
      p1db_dbm = 20.dBm
      psat_dbm = 22.dBm
      return_loss_db = 15.dB
      sparams = here / "rf_trx" / "gain_block.s2p"

  component C_OUT, kind = "capacitor", value = "100p":
    pin "1", lna_out, kind = ptPassive
    pin "2", rx_out, kind = ptPassive
    spec:
      package = "0402"
      dielectric = "C0G"
      voltage_rating = 50.0.V

  # --- the bias tee ---------------------------------------------------------
  # Load switch (receive only) -> bead -> bias resistor -> RF choke -> RF_OUT.
  # The resistor sets the current: (5 V - 4 V) / 50 mA = 20 ohm, less the
  # few hundred milliohms in series with it, which is close enough that the
  # E24 value is the nominal.
  component U3, kind = "load_switch", description = "load switch, active-high":
    pin "IN", vcc5, kind = ptPower
    pin "OUT", vlna, kind = ptOutput
    pin "EN", rx_en, kind = ptInput
    pin "GND", gnd, kind = ptGround
    spec:
      ron = 80.mohm
      roff = 10.Mohm
      vt = 1.0.V
      vh = 0.1.V
  component C_LNA, kind = "capacitor", value = "1u":
    pin "1", vlna, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0402"
      dielectric = "X7R"
      voltage_rating = 16.0.V

  # A 600 ohm bead at 100 MHz keeps the switched supply's edges and the
  # radio's harmonics out of the bias line.
  component FB1, kind = "ferrite_bead", description = "600 ohm @ 100 MHz bead":
    pin "1", vlna, kind = ptPassive
    pin "2", vbead, kind = ptPassive
    spec:
      z_peak = 600.ohm
      f_peak = 100.MHz
      dcr = 150.mohm
  component C_BEAD, kind = "capacitor", value = "100n":
    pin "1", vbead, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0402"
      dielectric = "X7R"
      voltage_rating = 16.0.V

  component R_BIAS, kind = "resistor", value = "20":
    pin "1", vbead, kind = ptPassive
    pin "2", vbias, kind = ptPassive
    spec:
      tolerance = 1.pct
  component C_BIAS, kind = "capacitor", value = "1n":
    pin "1", vbias, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0402"
      dielectric = "C0G"
      voltage_rating = 16.0.V

  # The choke presents a high impedance across the band so the RF stays on
  # the signal path; its DCR is in the bias loop.
  component L_CHOKE, kind = "inductor", value = "390n":
    pin "1", vbias, kind = ptPassive
    pin "2", lna_out, kind = ptPassive
    spec:
      dcr = 1.2.ohm

  # --- DC input ---------------------------------------------------------------
  # A common-mode choke in both lines of the DC input, 1:1 by construction,
  # so `lsec` equals `lpri`; the coupling is a tightly wound part's.
  component L1, kind = "common_mode_choke", description = "DC input CM choke":
    pin "1A", vin_raw, kind = ptPassive
    pin "1B", vcc5, kind = ptPassive
    pin "2A", gnd_in, kind = ptPassive
    pin "2B", gnd, kind = ptPassive
    spec:
      lpri = 100.uH
      lsec = 100.uH
      k_coupling = 0.995
      dcr = 50.mohm
  component C_VCC, kind = "capacitor", value = "10u":
    pin "1", vcc5, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0805"
      dielectric = "X7R"
      voltage_rating = 16.0.V

  # --- claims -----------------------------------------------------------------

  role "power_rail", supply, rail = vcc5, voltage = vSupply, band = 2.pct

  # The switched supply in receive. 50 mA through 80 mohm of on-resistance
  # is 4 mV; the claim is that the switch is *on* -- enabled at 3.3 V
  # against its 1.0 V threshold -- not a budget on its drop.
  require dc_voltage(vlna) >= 4.9.V,
          id = "REQ-RF-LNASUP-001",
          because = "RX_EN high must turn the load switch fully on; a switch " &
                    "left off or half-on starves the gain block"

  # The gain block's operating point. Everything in series from the 5 V
  # rail sets it: the choke's two windings, the load switch, the bead, the
  # 20 ohm resistor and the RF choke's DCR, against the die's 80 ohm. A Vd
  # outside 5% means the current is outside it too -- and gain, noise figure
  # and intercept are all specified at the rated current.
  require dc_voltage(lna_out) == vd, band = 5.pct,
          id = "REQ-RF-VD-001",
          because = "the gain block's datasheet figures hold at its rated " &
                    "bias; the device voltage is the operating point a " &
                    "multimeter can check"

  # Power-up state: with the radio unplugged the T/R line sits low.
  require dc_voltage(tr) <= 0.3.V, unmated = "J5",
          id = "REQ-RF-TRSAFE-001",
          because = "an undriven T/R line must select receive, so a " &
                    "transmitter is never switched into an open antenna port"

  # The DC barriers. Many antennas are DC shorts at their feed (folded
  # dipoles, PIFAs, loops), so the bias must not reach the SMA -- C_ANT is
  # the only thing stopping it, the microstrip being plain copper. And the
  # receiver hanging off J3 must not see the gain block's 4 V.
  require dc_path_exists(ant, lna_out) == 0.0,
          id = "REQ-RF-ANTDC-001",
          because = "a DC-shorted antenna would short the gain block's bias " &
                    "through the switch"
  require dc_path_exists(rx_out, lna_out) == 0.0,
          id = "REQ-RF-RXDC-001",
          because = "the downstream receiver's input must not see the gain " &
                    "block's bias"

# The gain block's DC stand-in on its output pin: Vd/Id at the rated bias.
setAnnotation(findComponent(d.netlist, "U2").pins["RF_OUT"], "zin",
              Ohms(float(vd) / float(id)))

# The switch's select line (MSB first; one bit for an SPDT).
findComponent(d.netlist, "U1").attrs["switch.select_pins"] = "CTRL"

# The bench: 5 V into the DC input, and the radio's control lines -- receive
# enabled, T/R left to its pull-down.
driveConnector(findComponent(d.netlist, "J4"),
               {"VIN": driveSource(vSupply, rout = 50.mohm)})
driveConnector(findComponent(d.netlist, "J5"),
               {"RX_EN": driveSource(3.3.V, rout = 100.ohm)})

quit(verifyMain(d))
