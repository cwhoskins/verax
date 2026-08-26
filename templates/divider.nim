## A resistive divider: the smallest circuit with a number worth checking.
##
##   nimcir check <this file>
##
## Start here if `blank.nim` left you wondering what a claim looks like when
## it is actually measured. There is no role in this file -- just two
## resistors and a bare `require`, which is the whole point: a quantity
## marked ``require`` by ``nimcir quantities`` needs nothing but its subjects,
## so `dc_voltage` of a net is reachable without any role at all.
##
## What it claims: the tap sits at 3.0 V, within 1%. That is measured with a
## `.op` over the design **as authored** -- not over an isolated fragment.
## The distinction is the reason the claim is worth making: a fragment cut
## out around the tap would be terminated with ideal sources at whatever
## voltage the boundary invented, and the check would measure its own
## assumption and pass every time.

import nimcir/contract/dsl
import nimcir/verify

let d = design("divider"):
  net gnd, kind = ntGround, name = "0"
  net vin, kind = ntPower:
    spec:
      voltage = 12.0.V
  net mid, kind = ntSignal

  # The supply. Note what is *not* simulated here: an ideal source. The
  # default `rout`/`lout` puts 10 mohm and 1 uH in series, because an ideal
  # source is a dead short at AC. At DC across 40 k that 10 mohm is worth
  # three microvolts, which is why a 1% band below needs no argument.
  component V1, kind = "voltage_source", value = "DC 12":
    pin "+", vin, kind = ptPower
    pin "-", gnd, kind = ptGround
    spec:
      voltage = 12.0.V

  # 30k over 10k: the tap sits at 12 * 10/(30+10) = 3.0 V, and the string
  # burns 300 uA. Those are the two numbers a divider is specified by, and
  # they trade against each other -- a stiffer divider (lower total) is less
  # bothered by whatever it drives and by stray capacitance, and costs
  # current all the time.
  component R1, kind = "resistor", value = "30k":
    pin "1", vin, kind = ptPassive
    pin "2", mid, kind = ptPassive
  component R2, kind = "resistor", value = "10k":
    pin "1", mid, kind = ptPassive
    pin "2", gnd, kind = ptPassive

  # --- claims -------------------------------------------------------------

  # A role, because a rail is a rail: `power_rail` claims the supply sits
  # where it says it does. Omitting `targetZ` means no decoupling claim is
  # made -- there is no decoupling here to claim anything about.
  role "power_rail", supply, rail = vin, voltage = 12.0.V, band = 5.pct

  # And a claim of your own. `band` is where the tolerance goes, and the unit
  # is taken from the literal so it cannot drift from the value. `because` is
  # printed by the report whenever the claim does not pass, which is the one
  # moment somebody needs to know why the limit is what it is.
  require dc_voltage(mid) == 3.0.V, band = 1.pct,
          id = "REQ-DIV-TAP-001",
          because = "the tap is the divider's entire output; 1% is what " &
                    "two 1% resistors give in the worst case, so a wider " &
                    "band would accept a stuffing error and a tighter one " &
                    "would fail parts that are in specification"

quit(verifyMain(d))
