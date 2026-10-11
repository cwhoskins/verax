---
description: Run scoped verification and report output evidence without fixes
argument-hint: "<test command or verification scope>"
---
Verify this verax scope:

$ARGUMENTS

If no arguments were supplied, ask for the verification scope or exact command and stop; do not assume a full suite.
Use the subagent tool with agentScope "project" and delegate verification to test-runner. Supply the requested scope or command and the root and applicable nested CLAUDE.md test rules from context; have test-runner discover missing instructions with narrowly necessary discovery commands.
Use the exact requested command when given, otherwise the smallest relevant checks. Run the full suite only if requested or required for explicitly scoped final verification.
Judge Nim results from complete output, never merely the exit code: nimble test can exit 0 on failure. Report every FAILED or Error: line and incomplete/aborted runs; no success claim from truncated output. Explicitly distinguish pass, fail, and missing-toolchain skips (including which toolchain is absent); a found-but-unloadable MFEM install is a failure, not a skip.
Return exact commands, relevant diagnostics, explicit skips, unverified coverage, and an overall conclusion. Do not edit files, install software, invoke implementer, or make automatic fixes. Report failures for a separate approved implementation workflow.
