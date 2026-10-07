## Simulation-backed evaluators for `verax/contract` -- the assembly point.
## They live in `analysis` (contract stays simulator-free), one file each
## (tightly coupled ones share), with shared machinery in
## `evaluators/common`. This imports them all and registers them at init.
##
## **Opt-in per import**; pass `allCapabilities` to run them:
##
## ```nim
## import verax/contract
## import verax/analysis/evaluators/contract_eval  # registers the simulated evaluators
##
## let results = evaluate(design, allCapabilities)
## ```

import ../../contract/evaluators/static
import ../../contract/evaluators/diff
import ./common
import ./dc_voltage
import ./pdn
import ./derating
import ./dcsweep
import ./startup
import ./transient
import ./oscillator
import ./current
import ./load_step
import ./opamp
import ./match
import ./psrr

export evaluate, static, common

proc registerSimulatedEvaluators*() =
  ## Called at module init; exposed so a cleared registry can be restored.
  registerDcVoltageEvaluator()
  registerDeratingEvaluator()
  registerPdnEvaluator()
  registerDcSweepEvaluator()
  registerStartupEvaluator()
  registerTransientEvaluator()
  registerCurrentEvaluator()
  registerLoadStepEvaluator()
  registerPsrrEvaluators()
  registerOscillatorEvaluator()
  registerOpAmpEvaluators()
  registerChannelMatchEvaluator()

registerSimulatedEvaluators()
