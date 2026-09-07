## Simulation-backed evaluators for `verax/contract` -- the assembly point.
##
## `contract/evaluate` depends only on `verax/netlist`, which is what keeps a
## design and its contract inspectable with no simulator in the build. The
## evaluators that *do* need one therefore cannot live there, and live here
## instead: `analysis` already depends on `spice`, and an `Evaluator` is a
## value with a `proc` field, so registering one from another module is the
## ordinary path rather than a workaround.
##
## Each evaluator has its own file beside this one (tightly-coupled evaluators
## -- the three op-amp bundles, the two PSRR methods -- share one), and
## `evaluators/common` holds the harvest adapter, the batch-refusal helper,
## the subject resolvers and the run-scoped operating-point cache they share.
## This module imports every one, calls their `register*` procs from
## `registerSimulatedEvaluators` and runs it at init -- mirroring
## `contract/roles/built_in`.
##
## **Opt-in per-import.** `verax/analysis.nim` does not export this, exactly
## as it does not export `pdn`/`startup`/`opamp`, and `verax/contract.nim`
## cannot. Import it explicitly, and pass `allCapabilities` to `evaluate`:
##
## ```nim
## import verax/contract
## import verax/analysis/evaluators/contract_eval  # registers the simulated evaluators
##
## let results = evaluate(design, allCapabilities)
## ```

import ../../contract/evaluators/static
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
  ## Called at module init; exposed for the same reason
  ## `roles.registerBuiltinRoles` is.
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
