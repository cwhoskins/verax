# Package-root modules — `units`, `eng`, `waveform`, `touchstone`, `verify`, `cli`

The modules that sit outside the submodule tree: three shared foundations
below everything, one format module beside them, and the runner and binary
above everything.

## `units.nim` — typed quantities at the authoring edge

`Volts`, `Ohms`, `Farads`, `Henries`, `Hertz`, `Seconds`, `Amps`, `Watts`,
`Fraction`, `Degrees`, `Decibels`, `Celsius`, `DBm`, `DBc`, `NoiseDensity`,
each a `distinct float`, with suffix constructors (`3.3.V`, `20.mohm`,
`5.pct`) scaling to SI base units, and a `Quantity` typeclass.

**Buys:** `esr = 20.mohm` cannot be misread the way `"20m"`/`"0.02"` can; a
wrong-unit `spec:` value is rejected at the setter (`esr = 20.nF`).

**Critique.** It is deliberately not dimensional analysis, and that is the
right scope. The limitation is reach: a quantity is typed only until it is
written into `attrs`, after which every consumer reads a bare `float` (see
`netlist.md`). Assertions carry `unit: string`, measurements carry
`unit: string`, `pcb` has its own `Nm`/`Deg`, IBIS and SI are bare floats by
decision. So "typed units" is a property of the DSL boundary, not of the
codebase. `Celsius` carrying both absolutes and differences, distinguished
only by the key it is stored under, is a documented compromise.

## `eng.nim` — presentation-only formatting

`eng(x, unit)` renders engineering notation for humans. The important design
fact is the *separation*: deck values go through
`netlist/formats/spice.spiceValue` (always an explicit exponent), because
SPICE reads `15.9M` as 15.9 milli. Two formatters with one purpose each is
the right structure here.

## `waveform.nim` — curve math over sampled axes

Pure procs over parallel `openArray[float]` pairs: crossings, `valueAt`,
`corner3dB`, `bandEdges`, `harmonicAmplitudes`/`thd` (over the samples' own
timestamps, last whole number of periods), `fundamentalFreq`, `timeMean`/
`timeRms` (time-weighted), rise/overshoot/settle. NaN for "not found", raise
for malformed input. Moved below `analysis` so `si` can share it.

**Buys:** all of the numerical judgement in measurement is testable with no
simulator, and `analysis` and `si` cannot measure the same thing two ways.

**Critique:** curves are pairs of arrays checked at each call (`checkPair`)
rather than a `Sampled` type that makes a length mismatch unrepresentable.
`openArray` keeps it zero-copy over `SimResult` seqs, which is likely why.
The module has no notion of whether an axis is log or linear beyond a
`logX` flag the caller must remember to pass for frequency data.

## `touchstone/` — S-parameter files

`SParams` (port count, single reference `z0`, `freqs`, row-major complex
matrices), a reader that normalises the 2-port order, and scalar conversions
with **two named dB pairs** (voltage-ratio 20·log vs power-ratio 10·log)
rather than one generic helper — a small, sharp decision that removes a
classic 2× error.

**Critique:** it is a real submodule (`types`/`parse`/`reader`) used by
`pcb/tline` and `si`, but it is not in `CLAUDE.md`'s dependency order or
`architecture.md`'s submodule table (**fixed 2026-10-10**). Per-port reference impedances
(Touchstone v2) are unsupported, which is stated.

## `verify.nim` — the runner, the catalog, and more

Owns `Readiness` (requested/available capabilities, simulator, environment,
structural issues, the `Plan`, `checks: seq[Check]` one per analysis run,
rejected and flat results) and the graded exit codes (0 clean, 1 failed,
2 structural, 3 unchecked, 4 environment, 5 compile). `readiness(d, allowed,
board)` is pure with respect to the design: structure → context → plan → run
→ collect → render.

**Patterns that make it work.**
- *Rendered fresh, not composed.* The report is built from `Readiness`
  rather than by concatenating `report`/`summary`/`explain`, because each of
  those re-lists claims; ordering and de-duplication are the product.
- *One block per analysis run.* Grouping by plan step lets assumptions be
  shown under the run they affected; it cannot be recovered from flat results.
- *`Readiness` never holds an `AnalysisReport`*, pinned by a size test, so
  curve data cannot leak into a report.
- *Machine formats are first-class.* JSON (`verax.readiness/1`, NaN → null)
  and JUnit; nothing else may write to stdout during `readiness`.

**Critique.**
1. **It has become the integration point for everything.** At ~1.5k lines it
   holds the runner, the role/quantity/annotation catalog (used by the CLI and
   the Python spike), three renderers, baseline diffing, BoM compilation entry, board
   layout entry, SI constraint derivation, schematic archiving, and option
   parsing. Each new top-level capability lands here because this is the one
   module allowed to import everything. Splitting by concern (`verify/run`,
   `verify/catalog`, `verify/render`, `verify/commands/*`) would keep "may
   import everything" without "contains everything".
2. **Catalog reachability is computed by probing role expanders with
   placeholder parameters** (`"1"`). Clever and honest (it reports what
   actually expands), but it is why string "mode" parameters are banned in
   roles: the catalog's probing strategy constrains how roles may be written.
3. **The hand-built JSON** (no `std/json` object model for output) keeps
   control over NaN and ordering; it is also a place where schema drift is
   caught only by tests.

## `cli.nim` — the binary

Compiles a design and runs it as **two processes**, never `nim c -r`, so "does
not compile" (exit 5) is distinct from "a claim failed". Locates verax's
sources through a validated candidate chain because nimble deletes build
directories. Thin by design.

**Critique:** the subcommands (`check`, `bom`, `layout`, `constraints`,
`roles`, `quantities`, `new`, …) are partly here and partly flags forwarded
into the compiled design's `verifyMain`, so a subcommand's behaviour is
split across the parent process and the design binary. That is inherent to
"a design is a program", and the forwarding is explicit; it does mean adding
a subcommand touches both `cli.nim` and `verify.nim`.

## Template leftovers

`src/verax.nim` is the nimble project template (`proc add*(x, y: int)`), and
`src/verax/submodule.nim` is the template's example module. The intent
("`src/verax.nim` is deliberately not a re-export hub") is met, but
`import verax` currently gives callers an `add` proc and nothing else.
**Fixed 2026-10-10:** `submodule.nim` deleted; `src/verax.nim` is now a doc-only module saying why it exports nothing.
