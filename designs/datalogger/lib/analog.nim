## The analog input sheet: a single-supply non-inverting gain stage built
## from `designs/lib/opamp_stages.nonInvertingAmp`, with the VDD/2 bias
## circuitry that makes it work on a single supply pulled out into its own
## subcircuit, `designs/lib/bias.biasNetwork` -- generic, like `opamp_stages`,
## and not specific to this board -- wired separately ahead of it, onto
## the non-inverting *input*, not onto `REF`. `REF` stays tied straight to
## true `GND`, the way `opamp_stages`'s own doc comment says a dual-supply
## board would wire it: this stage's gain-setting leg (`RG`, `REF` to the
## feedback node) is a real ground return, not a bias rail, so
## `gain = 1 + Rf/Rg` holds with no bias term folded in. What makes the
## stage single-supply instead is entirely upstream of `IN` -- `biasNetwork`
## AC-couples `AIN` onto a node held at `VDD/2`, so the op-amp's
## non-inverting input sees a DC-biased, AC-coupled version of the input
## signal and the feedback network never sees the bias at all.
##
## Ports: `AIN`, `AOUT`, `VDD`, `GND`.
##
## The op-amp `datalogger.nim`'s `opamp_stage`/`gain_stage` roles claim sits
## two levels deeper than it once did, at `<instance>.Xamp.U1` --
## `innerComponent` walks a multi-segment path exactly as readily as a
## single one (see `design.innerComponent`), so the nesting `nonInvertingAmp`
## brings along costs the role binding nothing but one more path segment.
## Real AC coupling ahead of the amplifier is also why `datalogger.nim`
## claims this stage with *both* roles rather than one: `opamp_stage` alone
## would claim `peaking_db`, referenced to the sweep's first point, and that
## point sits in `biasNetwork`'s own stopband -- see
## `contract/roles/analog.gainStageExpand`'s doc comment for why that pair
## exists.

import verax/contract/dsl
import verax/netlist/formats/spice as spiceFormat
import ../../lib/opamp_stages
import ../../lib/bias

proc analogInputChannel*(gain = 2.0, gbw = 20.0.MHz,
                         partNumber = "OPA320",
                         biasCornerHz = 1.6.Hz): Netlist =
  doAssert gain >= 1.0, "non-inverting gain is >= 1 (1.0 is a unity buffer)"

  result = subckt("ANALOG_IN", [AIN, AOUT, VDD, GND]):
    net GND,  kind = ntGround, name = "0"
    net VDD,  kind = ntPower
    net AIN,  kind = ntSignal
    net AOUT, kind = ntSignal
    net vin,  kind = ntSignal

    instance Xbias, biasNetwork(cornerHz = biasCornerHz),
      {"IN": AIN, "OUT": vin, "VDD": VDD, "GND": GND}

    # --- gain stage: the shared non-inverting amplifier, REF tied to true
    # ground -- see the module doc comment for why that is right here.
    instance Xamp, nonInvertingAmp(defaultOpAmp(partNumber, gbw), gain),
      {"IN": vin, "OUT": AOUT, "VP": VDD, "VN": GND, "REF": GND, "GND": GND}
