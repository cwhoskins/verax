## Built-in roles for digital buses.
##
## `i2c` and `spi` are the two so far. `i2c` is a multi-subject role --
## `sda` and `scl` are two nets judged together -- so it is where role part
## binding is actually exercised, and `designs/lib/i2c_parts.nim`'s
## user-written `i2c_transaction` is its counterpart outside this library.
## `spi` is the one whose fan-out is worth reading (`design.addImpliedRoles`):
## a chip-select bus is usually wide, so one `spiInterface` instance becomes
## one `spi` role instance *per chip select*, each judged locally.

import std/tables
import ./core
import ../../units

const i2cCornerMargin = 10.0
  ## How far above the bus clock the SDA/SCL RC corner must sit. A pull-up
  ## against bus capacitance is a first-order low-pass; a corner at the clock
  ## frequency would round the edges into the sampling window. Ten times is
  ## the usual rule of thumb, not a figure from the I2C specification, which
  ## states a rise-time limit instead.

proc i2cExpand*(inst: RoleInstance): seq[Assertion] =
  let freq = paramFloat(inst, "frequency", 100_000.0)
  for line in ["sda", "scl"]:
    let net = inst.subject(line)
    result.add Assertion(
      id: assertionId(inst, line & ".pullup"),
      subjects: @[net],
      quantity: "pullup_count",
      expect: atLeast(1.0),
      severity: sevError,
      rationale: "I2C is open-drain: with no pull-up the line can be driven " &
                 "low but never returns high",
      origin: inst.name)
    result.add Assertion(
      id: assertionId(inst, line & ".rc_corner"),
      subjects: @[net],
      quantity: "rc_corner",
      expect: atLeast(freq * i2cCornerMargin),
      unit: "Hz",
      severity: sevWarning,
      rationale: "pull-up resistance against bus capacitance must not round " &
                 "the edges into the sampling window at " & $Hertz(freq),
      origin: inst.name)
    # The other side of the same squeeze. `rc_corner` bounds the pull-up from
    # above -- too weak and the edges round off -- and this bounds it from
    # below: an I2C target must hold VOL at or below 0.4 V while sinking
    # 3 mA, so at 3.3 V the pull-up may not go under about 1 kohm. Fixing one
    # limit walks a design toward the other, and until this existed nothing
    # said so.
    #
    # 3 mA is the specification's number rather than a design choice, which
    # is why it is claimed unconditionally with a default. `maxSinkCurrent`
    # overrides it for a bus whose parts all state better.
    result.add Assertion(
      id: assertionId(inst, line & ".sink_current"),
      subjects: @[net],
      quantity: "pullup_sink_current",
      expect: atMost(paramFloat(inst, "maxSinkCurrent", 3.0e-3)),
      unit: "A",
      severity: sevError,
      rationale: "whatever pulls this line low has to sink the pull-up " &
                 "current while holding VOL at or below 0.4 V, and a " &
                 "pull-up stronger than the parts on the bus can sink puts " &
                 "the low level above the receiver's threshold",
      origin: inst.name)
  block:
    let sda = inst.subject("sda")
    result.add Assertion(
      id: assertionId(inst, "controllers"),
      subjects: @[sda],
      quantity: "controller_count",
      expect: nominal(1.0, absTol = 0.0),
      severity: sevWarning,
      rationale: "more than one controller needs multi-controller " &
                 "arbitration, which is rarely intended",
      origin: inst.name)

proc spiExpand*(inst: RoleInstance): seq[Assertion] =
  ## `sclk`/`mosi`/`miso`/`cs` are always claimed scalar, even though the
  ## interface this role rides on (`netlist/interfaces/std.spiInterface`)
  ## usually declares `cs` as an N-member bus: `design.addImpliedRoles` fans
  ## a wide `cs` out into one `spi` instance per member before this expander
  ## ever runs, each with its own `cs` narrowed to width 1 -- so a claim here
  ## is always about one chip select, and "two peripherals on one select"
  ## becomes a claim local to that instance rather than a cross-instance
  ## comparison. `inst.member` is which one, `0` for the first (or the only
  ## one, when the interface was never wide to begin with).
  var cond: OrderedTable[string, string]
  if hasParam(inst, "frequency"): cond["frequency"] = inst.params["frequency"]

  if inst.member == 0:
    # Claimed once per *bus*, not once per chip select -- SCLK/MOSI/MISO are
    # shared across every member of the fan-out, so asking three times would
    # be the identical question asked three times over the identical wire.
    let sclk = inst.subject("sclk")
    result.add Assertion(
      id: assertionId(inst, "controllers"),
      subjects: @[sclk],
      quantity: "controller_count",
      expect: nominal(1.0, absTol = 0.0),
      condition: cond,
      severity: sevWarning,
      rationale: "more than one controller driving one SPI bus needs " &
                 "arbitration the protocol has none of",
      origin: inst.name)

  let miso = inst.subject("miso")
  let cs = inst.subject("cs")
  result.add Assertion(
    id: assertionId(inst, "miso_drivers"),
    subjects: @[miso, cs],
    quantity: "miso_driver_count",
    expect: atMost(1.0),
    condition: cond,
    severity: sevError,
    rationale: "two peripherals sharing MISO must not also share this " &
               "chip select, or both drive the line at once when it is " &
               "asserted",
    origin: inst.name)

  # Opt-in, following `power_rail`'s `targetZ` doctrine: an unselected chip
  # select floating between transactions is a real risk, but plenty of
  # boards hold it from a GPIO rather than a resistor (every select in
  # `designs/spi_memories.nim` does), and claiming a pull-up unconditionally
  # would fail nine times on a correct board and turn `nimble verify` red.
  if hasParam(inst, "csPullup"):
    result.add Assertion(
      id: assertionId(inst, "cs.pullup"),
      subjects: @[cs],
      quantity: "pullup_count",
      expect: atLeast(1.0),
      condition: cond,
      severity: sevWarning,
      rationale: "an unselected chip select must be held inactive while " &
                 "nothing drives it, or the bus floats between transactions",
      origin: inst.name)
