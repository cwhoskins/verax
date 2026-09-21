## The buck-topology design equations, independent of which part implements
## them.
##
## Split out of `designs/lib/lt8640a.nim`, which used to carry `BuckConfig`
## and every proc below alongside the LT8640A's own XSPICE models,
## `simReplace` attachment and `buckSheet`. That file's own doc comment
## already tells the story of why `BuckConfig` and these equations were once
## split into `lt8640a_config.nim` and merged back -- this split is the same
## question asked again now that a second reason to separate them exists: a
## second part's sheet would want `inductorForRipple`/`outputCapForRipple`/
## `inputCapForRipple` and would have nothing to do with an LT8640A `.cm`.
## `lt8640a.nim` `import`s and `export`s this module, so nothing that already
## reads `buckConfig`/`BuckConfig`/`buckSheet` off `lt8640a` has to change.
##
## **Not fully part-agnostic yet.** `BuckConfig.ilim`/`dmax` are the
## LT8640A's own behavioural-model knobs (see `lt8640a.useLt8640a`'s own doc
## comment) and `r2` is specific to sizing the feedback divider against *this
## part's* 0.970 V reference (`lt8640a.feedbackPair`) -- they live on this
## type anyway because exactly one part is modelled in this codebase today,
## and a config type generic enough to describe a part that does not exist
## yet is a worse bet than moving them out once a second part needs to. What
## is genuinely general -- the topology, the ripple equations, the load
## current a converter is sized to deliver -- is everything else here.

import verax/units

# `inputBank`/`outputBank` are `CapBankSpec`s, so a caller stating one needs
# `capBankSpec`/`CapBankSpec` -- re-exported here for the same reason
# `lt8640a.nim` re-exports this module: one `import` reaches everything
# `buckConfig` takes.
import ./capbank
export capbank

type
  BuckConfig* = object
    voltage*: Volts
      ## The output rail this converter regulates to.
    vin*: Volts
      ## The board's input rail this converter runs from. A sheet's own
      ## `VIN` port is still wired by whatever net the caller instances it
      ## onto -- this does not constrain that -- it exists only so the
      ## input-side bypass caps can be sized against the voltage they
      ## actually see, the same way the output-side ones are sized against
      ## `voltage`.
    freq*: Hertz
    ilim*: Amps
      ## The LT8640A model's peak inductor current limit. `0.A` (the
      ## default) means "leave the model's own default" -- see
      ## `lt8640a.useLt8640a`. Not part-agnostic -- see this module's own
      ## doc comment.
    dmax*: float
      ## The LT8640A model's maximum duty cycle. `0.0` (the default) means
      ## "leave the model's own default". Not part-agnostic -- see this
      ## module's own doc comment.
    loadCurrent*: Amps
      ## The load current this converter is sized to deliver. Stated rather
      ## than derived because nothing upstream of it says what the board
      ## draws -- it feeds a sheet's own current rating and
      ## `inputCapForRipple`, whose input-ripple current scales with the
      ## load, the one place on this config that needs it.
    inductorRipple*: Amps
      ## Target peak-to-peak inductor ripple current -- the output inductor
      ## is sized from it by `inductorForRipple`, not stated directly.
    outputRipple*: Volts
      ## Target output voltage ripple -- the output capacitor is sized from
      ## it (together with `inductorRipple`) by `outputCapForRipple`.
      ## Capacitive-only, same caveat as that proc's own doc comment: this
      ## is a floor, not the whole of what a real board's ripple will
      ## measure.
    inputRipple*: Volts
      ## Target input voltage ripple -- the input bulk capacitor is sized
      ## from it by `inputCapForRipple`.
    isat*: Amps
    inductorRating*: Amps
    r2*: Ohms
      ## The bottom feedback resistor for the LT8640A's own 0.970 V
      ## reference. Held fixed and `r1` solved from it, the same split
      ## `designs/lt8640a_buck.nim` makes by hand -- see `lt8640a.feedbackPair`.
      ## Not part-agnostic -- see this module's own doc comment.
    inputBank*: CapBankSpec
      ## How `inputCapForRipple`'s total is split into real parts -- see
      ## `capbank.capBank`. Part-agnostic: any buck's input bulk capacitance
      ## is split the same way.
    outputBank*: CapBankSpec
      ## As `inputBank`, for `outputCapForRipple`'s total.

