## Wiring the I2C EEPROM example up: the stock ngspice models it leans on, the
## two ways of building the bus, and the attachment procs that put the Nim
## code models behind the real parts.
##
## The division of labour here is the same one `designs/lib/lt8640a.nim`
## draws. A design file declares the **real parts** -- an MCU and an EEPROM,
## with the pin names that are on the datasheet -- and this module hangs a
## simulation-only stand-in beside each of them through
## `Component.simReplace`. Nothing a BoM, a layout or `explain` reads changes;
## only the netlist that reaches ngspice does.
##
## ### Two buses, one pair of models
##
## Both device models drive SDA and SCL as **digital open-drain** pins:
## `dgHiImpedance` to release, `dsZero`/`dgStrong` to pull down. What supplies
## the `1` when everybody has released is the only thing that differs between
## the two buses, and neither model can tell which it is talking to.
##
## * `digitalBus` puts a `d_pullup` on each line. There is no analog anywhere,
##   ngspice takes enormous timesteps between events, and a whole transaction
##   simulates in well under a second. That makes it the right bus to develop
##   and regression-test a *protocol* on, which is what
##   `tests/test_xspice_i2c_eeprom.nim` uses it for.
## * `ensureAnalogBridge` puts a `bidi_bridge` between the real analog net --
##   with the pull-up resistor and the bus capacitance the design actually
##   declares -- and a digital net the models sit on. Now a released line rises
##   on an RC rather than instantly, a pulled-down line sits at a real VOL, and
##   the `i2c` role's `pullup_count`, `rc_corner` and `pullup_sink_current`
##   have resistors to find. It costs an analog solve per edge.
##
## The bridge is created **idempotently** because a `SimReplacement.build`
## runs once per component and both devices need the same bridge on the same
## line; whichever model is materialised first creates it and the second finds
## it.
##
## ### Where the clock comes from
##
## `dummy_mcu` needs a bit clock, and this repo has never exercised
## `cm_event_queue` self-scheduling. So `buildDummyMcu` also drops in ngspice's
## stock `d_osc` and a DC control node for it. That is deliberately part of the
## *model* and not of the board: a real microcontroller's bit clock is
## internal, so putting a clock pin on the part would be describing the
## simulation rather than the circuit.
##
## Likewise `done` and `pass` leave the model as digital and reach the design's
## real nets through a `dac_bridge`. Digital nodes are invisible to the rawfile
## reader -- only analog nets come back as vectors -- so this is what lets a
## claim be made about the outcome at all.

import std/[os, tables, times]

import nimcir/contract/dsl
import nimcir/contract/roles/core
import nimcir/netlist/graph
import nimcir/netlist/annotations
import nimcir/spice/xspice/spec
import nimcir/spice/xspice/instance
import nimcir/spice/xspice/build

import ./m24c64
import ./dummy_mcu

export m24c64, dummy_mcu

# --- the stock ngspice models -----------------------------------------------
#
# Described by hand, exactly as `tests/test_xspice_digital.nim` describes
# `adc_bridge` and `dac_bridge`: nimcir needs a `ModelSpec` only to render and
# check the `A` line, while the models themselves live in ngspice's own
# `digital.cm`, which `spinit` loads on every run. That is why none of these
# carries a `cmPath` and only the two Nim models do.

let dPullupSpec* = ModelSpec(
  name: "d_pullup", cFunction: "cm_d_pullup",
  description: "digital pullup resistor",
  ports: @[PortSpec(name: "out", dir: xdOut, default: xpD, allowed: @[xpD])],
  params: @[ParamSpec(name: "load", dataType: xtReal, default: "1.0e-12",
                      nullAllowed: true)])

