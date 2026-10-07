import std/[complex, math, os, streams, strutils, unittest]

import verax/touchstone

# Three fixtures encoding the same 2-port S-parameters at 1 GHz, one per
# data format, which must agree as Complex64. Values were computed by script
# from the RI numbers, not rounded by hand.

const riFixture = """
! 2-port, real/imaginary, hand-written fixture
# GHZ S RI R 50
1.0  0.1 0.2  0.9 -0.05  0.05 0.01  -0.2 0.1
"""

const maFixture = """
! same network, magnitude/angle(deg)
# GHZ S MA R 50
1.0  0.2236067977 63.4349488229  0.9013878189 -3.1798301199  0.0509901951 11.3099324740  0.2236067977 153.4349488229
"""

const dbFixture = """
! same network, dB-magnitude/angle(deg)
# GHZ S DB R 50
1.0  -13.0102999566 63.4349488229  -0.9017663035 -3.1798301199  -25.8502665203 11.3099324740  -13.0102999566 153.4349488229
"""

const tol = 1e-6

proc checkClose(a, b: Complex64) =
  check abs(a.re - b.re) < tol
  check abs(a.im - b.im) < tol

test "the historical 2-port column order (S11 S21 S12 S22) lands row-major":
  let sp = readTouchstone(newStringStream(riFixture), "fixture.s2p")
  check sp.nPorts == 2
  check sp.z0 == 50.0
  check sp.freqs.len == 1
  check abs(sp.freqs[0] - 1e9) < 1.0     # GHz -> Hz
  checkClose(sp.sAt(0, 0, 0), complex(0.1, 0.2))     # S11
  checkClose(sp.sAt(0, 1, 0), complex(0.9, -0.05))   # S21
  checkClose(sp.sAt(0, 0, 1), complex(0.05, 0.01))   # S12
  checkClose(sp.sAt(0, 1, 1), complex(-0.2, 0.1))    # S22

test "RI, MA and DB fixtures of the same network agree after conversion":
  let ri = readTouchstone(newStringStream(riFixture), "fixture.s2p")
  let ma = readTouchstone(newStringStream(maFixture), "fixture.s2p")
  let db = readTouchstone(newStringStream(dbFixture), "fixture.s2p")
  for (i, j) in [(0, 0), (1, 0), (0, 1), (1, 1)]:
    checkClose(ri.sAt(0, i, j), ma.sAt(0, i, j))
    checkClose(ri.sAt(0, i, j), db.sAt(0, i, j))

test "a stream with no .sNp-shaped name refuses rather than guessing the port count":
  expect(TouchstoneError):
    discard readTouchstone(newStringStream(riFixture), "")
  expect(TouchstoneError):
    discard readTouchstone(newStringStream(riFixture), "fixture.dat")

test "readTouchstoneFile opens a real file and reads it back the same way":
  let path = getTempDir() / "verax_test_fixture.s2p"
  writeFile(path, riFixture)
  defer: removeFile(path)
  let sp = readTouchstoneFile(path)
  checkClose(sp.sAt(0, 0, 0), complex(0.1, 0.2))

test "a 1-port file has no special column reordering to worry about":
  const s1p = """
  # MHZ S RI R 50
  100.0  0.5 0.25
  200.0  0.4 0.1
  """
  let sp = readTouchstone(newStringStream(s1p), "one.s1p")
  check sp.nPorts == 1
  check sp.freqs.len == 2
  check abs(sp.freqs[0] - 100e6) < 1.0
  check abs(sp.freqs[1] - 200e6) < 1.0
  checkClose(sp.sAt(0, 0, 0), complex(0.5, 0.25))
  checkClose(sp.sAt(1, 0, 0), complex(0.4, 0.1))

test "a malformed row raises TouchstoneError naming the line":
  const bad = """
  # GHZ S RI R 50
  1.0  0.1 0.2  0.9 -0.05  0.05 0.01
  """
  try:
    discard readTouchstone(newStringStream(bad), "bad.s2p")
    check false
  except TouchstoneError as e:
    check "line" in e.msg
