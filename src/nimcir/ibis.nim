## IBIS -- reading a silicon vendor's Input/output Buffer Information
## Specification (`.ibs`) file into a typed model of what a driver or
## receiver actually does: its I/V curves, edge rates, and die and package
## parasitics.
##
## This submodule owns *what the vendor says*. It does **not** simulate a
## buffer -- turning an IBIS I/V table into a device a circuit solver can
## run is `nimcir/spice`'s job, through `spice/models` -- and it does not
## judge a design against one, which is `nimcir/analysis`'s. It reads the
## file and hands back the data.
##
## The parser (`nimcir/ibis/parse` + `nimcir/ibis/reader`) is real and
## covers the IBIS 3.2 core. Everything downstream of a parsed file is a
## skeleton: `nimcir/ibis/attach` binds a model to a `Component`/`Pin` and to
## a board `Placement` and checks the pin names line up, and stops there.
##
## Backend/toolchain-free by construction -- there is no external tool to
## run -- so unlike `nimcir/spice` the whole submodule is in this hub.

import nimcir/ibis/types
import nimcir/ibis/parse
import nimcir/ibis/reader
import nimcir/ibis/attach

export types, parse, reader, attach