let dOscSpec* = ModelSpec(
  name: "d_osc", cFunction: "cm_d_osc",
  description: "controlled digital oscillator",
  ports: @[
    PortSpec(name: "cntl_in", dir: xdIn, default: xpV,
             allowed: @[xpV, xpVd, xpI, xpId]),
    PortSpec(name: "out", dir: xdOut, default: xpD, allowed: @[xpD])],
  params: @[
    ParamSpec(name: "cntl_array", dataType: xtReal, vector: true,
              nullAllowed: true),
    ParamSpec(name: "freq_array", dataType: xtReal, vector: true,
              nullAllowed: true),
    ParamSpec(name: "duty_cycle", dataType: xtReal, nullAllowed: true),
    ParamSpec(name: "init_phase", dataType: xtReal, nullAllowed: true),
    ParamSpec(name: "rise_delay", dataType: xtReal, nullAllowed: true),
    ParamSpec(name: "fall_delay", dataType: xtReal, nullAllowed: true)])

let dacBridgeSpec* = ModelSpec(
  name: "dac_bridge", cFunction: "cm_dac_bridge",
  description: "digital-to-analog node bridge",
  ports: @[
    PortSpec(name: "in", dir: xdIn, default: xpD, allowed: @[xpD],
             vector: true, vectorBounds: atLeast(1)),
    PortSpec(name: "out", dir: xdOut, default: xpV, allowed: @[xpV],
             vector: true, vectorBounds: atLeast(1))],
  params: @[
    ParamSpec(name: "out_low", dataType: xtReal, nullAllowed: true),
    ParamSpec(name: "out_high", dataType: xtReal, nullAllowed: true),
    ParamSpec(name: "out_undef", dataType: xtReal, nullAllowed: true),
    ParamSpec(name: "t_rise", dataType: xtReal, nullAllowed: true),
    ParamSpec(name: "t_fall", dataType: xtReal, nullAllowed: true)])

let bidiBridgeSpec* = ModelSpec(
  name: "bidi_bridge", cFunction: "cm_bidi_bridge",
  description: "bidirectional digital/analog node bridge",
  ports: @[
    # `g` -- a conductance -- because that is the only analog port type that
    # is bidirectional, which is what an open-drain line needs.
    PortSpec(name: "a", dir: xdInout, default: xpG, allowed: @[xpG, xpGd],
             vector: true, vectorBounds: atLeast(1)),
    PortSpec(name: "d", dir: xdInout, default: xpD, allowed: @[xpD],
             vector: true, vectorBounds: atLeast(1)),
    # Left unconnected here. With no direction input and `direction` at its
    # default of 2, the bridge is genuinely bidirectional: it drives the
    # analog side when the digital side is driven, and stops driving it --
    # letting the pull-up win -- when every digital driver has released.
    PortSpec(name: "dir", dir: xdIn, default: xpD, allowed: @[xpD],
             vector: true, nullAllowed: true)],
  params: @[
    ParamSpec(name: "direction", dataType: xtInt, nullAllowed: true),
    ParamSpec(name: "strength", dataType: xtInt, nullAllowed: true),
    ParamSpec(name: "input_load", dataType: xtReal, nullAllowed: true),
    ParamSpec(name: "in_low", dataType: xtReal, nullAllowed: true),
    ParamSpec(name: "in_high", dataType: xtReal, nullAllowed: true),
    ParamSpec(name: "out_low", dataType: xtReal, nullAllowed: true),
    ParamSpec(name: "out_high", dataType: xtReal, nullAllowed: true),
    ParamSpec(name: "drive_low", dataType: xtReal, nullAllowed: true),
    ParamSpec(name: "drive_high", dataType: xtReal, nullAllowed: true),
    ParamSpec(name: "t_rise", dataType: xtReal, nullAllowed: true),
    ParamSpec(name: "t_fall", dataType: xtReal, nullAllowed: true)])

# --- building the Nim models ------------------------------------------------

