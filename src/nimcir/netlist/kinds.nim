## Electrical classification of the open-ended strings in `Component.kind`
## and of a `Net`'s power/ground role.
##
## This is deliberately its own module rather than living in whichever
## consumer needed it first. Two independent subsystems ask the same
## questions -- `nimcir/analysis/io_check` walks DC paths, and
## `nimcir/spice/isolate` decides what to absorb into a simulation fragment
## and where to stop -- and they must agree, or a net that terminates one
## walk would be traversed by the other. `analysis` already depends on
## `spice`, so the shared answer cannot live in either of them without
## inverting that.
##
## It stays free of policy: it says what a component *is* electrically and
## whether a net *is* a rail, never what to do about it.

import std/[strutils, tables]
import ./types

type
  Conductivity* = enum
    condConductive, condBlocking, condAmbiguous

const
  conductiveKinds* = ["resistor", "inductor", "voltage_source", "wire", "jumper",
                      "ferrite_bead", "fuse"]
    ## Ideal DC-conductive two-terminal parts. An ideal voltage source's
    ## near-zero internal impedance ties its terminals for path-*existence*
    ## purposes -- this classification never asks about value, only about
    ## topology.
  blockingKinds* = ["capacitor", "current_source"]
    ## `capacitor` blocks DC despite being `ptPassive`-pinned, same as a
    ## resistor conducts -- which is exactly why classification is keyed on
    ## `Component.kind` (what the device physically *is*), not `Pin.kind`
    ## (which cannot distinguish a resistor from a capacitor). An ideal
    ## current source has infinite internal impedance, the opposite of a
    ## voltage source, so it is blocking too.

proc classifyConductivity*(c: Component): Conductivity =
  ## Never meaningful for a component with `subNetlist != nil` -- hierarchy is
  ## walked structurally via `Pin.hierNet`/`Netlist.instanceOf`, not by kind
  ## lookup. Any `kind` not in the built-in tables (a diode, transistor, IC,
  ## or custom part) is `condAmbiguous`, never silently guessed as either
  ## conductive or blocking.
  if c.kind in blockingKinds: condBlocking
  elif c.kind in conductiveKinds: condConductive
  else: condAmbiguous

const
  couplingKinds* = ["mutual_inductance"]
    ## The SPICE `K` card -- a *relationship* between two inductors, not a
    ## device with terminals. Synthesized only: `spice/models/magnetics`
    ## emits one per winding pair when it expands a `transformer` or a
    ## `common_mode_choke`.
    ##
    ## `isPassive` accepts it so `spice/isolate` pulls it into a fragment
    ## whenever both the inductors it couples are already there -- otherwise
    ## the coupling is silently dropped and the fragment is a different
    ## circuit. `classifyConductivity` still calls it `condAmbiguous`, and
    ## deliberately: a `K` card has no nodes to walk *through*, which for a
    ## transformer is precisely the isolation barrier `analysis/io_check`
    ## must not cross.

  behaviouralKinds* = ["vcvs", "vccs", "cccs", "ccvs", "bsource"]
    ## Controlled sources. Never real parts -- these only ever appear because
    ## something in `spice/models` synthesized one to stand in for a part that
    ## carries no model.
    ##
    ## Deliberately **not** in `conductiveKinds`: a controlled source is not a
    ## DC path in the conduction sense (its output *is* a source, not a
    ## connection to its input), so `classifyConductivity` keeps calling one
    ## ambiguous and `analysis/io_check` keeps refusing to walk through it.
    ## But its behaviour genuinely *is* fully described by its value -- the
    ## gain -- so a simulation fragment can absorb one, which is what
    ## `isPassive` is actually asked.

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
    "code_model": "A", "subcircuit": "X"}
  ## Reference-designator prefixes by component kind.
  ##
  ## **Deliberately a separate table from `formats/spice.prefixByDeviceKind`,
  ## and it must stay separate**, because the two genuinely disagree. A
  ## ferrite bead's designator on a schematic is `FB` while the letter it
  ## needs in a deck is `L`; a battery is `BT` on a board and `V` in a deck.
  ## They answer different questions -- one is a naming convention for people,
  ## the other is how SPICE decides what device it is reading -- and deriving
  ## either from the other is how `FB1` came to be simulated as a
  ## current-controlled current source in the first place.
  ##
  ## `U` is the fallback for anything unrecognised, which is the schematic
  ## convention for an integrated circuit. Unlike a SPICE device letter, a
  ## wrong designator prefix is cosmetic rather than a wrong answer, so
  ## guessing here is cheap where guessing there was not -- and
  ## `registerDesignatorPrefix` exists for a project with its own kinds.

var designatorPrefixes = block:
  var t: Table[string, string]
  for (k, v) in builtinDesignatorPrefixes: t[k] = v
  t

proc registerDesignatorPrefix*(kind, prefix: string) =
  ## Runtime, like every other registry here, so a project's own kinds are
  ## not second class.
  designatorPrefixes[kind] = prefix

proc designatorPrefixFor*(kind: string): string =
  ## The conventional prefix for `kind`, or `"U"` when nothing is registered.
  designatorPrefixes.getOrDefault(kind.toLowerAscii, "U")

proc hasDeviceModel*(c: Component): bool =
  ## Whether a `.MODEL` card in the owning netlist describes this part.
  ##
  ## SPICE binds a device to a model by name: the model name is the last
  ## token of the device line, which is what `Component.attrs["value"]`
  ## becomes. So a diode whose `value` is `"1N4148"` is fully modelled if and
  ## only if the netlist carries a `1N4148` card, and a part that *is*
  ## modelled must never be stood in for -- the stand-in exists precisely
  ## because nothing described the part.
  ##
  ## Matched case-insensitively, because SPICE is: a deck that says `1n4148`
  ## against a card that says `1N4148` binds in the simulator, and a check
  ## that disagreed with the simulator about the same part is the failure
  ## this whole area keeps producing.
  if c == nil or c.netlist == nil: return false
  if not c.attrs.hasKey("value"): return false
  let toks = c.attrs["value"].split()
  if toks.len == 0: return false
  let want = toks[^1].toLowerAscii
  for name, _ in c.netlist.models:
    if name.toLowerAscii == want: return true
  false

proc isPassive*(c: Component): bool =
  ## Whether a simulation fragment can absorb this part wholesale without
  ## needing a model for it -- because its behaviour is fully described by its
  ## value. True of an ideal two-terminal part, and of a synthesized
  ## controlled source, which would otherwise be discarded by the very
  ## isolation that was meant to keep the path it stands in for.
  classifyConductivity(c) != condAmbiguous or c.kind in behaviouralKinds or
    c.kind in couplingKinds or hasDeviceModel(c)

proc isRail*(net: Net): bool =
  ## Whether `net` is a power or ground rail, by *either* signal: the net's
  ## own `kind`, or any connected pin's `kind`.
  ##
  ## The two are populated inconsistently depending on where the netlist came
  ## from -- a netlist read from a SPICE deck only sets `ntGround` for node
  ## "0" and never touches `Pin.kind`, while a DSL author might tag a pin
  ## `ptPower` without tagging the net, or the reverse. Requiring both would
  ## make every realistic partially-annotated netlist look railless.
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
