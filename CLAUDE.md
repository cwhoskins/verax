# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

- **Run all tests**: `nimble test` — **read the output, never the exit code.** `nimble` exits 0 whether or not the suite passed; the real check is `nimble test 2>&1 | grep -cE "FAILED|Error:"` returning 0. The hand-written `test` task in `verax.nimble` aborts at the first failing file and names it. Tests compile via `tests/config.nims`, which adds `src` to the path.
- **Run a single test file**: `nim c -r --path:./src tests/test_netlist_core.nim`.
- **Skipped, not failed**, when the toolchain is absent: `tests/test_spice_ngspice.nim` needs `ngspice` on `PATH`; `tests/test_xspice_build.nim` and `tests/test_xspice_digital.nim` need `$NGSPICE_SRC` pointing at a *configured* ngspice source tree. `tests/test_fem_mfem.nim` needs `$MFEM_DIR` (an MFEM install prefix) or `nimble mfem` (fetches, builds and caches serial MFEM + the C shim; minutes of C++). `tests/test_fem_mfem_load.nim` (`nimble mfemcheck`) skips only when *no* toolchain is found — a found-but-unloadable install fails.
- **Type-check a module**: `nim check --path:./src src/verax/netlist.nim`
- **Build the binary**: `nimble build` → `./bin/verax`.
- **Check a design**: `./bin/verax check designs/foo.nim`. `nimble verify` checks every design under `designs/` and every file under `templates/` — template health is `verify`'s job, not `test`'s. `nimble guide` prints the authoring guide. See `designs/CLAUDE.md`.
- **Compile a BOM**: `./bin/verax bom designs/foo.nim --bom-catalog=parts.json [-o bom.csv] [--bom-format=text|csv|json] [--bom-lock=prior.json]` (`$VERAX_BOM_CATALOG` if no flag). Runs no checks; the JSON output is also the next run's `--bom-lock`.
- **Discovery** (reads live registries, writes nothing): `verax roles`, `verax role <name>`, `verax quantities`, `verax annotations`, `verax guide`, `verax env`, `verax new <blank|rail|i2c> <path>`.
- **Generate a board**: `verax layout designs/foo.nim -o foo.kicad_pcb [--layout-layers=N] [--layout-size=WxH]` — a blank `Pcb` with real footprints (from `spec: footprint = "Lib:Name"`, resolved against `$VERAX_FOOTPRINT_PATH`/`/usr/share/kicad/footprints`), parts gridded outside the outline, unrouted. `nimble generate` is its `kicad-cli` acceptance gate; `nimble kicadcheck` is the edit path's.
- **SI**: `./bin/verax check designs/foo.nim --board=foo.kicad_pcb` checks `si_net` claims on a routed board (native engine, no ngspice; `designs/si_spi.nim`). `./bin/verax constraints designs/foo.nim [--net=N] [--dru=out.kicad_dru] [--stackup-layers=N] [--format=json]` derives routing rules before layout. Plan and status: `docs/ibis_simulator_plan.md`.
- **Examples** (not part of `nimble test`): `nim c -r --path:./src examples/<name>.nim` — `divider`, `pdn_sweep`, `opamp_bode`, `design_contract`, `si_bench` (`-d:release`), and `xspice_gain`/`xspice_dff`/`xspice_integrator` (need `$NGSPICE_SRC`).

## Architecture

`verax` is a proprietary-licensed Nim library for describing a circuit, stating what it must do, and checking that by simulation.

Dependency order is `netlist` <- `spice` <- `analysis`, `netlist` <- `pcb`, `netlist` <- `contract`, `netlist` <- `schematic`, `netlist` <- `bom`, `netlist` <- `parts`, `pcb` <- `fem`, `netlist`/`pcb` <- `ibis`, `touchstone` <- `pcb`, `ibis`/`pcb`/`touchstone` <- `si` <- `analysis` (no `si` -> `spice` edge, no `spice` -> `schematic` edge — `run_archive.nim` joins those two from above). **Nothing depends backwards** — when a type is needed by two siblings it moves down, and when a module needs two siblings it moves up.

| Submodule | What it is |
| --- | --- |
| `netlist/` | Format-agnostic in-memory netlist: types, graph, annotation vocabulary, authoring DSL, `formats/`. |
| `schematic/` | Heuristic topology visualizer: scene, deterministic placement/routing, SVG + JSON. |
| `spice/` | Runs ngspice; owns simulation-only transforms (isolate, flatten, device models). `spice/xspice/` authors XSPICE code models. |
| `analysis/` | Questions about a netlist, from graph walks to full simulation. |
| `contract/` | Design intent: roles, assertions, evaluator registry. Depends only on `netlist`, so a design stays inspectable with no simulator. |
| `pcb/` | The physical board — layers, stack-up, copper, holes, placements, outline; KiCad read/write. |
| `parts/` | Which real part a computed value is: requests, policies, preferred-value series. |
| `bom/` | Which *orderable* part each component is: collect, resolve against catalogues, report/lock. Takes a `Netlist`, never a `Pcb`. |
| `ibis/` | IBIS `.ibs` reader, plus `behave`: a model interpreted as data (absolute curves, `Ku`/`Kd`). |
| `si/` | Native SI transient engine: one net (IBIS driver, package, lines, vias, receivers) simulated, measured, and its routing constraints derived. No ngspice. |
| `fem/` | Field-solver interface skeleton (no backend yet). |
| `touchstone/` | Touchstone `.sNp` reader and S-parameter/dB conversions; root-level, used by `pcb/tline` and `si`. |

`units.nim`/`stated.nim`/`eng.nim`/`waveform.nim` and `touchstone/` (S-parameter files) sit below everything, `run_archive.nim` joins `spice` to `schematic` for the run archive, `verify.nim` above everything, `cli.nim` is the binary. `src/verax.nim` is deliberately **not** a re-export hub — import submodules by path (`import verax/netlist`). `namedBin["verax/cli"] = "verax"` builds the binary from `cli.nim` so `import verax` doesn't drag in the simulator.

No dependencies beyond the Nim stdlib (`nim >= 2.2.10`). The MCP server is a **separate package** under `mcp/` because a nimble dependency can only be opt-in per package.

## Where the detail lives

Read the `CLAUDE.md` in the directory you are working in. Also: `docs/architecture.md` (how the submodules relate), `docs/authoring.md` (writing a design), `docs/findings.md` (what is open), `docs/RESOLVED_FINDINGS.md` (what was fixed and how).
