## An XSPICE code model with **analog state**: a time integrator.
##
##   nim c --path:../src -d:xspiceGenIfs xspice_integrator.nim
##
## `xspice_gain.nim` is memoryless and `xspice_dff.nim` is event-driven; this
## is the third shape, and the one a switching converter or any other
## continuous-time model with memory needs. Three things are new in it:
##
##   * **`analogAlloc` / `analogVar`** reserve and read a per-instance state
##     slot. ngspice rotates these buffers per accepted timepoint and rolls
##     them back when it rejects one, which is what makes them the correct
##     home for a value that has to survive a timestep the solver then
##     abandons. `stateVar` is *not* rolled back and would quietly keep a
##     value from a timepoint that never happened.
##   * **`analogIntegrate`** integrates with the simulator's own method,
##     whatever the rest of the deck is being solved with. Adding
##     `integrand * tstep` by hand would be forward Euler regardless, which
##     is a different circuit from the one the deck asked for.
##   * **`setPermBkpt`** forces a timepoint. Nothing else in the simulator
##     knows this model has anything happening at a particular time, so a
##     model whose behaviour changes on a schedule has to say so or the
##     step controller will walk straight over it. Here it is only
##     demonstrated -- the integrator has no edges -- by pinning a timepoint
##     on every `tsample`.
##
## `out_ic` is returned at t = 0 rather than integrating, exactly as ngspice's
## own `int` model does: `cm_analog_integrate` refuses outside `.tran`, and at
## the operating point there is no interval to integrate over.

import std/math
import nimcir/spice/xspice/dsl

const stIntegral = 1

codeModel "nimint":
  description "time integrator with analog state"

  port inp,  dir = xdIn,  default = xpV, allowed = [xpV],
             description = "integrand"
  port outp, dir = xdOut, default = xpV, allowed = [xpV],
             description = "its integral"

  param gain,    float, default = 1.0, description = "scales the integrand"
  param out_ic,  float, default = 0.0, description = "value at t = 0 (V)"
  param tsample, float, default = 0.0,
                 description = "force a timepoint every tsample seconds; 0 for none"

  eval:
    if analysis == maAc:
      # 1/(j w): purely imaginary and negative, since integration lags by 90
      # degrees. `radFreq` is already the stored angular frequency.
      acGain(outp, inp) = MifComplex(real: 0.0, imag: -param(gain) / radFreq)
    else:
      if init:
        analogAlloc(stIntegral, float)

      var slope = 0.0
      var value = param(out_ic)
      if analysis == maTran and time > 0.0:
        value = analogIntegrate(stIntegral, param(gain) * input(inp), slope)
      else:
        analogVar(stIntegral, 0, float) = value

      output(outp) = value
      partial(outp, inp) = slope * param(gain)

      if param(tsample) > 0.0 and analysis == maTran:
        setPermBkpt((floor(time / param(tsample)) + 1.0) * param(tsample))
