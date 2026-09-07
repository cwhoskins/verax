## A **switching** behavioural model of the LT8640A, as an XSPICE code model.
##
## The counterpart to `lt8640a_avg`, and the reason a part needs more than one
## model. The averaged model emits the switch node's cycle *average*, which is
## what makes it fast enough to run a five-millisecond soft start and what
## makes it structurally incapable of showing ripple: there is no waveform in
## it to have any. This one switches. It costs roughly fifty timepoints per
## cycle, so a millisecond of circuit time is fifty thousand of them and a
## soft start is out of the question -- and in exchange the output ripple, the
## inductor's triangle current and the input capacitor's ripple current are
## all things that exist in the answer.
##
## Neither is the better model. `Component.simModels` is what lets the design
## carry both and `spice/transform.selectSimModel` is what picks, by the
## question being asked rather than by which SPICE card gets written -- both
## of these are `.tran` models, and naming the card would not tell them apart.
##
## **The architecture, and why it is peak current mode.** The LT8640A is a
## peak-current-mode converter, and reproducing that here is not fidelity for
## its own sake: it is what makes the model converge and what makes the
## inductor current a measurable thing rather than an inference.
##
##   * `sw` is a **conductance** port, not a voltage one. The model puts the
##     top switch's on-resistance between VIN and SW, or the bottom switch's
##     between SW and ground, with a finite edge between the two. So SW is a
##     real switch node with a real source impedance rather than an ideal
##     source slamming an inductor -- and, decisively, **the model knows the
##     inductor current**, because it is the current through whichever switch
##     is conducting. A voltage-output switch node would hide it, and there is
##     nowhere else in a netlist to find it.
##   * That current is compared, cycle by cycle, against a peak command from
##     the error amplifier, with slope compensation. The inner loop is what
##     makes the outer one easy: it collapses the output LC into a single
##     pole, so a gm-C compensator with one zero is enough, which is what the
##     real part carries internally.
##   * `vin` is a conductance port too, and it draws the switch current. The
##     input capacitors therefore see the real trapezoidal draw, which is the
##     other thing an averaged model cannot show and the thing the datasheet's
##     insistence on two 1 uF parts at the package is about.
##
## **What is a datasheet figure and what is a stand-in.** `vref`, `iss` and
## `iq` are from the LT8640A datasheet (Rev. 0) and are the same numbers the
## averaged model uses. `fsw` is the board's choice, set by RT, which no model
## can read off a resistor -- state it to match. **`rtop`, `rbot`, `ilim`,
## `tedge` and `tminon` are order-of-magnitude stand-ins, not datasheet
## values**, and the compensation (`gmc`, `rzc`, `slope`) is chosen for a
## sensible loop rather than fitted to the part's internal network. That is a
## real limit and it bounds what may be claimed from this model:
##
##   * **Ripple is trustworthy.** Output ripple is set by the inductor's
##     current triangle into the output capacitor's ESR and capacitance, and
##     the triangle is set by V_IN, V_OUT, L and the switching frequency --
##     every one of them a board value, none of them a stand-in here. The
##     switch resistances shift the duty cycle by under a percent at these
##     currents and move the ripple by less.
##   * **A phase margin is not.** The compensation above is not the part's,
##     so a margin measured through it would be a statement about the numbers
##     on this page. That claim needs the internal network, which is not
##     published, or a measurement.
##   * There is no dead time, no body diode and no discontinuous mode: the
##     switches are complementary, so at a load light enough to reverse the
##     inductor current the model keeps conducting where the real part would
##     enter Burst Mode. There is no thermal behaviour and no efficiency
##     claim -- the conduction loss is present but the switching loss is not.

import std/math
import verax/spice/xspice/dsl

const
  ## Analog state slots. Rolled back with the timepoint, which is the whole
  ## reason for them over `stateVar`: a switching model decides things (this
  ## cycle's turn-off) that a rejected timestep has to be able to un-decide.
  stVc = 1      ## the compensation node, integrated
  stTOff = 2    ## absolute time this cycle's top switch turned off
  stCycle = 3   ## which switching cycle the last accepted timepoint was in

