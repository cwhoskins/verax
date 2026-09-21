## A resistive divider with real KiCad footprints stated on every part --
## the smallest design that exercises `verax layout` end to end, from a
## `spec: footprint = "Lib:Name"` line to a `.kicad_pcb` `kicad-cli pcb drc`
## accepts.
##
##   verax check designs/pcb_demo.nim
##   verax layout designs/pcb_demo.nim -o pcb_demo.kicad_pcb
##
## The circuit itself is `templates/divider.nim`'s: 12 V in, 30 k over 10 k,
## a 3.0 V tap within 1%. What is new here is the `footprint` annotation --
## distinct from `package`, which is a case size keying `spice/models`'
## parasitic defaults, not a land pattern -- on all three parts, so
## `pcb/assemble.nim` resolves a real pad pattern for each one rather than
## reporting `footprint_unresolved`. `V1` (the supply) stands in for a power
## input connector and is given a real through-hole header footprint for
## the same reason: a design with an unresolved part still generates a
## board (the missing part is reported as an `Issue`, never silently
## dropped or silently blocking), but this design's whole point is to show
## the clean path, not the refusal.
##
## `V1`'s netlist pins are named `+`/`-` (the schematic convention a
## voltage source uses everywhere else in this codebase) while the header
## footprint's own pads are `1`/`2`, so `verax layout` also reports two
## `footprint_pad_unmatched` warnings for it -- expected, and left in
## deliberately: a real board would either rename the pins to match the
## connector's own numbering or state which pad is which, and this is
## exactly the check that would tell an author to do one of those.

import verax/contract/dsl
import verax/verify

let d = design("pcb_demo"):
  net gnd, kind = ntGround, name = "0"
  net vin, kind = ntPower:
    spec:
      voltage = 12.0.V
  net mid, kind = ntSignal

  component V1, kind = "voltage_source", value = "DC 12":
    pin "+", vin, kind = ptPower
    pin "-", gnd, kind = ptGround
    spec:
      voltage = 12.0.V
      footprint = "Connector_PinHeader_2.54mm:PinHeader_1x02_P2.54mm_Vertical"

  component R1, kind = "resistor", value = "30k":
    pin "1", vin, kind = ptPassive
    pin "2", mid, kind = ptPassive
    spec:
      package = "0402"
      footprint = "Resistor_SMD:R_0402_1005Metric"
  component R2, kind = "resistor", value = "10k":
    pin "1", mid, kind = ptPassive
    pin "2", gnd, kind = ptPassive
    spec:
      package = "0402"
      footprint = "Resistor_SMD:R_0402_1005Metric"

  role "power_rail", supply, rail = vin, voltage = 12.0.V, band = 5.pct

  require dc_voltage(mid) == 3.0.V, band = 1.pct,
          id = "REQ-PCBDEMO-TAP-001",
          because = "the tap is the divider's entire output; 1% is what " &
                    "two 1% resistors give in the worst case"

quit(verifyMain(d))