proc cmPathFor*(model: string): string =
  ## Builds the named model if it is not already built, and returns the `.cm`
  ## path.
  ##
  ## Lazy, and deliberately not done at module init: importing a parts library
  ## would then run `nim c` and a C compiler, so `nimcir check --offline` on a
  ## design that never simulates would pay several seconds and fail outright
  ## on a machine with no ngspice source tree. A design must stay inspectable
  ## with no simulator in the build.
  let cache = getEnv("NIMCIR_CACHE", getCacheDir() / "nimcir") / "codemodels"
  createDir(cache)
  # Lowercase: ngspice case-folds the lines it pre-parses, including
  # `pre_codemodel`, so a `.cm` whose path has an uppercase character in it
  # can never be loaded from a deck.
  result = cache / (model & ".cm")
  let src = currentSourcePath().parentDir / (model & ".nim")
  if fileExists(result) and getLastModificationTime(result) >=
     getLastModificationTime(src):
    return
  try:
    discard buildCodeModel(src, result)
  except CatchableError:
    # Returning the path anyway is deliberate: the component records it,
    # `spice/ngspice.run` finds it missing, and the reader gets one sentence
    # naming the file and how to build it. Raising here would abort the whole
    # design -- including every claim that needs no simulator at all.
    discard

# --- the bus ----------------------------------------------------------------

const digitalSuffix* = "_d"
  ## What `ensureAnalogBridge` calls the digital twin of an analog bus net.

proc digitalBus*(nl: Netlist, lines: openArray[Net]) =
  ## A `d_pullup` on each line, and nothing else. The bus is digital end to
  ## end: there is no analog node on it, so ngspice never has to solve one.
  ##
  ## This is the fast bus. It says nothing about rise times, VOL or sink
  ## current, because there is no resistor anywhere in it to say it with.
  for n in lines:
    discard addCodeModelInstance(nl, "APU_" & n.name, dPullupSpec, [wire(n)],
                                 {"load": "1.0e-12"})

proc ensureAnalogBridge*(nl: Netlist, analog: Net): Net =
  ## The digital net the device models share on the far side of `analog`,
  ## creating the `bidi_bridge` between them on the first call.
  ##
  ## Idempotent because both devices on a line need the same bridge and each
  ## one is materialised by its own `SimReplacement.build`; whichever runs
  ## first builds it.
  let dName = analog.name & digitalSuffix
  let existing = findNet(nl, dName)
  if existing != nil: return existing
  result = addNet(nl, Net(name: dName, kind: ntSignal))
  # VIH = 0.7 x VDD and VIL = 0.3 x VDD, which is where the I2C specification
  # puts a receiver's thresholds on a 3.3 V rail.
  #
  # **`in_low` here is the upper threshold and `in_high` the lower**, which is
  # not a typo. `bidi_bridge` switches to hysteresis exactly when
  # `in_high < in_low`, and in that branch it reads `in_low` as the rising
  # threshold and `in_high` as the falling one (`cfunc.mod`, the
  # `if (in_high < in_low)` case). Ordering them the other way puts it in the
  # non-hysteresis branch, where everything between the two reports as
  # `dsUnknown` -- and a released open-drain line then rises
  # `0 -> unknown -> 1`, so an edge test written as "was low, is now high"
  # never fires and the target silently stops acknowledging. Measured: the
  # bus clocked a perfect `0xB0` and got a NACK for it.
  discard addCodeModelInstance(nl, "ABR_" & analog.name, bidiBridgeSpec,
    [wire([analog]), wire([result]), nullPort()],
    {"direction": "2", "in_low": "2.31", "in_high": "0.99",
     "out_low": "0.0", "out_high": "3.3", "t_rise": "1n", "t_fall": "1n"})

proc requirePin(c: Component, name: string, who: string): Net =
  if not c.pins.hasKey(name):
    raise newException(NetlistError,
      c.designator & " has no pin '" & name & "'; the " & who &
      " model needs it")
  result = c.pins[name].net
  if result == nil:
    raise newException(NetlistError,
      c.designator & "." & name & " is not connected, and the " & who &
      " model has no way to represent an open pin")