proc buckConfig*(voltage: Volts, freq = 1.0.MHz, ilim = 0.0.A, dmax = 0.0,
                 loadCurrent = 2.0.A, inductorRipple = 0.6.A,
                 outputRipple = 2.0.mV, inputRipple = 100.0.mV,
                 isat = 3.0.A, inductorRating = 1.5.A, r2 = 100.0.kohm,
                 vin = 12.0.V, inputBank = capBankSpec(),
                 outputBank = capBankSpec()): BuckConfig =
  ## A buck converter sheet's design equations: the feedback network for a
  ## requested output voltage, RT for a requested switching frequency, the
  ## two behavioural-model parameters closest to a real "mode" strap on the
  ## LT8640A -- see `lt8640a.useLt8640a`'s own doc comment for why
  ## `ilim`/`dmax` and not a `SYNC/MODE` pin -- and the output inductor,
  ## output capacitor and input bulk capacitor sized from ripple targets
  ## rather than stated as component values (`inductorForRipple`,
  ## `outputCapForRipple`, `inputCapForRipple`; the defaults here are round
  ## numbers for a few-amp board, not any part's own datasheet figures --
  ## state real targets where they matter more than a reasonable default).
  ## `vin` defaults to 12 V, the front-page reference design's input
  ## (`designs/lt8640a_buck.nim`) -- a caller on a different rail
  ## (`designs/datalogger`'s 5 V USB bus) should state its own, since it is
  ## what sizes the input-side bypass caps' voltage rating.
  ##
  ## `inputBank`/`outputBank` say how those two ripple-sized totals become
  ## real parts -- see `capbank.capBank`. Defaulted (`capBankSpec()`, X7R,
  ## 0805 ceiling) so an existing caller stating neither is unaffected; a
  ## board with a tighter keepout or a denser rail states its own.
  ##
  ## `lt8640a.buckSheet` is this computation wrapped in an actual
  ## `subckt`-returning sheet proc, for a caller (`designs/datalogger`'s)
  ## that wants the whole converter as one `instance` -- see that proc's own
  ## doc comment for why nesting an XSPICE-modelled part under an `instance`
  ## needed a real fix before it could exist.
  BuckConfig(voltage: voltage, vin: vin, freq: freq, ilim: ilim, dmax: dmax,
             loadCurrent: loadCurrent, inductorRipple: inductorRipple,
             outputRipple: outputRipple, inputRipple: inputRipple,
             isat: isat, inductorRating: inductorRating, r2: r2,
             inputBank: inputBank, outputBank: outputBank)

proc inductorForRipple*(vin, vout: Volts, freq: Hertz, ripple: Amps): Henries =
  ## Solves the standard buck inductor-ripple equation for `L` instead of
  ## measuring it after the fact. `designs/lt8640a_buck.nim`'s header states
  ## it the other way round -- `dI = V_OUT * (1 - D) / (L * f)`,
  ## `D = V_OUT / V_IN`, measured 0.94 A at D = 0.43 for that design's
  ## 3.3 uH -- rearranged here to
  ## `L = V_OUT * (V_IN - V_OUT) / (V_IN * f * dI)`.
  ##
  ## `ripple` is the target peak-to-peak inductor current itself, not a
  ## fraction of load current: a caller wanting "30% of load" states that
  ## arithmetic and passes the result, the same way `buckConfig`'s
  ## `inductorRipple` argument is always a stated amps value rather than a
  ## percentage.
  doAssert float(vin) > float(vout),
    "inductorForRipple: V_IN (" & $vin & ") must exceed V_OUT (" & $vout &
    ") for a buck topology"
  doAssert float(ripple) > 0.0,
    "inductorForRipple: ripple current must be positive"
  Henries(float(vout) * (float(vin) - float(vout)) /
          (float(vin) * float(freq) * float(ripple)))

proc outputCapForRipple*(ripple: Amps, freq: Hertz, voltageRipple: Volts): Farads =
  ## The capacitive half of output ripple, `dV = dI / (8 * f * C)`, solved
  ## for `C`. `ripple` is the same peak-to-peak inductor current
  ## `inductorForRipple` targets, or an inductor's measured triangle
  ## (`designs/lt8640a_buck.nim`'s 0.94 A) -- the current that flows into and
  ## out of the output capacitor once the inductor's DC component is
  ## subtracted off.
  ##
  ## **Capacitive-only, not the whole story.** This codebase's own measured
  ## ripple (`designs/lt8640a_buck.nim`'s 6.95 mV against 3 mohm of ESR and
  ## 0.94 A) is dominated by `dI * ESR`, not by this term -- a low-ESR
  ## ceramic bank's ripple is close to what this returns, a tantalum or
  ## electrolytic's is not. Add `ripple * esr` on top when the part's ESR is
  ## known, and size against that instead of this alone.
  doAssert float(ripple) > 0.0,
    "outputCapForRipple: ripple current must be positive"
  doAssert float(voltageRipple) > 0.0,
    "outputCapForRipple: voltage ripple target must be positive"
  Farads(float(ripple) / (8.0 * float(freq) * float(voltageRipple)))

proc inputCapForRipple*(iout: Amps, vin, vout: Volts, freq: Hertz,
                        voltageRipple: Volts): Farads =
  ## The input capacitor absorbs the same pulsed current the switch draws
  ## from `VIN`: on for `D` of the cycle, off for the rest.
  ## `dV = I_OUT * D * (1 - D) / (C * f)`, `D = V_OUT / V_IN`, solved for `C`.
  ##
  ## `iout` is the load current the converter is sized to deliver --
  ## `BuckConfig.voltage` names the rail, not the current on it, so a caller
  ## states that current here explicitly rather than it being read off the
  ## config.
  doAssert float(vin) > float(vout),
    "inputCapForRipple: V_IN (" & $vin & ") must exceed V_OUT (" & $vout &
    ") for a buck topology"
  doAssert float(iout) > 0.0,
    "inputCapForRipple: load current must be positive"
  doAssert float(voltageRipple) > 0.0,
    "inputCapForRipple: voltage ripple target must be positive"
  let d = float(vout) / float(vin)
  Farads(float(iout) * d * (1.0 - d) / (float(freq) * float(voltageRipple)))
