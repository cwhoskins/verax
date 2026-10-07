## Electrical classification of `Component.kind` strings and a `Net`'s
## power/ground role. Its own module because `analysis/io_check` and
## `spice/isolate` must agree, and `analysis` depends on `spice`. Policy-free:
## what a part *is*, never what to do about it.

import std/[strutils, tables]
import ./types
import ./traversal

export traversal

type
  Conductivity* = enum
    condConductive, condBlocking, condAmbiguous

const
  conductiveKinds* = ["resistor", "inductor", "voltage_source", "wire", "jumper",
                      "ferrite_bead", "fuse"]
    ## Ideal DC-conductive two-terminal parts (by topology, never value; an
    ## ideal voltage source ties its terminals).
  blockingKinds* = ["capacitor", "current_source"]
    ## Keyed on `Component.kind`, not `Pin.kind` (which can't tell a
    ## resistor from a capacitor). A current source's infinite impedance
    ## blocks.

proc classifyConductivity*(c: Component): Conductivity =
  ## Not meaningful for an instance (hierarchy is walked via `hierNet`).
  ## Any unlisted kind is `condAmbiguous`, never guessed.
  if c.kind in blockingKinds: condBlocking
  elif c.kind in conductiveKinds: condConductive
  else: condAmbiguous

proc conductivityBetween*(c: Component, a, b: Pin): Conductivity =
  ## Conductivity *per pin pair*, for N-pin parts with a `traversal` spec
  ## (an RF switch conducts RFC to the selected RFn only).
  ## `classifyConductivity` is not widened, since `isPassive` and
  ## `placement.portDrives` rely on its whole-component answer.
  ##
  ## Ladder:
  ##   1. A stated spec answers exclusively: `tmNone` -> blocking; `tmAll` ->
  ##      `classifyConductivity`; a declared edge -> its `conducts`; an
  ##      undeclared pair -> blocking (a declaration is exhaustive).
  ##   2. No spec, two connected pins -> `classifyConductivity`.
  ##   3. No spec, more than two -> `condAmbiguous`.
  if statesTraversal(c):
    let spec = traversal(c)
    case spec.mode
    of tmNone: return condBlocking
    of tmAll: return classifyConductivity(c)
    of tmDefault: discard
    for e in spec.edges:
      if (e.a == a.name and e.b == b.name) or (e.a == b.name and e.b == a.name):
        return (if e.conducts: condConductive else: condBlocking)
    return condBlocking
  var connected = 0
  for _, p in c.pins:
    if p.net != nil: inc connected
  if connected == 2: classifyConductivity(c) else: condAmbiguous

proc conductiveExits*(c: Component, fromPin: Pin): seq[Net] =
  ## Every net conduction reaches from `fromPin` through `c` (per
  ## `conductivityBetween`). The DC walkers' entry point: one exit for a
  ## plain two-terminal part, only the declared nets for a switch.
  for _, p in c.pins:
    if p == fromPin or p.net == nil or p.net == fromPin.net: continue
    if conductivityBetween(c, fromPin, p) == condConductive and
       p.net notin result:
      result.add p.net

const
  couplingKinds* = ["mutual_inductance"]
    ## The SPICE `K` card: a relationship between two inductors, not a
    ## device (synthesized by `spice/models/magnetics`). `isPassive` accepts
    ## it so isolation keeps the coupling when both inductors are present;
    ## it stays `condAmbiguous` so DC walks don't cross a transformer's
    ## isolation barrier.

  behaviouralKinds* = ["vcvs", "vccs", "cccs", "ccvs", "bsource"]
    ## Controlled sources, only ever synthesized by `spice/models`. Not
    ## conductive (the output is a source, not a connection), but fully
    ## described by their gain, so `isPassive` lets isolation absorb them.