codeModel "lt8640a_sw":
  description "lt8640a switching step-down: peak current mode, real switch node"

  port vin,  dir = xdInout, default = xpG, allowed = [xpG],
             description = "input supply: senses V_IN and draws the switch current"
  port fb,   dir = xdIn,    default = xpV, allowed = [xpV],
             description = "feedback, regulated to vref"
  port en,   dir = xdIn,    default = xpV, allowed = [xpV],
             description = "enable / undervoltage lockout"
  port trss, dir = xdInout, default = xpG, allowed = [xpG],
             description = "soft start: sources iss into the external cap"
  port sw,   dir = xdInout, default = xpG, allowed = [xpG],
             description = "switch node: top and bottom switch on-resistance"
  port pg,   dir = xdOut,   default = xpV, allowed = [xpV],
             description = "power good"
  port bst,  dir = xdInout, default = xpG, allowed = [xpG], nullAllowed = true,
             description = "bootstrap, as a DC load only"

  param vref,     float, default = 0.970,  description = "feedback reference (V)"
  param iss,      float, default = 1.9e-6, description = "tr/ss pull-up current (A)"
  param iq,       float, default = 2.5e-6, description = "quiescent current from vin (A)"
  param fsw,      float, default = 1.0e6,  description = "switching frequency (Hz), set by RT on the board"
  param rtop,     float, default = 0.070,  description = "top switch on-resistance (ohm)"
  param rbot,     float, default = 0.035,  description = "bottom switch on-resistance (ohm)"
  param ilim,     float, default = 7.0,    description = "peak inductor current at full command (A)"
  param tedge,    float, default = 1.0e-8, description = "switch transition time (s)"
  param tminon,   float, default = 3.0e-8, description = "minimum top-switch on-time (s)"
  param dmax,     float, default = 0.95,   description = "maximum duty cycle"
  param gmc,      float, default = 1.0e6,  description = "error amp integrator gain (1/V/s)"
  param rzc,      float, default = 20.0,   description = "compensation zero: peak command per volt of error (1/V)"
  param slope,    float, default = 0.15,  description = "slope compensation, fraction of ilim per cycle"
  param nsub,     float, default = 50.0,   description = "forced timepoints per switching cycle"
  param aol,      float, default = 1.0e4,  description = "error amplifier gain in the dc solve"
  param ven_th,   float, default = 1.00,   description = "en/uv rising threshold (V)"
  param ven_hyst, float, default = 0.04,   description = "en/uv hysteresis (V)"
  param pg_band,  float, default = 0.08,   description = "pg window, fraction of vref"
  param vpg,      float, default = 3.4,    description = "pg high level (V)"
  param rss_dis,  float, default = 200.0,  description = "tr/ss pull-down when off (ohm)"
  param rbst,     float, default = 1.0e5,  description = "bootstrap DC load (ohm)"

  stateVar enabled, float

  eval:
    # BST exists to give the pin a DC reference and nothing else, exactly as
    # in the averaged model: the datasheet circuit hangs C_BST between BST and
    # SW and nothing else, so without a path here that node is singular.
    output(bst) = input(bst) / param(rbst)
    partial(bst, bst) = 1.0 / param(rbst)

    let vi = input(vin)
    let vs = input(sw)
    let vt = input(trss)
    let vf = input(fb)

    # The state slots have to exist before the first transient timepoint.
    # `init` is true exactly once per instance, on its very first call ever --
    # and every analysis begins with an operating-point solve, so that call is
    # always a `maDc` one and the guard below never actually withholds the
    # allocation. It is written anyway because `cm_analog_alloc` reaches for
    # the state vectors of the analysis about to run, and `.ac` has none.
    if init and analysis != maAc:
      analogAlloc(stVc, float)
      analogAlloc(stTOff, float)
      analogAlloc(stCycle, float)

    # EN/UV with hysteresis: the threshold to turn on is above the one to stay
    # on, so a slowly-rising supply does not chatter the part across a single
    # trip point.
    let was = stateVar(enabled)
    let onNow =
      if was > 0.5: input(en) > param(ven_th) - param(ven_hyst)
      else: input(en) > param(ven_th)
    stateVar(enabled) = (if onNow: 1.0 else: 0.0)

    if not onNow:
      # Shut down. TR/SS is pulled to ground through an internal MOSFET so the
      # next start-up begins from zero, and both switches are off -- which for
      # a conductance port means a large resistance, not a disconnected pin:
      # SW would otherwise have no DC path and the matrix would be singular.
      output(sw) = vs / 1.0e6
      partial(sw, sw) = 1.0e-6
      partial(sw, vin) = 0.0
      partial(sw, fb) = 0.0
      output(vin) = param(iq)
      partial(vin, vin) = 0.0
      partial(vin, sw) = 0.0
      output(trss) = vt / param(rss_dis)
      partial(trss, trss) = 1.0 / param(rss_dis)
      output(pg) = 0.0
      partial(pg, fb) = 0.0
    else:
      let tnow = time
      let period = 1.0 / param(fsw)

      # TR/SS. At DC the pin is held at the reference so the node has a
      # definite solution -- a capacitor is an open circuit to the operating
      # point solver, and 1.9 uA into nothing leaves the pin unconstrained. In
      # time-domain it is a constant current out of the pin, so the ramp rate
      # is set by C_SS on the board rather than by anything in here.
      if analysis == maDc:
        output(trss) = (vt - param(vref)) / param(rss_dis)
        partial(trss, trss) = 1.0 / param(rss_dis)
      else:
        output(trss) = -param(iss)
        partial(trss, trss) = 0.0

      let vr =
        if analysis == maDc: param(vref)
        else: min(param(vref), vt)

      # `son` is the top switch's conduction fraction, and it is the only
      # thing that differs between the dc solve and the switching run: at DC
      # it is the duty cycle the error amplifier asks for, in a transient it
      # is 1 or 0 with a finite edge between them. Everything after it is the
      # same arithmetic either way.
      var son = 0.0
      var dSlope = 0.0
        ## d(son)/d(v_fb), which exists only in the averaged branch: in the
        ## switching one the path from FB to the switch runs through a latch,
        ## and a step has no derivative to report.

      if analysis != maTran or tnow <= 0.0:
        # --- the averaged branch: the dc solve, and t = 0 -----------------
        #
        # A switching model still has to answer "where does this circuit
        # sit", and at DC there is no time for it to switch in. So the switch
        # pair collapses to its cycle average, with the duty coming from the
        # error amplifier exactly as in `lt8640a_avg`. The transient's first
        # timepoint uses it too, which is what makes t = 0 continuous with
        # the operating point ngspice solved just before it.
        son = param(aol) * (vr - vf)
        dSlope = -param(aol)
        if son > param(dmax):
          son = param(dmax)
          dSlope = 0.0
        elif son < 0.0:
          son = 0.0
          dSlope = 0.0
      else:
        # --- the switching branch ----------------------------------------
        let cyc = floor(tnow * param(fsw))
        let tclk = cyc * period
        let tc = tnow - tclk

        # The error amplifier: a transconductance stage into a compensation
        # capacitor, plus the series resistance that puts a zero in it. The
        # integral is ngspice's own -- `analogIntegrate` uses whatever method
        # the rest of the deck is being solved with, where adding
        # `integrand * tstep` by hand would be forward Euler regardless.
        let err = vr - vf
        var dvc = 0.0
        var vcInt = analogIntegrate(stVc, param(gmc) * err, dvc)
        # Anti-windup: the command saturates, and an integrator left to run
        # past it takes just as long to come back, which is a recovery
        # overshoot that belongs to the model rather than to the part.
        if vcInt > 1.0:
          vcInt = 1.0
          analogVar(stVc, 0, float) = 1.0
        elif vcInt < 0.0:
          vcInt = 0.0
          analogVar(stVc, 0, float) = 0.0
        let vc = max(0.0, min(1.0, vcInt + param(rzc) * err))

        # The cycle-by-cycle latch. Read the last *accepted* timepoint, never
        # this iteration's: within one timepoint the solver calls this many
        # times and the current wanders, and a latch that believed each
        # iteration would chatter. A new cycle clears it.
        let prevCyc = analogVar(stCycle, 1, float)
        let prevTOff = analogVar(stTOff, 1, float)
        var tOff = (if abs(cyc - prevCyc) > 0.5: Inf else: prevTOff)

        if tnow < tOff:
          # The comparator only ever runs on the plateau, `tminon` being
          # longer than an edge, so the top switch is fully on and its
          # current *is* the inductor current.
          let iSense = (vi - vs) / param(rtop)
          # Slope compensation is sized against the inductor's own current
          # downslope rather than against the current limit; half the
          # downslope is the textbook figure, and 0.15 of `ilim` per cycle is
          # comfortably above it for a 5 V rail out of 3.3 uH. It costs
          # command headroom, which is why a figure chosen too large does
          # real damage: measured at 0.5 it pinned the error amplifier
          # against its clamp and left the loop running on its proportional
          # term alone, with a 12.7 mV static droop on a rail whose
          # integrator should leave none.
          let ipk = param(ilim) * (vc - param(slope) * (tc / period))
          if tc >= param(tminon) and iSense >= ipk:
            tOff = tnow
        if tc >= param(dmax) * period and tOff > tclk + param(dmax) * period:
          tOff = tclk + param(dmax) * period

        analogVar(stCycle, 0, float) = cyc
        analogVar(stTOff, 0, float) = tOff

        # The edge is smootherstep (6u^5 - 15u^4 + 10u^3) rather than a
        # straight ramp, and that is not cosmetic. A linear ramp has a corner
        # at each end -- the driven node's second derivative is a delta there,
        # and truncation-error control answers a delta by halving the timestep
        # until it gives up: measured with a 2 ns linear edge, `Timestep too
        # small; time = 2.2e-09, timestep = 3.4e-20` at the first edge of the
        # run. A raised cosine was the first fix and is not enough: it leaves
        # the *first* derivative continuous at both ends but steps the
        # *second* (its curvature jumps from +-0.5*(PI/tedge)^2 to 0 where the
        # edge meets the flat region), and the same truncation-error control
        # collapses the timestep at that curvature break -- measured, a 2 ns
        # print step died with `Timestep too small` at `tclk + tedge` of the
        # first cycle, which is exactly the step `analyzeOscillation` picks
        # (10000 samples over a 20 us window) and the reason a design could
        # not claim `fSw` through this model. smootherstep is zero in both the
        # first and second derivative at u = 0 and u = 1, so the edge joins
        # the flat regions to second order and the model runs at any print
        # step from ~1 ns up. `uOff` is only read on the falling edge, where
        # `tOff` is finite; on the plateau (`tnow < tOff`, possibly Inf) the
        # `1.0` branch is taken before it is touched.
        let uOn = (tnow - tclk) / param(tedge)
        let uOff = (tnow - tOff) / param(tedge)
        son =
          if tnow < tclk + param(tedge):
            uOn * uOn * uOn * (uOn * (uOn * 6.0 - 15.0) + 10.0)
          elif tnow < tOff: 1.0
          elif tnow < tOff + param(tedge):
            1.0 - uOff * uOff * uOff * (uOff * (uOff * 6.0 - 15.0) + 10.0)
          else: 0.0
        son = max(0.0, min(1.0, son))

        # Nothing else in the simulator knows a clock edge is coming: between
        # edges the interesting nodes are smooth, so truncation-error control
        # will step straight over one. The forced sub-steps are what give the
        # current comparator its resolution -- coarser, and the peak is
        # detected late and the duty jitters -- and the breakpoints on the
        # edges themselves are what stop the solver having to *discover* a
        # 10 ns transition inside a 20 ns step.
        setPermBkpt(tclk + period)
        setTempBkpt(tclk + param(tedge))
        if tOff < tclk + period:
          setTempBkpt(tOff)
          setTempBkpt(tOff + param(tedge))
        if param(nsub) > 0.0:
          setTempBkpt(tnow + period / param(nsub))

      # --- the switch pair ------------------------------------------------
      #
      # A Thevenin source at `son * V_IN` behind the conduction-weighted
      # on-resistance, rather than two conductances in parallel. The two are
      # identical at `son` of 0 and 1 and differ entirely in between, which is
      # where it matters: a pair of crossfading conductances is a
      # **shoot-through path** from V_IN to ground, and at the crossover point
      # that path is 105 mohm across 12 V. Measured, it put 60 A spikes
      # through the input capacitors' ESL every edge -- an artefact of the
      # crossfade, since the real part's switches are never both on. Driving
      # the node instead means the current drawn from V_IN is the top switch's
      # current and nothing else, which is also what makes the input
      # capacitor's ripple current worth reading.
      let rth = son * param(rtop) + (1.0 - son) * param(rbot)
      let gth = 1.0 / rth
      let iL = (son * vi - vs) * gth

      output(sw) = (vs - son * vi) * gth
      partial(sw, sw) = gth
      partial(sw, vin) = -son * gth
      partial(sw, fb) = -gth * vi * dSlope

      output(vin) = son * iL + param(iq)
      partial(vin, vin) = son * son * gth
      partial(vin, sw) = -son * gth

      if analysis == maTran and tnow <= 0.0:
        # Seed the compensation state from the operating point rather than
        # from a guess: the loop has to start commanding roughly the current
        # the load is already drawing, or the run opens with a start-up
        # transient it was set up to skip. Clamped away from both rails so
        # the first cycle can move in either direction.
        analogVar(stVc, 0, float) = max(0.02, min(0.98, iL / param(ilim)))
        analogVar(stTOff, 0, float) = 0.0
        analogVar(stCycle, 0, float) = -1.0

      output(pg) =
        if abs(vf - param(vref)) < param(pg_band) * param(vref): param(vpg)
        else: 0.0
      partial(pg, fb) = 0.0
