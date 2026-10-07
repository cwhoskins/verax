# Designs and templates

A design is a `.nim` file using `verax/contract/dsl` that ends with `quit(verifyMain(d))`, so `nim c -r --path:./src designs/foo.nim` is the same check as `./bin/verax check designs/foo.nim` minus the wrapper. That is the primary loop.

Exit codes: `0` clean, `1` a claim failed, `2` structural problem, `3` a claim nothing could check, `4` a requested capability is unavailable, `5` the design did not compile (only `verax check` produces `5`). Flags forwarded to the design binary: `--offline`, `--caps=op,dc,ac,tran,si`, `--verbose`, `--strict`, `--board=<file.kicad_pcb>`.

## Layout and build traps

- Shared parts and subcircuits live in `designs/lib/`. `nimble verify` does **not** check them (`listFiles` is not recursive); they compile as dependencies of the designs that import them.
- A file importing an XSPICE code model for its `ModelSpec` needs `-d:xspiceSpecOnly` (`verax check` passes it; tests use a per-file `tests/<name>.nim.cfg`, which is why `.gitignore` re-includes `/tests/*.nim.cfg`). Without it the compiler tries to build the model's FFI against ngspice headers.
- A board that is both a module and a program (`carrier`, `sensor_head`, `xbar_*`) splits on `when isMainModule`; `asSubcircuit` drops its connectors so bench drives don't leak into a system.
- A whole-system `.op` with both the LT8640A switching code model and the PoE rectifier bridge does not converge — `equipXbarPower(..., withBuckModel = false)` swaps in `buildIdealBuck` for the system.
- An `.ac` sweep through an XSPICE code model returns zero output (no model here sets `AC_GAIN`); use the `.tran` tone method for PSRR through one.
- `diff_pair`'s `z_diff`/`intra_pair_skew` always come back NOT CHECKED (no trace-length/Z0 solver yet), so designs meant to check clean claim only `diff_pair_symmetry`.

## Worked examples by feature

When looking for an example of a mechanism, start here: two-subject/`roleRef` claims and multi-channel packages → `riaa_preamp`, `aa_filter`; multiple sim models per part → `lt8640a_buck`; `SimReplacement.build` loop model → `adj_regulator`; parameterized subckts → `param_filter`, `divider_net`; event-driven XSPICE on a shared analog bus → `i2c_eeprom`; system of boards via `asSubcircuit` → `system_sensor_rig`, `xbar_switch`; user-defined role → `lib/xbar_parts.nim` (`safe_default`), `lib/i2c_parts.nim`; interface arrays and pinmux → `spi_memories` (`lib/stm32h563.nim`); interface defined in the design file → `rf_frontend`; differential pairs → `usb_hs_link`; magnetics + `dc_path_exists` barrier → `xbar_poe`; capacitor banks → `lib/capbank.nim`; signal integrity on a routed board (`si_net`, IBIS files, `--board=`, `verax constraints`) → `si_spi` (it passes its own `si_spi/si_spi.kicad_pcb` when no `--board=` is given, so `nimble verify` checks the routed result). `xbar_switch.nim`'s header lists what cannot yet be checked.

## Seeing what was actually simulated

Simulated fragments are derived (isolated, terminated, model-substituted), so inspect them rather than reasoning from the design file:

- `VERAX_KEEP_DECKS=<dir>` copies every deck handed to ngspice.
- `--keep-runs=<dir>` (or `$VERAX_KEEP_RUNS`) writes `runNNN.cir`/`.raw`/`.log`/`.svg`/`.json` per simulation plus `index.txt` naming each run, and `runFULL.*` schematics of the authored design. The deck is the one that ran; `load runNNN.raw` in ngspice restores the curves.
- `--save-currents` adds device terminal currents (`@r1[i]`), `.op`/`.tran`/`.dc` only.

None of these can move a measured number (`tests/test_spice_keep.nim`).
