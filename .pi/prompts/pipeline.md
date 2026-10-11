---
description: Plan, implement, and test a feature through specialized agents
argument-hint: "<feature description>"
---
Run the verax agent pipeline for this feature request:

$ARGUMENTS

Use project-local agents through the subagent tool with agentScope "project" for every delegation. First gather only the reconnaissance needed, then obtain a planner implementation plan with concrete test cases. Present the plan for my review and stop before implementation. Continue with implementation and testing only after I explicitly approve the plan.

Debugging can be requested before planning or during a failed verification loop:
- reader performs focused reconnaissance.
- The Sol debugger may create and run throwaway probes under `.tmp/`.
- After debugger finishes, invoke debug-reviewer as a separate task containing only the original question and exact `.tmp/` artifact paths. Never include a previous transcript, `{previous}` substitution, or debugger explanations or conclusions. Do not chain debugger output into the review. If exact paths are missing, request them before review.
- Debug findings are evidence supplied to the planner or implementer; they are not approval to edit production files.

Do not make debugging mandatory for every feature.
