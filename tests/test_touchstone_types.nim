import std/[complex, math, unittest]

import verax/touchstone/types

# Every expectation here is a closed form, matching
# tests/test_analysis_measure.nim's convention of exact rather than
# simulated expected values -- there is no simulator in this submodule to
# check these against, only arithmetic, so the arithmetic has to be right on
# its own.

test "a perfect match: Gamma = 0 gives VSWR 1 and infinite return loss":
  check vswrOf(0.0) == 1.0
  check returnLossDb(0.0) == Inf

test "a total reflection: Gamma = 1 gives infinite VSWR and 0 dB return loss":
  check vswrOf(1.0) == Inf
  check returnLossDb(1.0) == 0.0

test "a lossless through path: |S21| = 1 gives 0 dB insertion loss":
  check insertionLossDb(1.0) == 0.0

test "gammaOf(z0, z0) is exactly zero -- a matched load reflects nothing":
  let g = gammaOf(complex(50.0, 0.0), complex(50.0, 0.0))
  check abs(g) == 0.0

test "gammaOf an open or a short against a real z0 has unit magnitude":
  # An open (z -> infinity) is the limit gammaOf cannot evaluate directly,
  # so use a very large real z instead; a short (z = 0) is exact.
  let short = gammaOf(complex(0.0, 0.0), complex(50.0, 0.0))
  check abs(abs(short) - 1.0) < 1e-12
  let nearOpen = gammaOf(complex(1e9, 0.0), complex(50.0, 0.0))
  check abs(abs(nearOpen) - 1.0) < 1e-6

# --- the network from the plan's Context section, verified against real
# ngspice 46 rather than assumed: a 25 ohm series element between 50 ohm
# ports measured S11 = -13.979 dB and S21 = -1.938 dB. Both numbers are
# recovered here from the closed-form Gamma and transmission coefficient of
# that exact network, with no simulator involved. -------------------------

const
  z0 = 50.0
  zSeries = 25.0
  gammaSeries = zSeries / (zSeries + 2.0 * z0)      # 25 / 125 = 0.2
  s21MagSeries = 2.0 * z0 / (2.0 * z0 + zSeries)     # 100 / 125 = 0.8

test "the 25 ohm series network's Gamma matches the closed form":
  check abs(gammaSeries - 0.2) < 1e-12
  check abs(s21MagSeries - 0.8) < 1e-12

test "returnLossDb recovers the measured -13.979 dB reading, sign included":
  # ngspice reported S11 = -13.979 dB directly (a raw S11 reading, negative
  # for a lossy match); returnLossDb flips that sign by convention (a bigger
  # number is a better match), so it recovers +13.979 dB here.
  check abs(returnLossDb(gammaSeries) - 13.979) < 1e-3
  check abs(voltageRatioToDb(gammaSeries) - (-13.979)) < 1e-3

test "insertionLossDb recovers the measured -1.938 dB reading, sign included":
  check abs(insertionLossDb(s21MagSeries) - 1.938) < 1e-3
  check abs(voltageRatioToDb(s21MagSeries) - (-1.938)) < 1e-3

# --- dBm <-> watts --------------------------------------------------------

test "0 dBm is exactly 1 mW and 30 dBm is exactly 1 W":
  check dbmToWatts(0.0) == 1e-3
  check dbmToWatts(30.0) == 1.0
  check wattsToDbm(1e-3) == 0.0
  check wattsToDbm(1.0) == 30.0

# --- the two dB conversions must never collapse into one -----------------

test "powerRatioToDb and voltageRatioToDb disagree by exactly a factor of 2":
  # Pinned as its own test, named the way it is, so this distinction cannot
  # quietly be collapsed back into one `dbToLinear`-style proc later: an
  # S-parameter is a voltage-wave ratio (20*log10) and a gain/Friis/cascade
  # figure is a power ratio (10*log10) -- conflating them is a silent
  # factor-of-2 error in dB.
  let ratio = 4.0
  check abs(voltageRatioToDb(ratio) - 2.0 * powerRatioToDb(ratio)) < 1e-12

test "the dB<->linear pairs invert each other":
  check abs(dbToPowerRatio(powerRatioToDb(7.0)) - 7.0) < 1e-9
  check abs(dbToVoltageRatio(voltageRatioToDb(7.0)) - 7.0) < 1e-9

test "sAt indexes the row-major matrix by (frequency, row, column)":
  var sp: SParams
  sp.nPorts = 2
  sp.points = @[@[complex(1.0, 0.0), complex(2.0, 0.0),
                  complex(3.0, 0.0), complex(4.0, 0.0)]]
  check sp.sAt(0, 0, 0) == complex(1.0, 0.0)   # S11
  check sp.sAt(0, 0, 1) == complex(2.0, 0.0)   # S12
  check sp.sAt(0, 1, 0) == complex(3.0, 0.0)   # S21
  check sp.sAt(0, 1, 1) == complex(4.0, 0.0)   # S22
