# `parts/` — choosing a real part for a computed value

Small (≈400 lines) and deliberately narrow: a parameterised module states what
it needs and why; the board's policy decides which part that is. Imports
`units` and `netlist`; nothing in the pipeline imports it — design libraries
do.

## Data structures

| type | shape | notes |
|---|---|---|
| `CapUse` / `ResUse` / `IndUse` | closed enums of *function* (timing, coupling, decoupling, bulk; precision, general, power; filter, power) | the use is what decides dielectric/tolerance |
| `CapRequest` / `ResRequest` / `IndRequest` | typed value (`Farads`/`Ohms`/`Henries`) + use + one environment hint (`working: Volts`, `dissipating: Watts`, `carrying: Amps`) | zero hint = unknown |
| `Choice` | package, dielectric, ratings (typed), tolerance, ESR/ESL, part number, `use` string, `notes` | every non-empty field becomes a registered annotation |
| `PartPolicy` | three nullable `{.nimcall.}` procs (capacitor/resistor/inductor) | nil = "nothing to say", part left unannotated |
| `PreferredSeries` | hook over hard-coded E12/E24/E96 tables | `nearest` by ratio, considering the next decade |

## Patterns

**Request/policy split.** The module knows function, the board knows
environment; neither can choose alone. A `Request` crosses from one to the
other and a `Choice` comes back.

**Policy as a data object of procs** (same idiom as `RoleDef`), so a
runtime-built policy (a parts database, house derating rules) is
indistinguishable from the default.

**"Guess where forced, refuse where it's a choice."** `defaultPolicy`
silently picks C0G for timing (physics), picks X7R for decoupling *and notes
it* (judgement), and leaves voltage rating unset when no working voltage is
stated.

**Output as ordinary annotations with provenance.** `applyChoice` writes
registered keys with `annDerived`, so everything downstream (models,
derating, BoM) reads a chosen part exactly as it reads an authored one, and
the report can still tell them apart.

**One table read both ways.** `ceramicLadder` backs both
`smallestCeramicPackage` and `maxCeramicCapacitance`, so they cannot disagree.

## What this buys

- **Reusable circuit modules** that don't hard-code parts or take a dozen
  builder parameters, and boards that can change policy (derating, preferred
  dielectric, case size) in one place.
- **No new pipeline stage.** Because a choice lands as annotations, nothing
  in `spice`/`analysis`/`bom` has to know `parts` exists.
- **Traceability.** `part_use` survives on the component, so a finished
  netlist still records *why* a dielectric was chosen.

## Critique

1. **Zero means "not stated".** `applyChoice` writes a rating only when it is
   `> 0`; `CapRequest.working = 0` means unknown. This is the weakest of the
   absence idioms (README P7): a policy that wants to state "ESR is
   negligible, use 0" cannot. `Option` or `NaN` would distinguish the two.

2. **Overlap with `bom/` is unreconciled.** `parts` decides *what kind* of
   part (dielectric, case, rating); `bom` decides *which orderable* part, with
   its own `PartQuery`, family enum, case-code logic and tolerance-band rule.
   `parts/series.nim` (preferred values) and `bom`'s ignored `series`/
   `derating` defaults suggest the two were meant to meet; today a policy's
   choice and a catalogue's match are not checked against each other except
   as annotations `bom` happens to read.

3. **Closed `Use` enums vs. an open `part_use` annotation.** The enums are
   closed (good for exhaustive policy `case`s), but `part_use`'s allowed list
   is the *union* of three enums' spellings (`ruPower` and `iuPower` both map
   to `"power"`), so the annotation cannot tell a power resistor from a power
   inductor by itself — the kind does that. Fine; worth knowing.

4. **Only three part families have requests.** Ferrite beads, diodes and
   connectors have none; `bom` handles beads parametrically. The asymmetry is
   by scope, not design.

5. **Hard-coded density tables** (`ceramicLadder`) are honest about being
   typical, not vendor data, and are reported as such. They are also the
   kind of table a catalogue source could answer, which is another place the
   `parts`/`bom` split shows.

## Things that look odd but are right

- E-series tables are written out, not computed: seven E24 values deviate
  from `10^(n/24)`.
- Bypass-cap builders don't pass `working`; `spice/models` computes the DC
  across each cap at simulation time from the operating point.
- A capacitor-bank splitter lives in `designs/lib/capbank.nim`, not here,
  because it needs `spice/models/derating`.
