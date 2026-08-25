# nimcir MCP server

Exposes `nimcir` over the Model Context Protocol, for clients with no shell —
Claude Desktop, the web app, anything that cannot run a terminal. If you *do*
have a shell, use the `nimcir` binary directly; this adds nothing but a
transport.

## Build

```sh
cd ..           && nimble build      # produces ../bin/nimcir
cd mcp          && nimble build      # produces ./nimcir_mcp
```

The server drives the `nimcir` binary as a subprocess rather than linking the
library, so an MCP client and a terminal user get byte-identical answers.
Point `NIMCIR_BIN` at the binary or put it on `PATH`.

## Runtime requirement

`nimcp` uses Nim's `re` module, which needs **PCRE 1** (`libpcre.so.3` or
`libpcre.so.1`). A system carrying only PCRE 2 fails at startup with
`could not load: libpcre.so(.3|.1|)`. On openSUSE: `zypper install pcre`.
This is nimcp's dependency, not nimcir's — the `nimcir` binary itself needs
nothing beyond libc.

## Client configuration

```json
{
  "mcpServers": {
    "nimcir": {
      "command": "/path/to/nimcir/mcp/nimcir_mcp",
      "env": { "NIMCIR_BIN": "/path/to/nimcir/bin/nimcir" }
    }
  }
}
```

## Tools

| tool | what it answers |
|---|---|
| `nimcirGuide` | how to author a design and read its report — read this first |
| `nimcirRoles` / `nimcirRole` | what bundles of claims exist, and what each one claims |
| `nimcirQuantities` | every quantity a `require` can name |
| `nimcirAnnotations` | every key a `spec:` block accepts |
| `nimcirTemplate` | a starter design file |
| `nimcirCheck` | compile and check a design; returns the report and exit code |
| `nimcirEnv` | toolchain, simulator availability, registry sizes |

## Constraints worth knowing before extending this

Verified against nimcp's source, not its documentation (its `TUTORIAL.md` is
stale and references symbols that do not exist):

- `mcpTool` accepts only `int`/`uint`/`float`/`string`/`bool` parameters.
  `seq[T]` and `JsonNode` appear in its schema generator but have no branch in
  its argument extraction, so they fail to compile.
- **Parameter defaults are ignored** — every parameter is emitted as
  `required`, and omitting one raises `KeyError`. There are no optional
  arguments here; an empty string means "the default".
- Return values are stringified, so every tool returns `string`.
- `raise newException(ValueError, msg)` becomes JSON-RPC `-32602` with the
  message intact. Anything else becomes an opaque `-32603`.
- Every request must follow `initialize`; the server rejects anything before
  it with `-32000`.

**Keep the transport stdio** unless you deliberately decide otherwise. nimcir's
role, evaluator and annotation registries are process-global mutable tables;
nimcp's HTTP/WebSocket/SSE transports run handlers on Mummy worker threads,
where reading those is not `gcsafe`. stdio serialises every request.
