# Designs and templates

A design is a `.nim` file using `verax/contract/dsl` that ends with `quit(verifyMain(d))`, so `nim c -r --path:./src designs/foo.nim` is the same check as `./bin/verax check designs/foo.nim` minus the wrapper. That is the primary loop.

Exit codes: `0` clean, `1` a claim failed, `2` structural problem, `3` a claim nothing could check, `4` a requested capability is unavailable, `5` the design did not compile (only `verax check` produces `5`). Flags forwarded to the design binary: `--offline`, `--caps=op,dc,ac,tran,si`, `--verbose`, `--strict`, `--board=<file.kicad_pcb>`.

## Layout and build traps

- `lib/oring.nim` and `lib/adg904.nim` have no importing design (their `xbar_*` boards were removed), so nothing compiles them; type-check them by hand after changing what they use.
- Shared parts and subcircuits live in `designs/lib/`. `nimble verify` does **not** check them (`listFiles` is not recursive); they compile as dependencies of the designs that import them.
- A file importing an XSPICE code model for its `ModelSpec` needs `-d:xspiceSpecOnly` (`verax check` passes it; tests use a per-file `tests/<name>.nim.cfg`, which is why `.gitignore` re-includes `/tests/*.nim.cfg`). Without it the compiler tries to build the model's FFI against ngspice headers.
- A board that is both a module and a program (`carrier`, `sensor_head`) splits on `when isMainModule`; `asSubcircuit` drops its connectors so bench drives don't leak into a system.
- An `.ac` sweep through an XSPICE code model returns zero output (no model here sets `AC_GAIN`); use the `.tran` tone method for PSRR through one.
- `diff_pair`'s `z_diff`/`intra_pair_skew` always come back NOT CHECKED (no trace-length/Z0 solver yet), so designs meant to check clean claim only `diff_pair_symmetry`.

## Worked examples by feature

When looking for an example of a mechanism, start here: two-subject/`roleRef` claims and multi-channel packages → `riaa_preamp`; multiple sim models per part → `lt8640a_buck`; `SimReplacement.build` loop model → `adj_regulator`; parameterized subckts → `param_filter`, `divider_net`; event-driven XSPICE on a shared analog bus → `i2c_eeprom`; system of boards via `asSubcircuit` → `system_sensor_rig`; user-defined role → `lib/xbar_parts.nim` (`safe_default`, exercised by `tests/test_xbar_safe_default.nim`), `lib/i2c_parts.nim`, `rf_frontend`; interface arrays and pinmux → `spi_memories` (`lib/stm32h563.nim`); interface defined in the design file → `rf_frontend`; differential pairs → `usb_hs_link`; footprints → `verax layout` → `pcb_demo`; transient-only (no meaningful `.op`) → `charge_pump`; `oscillator` role → `wien_osc`; AC-coupled `gain_stage` + `large_signal` → `ts808_drive`; capacitor banks → `lib/capbank.nim`; signal integrity on a routed board (`si_net`, IBIS files, `--board=`, `verax constraints`, overshoot/undershoot ratings, a PRBS7 eye) → `si_spi` (it passes its own `si_spi/si_spi.kicad_pcb` when no `--board=` is given, so `nimble verify` checks the routed result; its eye claim makes `verax constraints` take ~2.5 min, since each sweep judges the eye at its intervals' ends, `docs/RESOLVED_FINDINGS.md` §75); bare `require`s sharing a role's run (load-step extremes, inductor valley/peak, settled min/max) → `lt8640a_buck`, `charge_pump`; a `%` quantity claimed as a relative bound to dodge `claim_unit_unstated` → `lt8640a_buck` (§76); user-defined role reaching the "needs a role binding" quantities (loop gain, crossover, `f_unity`, clipping, compression) → `datalogger/lib/analog.nim`'s `adc_driver`; the PDN's shape beyond its worst point (`z_min`, antiresonance, `cap_count`) and `parts_over_derating` → `datalogger`; BOM annotations (`mpn`/`manufacturer`, `dnp`, `bom_exclude`, `part_use`) → `datalogger` (`verax bom`); a predicate `require` over two measurements (firmware's CC-sense ADC reading against the Type-C detection window) → `datalogger` (`REQ-DL-CCSNS-ADC-001`); the RF annotation vocabulary (connector/microstrip/switch/gain-block/bead/choke keys, `sparams`) and the load-switch, ferrite and coupled-inductor models at DC → `rf_trx`.

## Seeing what was actually simulated

Simulated fragments are derived (isolated, terminated, model-substituted), so inspect them rather than reasoning from the design file:

- `VERAX_KEEP_DECKS=<dir>` copies every deck handed to ngspice.
- `--keep-runs=<dir>` (or `$VERAX_KEEP_RUNS`) writes `runNNN.cir`/`.raw`/`.log`/`.svg`/`.json` per simulation plus `index.txt` naming each run, and `runFULL.*` schematics of the authored design. The deck is the one that ran; `load runNNN.raw` in ngspice restores the curves.
- `--save-currents` adds device terminal currents (`@r1[i]`), `.op`/`.tran`/`.dc` only.

None of these can move a measured number (`tests/test_spice_keep.nim`).
