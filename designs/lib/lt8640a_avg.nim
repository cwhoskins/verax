## An averaged behavioural model of the LT8640A, as an XSPICE code model.
##
## **Why this exists at all.** Analog Devices publishes an LTspice model for
## the LT8640A, and it cannot be used here: LTC's switching-regulator models
## are encrypted and built on undocumented `A`-device primitives private to
## LTspice. ngspice cannot read them, by design and not by accident. So a
## board carrying this part is unsimulatable unless somebody writes a model,
## and this is that model.
##
## **What it represents.** The control path, averaged over a switching cycle:
##
##   * the 0.970 V reference and the error amplifier that servos FB to it
##   * TR/SS soft start -- an internal 1.9 uA pull-up charges the *external*
##     C_SS, and while TR/SS is below 0.970 V it takes over as the reference,
##     so the output ramps at the rate the board's own capacitor sets
##   * EN/UV, with its 1.00 V rising / 0.96 V falling hysteresis
##   * PG, asserting once FB is within +-8% of regulation
##   * the duty limit: SW cannot be driven above V_IN or below ground
##
## **What it does not.** The switch node is emitted as its cycle *average*,
## not as a waveform, so there is no ripple, no inductor current ripple and
## no EMI here -- and no current limit, because an averaged voltage output
## has no current to limit. The internal compensation is not modelled either:
## the only dynamics are the board's own L and C_OUT. That makes this model
## trustworthy for **DC regulation and start-up** and *not* for loop
## stability, and a design using it must not claim a phase margin from it.
## `lt8640a_sw` is the counterpart that does switch.
##
## Datasheet figures (LT8640A Rev. 0) are the parameter defaults, so a deck
## that states nothing gets the real part.

import nimcir/spice/xspice/dsl

codeModel "lt8640a_avg":
  description "lt8640a averaged step-down controller: reference, soft start, en, pg"

  port vin,  dir = xdIn,    default = xpV, allowed = [xpV],
             description = "input supply, sensed"
  port fb,   dir = xdIn,    default = xpV, allowed = [xpV],
             description = "feedback, regulated to vref"
  port en,   dir = xdIn,    default = xpV, allowed = [xpV],
             description = "enable / undervoltage lockout"
  port trss, dir = xdInout, default = xpG, allowed = [xpG],
             description = "soft start: sources iss into the external cap"
  port sw,   dir = xdOut,   default = xpV, allowed = [xpV],
             description = "switch node, cycle-averaged"
  port pg,   dir = xdOut,   default = xpV, allowed = [xpV],
             description = "power good"
  port bst,  dir = xdInout, default = xpG, allowed = [xpG], nullAllowed = true,
             description = "bootstrap, as a DC load only"

  param vref,     float, default = 0.970,  description = "feedback reference (V)"
  param iss,      float, default = 1.9e-6, description = "tr/ss pull-up current (A)"
  param aol,      float, default = 1.0e4,  description = "error amplifier DC gain"
  param ven_th,   float, default = 1.00,   description = "en/uv rising threshold (V)"
  param ven_hyst, float, default = 0.04,   description = "en/uv hysteresis (V)"
  param pg_band,  float, default = 0.08,   description = "pg window, fraction of vref"
  param vpg,      float, default = 3.4,    description = "pg high level (V)"
  param rss_dis,  float, default = 200.0,  description = "tr/ss pull-down when off (ohm)"
  param rbst,     float, default = 1.0e5,  description = "bootstrap DC load (ohm)"

  stateVar enabled, float

  eval:
    # BST exists here **only to give the pin a DC reference**, and that is
    # worth saying plainly rather than dressing up. On a real board the
    # bootstrap capacitor is charged from INTVCC through an internal diode
    # while SW is low and discharged into the top switch's gate while it is
    # high; averaged over a cycle none of that survives, so there is nothing
    # for this model to represent. What there *is* is a problem: the
    # datasheet circuit hangs C_BST between BST and SW and nothing else, so
    # with no pin here that node has no DC path anywhere and the operating
    # point is singular. Measured, that made the 5 V rail read 1.71 V.
    #
    # So: a large conductance to ground, standing for the gate-drive load the
    # pin does present on average, and a `nullAllowed` port so a design that
    # leaves BST unconnected is still legal.
    output(bst) = input(bst) / param(rbst)
    partial(bst, bst) = 1.0 / param(rbst)

    let vi = input(vin)
    let vt = input(trss)
    let vf = input(fb)

    # EN/UV with hysteresis. The threshold to turn *on* is higher than the
    # one to stay on, so a slowly-rising supply does not chatter the part on
    # and off across a single trip point.
    let was = stateVar(enabled)
    let onNow =
      if was > 0.5: input(en) > param(ven_th) - param(ven_hyst)
      else: input(en) > param(ven_th)
    stateVar(enabled) = (if onNow: 1.0 else: 0.0)

    if not onNow:
      # Shut down: the reference is gone and TR/SS is pulled to ground
      # through an internal MOSFET, so the next start-up begins from zero
      # rather than from wherever the capacitor was left.
      output(sw) = 0.0
      partial(sw, fb) = 0.0
      output(trss) = vt / param(rss_dis)
      partial(trss, trss) = 1.0 / param(rss_dis)
      output(pg) = 0.0
    else:
      # Negative because a `g` port's output is the current flowing *in* to
      # the model, and this pin sources.
      # At DC the pin is held at the reference so the node has a definite
      # solution; in time-domain it is a constant current out of the pin,
      # into whatever the board hung on it. The ramp rate is therefore set by
      # C_SS on the board and not by anything in here, which is the point:
      # soft-start time is a design choice, not a part property.
      if analysis == maDc:
        output(trss) = (vt - param(vref)) / param(rss_dis)
        partial(trss, trss) = 1.0 / param(rss_dis)
      else:
        output(trss) = -param(iss)
        partial(trss, trss) = 0.0

      # While TR/SS is below the internal reference it *is* the reference.
      # That single line is the whole of soft start.
      #
      # **Except at DC.** A capacitor is an open circuit to the operating-point
      # solver, so 1.9 uA into C_SS leaves TR/SS unconstrained and it lands
      # near zero -- and the model then reports a rail that never came up. A
      # .op asks where the circuit *sits*, and where a soft-start pin sits is
      # at its clamp, having finished charging long ago. Reporting 0 V for a
      # regulator that regulates would be a confident wrong answer of exactly
      # the kind an averaged model exists to avoid.
      let vr =
        if analysis == maDc: param(vref)
        else: min(param(vref), vt)
      var vs = param(aol) * (vr - vf)
      var slope = -param(aol)
      if vs > vi:
        vs = vi
        slope = 0.0
      elif vs < 0.0:
        vs = 0.0
        slope = 0.0
      output(sw) = vs
      partial(sw, fb) = slope
      # The Jacobian entry for the duty limit: once the loop is against the
      # input rail, SW follows V_IN rather than the error.
      partial(sw, vin) = (if slope == 0.0 and vs > 0.0: 1.0 else: 0.0)

      output(pg) =
        if abs(vf - param(vref)) < param(pg_band) * param(vref): param(vpg)
        else: 0.0
      partial(pg, fb) = 0.0
