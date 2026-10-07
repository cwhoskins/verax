## Simulation-only device models: parasitic expansion and synthesized
## macromodels for parts a netlist names but doesn't describe. Everything
## mutates its netlist (use a simulation clone) and returns the
## `Assumption`s it invents.
##
## The hub: one file per model under `models/`, re-exported here, plus
## `registerBuiltinBehavioralModels`.

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
import ./models/magnetics
import ./models/switch
import ./models/pin_models

export common, derating, capacitor, ferrite_bead, passives, source_impedance
export behavioral, regulator, buffer, opamp, magnetics, switch, pin_models

proc registerBuiltinBehavioralModels*() =
  ## Called at module init; exposed so re-registration can be tested and a
  ## cleared table restored.
  for kind in ["regulator", "ldo", "vreg", "dcdc", "smps", "switcher",
               "buck", "boost"]:
    registerBehavioralModel(kind, regulatorModel)
  for kind in ["buffer", "voltage_follower", "unity_gain_buffer",
               "line_driver", "level_shifter"]:
    registerBehavioralModel(kind, bufferModel, passesSignal = true)
  # `passesSignal` stays false: the static feedback walk can't know which of
  # an op-amp's two inputs a path enters (the `.ac` still sees the
  # cascade). Not `comparator`: this macromodel is linear.
  for kind in ["opamp", "op_amp", "operational_amplifier"]:
    registerBehavioralModel(kind, opampModel)
  # A mux passes signal from common to the selected throw.
  for kind in ["analog_switch", "rf_switch", "mux"]:
    registerBehavioralModel(kind, muxModel, passesSignal = true)

registerBuiltinBehavioralModels()
