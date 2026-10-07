# `parts` submodule

Given that a circuit needs 22.5 nF *here*, which capacitor is that. Depends on `units` and `netlist`; nothing requires it.

**Why it exists:** the *module* knows a part's function (a timing cap must be C0G; a bypass cap should be Class 2), the *board* knows its environment (rail voltage, temperature, cost), and neither can choose alone. So a module states a `CapRequest`/`ResRequest`/`IndRequest` (value + *use*) and the board supplies a `PartPolicy` that returns a `Choice`. Don't replace this with per-component builder parameters or a post-hoc annotation pass.

- `PartPolicy` holds procs on a data object (like `RoleDef`) so a runtime-built policy behaves identically. A `nil` member means "nothing to say" → leave the component unannotated.
- **`policy.defaultPolicy()`: guess where the guess is forced, refuse where it is a choice.** C0G for timing is physics (silent default); X7R for decoupling is a judgement (defaulted *and noted*); a voltage rating is derived from a stated working voltage and **left unset when none is stated**.
- Builders don't pass `working` for bypass caps — `spice/models` computes the DC across each cap at simulation time.
- `annotate.applyChoice` writes a `Choice` as ordinary registered annotations with `annDerived` provenance, including `part_use` (an `akEnum` checked at the setter — see `netlist/CLAUDE.md`).
- `policy.ceramicLadder`/`smallestCeramicPackage`/`maxCeramicCapacitance` read one case-size-by-voltage table in both directions so they can't disagree.
- A capacitor-*bank* splitter needs `spice/models/derating` and so cannot live here; it is `designs/lib/capbank.nim`.

## `series.nim`

E12/E24/E96 ladders, `nearest` (by *ratio*, with the next decade's first value as a candidate), and the `PreferredSeries` hook (`exactSeries` default rounds nothing).

- **The tables are written out, not computed** — seven E24 values deviate from `10^(n/24)`.
- 240 Ω is E24 but not E96; E96's worst gap (1.33→1.37) means rounding costs up to 1.49%. Tests pin both.