proc busNet(nl: Netlist, c: Component, pin, who: string): Net =
  ## The net a device model's SDA or SCL port binds to.
  ##
  ## On an analog bus that is the digital side of the line's bridge; on a
  ## digital one the design's net already *is* digital and is used directly.
  ## The models cannot tell the difference and do not need to.
  let n = requirePin(c, pin, who)
  if n.attrs.getOrDefault("i2c.analog", "") == "1": ensureAnalogBridge(nl, n)
  else: n

proc markAnalogBus*(d: Design, netNames: varargs[string]) =
  ## Say that these bus nets are analog, so the device models reach them
  ## through a `bidi_bridge` rather than driving them as digital nodes.
  ##
  ## Recorded as a namespaced attribute on the net rather than as an argument
  ## to `useM24C64`/`useDummyMcu`, for two reasons: it is a property of the
  ## *bus* and not of either device on it, and `attrs` survives the
  ## clone -> flatten -> model chain that stands between a design and a deck,
  ## which a captured closure would not -- `SimReplacement.build` is
  ## `{.nimcall.}` and has no environment.
  for name in netNames:
    let n = findNet(d.netlist, name)
    if n == nil:
      raise newException(NetlistError,
        "no such net: " & name & " (marking the I2C bus as analog)")
    n.attrs["i2c.analog"] = "1"

# --- attaching the models ---------------------------------------------------

proc buildM24c64(nl: Netlist, old: Component): Component =
  let sda = busNet(nl, old, "SDA", "M24C64")
  let scl = busNet(nl, old, "SCL", "M24C64")
  let desig = old.designator
  var params: seq[(string, string)]
  for key in ["uid", "uid_offset", "dev", "tw"]:
    let v = old.attrs.getOrDefault("m24c64." & key, "")
    if v.len > 0: params.add (key, v)
  removeComponent(nl, desig)
  addCodeModelInstance(nl, "A" & desig, m24c64Spec, [wire(sda), wire(scl)],
                       params, cmPath = cmPathFor("m24c64"))

proc buildDummyMcu(nl: Netlist, old: Component): Component =
  let sda = busNet(nl, old, "SDA", "dummy MCU")
  let scl = busNet(nl, old, "SCL", "dummy MCU")
  let doneA = requirePin(old, "DONE", "dummy MCU")
  let passA = requirePin(old, "PASS", "dummy MCU")
  let gnd = requirePin(old, "VSS", "dummy MCU")
  let desig = old.designator

  # The bit clock, which belongs to the model rather than to the board. A DC
  # control node costs the analog solver nothing: it never moves, so it forces
  # no timesteps.
  let clkD = addNet(nl, Net(name: desig & "_clk_d", kind: ntSignal))
  let ctl = addNet(nl, Net(name: desig & "_clk_ctl", kind: ntSignal))
  let vctl = addComponent(nl, Component(designator: "V" & desig & "CLK",
                                        kind: "voltage_source"))
  vctl.attrs["value"] = "DC 0"
  discard connect(vctl, "+", ctl)
  discard connect(vctl, "-", gnd)
  let fclk = old.attrs.getOrDefault("mcu.f_clk", "400e3")
  discard addCodeModelInstance(nl, "AOSC" & desig, dOscSpec,
    [wire(ctl), wire(clkD)],
    {"cntl_array": "[0 1]", "freq_array": "[" & fclk & " " & fclk & "]",
     "duty_cycle": "0.5"})

  # `done` and `pass` are digital inside the model and have to come back out
  # as voltages: only analog nets appear in the rawfile, so this is the whole
  # route by which the outcome becomes something a claim can be made about.
  let doneD = addNet(nl, Net(name: desig & "_done_d", kind: ntSignal))
  let passD = addNet(nl, Net(name: desig & "_pass_d", kind: ntSignal))
  let vHigh = old.attrs.getOrDefault("mcu.v_out_high", "3.3")
  discard addCodeModelInstance(nl, "ADAC" & desig, dacBridgeSpec,
    [wire([doneD, passD]), wire([doneA, passA])],
    {"out_low": "0", "out_high": vHigh, "t_rise": "1n", "t_fall": "1n"})

  var params: seq[(string, string)]
  for key in ["uid", "uid_offset", "dev", "wr_addr", "wr_data",
              "rb_addr", "rb_data", "poll_limit", "t_start"]:
    let v = old.attrs.getOrDefault("mcu." & key, "")
    if v.len > 0: params.add (key, v)
  removeComponent(nl, desig)
  addCodeModelInstance(nl, "A" & desig, dummy_mcuSpec,
    [wire(clkD), wire(sda), wire(scl), wire(doneD), wire(passD)],
    params, cmPath = cmPathFor("dummy_mcu"))

