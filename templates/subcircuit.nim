## One block, built by a Nim proc, used twice at two different settings.
##
##   nimcir check <this file>
##
## Everything else under `templates/` is a flat netlist with its component
## values typed in. This one has **no component value anywhere in the design
## itself**: a `subckt` is ordinary runtime code inside a `block` expression,
## so putting it in a proc and computing the values from the arguments is all
## it takes to have a parameterized module.
##
## That changes what the claims are worth. When a value is typed in, a claim
## that the tap sits at 3 V checks that somebody did the arithmetic twice.
## When the value is derived, the same claim checks the **design equation** --
## and it checks it at every setting the block is used at.
##
## Three things this template is here to show:
##
##   * a `subckt` built by a proc, instantiated with `instance`;
##   * `instantiateByPort` wiring -- `instance XA, tmpl, [a, b, c]` binds
##     positionally, which is fine for a block whose port order you wrote;
##   * a claim on a node **inside** an instance, via `innerNet`. Those
##     identifiers were bound inside the `subckt` and are long out of scope
##     at the design site, so a path is the only way to name them. It walks
##     the child immediately, so a typo raises there naming what the instance
##     actually contains rather than failing later as an unevaluable claim.
##
## Note the block is a *value*: `refDivider(...)` returns a `Netlist` and
## nothing registers it anywhere. Each `instance` deep-clones it, so the two
## instances share no `Net`, `Component` or `Pin` objects and cannot
## interfere -- except for nets marked global, like ground, which are
## deliberately reused as the same object at every level.

import nimcir/contract/dsl
import nimcir/netlist/formats/spice as spiceFormat
import nimcir/verify

# --- the block ------------------------------------------------------------

proc refDivider(rTotal: Ohms, ratio: Fraction, rFilt: Ohms,
                cFilt: Farads): Netlist =
  ## An RC-filtered voltage reference. Ports: `IN`, `OUT`, `BOT`.
  ##
  ## A divider sized by **total impedance and ratio** rather than by two
  ## resistor values, because those are the two things a designer actually
  ## chooses and they are independent of each other:
  ##
  ##   rTop = rTotal * (1 - ratio)      rBot = rTotal * ratio
  ##
  ## The ratio is the answer the circuit gives; the total is everything else
  ## -- how much current it burns, how hard it loads its source, how much
  ## noise it contributes. Write the two resistors instead and every edit
  ## couples the two: nudge one leg to a preferred value and the ratio moves
  ## as well, with nothing to say which you meant to keep.
  ##
  ## `BOT` is a port rather than an internal ground because a divider's
  ## return is not always ground -- it is the bottom of whatever the ratio is
  ## taken against, which for a bridge leg or a level shifter is another rail.
  let total = float(rTotal)
  let rTop = total * (1.0 - float(ratio))
  let rBot = total * float(ratio)

  result = subckt("REFDIV", [IN, OUT, BOT]):
    net IN,  kind = ntSignal
    net OUT, kind = ntSignal
    net BOT, kind = ntSignal
    # The unfiltered tap. It is **not** a port, which is the point of the
    # `innerNet` claim below: it is a real node with a real voltage that
    # nothing in the parent netlist witnesses.
    net TAP, kind = ntSignal

    component RTOP, kind = "resistor", value = spiceValue(rTop):
      pin "1", IN,  kind = ptPassive
      pin "2", TAP, kind = ptPassive
    component RBOT, kind = "resistor", value = spiceValue(rBot):
      pin "1", TAP, kind = ptPassive
      pin "2", BOT, kind = ptPassive

    # The filter. At DC it costs nothing -- CF blocks, so no current flows in
    # RF and OUT sits exactly where TAP does. Everywhere else it is a
    # single-pole low-pass on the reference, which is what keeps rail noise
    # off a comparator threshold or an ADC reference.
    component RF, kind = "resistor", value = spiceValue(float(rFilt)):
      pin "1", TAP, kind = ptPassive
      pin "2", OUT, kind = ptPassive
    component CF, kind = "capacitor", value = spiceValue(float(cFilt)):
      pin "1", OUT, kind = ptPassive
      pin "2", BOT, kind = ptPassive
      spec:
        package = "0603"
        dielectric = "X7R"
        voltage_rating = 25.0.V

# --- the design -----------------------------------------------------------

let d = design("subcircuit"):
  # Ground is `global`, so `clone` reuses the *same* net object at every
  # level of the hierarchy rather than giving each instance a private copy.
  # That is what makes SPICE node "0" behave the way a real ground does.
  net gnd, kind = ntGround, name = "0", global = true
  net vbus, kind = ntPower:
    spec:
      voltage = 12.0.V
  net refa, kind = ntSignal        # 25% reference
  net refb, kind = ntSignal        # 50% reference

  component V1, kind = "voltage_source", value = "DC 12":
    pin "+", vbus, kind = ptPower
    pin "-", gnd,  kind = ptGround
    spec:
      voltage = 12.0.V

  # Same block, two settings, no component value stated at either site. A
  # decade apart in impedance as well as different in ratio, so the claims
  # below exercise the equation rather than one arithmetic result.
  instance XA, refDivider(rTotal = 100.kohm, ratio = 25.pct,
                          rFilt = 10.kohm, cFilt = 100.nF),
           [vbus, refa, gnd]
  instance XB, refDivider(rTotal = 10.kohm, ratio = 50.pct,
                          rFilt = 1.kohm, cFilt = 1.uF),
           [vbus, refb, gnd]

  # --- claims -------------------------------------------------------------

  role "power_rail", bus, rail = vbus, voltage = 12.0.V, band = 5.pct

  # 25% of 12 V. Neither 75k nor 25k appears anywhere in this file: if the
  # equation in `refDivider` is wrong, this is what says so.
  require dc_voltage(refa) == 3.0.V, band = 1.pct,
          id = "REQ-SUB-REFA-001",
          because = "the block was asked for a quarter of its input, and " &
                    "the only thing that can put the tap anywhere else is " &
                    "the design equation that sized the two legs"

  require dc_voltage(refb) == 6.0.V, band = 1.pct,
          id = "REQ-SUB-REFB-001",
          because = "the same block at a different ratio and a tenth the " &
                    "impedance -- one setting passing proves an arithmetic " &
                    "result, two prove the equation"

  # The node inside. At DC the filter carries no current, so the unfiltered
  # tap must sit exactly where the filtered output does -- and a gap between
  # them means current *is* flowing in RF, which is a leaky capacitor or a
  # load on OUT that the block was not sized for. Nothing in the parent
  # netlist can see this node; `innerNet` is what reaches it.
  require dc_voltage(XA.innerNet("TAP")) == 3.0.V, band = 1.pct,
          id = "REQ-SUB-INNER-001",
          because = "CF blocks DC, so no current flows in RF and the tap " &
                    "and the output must agree; if they do not, the " &
                    "reference is being loaded and the ratio no longer holds"

quit(verifyMain(d))
