## "Is MFEM wired up?" in one small file -- the first thing to run when
## `test_fem_mfem.nim` fails. Also `nimble mfemcheck`.
##
## No toolchain found -> prints `SKIP: <report>` and passes. A toolchain that
## *is* found but whose shim is missing, will not load, or has the wrong ABI
## is a **failure**, not a skip: that is a broken install, and skipping it would
## hide exactly the thing this file exists to report.
import std/[os, strutils, unittest]
import verax/fem/mfem

let status = loadStatus()
echo $status

suite "MFEM load":
  test "a found toolchain must load, match the ABI and report v4.10":
    if not status.toolchainFound:
      echo "SKIP: ", $status
      skip()
    else:
      check status.shimExists
      check status.loaded
      check status.abiGot == status.abiExpected
      check status.version.startsWith("MFEM v4.10")

  test "available() is false and does not raise when $MFEM_DIR points nowhere":
    # Unconditional: this is the skip path every machine without MFEM takes.
    let old = getEnv("MFEM_DIR")
    let hadOld = existsEnv("MFEM_DIR")
    putEnv("MFEM_DIR", "/nonexistent/verax-mfem-test")
    defer:
      if hadOld: putEnv("MFEM_DIR", old) else: delEnv("MFEM_DIR")
    check not available()
    let s = loadStatus()
    check not s.toolchainFound
    check not s.loaded
    check s.abiGot == -1
    check mfemVersion() == ""
    # The report still renders and says what to do about it.
    check "nimble mfem" in $s
