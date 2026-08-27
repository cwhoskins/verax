## Simulation-only device models: parasitic expansion of real components, and
## synthesized macromodels for parts a netlist names but does not describe.
##
## Like `nimcir/spice/transform` and `nimcir/spice/probes`, everything here
## mutates whatever `Netlist` it is given -- run it on a simulation clone
## (`transform.materializeSimNetlist`, `extract.*` or `isolate.isolate`),
## never on the real design netlist.
##
## Every proc here *invents numbers the netlist does not contain*, so each
## returns a `seq[Assumption]` of human-readable assumption lines for the
## caller to put in `AnalysisReport.assumptions`. A result derived from an
## invented input has to say so where the reader will see it.
##
## This module is the hub: one file per model under `models/`, re-exported
## here so `import nimcir/spice/models` (or `nimcir/spice`) still reaches
## everything. What it keeps of its own is `registerBuiltinBehavioralModels`
## and the call that wires the built-in behavioural stand-ins at init.

import ./models/common
import ./models/derating
import ./models/capacitor
import ./models/ferrite_bead
import ./models/passives
import ./models/source_impedance
import ./models/behavioral
import ./models/regulator
import ./models/buffer
import ./models/opamp
import ./models/pin_models

export common, derating, capacitor, ferrite_bead, passives, source_impedance
export behavioral, regulator, buffer, opamp, pin_models

proc registerBuiltinBehavioralModels*() =
  ## Called at module init. Exposed so a test can prove re-registering is
  ## idempotent, and so an application that clears the table can restore it.
  for kind in ["regulator", "ldo", "vreg", "dcdc", "smps", "switcher",
               "buck", "boost"]:
    registerBehavioralModel(kind, regulatorModel)
  for kind in ["buffer", "voltage_follower", "unity_gain_buffer",
               "line_driver", "level_shifter"]:
    registerBehavioralModel(kind, bufferModel, passesSignal = true)
  # `passesSignal` stays false, unlike a buffer's. It governs whether
  # `analysis/opamp`'s static feedback walk may cross the part, and that walk
  # is forwards-only through `signalPathPins` -- which cannot answer for an
  # amplifier, because an op-amp has *two* inputs and nothing in a netlist
  # says which one a path enters by. The simulated stand-in above still
  # closes the path, so an `.ac` sees the cascade; only the static walk stays
  # conservative, which is the direction to be wrong in.
  # Deliberately not `comparator`: this macromodel is linear, and a
  # comparator's entire behaviour is that it is not.
  for kind in ["opamp", "op_amp", "operational_amplifier"]:
    registerBehavioralModel(kind, opampModel)

registerBuiltinBehavioralModels()
