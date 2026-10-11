## Built-in roles for digital buses. `i2c` binds two nets judged together
## (`sda`, `scl`). `spi` fans out (`design.addImpliedRoles`): a wide CS bus
## becomes one `spi` instance per chip select, each judged locally.

import std/tables
import ./core
import ../../units

const i2cCornerMargin = 10.0
  ## How far above the bus clock the SDA/SCL RC corner must sit (a rule of
  ## thumb; the I2C spec states a rise-time limit instead).

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
    # The other side of the squeeze: `rc_corner` bounds the pull-up from
    # above, this from below (a target must sink 3 mA at VOL <= 0.4 V, so
    # ~1 kohm minimum at 3.3 V). Claimed unconditionally since 3 mA is the
    # spec's figure; `maxSinkCurrent` overrides it.
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
  ## Signals are claimed scalar: `addImpliedRoles` fans a wide `cs` out into
  ## one instance per member first, so each claim concerns one chip select.
  ## `inst.member` says which (`0` for the first or only).
  var cond: OrderedTable[string, string]
  # Dotted: a record of the bus clock for readers, which no static
  # evaluator reads -- a bare key would be refused as unread.
  if hasParam(inst, "frequency"): cond["spi.frequency"] = inst.params["frequency"]

  if inst.member == 0:
    # Claimed once per bus: SCLK/MOSI/MISO are shared by every member.
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

  # Opt-in (the `targetZ` rule): many boards hold CS from a GPIO, so an
  # unconditional pull-up claim would fail on correct designs.
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
