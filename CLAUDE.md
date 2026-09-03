# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

- **Run all tests**: `nimble test` — **and read the output, never the exit code.** `nimble` returns 0 whether the suite passed or not, verified both ways; the check that means something is `nimble test 2>&1 | grep -cE "FAILED|Error:"` returning 0. The `test` task in `nimcir.nimble` is written out by hand rather than left to nimble's built-in one, which *printed* a compile error and then exited 0 anyway — so a green run meant only that nimble itself had run, and three real failures across two files sat hidden behind it. The hand-written task at least aborts at the first failing file and prints it. It compiles and runs every `tests/*.nim` file via `tests/config.nims`, which adds `src` to the path.
- **Run a single test file**: `nim c -r --path:./src tests/test_netlist_core.nim` (same for any other file under `tests/`).
- **Skipped, not failed**, when the toolchain is absent: the `nimcir/spice/ngspice` backend tests in `tests/test_spice_ngspice.nim` skip when `ngspice` isn't on `PATH`; `tests/test_xspice_build.nim` and `tests/test_xspice_digital.nim` skip unless `$NGSPICE_SRC` points at a *configured* ngspice source tree.
- **Type-check a module** without running anything: `nim check --path:./src src/nimcir/netlist.nim`
- **Build the binary**: `nimble build`, producing `./bin/nimcir`.
- **Check a design**: `./bin/nimcir check designs/foo.nim`. `nimble verify` checks every design under `designs/` and every file under `templates/`; `nimble guide` prints the authoring guide. See `designs/CLAUDE.md` for the designs themselves, the exit codes and how to inspect what was actually simulated. **Template health is `nimble verify`'s job, not `nimble test`'s** — `nimble test` used to compile and `--offline`-check every template too, but that cost ~42s per run for coverage `verify` already gives.
- **Discovery** (works in a repo that is not this one, reads the live registries, writes nothing): `nimcir roles`, `nimcir role <name>`, `nimcir quantities`, `nimcir annotations`, `nimcir guide`, `nimcir env`, `nimcir new <blank|rail|i2c> <path>`.
- **Run an example script** (none are part of `nimble test`): `nim c -r --path:./src examples/divider.nim` (builds a netlist with `nimcir/netlist/dsl` and prints it as SPICE), `examples/pdn_sweep.nim` (decoupling impedance vs frequency), `examples/opamp_bode.nim` (closed-loop response and loop gain of an amplifier stage), `examples/design_contract.nim` (roles, annotations and requirements), `examples/xspice_gain.nim` / `examples/xspice_dff.nim` / `examples/xspice_integrator.nim` (XSPICE code models — memoryless, event-driven and analog-state respectively; need `$NGSPICE_SRC`).

## Architecture

`nimcir` is a proprietary-licensed Nim library for describing a circuit, stating what it must do, and checking that by simulation.

Dependency order is `netlist` <- `spice` <- `analysis`, `netlist` <- `pcb`, `netlist` <- `contract`, `netlist` <- `schematic`, `pcb` <- `fem`, `netlist`/`pcb` <- `ibis`, and nothing depends backwards.

| Submodule | What it is |
| --- | --- |
| `src/nimcir/netlist/` | The format-agnostic in-memory netlist: types, graph, the annotation vocabulary, the authoring DSL, and file-format readers/writers under `formats/`. |
| `src/nimcir/schematic/` | A heuristic "does the topology look right" visualizer: a renderer-neutral scene, deterministic placement/routing, and self-contained SVG plus a public JSON API. Depends only on `netlist`. |
| `src/nimcir/spice/` | Runs simulations through an external SPICE backend (ngspice) and owns the simulation-only netlist transforms — isolation, flattening, device models. `spice/xspice/` authors XSPICE code models. |
| `src/nimcir/analysis/` | Answers questions *about* a netlist, from pure graph walks up to full simulation (PDN, start-up, transient, op-amp, DC sweep, derating). |
| `src/nimcir/contract/` | Design *intent*: roles, assertions and the evaluator registry. Depends only on `netlist`, so a design stays inspectable with no simulator in the build. |
| `src/nimcir/pcb/` | The *physical* board — layers, stack-up, copper, holes, placements, outline. Where DRC/DFM/SI/PI work lands. |
| `src/nimcir/parts/` | Which real part a computed value is: requests, policies and preferred-value series. |
| `src/nimcir/ibis/` | Interface to IBIS: reads a vendor's `.ibs` buffer model (I/V curves, edge rates, package RLC) into a typed model. No-op past parsing so far. Depends on `netlist` and `pcb`. |
| `src/nimcir/fem/` | Interface to an external finite-element field solver (electromagnetic + thermal). Skeleton — problem/mesh/backend types only, no backend (MFEM intended). Depends on `pcb`. |

Three modules sit outside any submodule because the dependency order gives them nowhere else to live: `units.nim` and `eng.nim` *below* everything, `verify.nim` (the runner and the readiness report) *above* everything. `cli.nim` is the `nimcir` binary. `src/nimcir.nim` is the package module and is deliberately **not** a re-export hub — submodules are imported by their own path (`import nimcir/netlist`).

The library has no dependencies beyond the Nim standard library (`requires "nim >= 2.2.10"`), and that stays true because the MCP server is a **separate package** under `mcp/` — "opt-in per import" is the rule everywhere else here, but a nimble dependency can only be made opt-in per *package*. Package metadata lives in `nimcir.nimble`, where `namedBin["nimcir/cli"] = "nimcir"` builds the binary from `src/nimcir/cli.nim` rather than `src/nimcir.nim`, so `import nimcir` in an unrelated program does not drag in the simulator, `osproc` and the whole analysis tree.

## Where the detail lives

Read the `CLAUDE.md` in the directory you are working in — each holds the design decisions, invariants and traps for that submodule, and they are where new detail belongs.

- `src/nimcir/CLAUDE.md` — the package-root modules: `units.nim`, `eng.nim`, `verify.nim`, `cli.nim`
- `src/nimcir/netlist/CLAUDE.md`, `src/nimcir/spice/CLAUDE.md`, `src/nimcir/spice/xspice/CLAUDE.md`, `src/nimcir/analysis/CLAUDE.md`, `src/nimcir/contract/CLAUDE.md`, `src/nimcir/pcb/CLAUDE.md`, `src/nimcir/parts/CLAUDE.md`, `src/nimcir/ibis/CLAUDE.md`, `src/nimcir/fem/CLAUDE.md`
- `designs/CLAUDE.md` — the worked designs, exit codes, and how to see the deck that actually ran
- `docs/architecture.md` — how the submodules relate, and what happens between `nimcir check board.nim` and the report
- `docs/authoring.md` — writing a design (also `nimble guide`)
- `docs/findings.md` — what is still open; `docs/RESOLVED_FINDINGS.md` — everything already fixed, with what it was and what the fix was
