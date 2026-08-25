## An MCP server over `nimcir`, for clients with no shell.
##
## Every tool here drives the `nimcir` binary as a subprocess rather than
## linking the library. That is the whole design: an MCP client and a terminal
## user then get byte-identical answers, because there is one implementation
## and this is a transport in front of it. It also means this package depends
## on `nimcp` and nothing else -- nimcir stays a library with no dependencies
## beyond the standard library, which a `requires` line here would have ended.
##
## Shaped by three nimcp constraints, all verified against its source rather
## than its documentation:
##
## - `mcpTool` accepts only `int`/`uint`/`float`/`string`/`bool` parameters.
##   `seq[T]` and `JsonNode` are declared in its schema generator but have no
##   branch in its argument extraction, so they do not compile.
## - **Parameter defaults are ignored.** Every parameter is emitted as
##   `required`, and an omitted one raises `KeyError` inside the wrapper. So
##   there are no optional arguments here; where one would be natural, the
##   parameter is required and an empty string means "the default".
## - The return value is stringified, so every tool returns `string`.
##
## Transport is stdio, and should stay that way without a deliberate decision:
## nimcir's role, evaluator and annotation registries are process-global
## mutable tables, and nimcp's HTTP/WebSocket/SSE transports run handlers on
## Mummy worker threads where that is not `gcsafe`. stdio serialises every
## request, so no locking is needed.

import std/[os, osproc, strutils]

import nimcp

proc nimcirExe(): string =
  let env = getEnv("NIMCIR_BIN")
  if env.len > 0 and fileExists(env): return env
  result = findExe("nimcir")
  if result.len == 0:
    raise newException(ValueError,
      "the `nimcir` binary was not found. Build it with `nimble build` in " &
      "the nimcir checkout and put ./bin on PATH, or set NIMCIR_BIN to it.")

proc runNimcir(args: seq[string], withExitCode = false): string =
  ## `ValueError` is deliberate: nimcp maps it to JSON-RPC -32602 with the
  ## message intact, where anything else becomes an opaque -32603.
  var cmd = @[nimcirExe()]
  cmd.add args
  let (outp, code) = execCmdEx(quoteShellCommand(cmd))
  result = outp
  if withExitCode:
    result &= "\n(exit " & $code & ")"
  elif code != 0 and outp.strip().len == 0:
    raise newException(ValueError, "nimcir exited " & $code & " with no output")

let server = mcpServer("nimcir", "0.1.0"):

  mcpTool:
    proc nimcirGuide(): string =
      ## How to author a nimcir design file and how to read its report. Read
      ## this before writing a design.
      runNimcir(@["guide"])

  mcpTool:
    proc nimcirRoles(): string =
      ## List the roles available. A role is a parameterized bundle of claims
      ## a design gets by naming it.
      runNimcir(@["roles"])

  mcpTool:
    proc nimcirRole(name: string): string =
      ## One role in full: its parts, its parameters, and the claims it makes.
      ## - name: the role name, e.g. power_rail, i2c, regulator, opamp_stage
      if name.strip().len == 0:
        raise newException(ValueError, "name must not be empty")
      runNimcir(@["role", name])

  mcpTool:
    proc nimcirQuantities(): string =
      ## Every quantity a `require` statement can name, with the evaluator
      ## that produces it. A quantity not listed cannot be checked.
      runNimcir(@["quantities"])

  mcpTool:
    proc nimcirAnnotations(): string =
      ## Every key a `spec:` block accepts, with its type, unit and scope.
      runNimcir(@["annotations"])

  mcpTool:
    proc nimcirTemplate(kind: string): string =
      ## A starter design file to adapt.
      ## - kind: one of blank, rail, i2c
      runNimcir(@["new", (if kind.strip().len == 0: "blank" else: kind), "-"])

  mcpTool:
    proc nimcirCheck(source: string, offline: bool): string =
      ## Check a design. Give the complete Nim source of a design file; it is
      ## compiled and run, and the readiness report is returned with the exit
      ## code on the last line (0 clean, 1 a claim failed, 2 structural
      ## problem, 3 a claim nothing could check, 4 a capability is
      ## unavailable, 5 the design did not compile).
      ## - source: the whole design file, ending with quit(verifyMain(d))
      ## - offline: true to skip simulation and do graph walks only
      if source.strip().len == 0:
        raise newException(ValueError, "source must not be empty")
      let dir = getTempDir() / "nimcir-mcp"
      createDir(dir)
      let path = dir / "design.nim"
      writeFile(path, source)
      var args = @["check", path]
      if offline: args.add "--offline"
      runNimcir(args, withExitCode = true)

  mcpTool:
    proc nimcirEnv(): string =
      ## What this machine can do: the toolchain found, whether a simulator is
      ## available, and how many roles and quantities are registered.
      runNimcir(@["env"])

when isMainModule:
  let transport = newStdioTransport()
  transport.serve(server)
