# Verax

**Warning** This repo is under heavy design and should not be used under the belief that anything is stable or fully fleshed out.

Verax lets you describe a circuit, state what it must do, and check that by simulation. It is an embedded DSL in a Nim library: a design is a `.nim` file that declares nets, parts and subcircuits alongside the claims they must meet, and `verax check` proves or disproves each claim with graph walks, ngspice runs or a native signal-integrity engine.

The language is highly parameterizable and hierarchical in nature. Designs should be composed of subcircuits which have factory methods for design decisions and connected via standard interfaces and buses whenever possible.

## Example

```nim
import verax/contract/dsl
import verax/verify

let d = design("divider"):
  net gnd, kind = ntGround, name = "0"
  net vin, kind = ntPower:
    spec:
      voltage = 12.0.V
  net mid, kind = ntSignal

  component V1, kind = "voltage_source", value = "DC 12":
    pin "+", vin, kind = ptPower
    pin "-", gnd, kind = ptGround
  component R1, kind = "resistor", value = "30k":
    pin "1", vin, kind = ptPassive
    pin "2", mid, kind = ptPassive
  component R2, kind = "resistor", value = "10k":
    pin "1", mid, kind = ptPassive
    pin "2", gnd, kind = ptPassive

  role "power_rail", supply, rail = vin, voltage = 12.0.V, band = 5.pct
  require dc_voltage(mid) == 3.0.V, band = 1.pct, id = "REQ-DIV-TAP-001",
          because = "two 1% resistors give 1% worst case"

quit(verifyMain(d))
```

```
$ verax check templates/divider.nim
  spice.dc_voltage  [.op]  --  2 claim(s): 2 met
    [PASS]  REQ-DIV-TAP-001   dc_voltage(net 'mid')
             expect 3.00 V +-1.00% (2.97 V .. 3.03 V)   measured 3.00 V
    [PASS]  supply.voltage   dc_voltage(net 'vin')
             expect 12.0 V +-5.00% (11.4 V .. 12.6 V)   measured 12.0 V

checked 2 assertion(s): 2 passed, 0 failed, 0 not evaluated, 0 not evaluable
```

The full, commented version is `templates/divider.nim`.

## Features
- **Design contracts**: `role` bundles and `require` claims state what a circuit must do; each claim carries its tolerance band, an ID and a `because`. Static checks run without a simulator (`--offline`), and `--strict` fails on anything left unchecked
- Pin muxing built into parts and pin decisions automatically validated against the pin muxing table
- Standard interfaces automatically infer schematic analysis and auto-generated SPICE simulations
- **SPICE simulation** through ngspice (`.op`, `.dc`, `.ac`, `.tran`), with simulation-only device models and XSPICE code models (analog and digital) authored from Nim
- **Native signal-integrity engine** (no ngspice): IBIS drivers and receivers, packages, transmission lines and vias, crosstalk, differential pairs, PRBS/eye analysis and S-parameter channels
- IBIS sweeps pre-layout derive routing constraints, written out as KiCad `.kicad_dru` rules (`verax constraints`); `si_net` claims are then checked against the routed board (`--board=`)
- **Test reports**: `verax report` writes one self-contained HTML (or PDF) file with each test's circuit under test, setup, pass criteria, simulated circuit and bench, plots, verdicts and logs
- **Bill of materials**: `verax bom` resolves each part against catalogues and writes text, CSV or JSON; the JSON doubles as a lock file so part choices stay the same between builds
- **KiCad**: `verax layout` generates a starting `.kicad_pcb` with real footprints, and `.kicad_pcb` files round-trip byte-exact
- Parameterizable subcircuits with arbitrary factory methods so a part's recommended circuit can be implemented with desired settings
- Automatic topology view: a heuristic, deterministic schematic drawing (SVG/JSON) of each design — a readable picture, not a hand-laid-out sheet
- Ability for user to define roles, tests and analyses
- **Templates and discovery**: `verax new` writes a starter design; `verax roles`, `role <name>`, `quantities`, `annotations`, `interfaces` and `guide` list what a design can claim, straight from the live registries

## Requirements

- **Nim ≥ 2.2.10**. There are no dependencies beyond the Nim standard library.
- **Optional**, for the features that need them:
  - `ngspice` on `PATH`: SPICE simulation (without it, `--offline` checks still run)
  - `$NGSPICE_SRC` pointing at a configured ngspice source tree: building XSPICE code models
  - headless chromium, weasyprint or wkhtmltopdf on `PATH`: PDF reports (otherwise the HTML is kept)
  - KiCad footprint libraries (`$VERAX_FOOTPRINT_PATH`, or `/usr/share/kicad/footprints`): `verax layout`

`verax env` reports which of these it found.

## Install

```sh
git clone <this repo> verax && cd verax
nimble build          # builds ./bin/verax
```

## Quickstart

```sh
verax new rail foo.nim        # starter design (also: blank, i2c, divider, ...)
verax check foo.nim           # check every claim
verax check foo.nim --offline # graph walks only, no simulator
verax report foo.nim -o foo_report.html
verax guide                   # the authoring guide
```

## Where to look next

- `designs/` — example designs; `designs/datalogger/` is the largest, a full board split across sheets
- `templates/` — small commented starters, one idea each (what `verax new` writes)
- `docs/authoring.md` — writing a design
- `docs/architecture.md` — how the submodules relate
- `docs/findings.md` — what is open

## License

MIT — see `LICENSE`.
