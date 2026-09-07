## Built-in roles for digital buses.
##
## `i2c` is the only one so far. It is a multi-subject role -- `sda` and `scl`
## are two nets judged together -- so it is where role part binding is
## actually exercised, and `designs/lib/i2c_parts.nim`'s user-written
## `i2c_transaction` is its counterpart outside this library.

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
