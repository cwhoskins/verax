## SPICE circuit simulation: running a `nimcir/netlist` `Netlist` through an
## external SPICE backend, plus simulation-only netlist transforms.
##
## This is the *simulation runner*; for the *file-format* deck reader/writer
## see `nimcir/netlist/formats/spice`.
##
## A specific backend (e.g. `nimcir/spice/ngspice`) is opt-in per-import,
## mirroring how file formats are opt-in under `nimcir/netlist/formats/` --
## this hub only exports the backend-agnostic pieces: the result/error types
## (`nimcir/spice/backend`), probes (`nimcir/spice/probes`), component
## replacement (`nimcir/spice/transform`), subcircuit extraction
## (`nimcir/spice/extract`), simulation-fragment isolation
## (`nimcir/spice/isolate`), and simulation-only device models
## (`nimcir/spice/models`).

import nimcir/spice/backend
import nimcir/spice/probes
import nimcir/spice/transform
import nimcir/spice/extract
import nimcir/spice/isolate
import nimcir/spice/models
import nimcir/spice/boundary

export backend, probes, transform, extract, isolate, models, boundary
