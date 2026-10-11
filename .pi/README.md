# verax agent pipeline

This project-local Pi setup provides eight agents:

| Agent | Model | Access |
| --- | --- | --- |
| `planner` | `openai-codex/gpt-6.1-sol` | Read-only |
| `implementer` | `openai-codex/gpt-6-astra` | Read/write/shell |
| `reader` | `openai-codex/gpt-6-luna` | Read-only |
| `test-runner` | `openai-codex/gpt-6-luna` | Shell, restricted by prompt to verification |
| `debugger` | `openai-codex/gpt-6.1-sol` | Read-only repository tools plus `debug_write`/`debug_bash`, both restricted to `.tmp/` |
| `debug-reviewer` | `openai-codex/gpt-6-luna` | Read-only, reviews `.tmp/` artifacts only |
| `architecture-reviewer` | Session model (no model field; requires extension support) | Read-only |
| `orchestrator` | `openai-codex/gpt-6-astra` | Subagent delegation only |

Pi starts this repository with the Astra orchestrator model, no built-in tools, and the project-local `subagent` delegation tool. The orchestrator must present the planner's implementation plan and concrete test cases, then wait for explicit user approval before implementation.

`reader` performs general-purpose read-only reconnaissance. `debug-reviewer` is a separate Luna agent that independently explains `.tmp/` debug scripts and logs; it never executes or modifies them.

## Debugging flow

1. `reader` performs focused reconnaissance when useful.
2. `debugger` (Sol) plans, writes, and runs throwaway probes under `.tmp/` using only `debug_write` and `debug_bash`.
3. Invoke `debug-reviewer` (Luna) as a separate task containing only the original question and exact `.tmp/` artifact paths — never a previous transcript, `{previous}` substitution, debugger explanations/conclusions, or reconnaissance summaries. Do not chain debugger output into review. Request missing paths rather than inventing them.
4. The orchestrator presents both conclusions, marking agreements and disagreements. Debug findings are evidence for the planner or implementer, never a bypass of the normal plan/approve/implement/test workflow.

## Security prerequisites

The `debugger`'s two mutation tools are an enforced boundary, not prompt guidance. They are implemented by `.pi/extensions/debug-tools/` and fail closed.

- `debug_write` permits writes only under the repository `.tmp/`, with component-aware path containment and symlink checks.
- `debug_bash` runs commands in a bubblewrap sandbox: the host filesystem is mounted read-only, only `.tmp/` is writable, `/tmp` is a private in-memory filesystem, network is disabled, and process/session namespaces are isolated.
- On Linux, `bwrap` (bubblewrap) is a runtime prerequisite. If it is absent, on a non-Linux platform, or if sandbox setup fails, `debug_bash` refuses to run rather than falling back unsandboxed.
- Debug artifacts remain in `.tmp/` (ignored by Git) for independent review; cleanup is explicit.

## Usage

Trust the project when Pi asks, then restart or run `/reload` after changing this configuration.

Templates are direct Markdown children of `.pi/prompts/`; filenames become commands. They expand text, not executable workflows or security boundaries. Only `description` and `argument-hint` metadata are used, with `$ARGUMENTS` for the request. All delegations use `agentScope "project"`.

| Command | Behavior |
| --- | --- |
| `/pipeline <feature description>` | Plan with concrete tests, stop for approval, then implement and verify. |
| `/explain <question or code scope>` | Reader only; factual explanation with paths/symbols, no edits or plans. |
| `/plan <change request>` | Planner produces steps and concrete tests (locations, setup, action, expected result, commands); stops for explicit approval before implementation. |
| `/debug <original question>` | Sandboxed debugger probes under `.tmp/`, then a separate independent debug-reviewer task; no automatic fixes. |
| `/verify <command or scope>` | Test-runner reports exact commands and output-based pass/fail/skip evidence, not nimble's exit code; explicit missing-toolchain skips, no automatic fixes. |
| `/architecture-review <question or module scope>` | Read-only architecture-reviewer inspects actual dependencies, ownership, coupling, opt-in imports, and stdlib constraints; evidence-backed prioritized recommendations and uncertainty. |

The five focused commands ask for missing arguments and stop; in particular `/verify` alone does not assume a full suite. Recommendations and debug findings never bypass planning and approval.

Examples:

```text
/explain "How are netlist annotations evaluated?"
/plan Add a validation rule for this annotation
/debug Why does this targeted test fail?
/verify nim c -r --path:./src tests/test_netlist_core.nim
/architecture-review si and analysis dependency boundaries
```

### Model selection

Select the desired session model manually with `/model` before `/architecture-review`. Templates do not switch models and have no model metadata. `architecture-reviewer` deliberately omits a `model` field. The current `.pi/extensions/subagent/index.ts` forwards the active session model (and thinking level) for unpinned agents; this inheritance is extension behavior, not a prompt-template guarantee. With another extension/version, confirm support and report limitations rather than assuming inheritance. Pinned agents retain their configured models regardless of `/model`.

You can also ask the orchestrator to invoke a specific agent. Agent definitions live in `.pi/agents/`; no source or extension behavior is changed by these templates.

### Static contract tests

```sh
node --experimental-strip-types --test .pi/tests/prompt-templates.test.ts
```

These Node standard-library tests check template discovery/metadata, delegation and safety instructions, reviewer tools/model omission, and documentation contracts. They do not execute agents, prove model compliance, or replace runtime verification.
