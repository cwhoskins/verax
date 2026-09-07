## Whether the parts on a rail are being used within what they can take.
##
##   verax check <this file>
##
## Every other template here asks whether the circuit *works*. This one asks
## whether it will keep working, which is a different question and changes
## nothing about the answer the circuit gives today: a capacitor at 95% of
## its rating and one at 40% behave identically on the bench and fail years
## apart.
##
## One `.op` over the whole design -- **not isolated**, for the same reason
## `dc_voltage` is not: a fragment terminated with ideal sources would check
## every part against a voltage the boundary invented rather than against the
## one it actually sees.
##
## ## Two ratings, checked differently
##
## `voltage_rating` is compared against the DC actually across each part.
## `power_rating` on a resistor is compared against V^2/R at the voltage the
## solve found across it. Both come back as a **fraction of rating used**, so
## 0.48 means "the worst part on this rail is at 48% of what it is rated for".
##
## ## Where the ceiling lives, and why it is not in the analysis
##
## The analysis reports the fraction and stops. **The ceiling belongs to the
## assertion**, and that is deliberate: a limit left live in the analysis as
## well would report the same claim twice, possibly at two different
## thresholds, and the assertion is the authority. So the way to state a
## ceiling is `require worst_voltage_derating(rail) <= 0.5`, or the
## `maxDerating` parameter on `power_rail`, which expands to the same claim.
##
## Ceilings are per-family in real practice because the *reason* to derate
## differs. A tantalum is held near 50% because it fails **short** and takes
## the rail with it. A Class 2 ceramic's headroom is mostly about losing
## capacitance to DC bias -- which `spice/models` already models directly by
## derating the part before it simulates it, so applying the tantalum rule to
## ceramics would count the same effect twice. A film capacitor barely cares.
##
## ## A gap worth knowing about
##
## `current_rating` and `isat` are registered annotations, are set by the
## part policy, and are checked by **nothing**. A branch current is not in a
## `.op` for anything but a voltage source, and an inductor's saturation
## needs a `.tran`. For a converter that is the failure mode that matters, so
## do not read a clean report here as a statement about either.

import verax/contract/dsl
import verax/verify

let d = design("derating"):
  environment:
    t_ambient_min = -20.degC
    t_ambient_max = 85.degC

  net gnd,  kind = ntGround, name = "0"
  net vbus, kind = ntPower:
    spec:
      voltage = 12.0.V

  component V1, kind = "voltage_source", value = "DC 12":
    pin "+", vbus, kind = ptPower
    pin "-", gnd,  kind = ptGround
    spec:
      voltage = 12.0.V

  # A 25 V tantalum on a 12 V rail: 48% of rating, just inside the 50% a
  # tantalum is conventionally held to. Fit the 16 V part that costs less and
  # fits the same footprint and it is at 75%, which is the single most common
  # way a board passes every functional test and comes back from the field.
  component C1, kind = "capacitor", value = "47u":
    pin "1", vbus, kind = ptPassive
    pin "2", gnd,  kind = ptPassive
    spec:
      package = "tantalum"
      dielectric = "tantalum"
      voltage_rating = 25.0.V
      esr = 150.mohm

  # A 25 V X7R, also at 48%. Note this part is derated **twice over**, for
  # two unrelated reasons: here, against what it can survive; and inside the
  # simulation, where its capacitance is reduced to what a Class 2 ceramic
  # actually has at 12 V of bias before any impedance is computed. The
  # second is why an X7R bank can measure seven times the rail impedance its
  # nominal values predict.
  component C2, kind = "capacitor", value = "1u":
    pin "1", vbus, kind = ptPassive
    pin "2", gnd,  kind = ptPassive
    spec:
      package = "0805"
      dielectric = "X7R"
      voltage_rating = 25.0.V

  # The bleed, and the part this template exists to catch. 12 V across 1k is
  # 144 mW. In an 0603 -- rated 100 mW -- that is 144% of rating: a part that
  # works perfectly on the bench, runs at a temperature that ages everything
  # near it, and is only visible if something multiplies V^2/R for you.
  # Stated at 250 mW (an 0805 or a 1206) it sits at 58%, which is where it
  # belongs.
  component R1, kind = "resistor", value = "1k":
    pin "1", vbus, kind = ptPassive
    pin "2", gnd,  kind = ptPassive
    spec:
      package = "0805"
      power_rating = 0.25

  # --- claims -------------------------------------------------------------

  # `maxDerating` on the role is the short way to state a voltage ceiling.
  # It expands to exactly the `worst_voltage_derating` claim a bare `require`
  # would make, so use whichever reads better -- the role when the rail is
  # already declared, the `require` when you want an id and a rationale.
  role "power_rail", bus, rail = vbus,
       voltage = 12.0.V, band = 5.pct,
       maxDerating = 0.5

  require worst_power_derating(vbus) <= 0.7,
          id = "REQ-DER-PWR-001",
          because = "a resistor run near its rating is a heat source with a " &
                    "temperature coefficient, and it ages whatever sits " &
                    "next to it; 70% is the conventional ceiling and this " &
                    "is the only check that multiplies V^2/R for you"

quit(verifyMain(d))
