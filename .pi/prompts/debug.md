---
description: Diagnose with sandboxed probes and independent artifact review
argument-hint: "<original debugging question>"
---
Investigate this original debugging question:

$ARGUMENTS

If no arguments were supplied, ask for the debugging question and stop.
Use the subagent tool with agentScope "project" for every delegation.
1. Use reader for focused reconnaissance only when useful.
2. Invoke debugger with the original question and relevant context. Require root and applicable nested CLAUDE.md instructions, and throwaway probes and reviewable scripts/logs under `.tmp/` only, using debug_write and debug_bash. Never fall back to unsandboxed execution if the sandbox is unavailable; report the blocker.
3. After debugger finishes, invoke debug-reviewer as a separate task containing only the original question and exact `.tmp/` artifact paths. Never include a previous transcript, `{previous}` substitution, debugger explanations, conclusions, or reconnaissance summaries in this reviewer task. Do not chain debugger output into the review. If exact paths are missing, request them before review; do not invent artifacts.
4. Present both conclusions separately, marking agreements, disagreements, uncertainty, and evidence limitations. If review cannot run, say so rather than claiming independent confirmation.
Debug findings are evidence only. Do not edit production code, promote probes into src/ or tests/, or automatically fix anything. Any implementation must go through planner, explicit user approval, implementer, and test-runner.
