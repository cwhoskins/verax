## Design intent: what a circuit *is* and what it must *do*.
##
## `nimcir/netlist` models topology and `nimcir/netlist/annotations` gives the
## per-entity vocabulary a name and a type. This submodule adds the two things
## neither can express: **roles** (what something is in this design) and
## **assertions** (what it must do). It depends only on `nimcir/netlist`, so a
## design and its contract can be authored, read and inspected with no
## simulator anywhere in the build.
##
## **A role is a bundle of assertions, plus the parameters they share.** That
## is the whole model. "This is a 3V3 rail" unpacks into a nominal voltage
## (consumed as an input by `spice/isolate`) and a claim that the rail sits
## there. "This is a 400 kHz I2C bus" unpacks into pull-up, RC-corner and
## single-controller claims. Because expansion is the only mechanism, there is
## no separate "derive default assertions" path to keep in step with it, and
## what a role produced can always be printed (`explain`).
##
## **Not an expression language, deliberately.** Almost every claim is
## "quantity Q of subjects S under conditions C lies in interval I", and when
## it is not, the escalation is: put the arithmetic in a Nim proc that emits a
## derived quantity (SPI setup margin is a computation over datasheet numbers,
## not a measurement), then `ekRelative` for a bound that references another
## measurement, then a Nim predicate. Nim is the expression language -- a
## macro can compile an ordinary Nim expression into a predicate plus its
## measurement dependencies, which costs no parser, no evaluator and no
## bespoke error messages.
##
## **Assertions are checked by `contract/evaluate`.** It holds a registry of
## capability-tagged evaluators and returns an `AssertionResult` carrying
## pass / fail / not-evaluated / not-evaluable. That result is deliberately
## not an `Issue`: `Issue` cannot say "checked, and it is fine" or "could not
## check", and silence meaning pass is how assertion systems become theatre.
## Evaluation is planned before it is run -- assertions are grouped by
## evaluator and setup key, so one analysis runs once per distinct setup
## rather than once per assertion, and `explainPlan` shows what would run
## before anything does.
##
## The evaluators that need no toolchain (`contract/evaluators/static`) are
## exported from here. The simulation-backed ones live in
## `nimcir/analysis/evaluators/contract_eval` and are **opt-in per-import**, the same
## rule `analysis.nim` and `spice.nim` already apply: importing this hub must
## never require a simulator in the build.

import nimcir/contract/types
import nimcir/contract/roles/built_in as roles
import nimcir/contract/design
import nimcir/contract/evaluate
import nimcir/contract/evaluators/static

export types, roles, design, evaluate, static
