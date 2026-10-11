---
description: Explain code through read-only reconnaissance
argument-hint: "<question or code scope>"
---
Explain this verax code question:

$ARGUMENTS

If no arguments were supplied, ask for the question or code scope and stop.
Use the subagent tool with agentScope "project" and delegate only to reader. Require it to read root and applicable nested CLAUDE.md instructions, then inspect the relevant code and tests.
Return a factual explanation with file paths and symbols, control/data flow, invariants, dependencies, existing tests, and unresolved questions. Distinguish evidence from inference.
Remain read-only: do not execute code, propose edits, create an implementation plan, or invoke planner, implementer, debugger, or test-runner.
