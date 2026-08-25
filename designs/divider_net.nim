## Two dividers built from a total and a ratio, and the composition of them.
##
##   nimcir check designs/divider_net.nim
##
## No resistor value appears in this file. `designs/lib/dividers.nim` derives
## every leg from a total impedance and a fraction, so what is checked below
## is the design equations -- and, for the three-resistor network, the claim
## that a current divider is a drop-in replacement for a resistor of the same
## value.
##
## Two networks hang off the same 10 V source:
##
##   XV   two resistors: a plain voltage divider, 100 k total, tap at 25%.
##   XN   three resistors: the same divider with its bottom leg realised as a
##        current divider splitting the tap current 30 : 70.
##
## They are given identical `rTotal` and `ratio`, so **both taps must read the
## same 2.5 V**. That is the substitutability property, measured rather than
## asserted: if `currentDividerLegs` were wrong, `RA || RB` would not be the
## 25 k the tap needs and XN's tap would move while XV's did not.
##
## The split itself is invisible at every node of XN -- both legs return to
## the same ground, so no node voltage depends on how the current divided.
## Making 1 k of leg A a separate sense resistor gives it a witness: the
## junction sits at `I_A * 1 k`. It is part of the leg rather than added to
## it, so the split is unperturbed and the reading is exact rather than a
## first-order correction.
##
## ## The arithmetic the claims below rest on
##
## 10 V across 100 k draws 100 uA. The tap sits at 25% of 10 V = 2.5 V and
## the whole 100 uA flows through the bottom leg, where it splits 30 : 70 --
## so 30 uA through leg A, and 30 uA through 1 k is 30 mV. Every one of those
## numbers follows from the four parameters the two `instance` lines state;
## none of them is a component value.

import nimcir/contract/dsl
import nimcir/verify

import ./lib/dividers

let d = design("divider_net"):
  net gnd, kind = ntGround, name = "0", global = true
  net vin, kind = ntPower:
    spec:
      voltage = 10.0.V
  net tapv, kind = ntSignal                # plain two-resistor divider
  net tapn, kind = ntSignal                # composed three-resistor network

  # A bench supply. `rout`/`lout` are left at their defaults, which puts
  # 10 mohm and 1 uH in series with it -- an ideal source is a dead short at
  # AC and `spice/models.expandSourceImpedance` exists to stop that. At DC
  # across 100 k it is worth about ten microvolts, which is why the claims
  # below can be stated to 1% without arguing about it.
  component V1, kind = "voltage_source", value = "DC 10":
    pin "+", vin, kind = ptPower
    pin "-", gnd, kind = ptGround
    spec:
      voltage = 10.0.V

  # Same total, same ratio, different number of resistors.
  instance XV, voltageDivider(rTotal = 100.kohm, ratio = 25.pct),
           [vin, tapv, gnd]
  instance XN, splitTapDivider(rTotal = 100.kohm, ratio = 25.pct,
                               split = 30.pct, sense = 1.kohm),
           [vin, tapn, gnd, gnd]

  # --- claims ------------------------------------------------------------

  require dc_voltage(tapv) == 2.5.V, band = 1.pct,
          id = "REQ-DIV-VDIV-001",
          because = "the tap is the divider's whole output, and 25% of a " &
                    "stated 10 V is the only answer the equations allow"

  require dc_voltage(tapn) == 2.5.V, band = 1.pct,
          id = "REQ-DIV-COMP-001",
          because = "the composed network was given the same total and the " &
                    "same ratio as XV, so a tap that differs means the two " &
                    "parallel legs do not present the bottom-leg impedance " &
                    "they were sized for -- which is exactly the property " &
                    "that lets a current divider stand in for a resistor"

  # The sense node lives two levels down: inside the current divider, which
  # is itself instanced inside the composed network. `innerNet` walks it by
  # name, because those identifiers were bound inside a `subckt` in another
  # module and are long out of scope here.
  require dc_voltage(XN.innerNet("XI", "sns")) == 30.mV, band = 2.pct,
          id = "REQ-DIV-SPLIT-001",
          because = "30% of the 100 uA the string draws, through the 1 k " &
                    "that leg A's sense element accounts for -- the one " &
                    "node in the network whose voltage depends on how the " &
                    "current divided rather than on where the tap sits"

quit(verifyMain(d))
