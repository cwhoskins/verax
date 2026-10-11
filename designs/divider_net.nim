## Two dividers built from a total and a ratio, and the composition of them.
##
##   verax check designs/divider_net.nim
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
##
## ## Two properties an operating point cannot witness
##
## A tap reading 2.5 V at 10 V in is **one point on a line**, and a network
## with the wrong ratio and a compensating error passes it. `source_sweep`
## sweeps the supply from zero and measures the *slope*, which is the ratio
## itself: 250.0 m for both networks, against the 25% the `instance` lines
## stated.
##
## And substitutability is a claim about **impedance**, not only about the
## tap. `load_sweep` draws a swept current out of each tap and reports what
## it is looking back into: 18.75 k, which is 75 k over 25 k in parallel, and
## which appears in neither this file nor the netlist. The composed network
## has to present the same figure as the two-resistor one, and it does only
## because `currentDividerLegs` makes `RA || RB` the 25 k the tap was sized
## for. The load is a sink the analysis injects; nothing here is a test load,
## because a test load is not a part anybody solders.

import verax/contract/dsl
import verax/verify

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

  # --- the same two properties, swept rather than sampled -----------------
  #
  # A tap that reads 2.5 V at 10 V in is one point on a line, and a network
  # with the wrong ratio and a compensating error still passes it. Sweeping
  # the supply from zero measures the *slope*, which is the ratio itself --
  # the same number the two `instance` lines stated, and still nothing
  # compared against a component value.
  #
  # XV's tap also carries the limits of what it feeds. Assume an ADC with a
  # 2.5 V full scale and an input that must not be pulled below ground:
  # across the whole 0-10 V supply range the tap has to stay between the two,
  # and the slope claim cannot say that -- it is a ratio and holds for any
  # offset. The ceiling is the 1% the ratio is allowed and no more, and the
  # whole excursion together has to fit inside the ADC's span.
  role "source_sweep", "vdiv_line", source = V1, output = tapv,
       vFrom = 0.0.V, vTo = 10.0.V,
       ratio = 25.pct, band = 1.pct,
       minOut = -10.mV, maxOut = 2.525.V, maxDelta = 2.525.V
  role "source_sweep", "ndiv_line", source = V1, output = tapn,
       vFrom = 0.0.V, vTo = 10.0.V,
       ratio = 25.pct, band = 1.pct

  # And the other half of substitutability, which no node voltage witnesses:
  # a network standing in for a resistor has to present the same *impedance*,
  # not merely the same tap. 100 k split at 25% is 75 k over 25 k, so the tap
  # looks back into 18.75 k -- a number the design equations fix and that
  # appears nowhere in this file or in the netlist. Both taps have to show
  # it, and if `currentDividerLegs` were wrong XN's would not.
  #
  # The load is a swept current sink the analysis injects at the node; there
  # is nothing here to bind it to, because a test load is not a part anybody
  # solders.
  #
  # The same sweep also says what that impedance *costs* whatever reads the
  # tap. 10 uA out of 18.75 k is 187.5 mV, 7.5% of the 2.5 V tap, and that
  # is the figure an ADC's input current has to be budgeted against -- so
  # XV's sweep claims it four ways: as load regulation, as an absolute sag,
  # as a floor at the heaviest load, and as an impedance ceiling for a
  # replacement network that need not hit 18.75 k exactly but may not be
  # worse. The ceiling at no load is the 2.5 V the line sweep already pins,
  # which here says the injected sink only ever pulls down.
  role "load_sweep", "vdiv_load", output = tapv,
       iFrom = 0.0.A, iTo = 10.uA,
       zOut = 18.75.kohm, band = 1.pct,
       maxLoadReg = 8.0, maxDelta = 200.mV, minOut = 2.29.V,
       maxOut = 2.525.V, maxZOut = 20.kohm
  role "load_sweep", "ndiv_load", output = tapn,
       iFrom = 0.0.A, iTo = 10.uA,
       zOut = 18.75.kohm, band = 1.pct

quit(verifyMain(d))
