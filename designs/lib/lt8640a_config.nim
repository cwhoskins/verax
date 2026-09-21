## The buck converter sheet's design equations: the feedback network for a
## requested output voltage, RT for a requested switching frequency, and the
## two behavioural-model parameters closest to a real "mode" strap on this
## part -- see `useLt8640a`'s own doc comment (`designs/lib/lt8640a.nim`)
## for why `ilim`/`dmax` and not a `SYNC/MODE` pin.
##
## **This sheet is pure computation, not a `subckt` -- historically because
## nesting broke it, now just because nobody has needed one yet.** Every
## other sheet in this board returns a `subckt`-shaped `Netlist` for
## `instance` to place; this one didn't, because `Component.simReplace`
## (what attaches the LT8640A's XSPICE behavioural models) bakes its
## device's node list into a string attribute (`xspice.ports`, see
## `spice/probes.nim`'s own doc comment) at *model-pass* time, and every
## analysis used to run that pass **before** `spice/flatten.nim` had
## resolved a nested instance's internal nets back to their board-level
## names -- measured: nesting the LT8640A one level deep under an
## `instance` put the literal template-local names `VIN`, `fb`, `EN`,
## `trss`, `sw`, `pg`, `bst` into the deck's `A` line instead of the
## resolved ones, floating every one of those nodes and failing the `.op`
## outright ("Timestep too small" on a *DC* solve, from a genuinely
## singular matrix). No other design in this repository had ever nested an
## XSPICE-modelled part inside a subcircuit instance, so this was a real,
## previously unexercised limit rather than a design mistake.
##
## **Fixed**: every one of the nine analysis call sites (`analyses/*.nim`)
## now clones, flattens, and only *then* calls
## `spice/transform.applySimReplacements` -- three explicit steps in place
## of the combined `materializeSimNetlist` (clone+replace) followed by
## flatten -- so a code model's ports are rendered from post-flatten net
## names, which still exist, rather than child-template-local ones flatten
## is about to rename out from under them. See `spice/flatten.nim`'s module
## doc and `spice/transform.applySimReplacements`'s own doc comment for the
## detail. `designs/datalogger/datalogger.nim` (the first caller) still
## declares the buck's components directly, at the same (flat) level
## `designs/lt8640a_buck.nim` always has, driven by the values this module
## computes -- it was built as a workaround for the bug above and there is
## no correctness reason left to restructure it now that nesting works;
## re-platforming it onto a nested `subckt` sheet like this module could now
## grow is future housekeeping, not a fix. This module can grow a
## `subckt`-returning sheet proc like every other generic building block
## under `designs/lib/` whenever that housekeeping happens.

import verax/units

type
  BuckConfig* = object
    voltage*: Volts
    freq*: Hertz
    ilim*: Amps
      ## The model's peak inductor current limit. `0.A` (the default) means
      ## "leave the model's own default" -- see `useLt8640a`.
    dmax*: float
      ## The model's maximum duty cycle. `0.0` (the default) means "leave
      ## the model's own default".
    inductor*: Henries
    isat*: Amps
    inductorRating*: Amps
    outCap*: Farads
    r2*: Ohms
      ## The bottom feedback resistor. Held fixed and `r1` solved from it,
      ## the same split `designs/lt8640a_buck.nim` makes by hand -- see
      ## `feedbackPair`.

proc buckConfig*(voltage: Volts, freq = 1.0.MHz, ilim = 0.0.A, dmax = 0.0,
                 inductor = 3.3.uH, isat = 3.0.A, inductorRating = 1.5.A,
                 outCap = 47.0.uF, r2 = 100.0.kohm): BuckConfig =
  BuckConfig(voltage: voltage, freq: freq, ilim: ilim, dmax: dmax,
             inductor: inductor, isat: isat, inductorRating: inductorRating,
             outCap: outCap, r2: r2)

proc feedbackPair*(cfg: BuckConfig): tuple[r1, r2: Ohms] =
  ## `V_OUT = 0.970 * (1 + R1/R2)`, the reference every LT8640A design in
  ## this repo reads off the same model (`designs/lt8640a_buck.nim`'s own
  ## header). `r2` is `cfg.r2` and `r1` is solved from it -- exact for
  ## whatever `cfg.voltage` asks for, and neither is snapped to a preferred
  ## series, the same choice `designs/lib/filters.nim` makes and for the
  ## same reason: see that module's own doc comment.
  let ratio = float(cfg.voltage) / 0.970 - 1.0
  doAssert ratio > 0.0,
    "feedbackPair: " & $float(cfg.voltage) & " V is at or below what this " &
    "part's 0.970 V reference can reach with any positive ratio"
  (r1: Ohms(float(cfg.r2) * ratio), r2: cfg.r2)

proc rtForFsw*(freq: Hertz): Ohms =
  ## RT sets the switching frequency through the part's internal gm
  ## oscillator. The only calibration point this codebase has actually
  ## verified against the datasheet is the front-page schematic's own
  ## **41.2 kOhm -> 1 MHz** (`designs/lt8640a_buck.nim`) -- ADI's full
  ## RT-vs-frequency table was not reachable to confirm a second point, so
  ## this is **not** a transcribed datasheet formula. A gm-oscillator's
  ## period against its programming resistor is ordinarily close to
  ## `fSW * RT = constant` over a part's specified range, and that is what
  ## this scales from the one verified point -- exact at 1 MHz, an
  ## assumption everywhere else. State a real RT from ADI's Table 1 where
  ## this matters more than a reasonable board value.
  Ohms(41200.0 * 1.0e6 / float(freq))
