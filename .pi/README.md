# verax agent pipeline

This project-local Pi setup provides seven agents:

| Agent | Model | Access |
| --- | --- | --- |
| `planner` | `openai-codex/gpt-5.6-sol` | Read-only |
| `implementer` | `deepseek/deepseek-v4-pro` | Read/write/shell |
| `reader` | `openai-codex/gpt-5.6-luna` | Read-only |
| `test-runner` | `deepseek/deepseek-v4-flash` | Shell, restricted by prompt to verification |
| `debugger` | `openai-codex/gpt-5.6-sol` | Read-only repository tools plus `debug_write`/`debug_bash`, both restricted to `.tmp/` |
| `debug-reviewer` | `openai-codex/gpt-5.6-luna` | Read-only, reviews `.tmp/` artifacts only |
| `orchestrator` | `openai-codex/gpt-5.6-terra` | Subagent delegation only |

Pi starts this repository with the Terra orchestrator model, no built-in tools, and the project-local `subagent` delegation tool. The orchestrator must present the planner's implementation plan and concrete test cases, then wait for explicit user approval before implementation.

`reader` performs general-purpose read-only reconnaissance. `debug-reviewer` is a separate Luna agent that independently explains `.tmp/` debug scripts and logs; it never executes or modifies them.

## Debugging flow

1. `reader` performs focused reconnaissance when useful.
2. `debugger` (Sol) plans, writes, and runs throwaway probes under `.tmp/` using only `debug_write` and `debug_bash`.
3. `debug-reviewer` (Luna) reviews the named `.tmp/` artifacts with only the original question and artifact paths — never the debugger's own explanation.
4. The orchestrator presents both conclusions, marking agreements and disagreements. Debug findings are evidence for the planner or implementer, never a bypass of the normal plan/approve/implement/test workflow.

## Security prerequisites

The `debugger`'s two mutation tools are an enforced boundary, not prompt guidance. They are implemented by `.pi/extensions/debug-tools/` and fail closed.

- `debug_write` permits writes only under the repository `.tmp/`, with component-aware path containment and symlink checks.
- `debug_bash` runs commands in a bubblewrap sandbox: the host filesystem is mounted read-only, only `.tmp/` is writable, `/tmp` is a private in-memory filesystem, network is disabled, and process/session namespaces are isolated.
- On Linux, `bwrap` (bubblewrap) is a runtime prerequisite. If it is absent, on a non-Linux platform, or if sandbox setup fails, `debug_bash` refuses to run rather than falling back unsandboxed.
- Debug artifacts remain in `.tmp/` (ignored by Git) for independent review; cleanup is explicit.

## Usage

Trust the project when Pi asks, then restart or run `/reload` after changing this configuration.

```text
/pipeline <feature description>
```

You can also ask the orchestrator to invoke a specific agent, such as the reader, debugger, debug-reviewer, or test runner. Agent definitions live in `.pi/agents/`; the workflow prompt is `.pi/prompts/pipeline.md`.
