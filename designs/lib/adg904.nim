## The ADG904 as a set of annotations on a `kind = "rf_switch"` component.
##
## `designs/xbar_rf.nim` builds eight of these -- an absorptive SP4T RF mux.
## The library's generic `muxModel` (`src/verax/spice/models/switch.nim`)
## does the electrical work: one voltage-controlled `S` element per throw,
## a smooth decoder from the select pins gated by `EN`, and -- because
## `switch.off_termination` is stated -- a second `S` element and a 50 ohm
## resistor terminating each open throw.
##
## Deliberately no build proc, unlike `designs/lib/oring.nim`: if the ADG904
## needs one, the model was put at the wrong altitude. What is here is the
## datasheet, as data.
##
## What the model covers: the on/off DC path, the turns of routing a `.op`
## can see, and the absorptive terminated state that `safe_default` is about.
## What it does not: insertion loss and isolation vs frequency (flat `Roff`,
## no transmission lines), charge injection, and break-before-make timing.
## See the cannot-check list in `designs/xbar_switch.nim`.
##
## `equipAdg904` also stamps the `traverse:` edges (`RFC <-> RF1..4`) that
## used to be authored inline at every instantiation site
## (`designs/xbar_rf.nim`) -- both callers already run every ADG904
## designator through this proc, so it is the one place that answers "can a
## graph walk pass through this part" for all of them, rather than a
## statement repeated per instance that could drift.

import std/tables

import verax/netlist/graph
import verax/netlist/traversal
import verax/netlist/types

proc equipAdg904*(nl: Netlist, designators: openArray[string]) =
  ## Stamp the ADG904's datasheet numbers onto each named `rf_switch`.
  ##
  ## `select_pins` is MSB first: `A1,A0`, so the truth table is
  ## `A1 A0 -> RFC`: `00 -> RF1`, `01 -> RF2`, `10 -> RF3`, `11 -> RF4`,
  ## `EN` low -> all off, every port in 50 ohm.
  for d in designators:
    let c = findComponent(nl, d)
    if c == nil:
      raise newException(NetlistError,
        "equipAdg904: no such component '" & d & "'")
    c.attrs["ron"] = "4"                       # ~4 ohm on, against 50 ohm ports
    c.attrs["roff"] = "1e9"
    c.attrs["switch.select_pins"] = "A1,A0"
    c.attrs["switch.off_termination"] = "50"   # absorptive
    for rf in ["RF1", "RF2", "RF3", "RF4"]:
      addTraversalEdge(c, "RFC", rf)
