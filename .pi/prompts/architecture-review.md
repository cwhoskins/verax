---
description: Review actual architecture and boundaries with read-only evidence
argument-hint: "<architecture question or module scope>"
---
Review this verax architecture scope:

$ARGUMENTS

If no arguments were supplied, ask for the architecture question or module scope and stop.
Use the subagent tool with agentScope "project" and delegate to architecture-reviewer. Require root and applicable nested CLAUDE.md instructions and docs/architecture.md, then evidence from actual imports, types, APIs, callers, and tests rather than documentation alone.
Review dependency direction, ownership, coupling, opt-in imports, Nim 2.2.10 compatibility, and standard-library-only constraints. Return a concise architecture map, evidence-backed findings with paths and symbols, prioritized recommendations with tradeoffs, and explicit uncertainty or uninspected areas.
Remain read-only: no commands, edits, implementation, or automatic fixes. Recommendations are not an approved implementation plan; follow the normal planning and explicit approval workflow for changes.
Do not switch models automatically. The reviewer has no model field and inherits the session model only through the active subagent extension's support; if unavailable, report the limitation rather than claiming inheritance.