proc setModelAttrs(d: Design, designator, prefix, who: string,
                   keys: openArray[(string, string)]): Component =
  result = findComponent(d.netlist, designator)
  if result == nil:
    raise newException(NetlistError,
      "no such component: " & designator & " (attaching the " & who &
      " model)")
  for (k, v) in keys:
    if v.len > 0: result.attrs[prefix & k] = v

proc useM24C64*(d: Design, designator: string, uid = "",
                uidOffset = -1, dev = -1, tw = 0.0) =
  ## Attaches the EEPROM model to the named part. Call it after the
  ## `design(...)` block; it only adds to `simModels`, so the design netlist
  ## still describes the board.
  ##
  ## By *designator* rather than by `Component`, because the DSL's `let`
  ## bindings are scoped to the macro's own block and a design file imports no
  ## `std/tables` -- so `d.netlist.components["U2"]` does not even compile.
  ##
  ## Every argument has an "unset" spelling and unset ones are not written at
  ## all, so the model's own defaults stay in force and a design says only
  ## what it means to change. `tw` in particular: the datasheet's 5 ms is what
  ## the model defaults to, and stating a shorter one is a simulation
  ## concession rather than a fact about the part.
  discard setModelAttrs(d, designator, "m24c64.", "M24C64", {
    "uid": uid,
    "uid_offset": (if uidOffset >= 0: $uidOffset else: ""),
    "dev": (if dev >= 0: $dev else: ""),
    "tw": (if tw > 0.0: $tw else: "")})
  let c = findComponent(d.netlist, designator)
  addSimModel(c, newSimReplacement(buildM24c64, name = "behavioural"))
  c.simDefault = "behavioural"

proc useDummyMcu*(d: Design, designator: string, uid = "",
                  uidOffset = -1, dev = -1, wrAddr = -1, wrData = "",
                  rbAddr = -1, rbData = "", pollLimit = -1,
                  tStart = 0.0, fClk = 0.0, vOutHigh = 0.0) =
  ## Attaches the controller model, and with it the bit clock and the
  ## `dac_bridge` that carries its verdict back into the analog world.
  ##
  ## `uid` here is what the controller *expects* to read. Pointing it at a
  ## different string from the EEPROM's is how the negative case is written,
  ## and a verdict that cannot be made to fail is not worth asserting on.
  discard setModelAttrs(d, designator, "mcu.", "dummy MCU", {
    "uid": uid,
    "uid_offset": (if uidOffset >= 0: $uidOffset else: ""),
    "dev": (if dev >= 0: $dev else: ""),
    "wr_addr": (if wrAddr >= 0: $wrAddr else: ""),
    "wr_data": wrData,
    "rb_addr": (if rbAddr >= 0: $rbAddr else: ""),
    "rb_data": rbData,
    "poll_limit": (if pollLimit > 0: $pollLimit else: ""),
    "t_start": (if tStart > 0.0: $tStart else: ""),
    "f_clk": (if fClk > 0.0: $fClk else: ""),
    "v_out_high": (if vOutHigh > 0.0: $vOutHigh else: "")})
  let c = findComponent(d.netlist, designator)
  addSimModel(c, newSimReplacement(buildDummyMcu, name = "behavioural"))
  c.simDefault = "behavioural"

