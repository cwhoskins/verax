## Design intent: what a circuit *is* and what it must *do*. Adds **roles**
## and **assertions** on top of `verax/netlist`, depending on nothing else,
## so a contract is inspectable with no simulator.
##
## **A role is a bundle of assertions plus shared parameters.** "3V3 rail"
## expands to a nominal voltage (read by `spice/isolate`) and a claim the
## rail sits there. Expansion is the only mechanism, so `explain` can always
## print it.
##
## **Not an expression language.** Escalate from an interval to a derived
## quantity (a Nim proc), then `ekRelative`, then a Nim predicate.
##
## **`contract/evaluate`** checks assertions through capability-tagged
## evaluators, returning pass / fail / not-evaluated / not-evaluable (not an
## `Issue`). Evaluation is planned first: one run per evaluator and setup
## key; `explainPlan` shows it.
##
## Static evaluators are exported here; simulation-backed ones
## (`analysis/evaluators/contract_eval`) are opt-in per import.

import verax/contract/types
import verax/contract/roles/built_in as roles
import verax/contract/design
import verax/contract/evaluate
import verax/contract/evaluators/static
import verax/contract/evaluators/diff

export types, roles, design, evaluate, static, diff
