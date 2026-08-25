## Parts shared between designs: `.MODEL` cards, and the provenance of the
## numbers in them.
##
## This module exists because a model card is exactly the kind of thing that
## must not be retyped. `Netlist.models` stores a card verbatim and nothing
## parses it, which is the right call -- the simulator then reads precisely
## what the datasheet said -- but it also means a typo in a card is
## indistinguishable from a deliberate parameter, and a diode with a subtly
## wrong `IS` simulates as a different part with nothing reported anywhere.
## One copy, named, with its source written down beside it.
##
## Use it from a design like this:
##
## ```nim
## import ./lib/parts
##
## let d = design("...")
##   model d1N4148, d1N4148Card
##   component D1, kind = "diode", partNumber = d1N4148, value = d1N4148:
##     pin "A", a, kind = ptPassive
##     pin "K", k, kind = ptPassive
## ```
##
## The `model` statement takes two ordinary string *expressions*, not string
## literals, so a `const` from here reaches it unchanged. `value` must name
## the model for `kinds.hasDeviceModel` to bind them -- SPICE binds a device
## to a model by the last token of its device line, and that token is
## `attrs["value"]`. Spell the name once, here, and a design cannot get the
## two out of step.

const
  d1N4148* = "1N4148"
  d1N4148Card* =
    "D(IS=2.52n RS=0.568 N=1.752 CJO=4p M=0.4 VJ=0.4 " &
    "BV=110 IBV=100u TT=20n)"
    ## Small-signal silicon switching diode. This is the card
    ## `designs/ts808_drive.nim` established: without it the pedal's clipping
    ## pair became two 1 Mohm resistors to ground and shunted the inverting
    ## node with 500k, worth 4.2 dB of gain the circuit does not have.
    ##
    ## Forward drop is roughly 0.6 V at 1 mA and 0.75 V at 20 mA, which is
    ## what makes it the *wrong* diode for a charge pump and the right one
    ## for a soft clipper.

  d1N5819* = "1N5819"
  d1N5819Card* =
    "D(IS=31.7u RS=0.051 N=1.373 CJO=160p M=0.38 VJ=0.6 " &
    "BV=40 IBV=1m EG=0.69 XTI=2)"
    ## 1 A / 40 V Schottky. `EG=0.69` and `XTI=2` are what make it a Schottky
    ## rather than a silicon diode with a small `IS`: they set the barrier
    ## height and the saturation-current temperature exponent, and leaving
    ## them at the silicon defaults (1.11 eV, 3) is the usual way a Schottky
    ## model comes out wrong.
    ##
    ## Forward drop is roughly 0.20 V at 10 mA rising to about 0.45 V at 1 A.
    ## `designs/charge_pump.nim` checks that figure rather than assuming it,
    ## because a doubler's output is its drive minus two of these and nothing
    ## else -- the diode *is* the specification.

  packageElectrolytic* = "electrolytic"
  packageFilm* = "film"
  packageTantalum* = "tantalum"
    ## The `package` keys `spice/models.defaultParasitics()` recognises, spelled
    ## once. A misspelling here is not an error -- it silently falls through to
    ## the global fallback (20 mohm, 1 nH), which for an electrolytic is wrong
    ## by an order of magnitude in ESR and reported only as an assumption.
