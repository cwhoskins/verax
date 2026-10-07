# `spice/xspice` submodule

Authors **XSPICE code models** — behavioural devices compiled to a `.cm` that ngspice `dlopen`s as an `A` device. The hub exports only toolchain-free pieces (`spec`, `ifs`, `instance`); `mif`, `accessors`, `dsl`, `build` are opt-in.

**Prerequisite:** a `.cm` needs a **configured ngspice source tree** at `$NGSPICE_SRC` (`./configure --enable-xspice --enable-cider`); distro `-devel` packages lack `cmpp`, `dlmain.c`, `dstring.c` and the MIF headers. `findToolchain` also checks a configured tree under the cache dir.

**Why a DSL:** `cmpp -mod` is a lex/yacc translator, not a C preprocessor — `PARAM(x)` etc. aren't C macros. One `codeModel` block emits both `ifspec.ifs` and the C, so accessors resolve against the real ports (a misspelled port is a compile error). Generated accessor C is byte-identical to cmpp's.

- **`spec.nim`** — `ModelSpec` etc. **Declaration order in the `seq`s *is* the `conn[i]`/`param[i]` index** — the central invariant. Enum prefixes `xp*`/`xd*`/`xt*` avoid `netlist`'s `pt*`.
- **`ifs.nim`** — one row per repeated table block. An empty `Description:` is *omitted* (cmpp rejects `""`).
- **`mif.nim` / `private/mifshim.h`** — FFI. Every struct is `{.importc, header.}` (never hand-declare offsets); C enum values go through an `{.emit.}` TYPESECTION. `Mif_Value_t` has no digital member — digital ports use `pvalue` as `Digital_t*`.
- **`accessors.nim`** — `template`s returning `untyped` (so `output(o) = x` is an assignment). `PARTIAL(o,i)`/`AC_GAIN(o,i)`: both indices are *connection* indices; direction check accepts the required direction or `inout`. Field selection uses `Allowed_Types[0]` (as cmpp does).
  - **Analog state**: `analogAlloc`/`analogVar`/`analogIntegrate`/`setPermBkpt`/`setTempBkpt`. These buffers are **rolled back on a rejected timestep**; `stateVar` (STATIC_VAR) is not — right for a latched enable, wrong for a cycle's turn-off time. Use `analogIntegrate` (simulator's method), not `x * tstep` (forward Euler). **`setPermBkpt` is mandatory for anything with edges** or the solver steps over them. Example: `examples/xspice_integrator.nim`.
- **`dsl.nim`** — `codeModel` macro. Unknown names are hard compile errors (no `attrs` bag here). Under `-d:xspiceGenIfs` it emits an `.ifs` writer with no FFI. `default =` implies `nullAllowed`. Assignments to `outputState`/`outputStrength`/`outputChanged` are rewritten into setter calls.
- **`build.nim`** — `buildCodeModel(source, outPath)`: genIfs → `cmpp -ifs` → `cmpp -lst` → compile `ifspec.c`/`dlmain.c`/`dstring.c` → `nim c --app:lib`. **`dstring.c` must be linked** (`ds_free` isn't exported by ngspice). **The tree's configure flags must match the installed ngspice** — `#ifdef CIDER`/`KLU` members inside `SPICEdev` shift slots and ngspice segfaults silently. `checkAbi` warns where it can (CIDER isn't reported by `ngspice -v`). Nothing links `libngspice`.
- **`cmpath.nim`** — ngspice **case-folds** `pre_codemodel`'s argument, so a `.cm` path with uppercase can't load (quoting doesn't help). `deckSafeCmPath` returns a lowercase symlink.
- **`instance.nim`** — `addCodeModelInstance(nl, designator, spec, bindings, params, cmPath)`. An `A` line is **not positional**: differential ports take two nodes, vectors are `[a b c]` with no nesting, `null` is allowed for a whole connection but **not inside a bracket**. `PortBinding` (`wire(n)`, `wire(p, n)`, `wire([...])`, `nullPort()`) says which nets; `checkBinding` rejects bad counts, partial differentials, out-of-range vectors and `vnam` ports. **Pins stay real** (`name[0]`, `name.p`). Port text goes to `attrs["xspice.ports"]`; `cmPath` to `attrs["xspice.cm"]`, gathered by `collectCodeModels` (attrs survive clone→flatten→expandPinModels→isolate). **String params are quoted** by `paramText` (an unquoted letter-initial token aborts ngspice; a digit-initial one silently works).
- **Deck emission** — `formats/spice.formatDeviceLine` writes `xspice.ports` verbatim. `'A'` is write-side only; an `A` line can't be read back into ports without the `.ifs`.
- **`-d:xspiceSpecOnly`** emits the `ModelSpec` without the FFI entry point, so importing a model to instantiate it doesn't require the source tree. `verax check` passes it.

## Digital / event-driven models

Called on input events; read `inputState`, schedule with `outputState` + `outputDelay`; `load(port)` declared under `init`. Example: `examples/xspice_dff.nim`, `designs/i2c_eeprom.nim`.

- **Set `outputChanged(port) = false` when nothing changed**, or every input event emits a redundant event (looks like a hang under heavy traffic).
- Previous-timepoint and bulk per-instance state go in **`eventAlloc`/`eventVar`** (rotated and rolled back by ngspice), never a Nim global (shared across instances) or `stateVar`.
- `validate` rejects mixing digital and analog allowed types on one port.
- A bidirectional open-drain line is a single `xdInout` port (`dsZero`/`dgStrong` to pull, `dgHiImpedance` to release).
- **`bidi_bridge` digital levels are three-valued** (`dsUnknown` between thresholds) — hold the previous level through unknown (Schmitt behaviour). For hysteresis, **`in_high < in_low`** selects the hysteresis branch and `in_low` becomes the *rising* threshold; ordered the other way it silently goes back to three-valued.
- Clock event controllers from stock `d_osc` (a DC control node costs the analog solver nothing).
- Not yet exercised: user-defined node types, `cm_event_queue` self-scheduling, `.ac` readback from a model setting `AC_GAIN`.
