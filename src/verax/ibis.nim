## IBIS -- reading a silicon vendor's Input/output Buffer Information
## Specification (`.ibs`) file into a typed model of what a driver or
## receiver actually does: its I/V curves, edge rates, and die and package
## parasitics.
##
## This submodule owns *what the vendor says*. It does **not** simulate a
## buffer -- turning an IBIS I/V table into a device a circuit solver can
## run is `verax/spice`'s job, through `spice/models` -- and it does not
## judge a design against one, which is `verax/analysis`'s. It reads the
## file and hands back the data.
##
## The parser (`verax/ibis/parse` + `verax/ibis/reader`) is real and
## covers the IBIS 3.2 core. Everything downstream of a parsed file is a
## skeleton: `verax/ibis/attach` binds a model to a `Component`/`Pin` and to
## a board `Placement` and checks the pin names line up, and stops there.
##
## Backend/toolchain-free by construction -- there is no external tool to
## run -- so unlike `verax/spice` the whole submodule is in this hub.

import verax/ibis/types
import verax/ibis/parse
import verax/ibis/reader
import verax/ibis/attach

export types, parse, reader, attach
