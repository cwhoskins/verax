## A USB 2.0 high-speed link: receptacle, common-mode choke, series
## termination, ESD protection, into a transceiver -- plus a second,
## unrelated pair of differential links declared as an interface *array*.
##
##   verax check designs/usb_hs_link.nim
##
## Every differential pair here is declared with nothing new: a `diffPair`
## is an ordinary `InterfaceDef` with two signals named `p`/`n`
## (`verax/netlist/interfaces/std.diffPairInterface`), and instantiating one
## auto-attaches the `diff_pair` role through the same `implies` mechanism
## `i2cInterface()` already uses for `"i2c"`. There is no new declaration
## syntax anywhere in this file.
##
## `diff_pair_symmetry` -- a graph walk comparing both legs' series parts,
## `contract/evaluators/diff.nim` -- is the one claim every pair here can
## check today: R1/R2 (the 22R series termination close to the transceiver)
## and D1/D2 (the ESD clamps) must agree, leg for leg, in kind and value.
## `usb2Interface()` (used in `templates/diff_pair.nim` and in tests) also
## claims a 90 ohm differential impedance, but that quantity is registered
## and always comes back NOT CHECKED -- nothing in `pcb/` yet accumulates
## trace length or solves a stackup for it -- so this design deliberately
## uses the bare `diffPairInterface()` instead: a design meant to check
## clean cannot claim a number nothing can measure. See `docs/findings.md`
## for what that check needs.
##
## The connector-to-choke and choke-to-termination net pairs (`dp_ext`/
## `dn_ext`, `dp_choke`/`dn_choke`, `aux0*_ext`/`aux1*_ext`) are real,
## electrically distinct nodes -- L1 and the series resistors sit between
## them and the declared `diff_pair` nets, so they cannot *be* the same
## interface member net without shorting out the very parts that make them
## a pair. Each is tagged with the schematic-only `bus name, nets = [...]`
## statement instead of another `iface`: it sets the identical `bus.name`
## net attr `schematic/bundles.nim` already groups on, with none of
## `iface`'s side effects (no role, no assertions, nothing `contract` ever
## sees) -- exactly what a pin-collapse hint should cost when the two nets
## are not themselves a declared interface. That, plus the declared-pair
## floor in `schematic/arrays.nim`'s component-array collapse, is what lets
## every part along both differential paths (`J1`, `L1`, `R1`/`R2`, `D1`/
## `D2`, `J2`, `R3`..`R6`) draw its differential pins merged to one, the
## way `U1`'s already did.

import verax/contract/dsl
import verax/verify
import verax/netlist/interfaces/std

let d = design("usb_hs_link"):
  net gnd, kind = ntGround, name = "0"

  # --- the high-speed pair: receptacle -> choke -> termination -> ESD ---
  net dp_ext, kind = ntSignal
  net dn_ext, kind = ntSignal
  bus hs_ext, nets = [dp_ext, dn_ext]
  component J1, kind = "connector", description = "USB-C receptacle":
    pin "DP", dp_ext, kind = ptPassive
    pin "DN", dn_ext, kind = ptPassive

  net dp_choke, kind = ntSignal
  net dn_choke, kind = ntSignal
  bus hs_choke, nets = [dp_choke, dn_choke]
  component L1, kind = "common_mode_choke", partNumber = "744235800":
    pin "P1", dp_ext,   kind = ptPassive
    pin "P2", dp_choke, kind = ptPassive
    pin "S1", dn_ext,   kind = ptPassive
    pin "S2", dn_choke, kind = ptPassive
    spec:
      lpri = 900.nH
      dcr = 300.mohm

  # The pair itself: `hs_p`/`hs_n` are exactly `iface hs`'s two member nets,
  # and `addImpliedRoles` binds them to the `diff_pair` role's `p`/`n` parts
  # by the ordinary same-name matching -- nothing upstream of them (the
  # connector, the choke) is part of the pair *as declared*, which is why
  # the symmetry walk below starts here rather than at the connector; the
  # `bus hs_ext`/`bus hs_choke` tags above are schematic-only (see the file
  # header) and carry no such claim.
  iface hs, diffPairInterface()

  component R1, kind = "resistor", value = "22":
    pin "1", dp_choke, kind = ptPassive
    pin "2", hs["p"],  kind = ptPassive
  component R2, kind = "resistor", value = "22":
    pin "1", dn_choke, kind = ptPassive
    pin "2", hs["n"],  kind = ptPassive

  component D1, kind = "diode", partNumber = "PESD5V0S1BA":
    pin "A", hs["p"], kind = ptPassive
    pin "K", gnd,      kind = ptPassive
  component D2, kind = "diode", partNumber = "PESD5V0S1BA":
    pin "A", hs["n"], kind = ptPassive
    pin "K", gnd,      kind = ptPassive

  # --- a second, unrelated pair of links, declared as an array ----------
  # `count = 2` makes `aux_0`/`aux_1` two independent interface instances,
  # each with its own `p`/`n` nets and its own auto-implied `diff_pair` role
  # instance -- `iface lane, pairDef, count = N` is how an LVDS byte or a
  # DDR data group is declared the same way, N times over, with no new
  # mechanism beyond what already builds an interface array.
  iface aux, diffPairInterface(), count = 2

  net aux0p_ext, kind = ntSignal
  net aux0n_ext, kind = ntSignal
  net aux1p_ext, kind = ntSignal
  net aux1n_ext, kind = ntSignal
  bus aux0_ext, nets = [aux0p_ext, aux0n_ext]
  bus aux1_ext, nets = [aux1p_ext, aux1n_ext]
  component J2, kind = "connector", description = "JST-GH 4-way":
    pin "1", aux0p_ext, kind = ptPassive
    pin "2", aux0n_ext, kind = ptPassive
    pin "3", aux1p_ext, kind = ptPassive
    pin "4", aux1n_ext, kind = ptPassive

  component R3, kind = "resistor", value = "33":
    pin "1", aux0p_ext, kind = ptPassive
    pin "2", aux[0]["p"], kind = ptPassive
  component R4, kind = "resistor", value = "33":
    pin "1", aux0n_ext, kind = ptPassive
    pin "2", aux[0]["n"], kind = ptPassive
  component R5, kind = "resistor", value = "33":
    pin "1", aux1p_ext, kind = ptPassive
    pin "2", aux[1]["p"], kind = ptPassive
  component R6, kind = "resistor", value = "33":
    pin "1", aux1n_ext, kind = ptPassive
    pin "2", aux[1]["n"], kind = ptPassive

  # --- the transceiver ----------------------------------------------------
  component U1, kind = "mcu", description = "dummy USB HS PHY":
    pin "DP",    hs["p"],    kind = ptInOut
    pin "DN",    hs["n"],    kind = ptInOut
    pin "AUX0P", aux[0]["p"], kind = ptInOut
    pin "AUX0N", aux[0]["n"], kind = ptInOut
    pin "AUX1P", aux[1]["p"], kind = ptInOut
    pin "AUX1N", aux[1]["n"], kind = ptInOut

quit(verifyMain(d))