const builtinDesignatorPrefixes* = {
    "resistor": "R", "capacitor": "C", "inductor": "L", "ferrite_bead": "FB",
    "diode": "D", "led": "D", "zener": "D", "bjt": "Q", "mosfet": "Q",
    "jfet": "Q", "transistor": "Q", "voltage_source": "V", "battery": "BT",
    "current_source": "I", "fuse": "F", "crystal": "Y", "oscillator": "Y",
    "switch": "SW", "relay": "K", "connector": "J", "jumper": "JP",
    "analog_switch": "U", "rf_switch": "U", "mux": "U", "load_switch": "U",
    "vswitch": "S", "iswitch": "W", "mutual_inductance": "K",
    "common_mode_choke": "FL", "coupled_inductor": "T",
    "transformer": "T", "test_point": "TP", "antenna": "E", "speaker": "LS",
    "potentiometer": "RV", "thermistor": "RT", "varistor": "RV",
    "opamp": "U", "op_amp": "U", "operational_amplifier": "U", "comparator": "U",
    "mcu": "U", "ic": "U", "regulator": "U", "ldo": "U", "vreg": "U",
    "dcdc": "U", "smps": "U", "buck": "U", "boost": "U", "switcher": "U",
    "buffer": "U", "voltage_follower": "U", "unity_gain_buffer": "U",
    "line_driver": "U", "level_shifter": "U", "sensor": "U",
    "code_model": "A", "subcircuit": "X",
    "attenuator": "AT", "balun": "T", "coupler": "DC",
    "transmission_line": "TL"}
    ## Cosmetic prefixes. `balun` sharing `"T"` is intentional. RF amplifier,
    ## mixer and transmission-line kinds fall back to `"U"` until they have a
    ## model.
  ## Reference-designator prefixes by kind. **Must stay separate from
  ## `formats/spice.prefixByDeviceKind`**: a ferrite is `FB` on a schematic
  ## but `L` in a deck. `U` is the fallback; a wrong prefix is only
  ## cosmetic. Projects can `registerDesignatorPrefix`.

var designatorPrefixes = block:
  var t: Table[string, string]
  for (k, v) in builtinDesignatorPrefixes: t[k] = v
  t

proc registerDesignatorPrefix*(kind, prefix: string) =
  ## Runtime, so a project's own kinds are first-class.
  designatorPrefixes[kind] = prefix

proc designatorPrefixFor*(kind: string): string =
  ## The conventional prefix for `kind`, or `"U"` when nothing is registered.
  designatorPrefixes.getOrDefault(kind.toLowerAscii, "U")

proc hasDeviceModel*(c: Component): bool =
  ## Whether a `.MODEL` card in the owning netlist names this part's `value`
  ## (SPICE binds models by name). A modelled part must never be stood in
  ## for. Case-insensitive, as SPICE is.
  if c == nil or c.netlist == nil: return false
  if not c.attrs.hasKey("value"): return false
  let toks = c.attrs["value"].split()
  if toks.len == 0: return false
  let want = toks[^1].toLowerAscii
  for name, _ in c.netlist.models:
    if name.toLowerAscii == want: return true
  false

proc isPassive*(c: Component): bool =
  ## Whether a fragment can absorb this part without a model, because its
  ## value fully describes it: ideal two-terminal parts and synthesized
  ## controlled sources.
  classifyConductivity(c) != condAmbiguous or c.kind in behaviouralKinds or
    c.kind in couplingKinds or hasDeviceModel(c)

proc isRail*(net: Net): bool =
  ## Whether `net` is a power or ground rail by *either* the net's `kind` or
  ## any pin's `kind`; sources set them inconsistently, so requiring both
  ## would find no rails.
  if net == nil: return false
  if net.kind in {ntPower, ntGround}: return true
  for p in net.pins:
    if p.kind in {ptPower, ptGround}: return true
  false

proc isGround*(net: Net): bool =
  ## Ground specifically, by net kind, pin kind, or the SPICE reserved name.
  if net == nil: return false
  if net.kind == ntGround or net.name == "0": return true
  for p in net.pins:
    if p.kind == ptGround: return true
  false
