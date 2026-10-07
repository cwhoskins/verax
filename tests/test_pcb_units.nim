import std/unittest

import verax/pcb/units

test "length constructors and accessors round-trip":
  check mm(1.0).raw == 1_000_000
  check inch(1.0).raw == 25_400_000
  check mil(1.0).raw == 25_400
  check um(1.0).raw == 1_000

  check mm(1.6).toMm == 1.6
  check inch(0.5).toInch == 0.5
  check mil(62.5).toMil == 62.5
  check mm(25.4).toInch == 1.0

test "Nm arithmetic and comparison behave like integers":
  check (mm(1.0) + mm(2.0)) == mm(3.0)
  check (mm(3.0) - mm(1.0)) == mm(2.0)
  check -mm(1.0) == nm(-1_000_000)
  check abs(nm(-5)) == nm(5)
  check mm(1.0) < mm(2.0)
  check mm(2.0) <= mm(2.0)
  check (mm(1.0) * 3) == mm(3.0)
  check (3 * mm(1.0)) == mm(3.0)
  check (mm(1.0) * 0.5) == mm(0.5)
  check (mm(1.0) div 4) == mm(0.25)
  check (mm(3.0) / mm(1.5)) == 2.0

test "toNm converts every source unit a reader can encounter":
  check toNm(1.0, luNm) == nm(1)
  check toNm(1.0, luUm) == um(1.0)
  check toNm(1.0, luMm) == mm(1.0)
  check toNm(1.0, luMil) == mil(1.0)
  check toNm(1.0, luInch) == inch(1.0)

test "ODB++ 2.5nm quantum rounds to the nearest nanometre as documented":
  # ODB++'s finest resolution (1/400 um) isn't exact in nm; the loss is
  # under half a nanometre.
  let quantum = um(0.0025)
  check abs(quantum.raw.float - OdbQuantumNm) <= 0.5
  # The full ODB++ coordinate range still fits comfortably in int64.
  check inch(100.0).raw == 2_540_000_000'i64
  check inch(-100.0).raw == -2_540_000_000'i64

test "Nm renders losslessly":
  check $mm(1.0) == "1000000nm"
  check $nm(-5) == "-5nm"

test "angles normalise into [0, 360)":
  check deg(0.0).normalized.value == 0.0
  check deg(360.0).normalized.value == 0.0
  check deg(-90.0).normalized.value == 270.0
  check deg(450.0).normalized.value == 90.0
  check deg(180.0).toRadians == 3.141592653589793
  check fromRadians(3.141592653589793).value == 180.0
