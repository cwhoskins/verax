## Physical package definitions for multi-channel op-amps.
##
## `lib/parts.nim` is ".MODEL cards"; a package is a *pinout*, not a model, so
## it lives here. Importing this module registers the definitions, the same
## way importing `contract/dsl` registers the built-in roles.
##
## Both parts here are 8-pin single-supply-or-split duals in the industry
## standard pinout:
##
##     1  OUT A      8  V+
##     2  IN- A      7  OUT B
##     3  IN+ A      6  IN- B
##     4  V-         5  IN+ B
##
## `V+`/`V-` are the shared (global) pins: `validatePackages` checks that both
## sections' supply pins resolve to the same net, which is the one thing a
## two-section board can get wrong that no per-section check would catch.

import verax/netlist/packages
export packages

const dualOpampPinout = [
  (id: "1", section: "A", logical: "OUT"),
  (id: "2", section: "A", logical: "IN-"),
  (id: "3", section: "A", logical: "IN+"),
  (id: "4", section: "",  logical: "V-"),
  (id: "5", section: "B", logical: "IN+"),
  (id: "6", section: "B", logical: "IN-"),
  (id: "7", section: "B", logical: "OUT"),
  (id: "8", section: "",  logical: "V+")]

registerPackage(newPackageDef("NE5532", dualOpampPinout,
  partNumber = "NE5532", footprint = "SOIC-8",
  doc = "Dual low-noise op-amp, 10 MHz GBW"))

registerPackage(newPackageDef("OPA1642", dualOpampPinout,
  partNumber = "OPA1642", footprint = "SOIC-8",
  doc = "Dual JFET audio op-amp"))
