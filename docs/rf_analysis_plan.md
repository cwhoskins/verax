# RF analysis and simulation: plan for the remaining phases

**Status: Phase 0 shipped** (`e8ff729`, "Structure for RF verification
information") — the three new `units.nim` quantity types (`DBm`, `DBc`,
`NoiseDensity`), the `eng()` no-prefix fix for logarithmic units, the new
`src/verax/touchstone/` submodule (`SParams`, a Touchstone `.sNp` reader, and
the scalar Γ/VSWR/return-loss/insertion-loss/dB↔linear/dBm↔W conversions),
~19 new RF annotation keys in `netlist/annotations.nim`, and four designator
prefixes in `netlist/kinds.nim`. Nothing simulates yet; this document covers
what is still ahead — Phases 1 through 6 — and the context and structural
decisions that constrain them, carried over unchanged from the approved
strategic plan.

*General strokes for phases 1–6. Each phase gets its own detailed
implementation plan (in the shape Phase 0's was) when it is taken up.*

---

## Context

`verax` can check a power rail, an op-amp stage, an oscillator, a bus edge and
a converter's inductor current. It cannot check anything an RF board is
actually specified by. `docs/findings.md` §66 records this as the single
largest gap — every RF claim on `designs/xbar_switch.nim` (insertion loss,
isolation, return loss, VSWR, cascade loss, port match) is on the
cannot-check list — and `designs/rf_frontend.nim` is worse than blocked: it
declares `lna`, `power_amplifier` and `vga` components that reach no model,
fall through to `expandPinModels`' per-pin impedances, and are **deleted from
the deck**. A design whose whole point is a transmit and receive chain
currently simulates as three holes.

The target is the set of questions an RF designer asks: impedance matching,
gain, noise figure, linearity and distortion, and the dynamic range through a
transmit and a receive chain.

**Two findings changed the shape of this plan, both verified against the
installed toolchain rather than assumed:**

1. **ngspice 46 here already does S-parameters.** `.sp lin N f1 f2` with
   `portnum`/`z0` on voltage sources returned exact S11 and S21 for a test
   network (a 25 Ω series element between 50 Ω ports: S11 −13.979 dB, S21
   −1.938 dB, both to the last digit of the closed form). The build also
   carries `mlin` — a microstrip model taking `er`, `h`, `t`, `tand`, `rho`
   and roughness, which is exactly what `pcb/types.nim`'s `StackMaterial` and
   `StackEntry` already hold — plus `tline`, coupled lines, `.noise` and
   `.disto`. §66's "no S-parameters" is a verax gap, not a toolchain one.
2. **`.sp` sees XSPICE code models.** A `.sp` run through ngspice's built-in
   `gain` code model returned S21 = +9.99 dB against its 3.16 linear gain. So
   `acGain` reaches the S-parameter matrix, and a behavioural RF block is
   swept by `.sp` like any other device. This retires the risk that the
   behavioural-first choice and the S-parameter capability were incompatible.

A third check sets the honesty policy: **`.noise` confirms a behavioural block
is noiseless.** A gain-10 VCVS chain reported output noise equal to the source
resistor's thermal noise times ten and nothing else (9.099 µV against the
50 Ω source's 9.099 µV / 10). A simulated noise figure through a chain of
behavioural or S-parameter blocks measures the passive network and calls it
the chain — which is why noise figure carries provenance rather than a single
authoritative number.

**One scope decision to flag.** Converters were put out of scope as *modelled
parts*, but the dynamic-range mapping was the original ask. The plan resolves
this by making a converter's numbers **role parameters** — the author states
the ADC's full-scale and required SNR, the chain measures what arrives, and
the claim is against the stated limit. The mapping is claimable without a
`dac`/`adc` component existing; a spec-block component is a later phase.

---

## Where each piece lands

No new submodule beyond `touchstone/` (phase 0, shipped). Each remaining
piece goes where its dependencies already are, and the existing dependency
order is unchanged — critically, **`spice` never gains an edge to `pcb`**,
because a microstrip reaches a deck through annotations on a component, not
through a `Pcb` object.

```
units.nim, eng.nim          [shipped] dBm, dBc, noise density, no-prefix dB
  <- touchstone/            [shipped] .sNp reader + SParams type + scalar
  |    types.nim              conversions (Gamma, VSWR, RL, dB<->linear)
  |    parse.nim              -- a sibling of ibis/, not a netlist format
  |    reader.nim
  |
  <- netlist/               [shipped] RF annotation keys; four designator
  |    kinds.nim              prefixes (attenuator/balun/coupler/
  |    annotations.nim        transmission_line); no conductivity-list or
  |                           formats/spice.nim change until phase 2/3
  |
  <- pcb/impedance.nim      closed-form Z0 from a stackup   [phase 5]
  |    <- fem/               full-wave port solve            [phase 6]
  |
  <- contract/roles/rf.nim  rf_port, rf_chain, tx_chain, rx_chain  [ph. 1]
  |
  <- spice/                 S-block, microstrip -> mlin,
       models/rf.nim          behavioural PA/LNA/VGA/mixer   [ph. 2/3]
       xspice/
       <- analysis/
            rf_chain.nim         the ordered-path walk (pure graph)  [ph.1]
            cascade.nim          Friis, cascaded IP3, dynamic range  [ph.1]
            analyses/sparam.nim  .sp                                [ph.3]
            analyses/noise.nim   .noise                             [ph.4]
            analyses/intermod.nim two-tone .tran                    [ph.2]
            evaluators/*
```

Two pure modules (`rf_chain.nim`, `cascade.nim`) join `analysis.nim`'s
toolchain-free hub alongside `io_check` and `measure`, so the whole budget
tier works with no simulator in the build — the property `contract/` is
separated for.

**New capabilities.** `capSpiceSp` and `capSpiceNoise` join the closed
`Capability` enum at `contract/evaluate.nim:59`, each needing a `capLabel`
case, an `allCapabilities` entry and CLI `--caps` parsing. Two capabilities,
not one, because a chain can be swept without being noise-analysed and the
report must be able to say which is missing.

**New device kinds still ahead.** `transmission_line`, `microstrip`,
`stripline`, `sparam_block`, plus giving `lna`, `power_amplifier`, `vga`,
`mixer`, `circulator` real behavioural models (their kind strings and,
for `attenuator`/`balun`/`coupler`/`transmission_line`, their designator
prefixes already exist from phase 0). Per §66 each still needs a
`kinds.nim` conductivity/passivity entry where applicable, a
`prefixByDeviceKind` letter and a `pinTemplates` entry when it reaches a
deck as a real SPICE primitive; `tests/test_spice_spellable.nim` will name
a half-done addition, which is the guard rail to lean on.

---

## The vocabulary

### Units (`src/verax/units.nim`) — shipped

`DBm`/`dBm` (`"dBm"`), `DBc`/`dBc` (`"dBc"`), `NoiseDensity`/`VrtHz`/`nVrtHz`
(`"V/rtHz"`) all exist now, alongside the pre-existing `Decibels`/`dB`.

**Hazard already respected**: `unitOf(Fraction) == ""` and `unitsAgree` reads
empty as "not stated, therefore unchecked" (`src/verax/CLAUDE.md`). Every new
quantity below must state a non-empty unit for the same reason.

### Annotations (`src/verax/netlist/annotations.nim`) — shipped

`gain_db`, `nf_db`, `oip3_dbm`, `iip3_dbm`, `p1db_dbm`, `psat_dbm`, `il_db`,
`isolation_db`, `return_loss_db`, `z0`, `sparams` (a file path), and for
lines `er`, `tand`, `trace_width`, `trace_length`, `substrate_h`, `copper_t`,
`roughness`. Antenna: `antenna_gain_dbi`, `antenna_efficiency`. All in
`verax annotations` today.

### Quantities — still to register (phases 1–4)

One producer per quantity, enforced by a raise at registration — so the
budget-derived and simulation-derived answers to the same question **must
carry different names**, the way `psrr_db` and `psrr_min_db` already do. This
is what makes the provenance split structural rather than a convention:

| budget (pure, datasheet-derived) | simulated (measured) |
|---|---|
| `cascade_gain_db`, `cascade_nf_db`, `cascade_oip3_dbm`, `cascade_iip3_dbm`, `cascade_p1db_dbm` | `s21_db`, `gain_at_f_db`, `nf_sim_db` |
| `sensitivity_dbm`, `p_in_max_dbm`, `dynamic_range_db`, `sfdr_db` | `oip3_sim_dbm`, `im3_dbc`, `p1db_sim_dbm` |
| `p_out_dbm`, `papr_headroom_db`, `eirp_dbm` | `s11_db`, `vswr`, `return_loss_db`, `insertion_loss_db`, `isolation_sim_db`, `z_in_ohm`, `group_delay_s` |
| | `vn_out_density`, `vn_out_rms` |

---

## Two disciplines that run through every remaining phase

**Provenance is reported, not implied.** Every budget number names the
annotations it was computed from, as `Assumption` records in
`AnalysisReport.assumptions` — the mechanism `invented()` already counts. A
report shows `cascade_nf_db 2.31 dB [datasheet: U2.nf_db, U4.nf_db]` beside
`nf_sim_db 0.42 dB [.noise; assumption: U2 is behavioural and contributes no
noise]`, and the reader is never left guessing which one is a measurement.

**Graceful degradation by available data**, generalising the rule chosen for
the antenna boundary. Each quantity is produced only when its inputs are
stated and returns `NaN` otherwise, which `verdict` already reads as
*notEvaluated* rather than *fail*. So: state antenna gain and efficiency and
get `eirp_dbm`; state a path loss too and get link margin; state neither and
the chain still reports conducted power at the port. Nothing is invented to
fill a gap — the same rule `regulatorModel` follows when it declines rather
than guessing an output voltage.

---

## Phase 1 — The cascade budget

The spine, and pure: `analysis/rf_chain.nim` walks the ordered path (inferred
from a source port to a sink port through two-port components, with an
explicit stage order on the role as the override — the `SimReplacement`
shape); `analysis/cascade.nim` does Friis, cascaded IP3 and the dynamic-range
arithmetic; `contract/roles/rf.nim` adds `rf_chain`, `tx_chain` and `rx_chain`
with the converter numbers as parameters (`sourceDbm`, `maxInputDbm`,
`requiredSnrDb`, `bandwidthHz`, `paprDb`).

**Proved on `designs/rf_frontend.nim`**, which grows a real Rx chain
(antenna → T/R switch → LNA → VGA) and a Tx chain, and gets the first RF
claims in the repo — with no simulator involved at all.

## Phase 2 — Behavioural active blocks, and measured linearity

XSPICE code models for `power_amplifier`, `lna`, `vga` and `mixer` in
`spice/xspice/`, each with a **smooth** saturating transfer (tanh or logistic
— a hard limit has zero derivative at the limit and infinite derivative at the
corner, the convergence trap `switch.nim` and `opampModel` both document) and
`acGain` set so `.ac` and `.sp` see them. Registered through
`spice/models/behavioral.nim`, so they take precedence over per-pin impedances
and the three stages stop being deleted.

Then `analysis/analyses/intermod.nim`: a two-tone `.tran` measured by
`measure.harmonicAmplitudes`, which already integrates against cos/sin at
arbitrary frequencies over whole periods and therefore has no FFT leakage to
fight. Pointing it at 2f₁−f₂ and 2f₂−f₁ gives IM3, hence a **measured**
`oip3_sim_dbm` to set against the budget's `cascade_oip3_dbm`.

This phase also closes the standing hole `spice/xspice/CLAUDE.md:24` records —
no Nim-authored model has yet set `acGain` and had the result read back.

## Phase 3 — `.sp`, ports, and transmission lines

`capSpiceSp`; `analysis/analyses/sparam.nim` + its evaluator; an `rf_port`
role binding a net and a reference impedance; `formats/spice.nim` rendering
`portnum`/`z0`; `spice/models/rf.nim` expanding `microstrip` to `mlin` and
`transmission_line` to `tline`; and the `.s2p` block as an XSPICE model that
interpolates the table and sets `acGain` per port pair — exact at the sample
points, no fitting, no passivity problem, and confirmed above to reach the
`.sp` matrix. It declines a `.tran` rather than inventing a time-domain path;
where a `.tran` through a vendor block is genuinely needed, the behavioural
model of the same part is what runs.

`touchstone/attach.nim` (binding an `.s2p` to a `Component`, deferred in
phase 0) is built here, since this is where its first consumer exists —
`ibis/attach.nim` is the shape to copy.

**`designs/xbar_rf.nim` is the second proof design** and the payoff is
concrete: return loss, VSWR, insertion loss, isolation-vs-frequency and the
two-stage cascade loss all become claims, deleting the largest entry on
`xbar_switch.nim`'s cannot-check list.

## Phase 4 — `.noise` and simulated noise figure

`capSpiceNoise`; `analysis/analyses/noise.nim` producing `vn_out_density`,
`vn_out_rms` and `nf_sim_db` against a stated source resistance. Closes §54,
which `designs/riaa_preamp.nim` wants independently — a phono preamp is
*specified* on input-referred noise and the library cannot express the claim.

Two known traps to settle here rather than discover: ngspice writes **two**
plots for a noise run and only one is the spectral density (§54 already flags
it); and whether a per-resistor `temp` or `noisy` parameter can carry a
stage's datasheet NF into the deck as an equivalent noise element is
**unverified** — earlier attempts to confirm it were inconclusive and it
should be settled empirically before being designed around. If it works, a
datasheet-stated NF becomes a real contributor to a simulated cascade; if not,
`nf_sim_db` stays honestly limited to the parts that have noise models and the
budget's `cascade_nf_db` remains the headline.

## Phase 5 — Board-derived characteristic impedance

`pcb/impedance.nim`: closed-form Hammerstad-Jensen / IPC-2141 microstrip and
stripline from a `Stackup`, making `z0` a *checkable* quantity ("this trace is
50 Ω ±10%") and not merely an input to a solve. Gated on a `Pcb` reader
existing — none does — and on the stackup being populated, which
`pcb/types.nim:115-118` warns is routinely not the case on real KiCad boards.

Until then a microstrip's substrate numbers are authored on the component,
which is what makes phase 3 independent of this one. Also the natural place
to revisit phase 0's deferred geometry-unit decision (`trace_width` etc. are
registered with unit `""`, documented in prose as metres) if this phase ends
up wanting typed length arithmetic.

## Phase 6 — FEM full-wave, sequenced

`fem/` already has the intended shape written: `pkFullWave`, `bcPec`,
`bcPort`, `Excitation.impedance`, `FemProblem.frequencies` and
`FemResult.scalars["z0"]`. It is blocked on a chain it names itself, in order:

**Pcb reader → `Zone.fills` (a plane cannot be meshed without them) → a
mesher → the MFEM backend → the full-wave port solve.**

The interface obligation this plan carries for it is small and worth honouring
now: `z0` and an S-matrix must be able to arrive from any of three
provenances — authored, closed-form, `mlin`, or field-solved — through the
same quantity names, so the solver drops in as a fourth without a vocabulary
change.

## Later, deliberately not scheduled

Synthesis of matching networks, pads and bias tees (checking first, in the
`filters.sallenKeyLP(fc, r, q)` spirit, once the quantities exist to verify
against); `dac` / `adc` spec-block components; a spectral emission mask, which
needs a limit-vs-frequency `Expectation` shape that no variant covers today;
vector-fitting a `.s2p` to an equivalent circuit for `.tran`.

---

## Critical files for phases 1–6

Modified (beyond phase 0's `units.nim`/`eng.nim`/`kinds.nim`/
`annotations.nim`): `src/verax/netlist/formats/spice.nim` (phase 3 — `portnum`/
`z0` rendering, `mlin`/`tline` device letters), `src/verax/contract/evaluate.nim`
(the `Capability` enum, `capLabel`, `allCapabilities` — phases 3/4),
`src/verax/cli.nim` (`--caps` — phases 3/4),
`src/verax/analysis/evaluators/contract_eval.nim` (registration, every
phase), `src/verax/spice/models/pin_models.nim` and `behavioral.nim`
(phase 2), `designs/rf_frontend.nim`, `designs/xbar_rf.nim`,
`designs/xbar_switch.nim` (its cannot-check list is a deliverable and
shrinks each phase).

New: `analysis/rf_chain.nim`, `analysis/cascade.nim` (phase 1),
`analysis/analyses/{sparam,noise,intermod}.nim` with evaluators alongside
(phases 2–4), `contract/roles/rf.nim` (phase 1), `spice/models/rf.nim`
(phase 2/3), XSPICE models under `spice/xspice/` (phase 2), `pcb/impedance.nim`
(phase 5), `touchstone/attach.nim` (phase 3).

Reused rather than rebuilt: `measure.harmonicAmplitudes` (two-tone IM3),
`spice/backend.SimVector`'s complex path and `cplx`/`mag`/`db`/`phaseDeg`
(`.sp` results are `.ac`-shaped), `probes.addImpedanceProbe` (port
impedance without `.sp`), `opamp.checkInjectionPoint` and `detachDrivers`,
`evaluators/common.{harvest,failBatch,subjectNet,groundNetOf}`,
`transform.selectSimModel` and `SimReplacement` (the behavioural/S-block
precedence), `spice/isolate` and `flattenForSim`; and, from phase 0,
`touchstone.SParams`/`gammaOf`/`vswrOf`/`returnLossDb`/`insertionLossDb`/
`powerRatioToDb`/`voltageRatioToDb`/`dbmToWatts`/`wattsToDbm`.

---

## Verification, per phase, in this order

1. **`nim check --path:./src src/verax/<module>.nim`** on each touched module.
2. **`nimble test 2>&1 | grep -cE "FAILED|Error:"` returns 0** — never the
   exit code, which is 0 either way. New tests follow the existing shape: one
   `tests/test_analysis_<name>.nim` per analysis, plus
   `tests/test_contract_eval_spice.nim` for the adapter.
   `tests/test_spice_spellable.nim` is the guard that catches a half-added
   device kind and should be watched deliberately in phase 3.
3. **Closed-form cross-checks**, which is what makes an RF number trustworthy:
   a 25 Ω series element between 50 Ω ports must return S11 −13.979 dB and
   S21 −1.938 dB (already verified against real ngspice, and pinned in
   `tests/test_touchstone_types.nim`); a quarter-wave 70.7 Ω line must
   transform 100 Ω to 50 Ω at its centre frequency; a matched attenuator's
   `nf_db` must equal its loss; Friis over a single stage must return that
   stage's NF.
4. **`nimble verify`** — every design and template still checks, and the two
   proof designs make their new claims. Exit codes are graded, so a `3`
   (claim nothing could check) is the specific failure to watch for: it means
   a quantity was registered but no role reaches it.
5. **`VERAX_KEEP_RUNS=<dir> ./bin/verax check designs/rf_frontend.nim`** and
   read the deck. For a new analysis family this is not optional — the
   fragments are derived, and it is the only way to confirm that the S-block
   or the microstrip that produced a number is the circuit intended.
6. **`verax quantities` and `verax roles`** — every new quantity must report
   as reachable by a role. One reporting "needs a role binding" with no role
   naming it is the §46 `tolerance` smell: registered and consumed by nothing.