# --- a role for the outcome -------------------------------------------------

proc i2cTransactionExpand(inst: RoleInstance): seq[Assertion] =
  ## Two claims: the exchange finished, and it was right.
  ##
  ## `settled_v` on a flag rather than something more expressive, because
  ## every quantity the contract layer knows is electrical -- a voltage, a
  ## current, an impedance, a frequency, a time or a count -- and there is no
  ## digital one. So the controller drives its verdict out through a
  ## `dac_bridge` and the claim is made about the voltage that arrives. The
  ## indirection is real and worth knowing about; what it buys is that the
  ## outcome of a protocol exchange lands in the readiness report beside every
  ## other claim instead of in a test nobody runs with the design.
  ##
  ## `tSettle` and `tWindow` are **conditions, not limits**, exactly as
  ## `settled_rail`'s are: they say what was run, the answer is a function of
  ## them, and `contract_eval`'s setup key reads them back so two claims over
  ## two windows stay two runs. They are also the only channel an assertion
  ## has for a window at all -- a bare `require settled_v(n)` gets `tSettle =
  ## 0` and a one-millisecond run, which is nowhere near long enough for a
  ## transaction that spends five of them waiting on a write cycle.
  ##
  ## Both claims are unconditional. A ripple budget is a system decision a
  ## designer may reasonably not want to make, so `settled_rail` makes its
  ## claims opt-in; "the exchange completed and was correct" is not that kind
  ## of judgement, and a role instance that declined it would be stating
  ## nothing at all.
  let rail = paramFloat(inst, "rail", 3.3)
  let band = paramFloat(inst, "band", 0.1)
  let tSettle = paramFloat(inst, "tSettle", 0.0)
  let tWindow = paramFloat(inst, "tWindow", 0.0)

  template flag(part, sfx, why: string) =
    var claim = Assertion(
      id: assertionId(inst, sfx),
      subjects: @[inst.subject(part)],
      quantity: "settled_v",
      expect: nominal(rail, fracTol = band),
      unit: "V",
      severity: sevError,
      rationale: why,
      origin: inst.name)
    claim.condition["t_settle"] = $tSettle
    claim.condition["t_window"] = $tWindow
    result.add claim

  flag("done", "done",
       "the controller drives this high when its script ends, however it " &
       "ended, so a run that stalled part way through fails here rather " &
       "than looking like a claim nobody got round to checking")
  flag("verdict", "verdict",
       "high only if every byte read back matched what was expected -- the " &
       "unique ID out of the identification page, and the data out of the " &
       "memory array after the write cycle. It starts low and is driven " &
       "once, so silence is a failure and not a pass")

registerRole(RoleDef(
  name: "i2c_transaction",
  doc: "A scripted bus exchange that either completed correctly or did not.",
  parts: @[
    RolePart(name: "done", kind: skNet,
             doc: "driven high when the controller's script ends"),
    RolePart(name: "verdict", kind: skNet,
             doc: "driven high only if every readback matched"),
  ],
  params: @[
    AnnDef(key: "tSettle", kind: akFloat, unit: "s", scopes: {asNet},
           doc: "how long the exchange is given before the flags are read"),
    AnnDef(key: "tWindow", kind: akFloat, unit: "s", scopes: {asNet},
           doc: "how long a window the flags are averaged over"),
    AnnDef(key: "rail", kind: akFloat, unit: "V", scopes: {asNet},
           doc: "what a driven flag reads as; default 3.3 V"),
    AnnDef(key: "band", kind: akFloat, unit: "", scopes: {asNet},
           doc: "fractional tolerance on that; default 10%"),
  ],
  apply: nil,
  expand: i2cTransactionExpand))
