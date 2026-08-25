## Two rails from one adjustable part, with the datasheet doing the sizing.
##
##   nimcir check designs/adj_regulator.nim
##
## No resistor value appears below. `designs/lib/adjreg.nim` carries the
## LM317 as a *value* -- its reference, its ADJ-pin current, its output
## range, its dropout, its minimum load and its thermal resistance -- and the
## equations that turn those into a programming network. This file says what
## it wants: 15 V in, 5 V at 100 mA and 12 V at 50 mA out.
##
## ## Why the claims are worth making
##
## The simulation does not read back what the equations computed. The
## regulator is replaced, for simulation only, by the loop it closes -- an
## error amplifier holding the reference between OUT and ADJ, and a current
## source for the ADJ pin -- so ngspice solves the divider that is actually
## in the netlist and reports what the rail actually comes to. The claim
## compares that to the voltage this file asked for.
##
## So the check fails if the design equation is wrong or incomplete, and it
## fails at the precision the claim states. Dropping the `iAdj * rAdj` term
## from `setResistor` -- the term everyone drops -- picks 720 R instead of
## 713 R for the 5 V rail and the simulator reports 5.036 V, which misses the
## 0.5% band below. Rounding to E96 costs the 12 V rail 0.25%, which does
## not.
##
## ## Two things this design states that the equations then use
##
## The **input current** is declared, not derived: there is no pass element
## in the loop model, so the regulator's draw is stated once as a
## constant-current sink. That is what puts a real drop across the 1 ohm of
## supply lead below -- and the claim on `vboard` is what tests it, since a
## model that quietly drew nothing would report the full 15 V there.
##
## The **dissipation** is where the interesting answer is. The 5 V rail burns
## (14.8 - 5) V at the 100 mA of load plus the 5.2 mA the divider programs --
## a little over a watt -- and a TO-220 in free air is about 50 degC/W, so
## `delta_t` on that part comes out at 52 degC and the readiness report names
## it as the hottest thing on the board. At the 60 degC top of the stated
## ambient range that is a junction at 112 degC against a 125 degC limit: it
## works, and it works with no margin worth having. The fix is a heatsink, and
## `thetaJA` on the part is where that gets said. None of that is simulated --
## `netlist/environment` wires the figures together and models nothing -- but
## a premise carried silently is a premise nobody checks.
##
## ## What this design deliberately does not claim
##
## No PDN sweep, and no start-up claim. The loop model's error amplifier
## drives its output through an ideal source, which is a dead short at AC and
## has no ramp at t = 0: a `z_max_in_band` claim against either rail would
## report 0 ohm and pass any target that could be set, and a `regulator` role
## would measure the soft start of a part that has none. Both are stated in
## `lib/adjreg.nim` as limits of the model rather than left to be discovered.

import nimcir/contract/dsl
import nimcir/verify
import nimcir/netlist/formats/spice as spiceFormat
import nimcir/parts/series          # `e96`, the ladder the 12 V rail rounds to

import ./lib/adjreg

# What the design is asking for. Everything below is derived from these.
let
  vSupply = 15.0.V
  rLead = 1.ohm            ## supply lead, connector and polyfuse, together
  iQ = 5.mA                ## regulator quiescent draw, per part
  v5 = 5.0.V
  i5 = 100.mA
  v12 = 12.0.V
  i12 = 50.mA

  # The board's input node sits below the supply by the lead drop, which is
  # what both regulators are actually working from -- so it is what the
  # headroom check inside the builder has to be given. Getting this wrong is
  # how a 12 V rail out of a 15 V supply passes on paper and drops out on the
  # bench.
  iTotal = Amps(float(i5) + float(i12) + 2.0 * float(iQ))
  vBoardNominal = Volts(float(vSupply) - float(iTotal) * float(rLead))

let d = design("adj_regulator"):
  environment:
    t_ambient_min = 0.degC
    t_ambient_max = 60.degC

  net gnd, kind = ntGround, name = "0", global = true
  net vsup, kind = ntPower:
    spec:
      voltage = 15.0.V
  net vboard, kind = ntPower:              # after the lead drop
    spec:
      voltage = vBoardNominal
  net v5rail, kind = ntPower:
    spec:
      voltage = 5.0.V
  net v12rail, kind = ntPower:
    spec:
      voltage = 12.0.V

  component V1, kind = "voltage_source", value = "DC 15":
    pin "+", vsup, kind = ptPower
    pin "-", gnd, kind = ptGround
    spec:
      voltage = 15.0.V

  component RLEAD, kind = "resistor", value = spiceValue(float(rLead)):
    pin "1", vsup,   kind = ptPassive
    pin "2", vboard, kind = ptPassive

  # Same part, same reference resistor, two outputs -- and two different
  # answers to "what can I buy". The 5 V rail takes the computed value; the
  # 12 V rail is rounded to E96, and what it then makes is recomputed from
  # the rounded part rather than reported back as the 12 V that was asked
  # for.
  instance XR5, adjustableRegulator(lm317, vin = vBoardNominal, vout = v5,
                                    iLoad = i5, rSet = 240.ohm,
                                    iQuiescent = iQ),
           [vboard, v5rail, gnd]
  instance XR12, adjustableRegulator(lm317, vin = vBoardNominal, vout = v12,
                                     iLoad = i12, rSet = 240.ohm,
                                     iQuiescent = iQ, series = e96),
           [vboard, v12rail, gnd]

  # The loads the currents above describe. Stated as resistors because that
  # is what the check needs them to be at DC; a real MCU or motor driver is
  # a regulated draw and would be a `driveSink` behind a connector.
  component RL5, kind = "resistor",
            value = spiceValue(float(v5) / float(i5)):
    pin "1", v5rail, kind = ptPassive
    pin "2", gnd,    kind = ptPassive
  component RL12, kind = "resistor",
            value = spiceValue(float(v12) / float(i12)):
    pin "1", v12rail, kind = ptPassive
    pin "2", gnd,     kind = ptPassive

  # --- claims ------------------------------------------------------------

  require dc_voltage(v5rail) == 5.0.V, band = 0.5.pct,
          id = "REQ-REG-5V-001",
          because = "the divider was sized by the full output equation, " &
                    "ADJ-pin term included, and the simulator solves that " &
                    "divider without reading anything this design computed " &
                    "-- so 0.5% is a check of the equation, not of the " &
                    "arithmetic being done twice"

  require dc_voltage(v12rail) == 12.0.V, band = 0.5.pct,
          id = "REQ-REG-12V-001",
          because = "the same equation with its bottom resistor rounded to " &
                    "a part that exists; what E96 granularity costs at " &
                    "12 V from a 1.25 V reference has to fit inside the " &
                    "same budget as everything else"

  # The loop's own promise, checked at the node it is made about: the part
  # holds its reference between OUT and ADJ, so the tap sits one reference
  # below the rail. If this reads 5 V the divider is open; if it reads 0 the
  # loop is not closing through it.
  require dc_voltage(XR5.innerNet("adj")) == 3.75.V, band = 1.pct,
          id = "REQ-REG-VREF-001",
          because = "Vout - Vref is what an LM317 actually regulates; the " &
                    "output voltage is a consequence of it and of two " &
                    "resistors, and this is the half that is the part's"

  require dc_voltage(vboard) == vBoardNominal, band = 0.5.pct,
          id = "REQ-REG-LEAD-001",
          because = "both regulators draw their load current through the " &
                    "supply lead, and the 12 V rail's headroom is measured " &
                    "from this node rather than from the supply"

quit(verifyMain(d))
