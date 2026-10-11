---
description: Produce a concrete implementation and test plan, then stop for approval
argument-hint: "<feature or change request>"
---
Plan this verax change:

$ARGUMENTS

If no arguments were supplied, ask for the change request and stop.
Use the subagent tool with agentScope "project" for every delegation. Use reader only if focused reconnaissance is needed, then invoke planner with the request and useful reconnaissance. Require root and applicable nested CLAUDE.md instructions to be read.
Request affected files and symbols, ordered steps, assumptions and unresolved decisions, dependency direction, Nim 2.2.10 compatibility, standard-library-only constraints, risks, and non-goals.
Require concrete tests: test file locations, setup, action, expected result, and exact targeted and full-suite commands. Present the plan and tests to the user and stop for explicit approval before implementation. Do not invoke implementer or start verification in this planning command; do not treat the request to plan as approval.
