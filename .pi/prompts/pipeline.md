---
description: Plan, implement, and test a feature through specialized agents
argument-hint: "<feature description>"
---
Run the verax agent pipeline for this feature request:

$ARGUMENTS

Use project-local agents. First gather only the reconnaissance needed, then obtain a planner implementation plan with concrete test cases. Present the plan for my review and stop before implementation. Continue with implementation and testing only after I explicitly approve the plan.

Debugging can be requested before planning or during a failed verification loop:
- reader performs focused reconnaissance.
- The Sol debugger may create and run throwaway probes under `.tmp/`.
- Luna debug-reviewer independently reviews those `.tmp/` artifacts.
- Debug findings are evidence supplied to the planner or implementer; they are not approval to edit production files.

Do not make debugging mandatory for every feature.
