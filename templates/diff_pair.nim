## A differential pair: two nets, declared as one interface, checked for
## symmetry between their legs.
##
##   verax check <this file>
##
## `diffPairInterface()` is an ordinary two-signal `InterfaceDef` (signals
## `p`/`n`) that `implies` the `diff_pair` role -- the same mechanism
## `i2cInterface()` uses to attach the `i2c` role. Instantiating it with
## `iface <name>, diffPairInterface()` is the whole declaration; nothing else
## is required to get `diff_pair_symmetry` checked.
##
## `diff_pair_symmetry` walks both legs' series parts -- here, R1/R2 -- and
## compares them hop for hop by kind and value: mismatch either one (a
## different value, an extra part on only one leg) and the claim fails,
## naming the part. `z_diff`/`intra_pair_skew` exist as quantities too (see
## `usb2Interface()`, which states a real 90 ohm target) but always come back
## NOT CHECKED -- they are routing properties, and nothing here accumulates
## trace length or solves a stackup yet, so a template meant to check clean
## does not claim them.

import verax/contract/dsl
import verax/verify
import verax/netlist/interfaces/std

let d = design("diff_pair"):
  net gnd, kind = ntGround, name = "0"

  net p_in, kind = ntSignal
  net n_in, kind = ntSignal
  component J1, kind = "connector", partNumber = "differential link":
    pin "P", p_in, kind = ptPassive
    pin "N", n_in, kind = ptPassive

  # `pair_p`/`pair_n` are `iface pair`'s two member nets -- the `diff_pair`
  # role's `p`/`n` parts bind to them automatically, by name.
  iface pair, diffPairInterface()

  component R1, kind = "resistor", value = "100":
    pin "1", p_in,       kind = ptPassive
    pin "2", pair["p"],  kind = ptPassive
  component R2, kind = "resistor", value = "100":
    pin "1", n_in,       kind = ptPassive
    pin "2", pair["n"],  kind = ptPassive

  component U1, kind = "mcu", partNumber = "differential receiver":
    pin "P", pair["p"], kind = ptInOut
    pin "N", pair["n"], kind = ptInOut

quit(verifyMain(d))
