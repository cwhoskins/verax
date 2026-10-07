# `ibis` submodule

Reads an IBIS `.ibs` file into a typed model (I/V curves, edge rates, die C, package RLC as `typ/min/max`) and **interprets** it as a behaviour (`behave.nim`). Depends on `netlist` and `pcb`. The whole submodule is in the hub (no external tool). Interpreting is pure data: `behave` builds no solver devices and reaches no verdicts — simulating is `si/`'s job, judging a design is `analysis`'. IBIS 3.2 core is parsed, plus `[Model Spec]` and `[Receiver Thresholds]`. **No writer**, deliberately.

- **`types.nim`**
  - Every quantity is a bare `float` in SI base units, not a `verax/units` type — one generic `Triplet` can't carry six quantity types. Don't "fix" this with per-quantity triplet types.
  - `Triplet` records presence per corner: `NA` ≠ `0.0`. `get` **raises** on an absent corner; `has` is the non-raising check.
  - `raw` fields keep each block as lexed so unmodelled subparameters stay reachable; unmodelled keywords survive in `IbisFile.sections`.
- **`parse.nim`** — lexer, separate from `reader` so unknown keywords round-trip. Grammar traps:
  - `[Comment Char]` redefines the comment character from that line on; parse it from the raw line *before* comment stripping.
  - Keywords are case-insensitive and space/underscore-equivalent (`canonicalKeyword`).
  - A keyword's `[` must be in column 1. `[End]` ends the file.
  - `parseIbisNumber`: `M` is mega, `m` is milli; `meg` is not IBIS; RKM (`2k2`) is rejected.
  - The 120-char line limit is not enforced (vendor files exceed it).
- **`reader.nim`** — `readIbis`/`readIbisFile`. Errors are `IbisError` with line context. **An unrecognised keyword degrades, it does not error** — that's why a 3.2 reader opens a 7.x file.
  - `[Model Spec]` rows are triplets; `[Receiver Thresholds]` values are single and `Vinh_ac`-style offsets stay offsets from `Vth`, as written. `V_fixture_min/max` fill `Waveform.vFixture`'s min/max corners.
- **`behave.nim`** — `driverBehaviour`/`receiverBehaviour` per corner. Its module doc is the normative convention list (IBIS 7.2 clauses cited); the traps:
  - `IvCurve` is **absolute pad voltage, current out of the die** — the opposite sign to IBIS. Converted once here.
  - **Every table is added once**: IBIS requires pullup/pulldown with the clamp current already subtracted. A test folds clamps into the tables and must see the steady state move.
  - End segments **extend linearly** (flat would switch a clamp off).
  - `Ku`/`Kd` solve the *full* driver equation (clamps and `C_comp·dv/dt` included) per time point, least squares past two fixtures, rejected when ill-conditioned, **never clamped to [0, 1]** (a warning instead). The reconstruction residual decides `KSeries.available`.
  - Fixtures with `L_fixture`/`R_dut`/`L_dut`/`C_dut` are reported unusable, never simplified. Too few usable waveforms → the `[Ramp]` fallback with an `Assumption`.
  - **No corner substitution policy exists** (plan open decision 2): an absent min/max field makes that corner unsupported. The one permitted fill is `[Model Spec]`'s own "NA means typ" rule, recorded as a substitution.
  - Model types: Output/3-state/I/O drive; Open_drain/Open_sink have no pullup; Input/Terminator/I/O receive. `I/O_open_*`, ECL, Series… are unsupported by name.
- **`attach.nim`** — `bindIbis(nl, designator, file)` verifies every `[Pin]` maps to a real `Pin` and raises on the first mismatch; that check is the binding's whole value.
