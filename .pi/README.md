# nimcir agent pipeline

This project-local Pi setup provides five agents:

| Agent | Model | Access |
| --- | --- | --- |
| `planner` | `openai-codex/gpt-5.6-sol` | Read-only |
| `implementer` | `deepseek/deepseek-v4-pro` | Read/write/shell |
| `reader` | `openai-codex/gpt-5.6-luna` | Read-only |
| `test-runner` | `deepseek/deepseek-v4-flash` | Shell, restricted by prompt to verification |
| `orchestrator` | `openai-codex/gpt-5.6-terra` | Subagent delegation only |

Pi starts this repository with the Terra orchestrator model, no built-in tools, and the project-local `subagent` delegation tool. The orchestrator must present the planner's implementation plan and concrete test cases, then wait for explicit user approval before implementation.

## Usage

Trust the project when Pi asks, then restart or run `/reload` after changing this configuration.

```text
/pipeline <feature description>
```

You can also ask the orchestrator to invoke a specific agent, such as the reader or test runner. Agent definitions live in `.pi/agents/`; the workflow prompt is `.pi/prompts/pipeline.md`.
