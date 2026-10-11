# `ibis/` — what a vendor says a buffer does

Reads an IBIS `.ibs` file into a typed model and interprets it as behaviour
(absolute I/V curves, switching coefficients `Ku`/`Kd`, receiver thresholds,
power-aware factors). No writer; no solver; no verdicts. Imports `netlist`,
and `pcb` for one helper (`attach.placementOf`).

## Data structures

Two layers, deliberately separate.

**Transcription (`types.nim`) — what the file says.**

| type | shape | notes |
|---|---|---|
| `Triplet` | `present: array[Corner, bool]`, `value: array[Corner, float]` | typ/min/max with per-corner presence; `get` raises on an absent corner, `has` checks |
| `IvTable` / `VtPoint` / `Waveform` | rows of triplets; waveform carries its fixture (`R/L/C_fixture`, `R/L/C_dut`, `V_fixture`) and optional composite current | sign convention as IBIS writes it |
| `IbisModel` | model type, refs (pullup/pulldown/clamp reference triplets), four I/V tables, ISSO tables, `RampSpec`, rising/falling waveforms, `ModelSpec`, `ReceiverThresholds`, and `raw: IbisSection` | |
| `ModelParam` | `{present, value}` | single (non-triplet) values |
| `IbisComponent` / `PinEntry` / `DiffPin` / `Package` | package RLC triplets, per-pin RLC with `present: set[PinRlc]` | |
| `IbisSection` | keyword, raw keyword, line, args, body lines, children | the lexed tree; unknown keywords survive here |
| `IbisFile` | header strings + components, models, selectors, all `sections` | |

**Interpretation (`behave.nim`) — what it means.**

| type | shape | notes |
|---|---|---|
| `IvCurve` | absolute pad voltage → current *out of the die*, with slope; linear extension past the ends | sign flipped once, here |
| `CornerData` | one corner's resolved curves, rails, C_comp | the only corner policy: none, beyond `[Model Spec]`'s own NA→typ rule |
| `KSeries` | `Ku(t)`/`Kd(t)` for an edge, `available` gated by reconstruction residual, source (`waveforms`/`ramp`) | |
| `DriverBehaviour` / `ReceiverBehaviour` | everything `si/` needs per corner, plus `issues` and `assumptions` | |
| `ExtractTolerances` | conditioning and residual thresholds, fixture probe point | the probe point default is an `Assumption` |

## Patterns

**Lexer / reader / interpreter split.** `parse` lexes into a keyword tree
that preserves everything; `reader` maps the keywords it knows onto types and
leaves the rest in `sections`; `behave` turns data into behaviour. An
unrecognised keyword degrades, it does not error — a 3.2 reader opens a 7.x
file.

**Presence is explicit per value.** `NA` is not `0.0`. Corners are never
filled in from each other except where the spec says so, and that one
substitution is recorded.

**Self-validation of the interpretation.** `Ku`/`Kd` are solved by least
squares against the full driver equation, and the solved series is
*re-simulated* against the fixture (`reconstructNetwork`); the residual
decides availability. Ill-conditioned solves are rejected, out-of-range
coefficients warned, never clamped.

**Binding verifies, then gets out of the way.** `bindIbis` checks every
`[Pin]` maps to a real netlist pin and raises on the first mismatch; that
check is the whole value of the binding.

## What this buys

- **Fidelity to the source**, which is what an SI result can be no better
  than. Keeping `raw` sections means a later feature can read a
  subparameter without re-parsing or changing the reader.
- **Physics conventions resolved once.** Every downstream consumer (`si/`)
  sees absolute curves with a single sign convention; the IBIS conventions
  (clamp-subtracted tables, rail-relative voltages) are handled in one
  place with the spec clauses cited.
- **Interpretation that checks itself** — a vendor waveform that the extracted
  coefficients cannot reproduce is reported, not silently used.

## Critique

1. **Four presence idioms in one module.** `Triplet.present` (array),
   `ModelParam.present` (bool), `RampSpec.rLoadPresent` (named bool),
   `PinEntry.present: set[PinRlc]`, and `ReceiverThresholds.present` /
   `ModelSpec.present` for whole blocks. Each fits its shape; a reader has to
   learn all of them, and none is the `AnnValue`/`Option` the rest of the
   codebase uses (README P7).

2. **Lookups by linear case-insensitive scan** (`model`, `component`,
   `hasModel`) over `seq`s, and `pin` is case-*sensitive* while `model` and
   `component` are case-insensitive. IBIS model names are case-insensitive;
   pin names are not specified as such. The asymmetry is plausibly right but
   is not documented where it is implemented.

3. **`ibis → pcb` for one function.** `attach.placementOf(pcb, binding)` is
   the only reason `ibis` imports `pcb`. That helper could live in `si/`
   (which already imports both), leaving `ibis` dependent only on `netlist`.

4. **Bare floats by decision.** The doc comment explains why one generic
   `Triplet` can't carry six unit types, and that is right; it means the
   IBIS layer is outside the `units` discipline entirely, and SI quantities
   enter the rest of the codebase as plain floats.

5. **`behave.nim` is ~1k lines of numerics in one module** (curve
   conversion, fixture back-solving, 4×4 least squares, scalar root finding,
   reconstruction). It is well commented and tested; it is also the densest
   file in the tree and a natural candidate to split along those seams.

## Things that look odd but are right

- `IvCurve` sign is opposite to IBIS (current out of the die). Converted once.
- Each I/V table is added once: IBIS requires pullup/pulldown with the clamp
  current already subtracted.
- End segments extend linearly; extending flat would switch a clamp off.
- `Ku`/`Kd` are never clamped to [0, 1]; out-of-range is a warning, because
  clamping hides a fixture or model error.
