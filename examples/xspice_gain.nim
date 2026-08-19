## An XSPICE code model -- a behavioural gain block -- written in Nim.
##
## This is the Nim equivalent of ngspice's own `src/xspice/icm/analog/gain`,
## whose C version needs two hand-maintained files (`ifspec.ifs` and
## `cfunc.mod`) that nothing cross-checks. Here the ports and parameters are
## declared once, so `param(gain)` and `partial(outp, inp)` are resolved
## against them at compile time.
##
## Build it into a loadable `.cm` with `nimcir/spice/xspice/build`:
##
## ```nim
## import nimcir/spice/xspice/build
## discard buildCodeModel("examples/xspice_gain.nim", "/tmp/gain.cm")
## ```
##
## then use it from a deck:
##
## ```
## a1 vin vout g1
## .model g1 nimgain(gain=2.0)
## .control
## pre_codemodel /tmp/gain.cm
## op
## .endc
## ```

import nimcir/spice/xspice/dsl

codeModel "nimgain":
  description "a behavioural gain block, written in nim"

  port inp,  dir = xdIn,  default = xpV,
             allowed = [xpV, xpVd, xpI, xpId, xpVnam],
             description = "input"
  port outp, dir = xdOut, default = xpV,
             allowed = [xpV, xpVd, xpI, xpId],
             description = "output"

  param gain,      float, default = 1.0, description = "gain"
  param in_offset, float, default = 0.0, description = "input offset"

  eval:
    if analysis != maAc:
      output(outp) = param(gain) * (input(inp) + param(in_offset))
      # The simulator needs d(out)/d(in) to solve the nonlinear system; a
      # wrong partial shows up as non-convergence, not as a wrong number.
      partial(outp, inp) = param(gain)
    else:
      acGain(outp, inp) = MifComplex(real: param(gain), imag: 0.0)
