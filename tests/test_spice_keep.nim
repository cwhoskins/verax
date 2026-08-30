## `$NIMCIR_KEEP_RUNS` -- the run archive -- and `$NIMCIR_SAVE_CURRENTS`.
##
## The property worth pinning here is not that files appear. It is that
## switching either of them on cannot change what was simulated, and that the
## device-current `.save` stays away from the analyses whose plot is complex:
## a real-valued `@r1[i]` written into a complex rawfile is a malformed line,
## so an unguarded version of this would turn every frequency sweep in the
## library into a parse error.

import std/[math, os, sequtils, strutils, tables, tempfiles, unittest]

import nimcir/netlist
import nimcir/schematic
import nimcir/spice/ngspice

let haveNgspice = findExe("ngspice").len > 0

proc dividerNetlist(): Netlist =
  result = newNetlist("rc_divider")
  let vin = addNet(result, newNet("vin"))
  let vout = addNet(result, newNet("vout"))
  let gnd = addNet(result, newNet("0", ntGround))

  let v1 = addComponent(result, newComponent("V1", kind = "voltage_source"))
  discard connect(v1, "+", vin)
  discard connect(v1, "-", gnd)
  v1.attrs["value"] = "DC 10 AC 1"

  let r1 = addComponent(result, newComponent("R1", kind = "resistor"))
  discard connect(r1, "1", vin, ptPassive)
  discard connect(r1, "2", vout, ptPassive)
  r1.attrs["value"] = "1k"

  let r2 = addComponent(result, newComponent("R2", kind = "resistor"))
  discard connect(r2, "1", vout, ptPassive)
  discard connect(r2, "2", gnd, ptPassive)
  r2.attrs["value"] = "1k"

  let c1 = addComponent(result, newComponent("C1", kind = "capacitor"))
  discard connect(c1, "1", vout, ptPassive)
  discard connect(c1, "2", gnd, ptPassive)
  c1.attrs["value"] = "100n"

proc floatingNetlist(): Netlist =
  ## A capacitor-only node: no DC path to ground, so the solve is singular.
  result = newNetlist("floating")
  let vin = addNet(result, newNet("vin"))
  let mid = addNet(result, newNet("mid"))
  let gnd = addNet(result, newNet("0", ntGround))

  let v1 = addComponent(result, newComponent("V1", kind = "voltage_source"))
  discard connect(v1, "+", vin)
  discard connect(v1, "-", gnd)
  v1.attrs["value"] = "DC 10"

  let c1 = addComponent(result, newComponent("C1", kind = "capacitor"))
  discard connect(c1, "1", vin, ptPassive)
  discard connect(c1, "2", mid, ptPassive)
  c1.attrs["value"] = "1u"

  let c2 = addComponent(result, newComponent("C2", kind = "capacitor"))
  discard connect(c2, "1", mid, ptPassive)
  discard connect(c2, "2", gnd, ptPassive)
  c2.attrs["value"] = "1u"

template withEnv(key, value: string, body: untyped) =
  let had = existsEnv(key)
  let old = getEnv(key)
  putEnv(key, value)
  try:
    body
  finally:
    if had: putEnv(key, old) else: delEnv(key)

# --- the card, which needs no simulator -----------------------------------

test "no .save card unless asked for":
  delEnv("NIMCIR_SAVE_CURRENTS")
  check saveCurrentsCard(dividerNetlist(), ".op") == ""

test "the .save card leads with `all`":
  # Naming any vector turns the default set off, so a card that said only
  # @r1[i] would archive a resistor current and throw away every node voltage.
  withEnv("NIMCIR_SAVE_CURRENTS", "1"):
    let card = saveCurrentsCard(dividerNetlist(), ".tran 1u 1m")
    check card.startsWith(".save all ")
    check "@R1[i]" in card
    check "@R2[i]" in card
    check "@C1[i]" in card
    # A voltage source's branch current is already an MNA unknown, saved as
    # v1#branch by default; asking for a terminal current it does not have
    # would only earn an `unrecognized variable` warning.
    check "@V1[" notin card

test "no .save card for a complex-plot analysis":
  # The whole reason this is built here rather than asked for with
  # `.options savecurrents`: a real-valued @r1[i] written into a complex
  # rawfile is a malformed value line.
  withEnv("NIMCIR_SAVE_CURRENTS", "1"):
    check saveCurrentsCard(dividerNetlist(), ".ac dec 10 1 1k") == ""
    check saveCurrentsCard(dividerNetlist(), ".noise v(vout) V1 dec 10 1 1k") == ""
    check saveCurrentsCard(dividerNetlist(), ".op").len > 0
    check saveCurrentsCard(dividerNetlist(), ".dc V1 0 5 0.1").len > 0

# --- the archive ----------------------------------------------------------

suite "run archive":
  if not haveNgspice:
    echo "  [skipped: ngspice not found on PATH]"
  else:
    test "nothing is left behind when the archive is off":
      delEnv("NIMCIR_KEEP_RUNS")
      let before = walkDirRec(getTempDir(), yieldFilter = {pcDir}).toSeq.len
      discard run(dividerNetlist(), ".op")
      # The temp directory `run` makes is removed in its own `finally`; all we
      # can check cheaply is that the count did not grow.
      check walkDirRec(getTempDir(), yieldFilter = {pcDir}).toSeq.len <= before

    test "deck, rawfile, log and index land in the archive":
      let dir = createTempDir("nimcir_keeptest_", "")
      defer: removeDir(dir)
      withEnv("NIMCIR_KEEP_RUNS", dir):
        let res = run(dividerNetlist(), ".op", label = "divider:op")
        check abs(res["v(vout)"][0] - 5.0) < 1e-9

      check fileExists(dir / "run000.cir")
      check fileExists(dir / "run000.raw")
      check fileExists(dir / "run000.log")
      check fileExists(dir / "run000.svg")
      check fileExists(dir / "run000.json")
      check fileExists(dir / "index.txt")

      # The JSON is the public scene for the very fragment that ran, byte-for-
      # byte the scene a fresh layout of that netlist produces.
      check readFile(dir / "run000.json") == sceneToJsonString(dividerNetlist())

      # The rawfile is ngspice's own ASCII format, loadable straight back in.
      let raw = readFile(dir / "run000.raw")
      check raw.startsWith("Title:") or "Plotname:" in raw
      check "v(vout)" in raw.toLowerAscii

      # The archived deck is the one that ran: its `write` names the rawfile
      # sitting beside it, so handing it back to ngspice reproduces the run.
      check ("write " & dir / "run000.raw") in readFile(dir / "run000.cir")

      let rows = readFile(dir / "index.txt").strip.splitLines
      check rows.len == 2
      check rows[0].startsWith("slot\tstatus")
      let cols = rows[1].split('\t')
      check cols[0] == "run000"
      check cols[1] == "ok"
      check cols[2] == "divider:op"
      check cols[3] == ".op"
      check cols[5] == "rc_divider"

    test "the archive schematic uses the constrained layout from the environment":
      let dir = createTempDir("nimcir_keeptest_", "")
      defer: removeDir(dir)
      var options = defaultLayoutOptions()
      options.policy = lpConstrainedLayered
      withEnv("NIMCIR_KEEP_RUNS", dir):
        withEnv("NIMCIR_SCHEMATIC_LAYOUT", "constrained-layered"):
          discard run(dividerNetlist(), ".op")

      check readFile(dir / "run000.json") ==
            sceneToJsonString(layout(dividerNetlist(), options))

    test "a second run takes the next slot and appends a row":
      let dir = createTempDir("nimcir_keeptest_", "")
      defer: removeDir(dir)
      withEnv("NIMCIR_KEEP_RUNS", dir):
        discard run(dividerNetlist(), ".op")
        discard run(dividerNetlist(), ".tran 10u 1m", label = "divider:tran")

      check fileExists(dir / "run000.raw")
      check fileExists(dir / "run001.raw")
      let rows = readFile(dir / "index.txt").strip.splitLines
      check rows.len == 3
      check rows[2].split('\t')[0] == "run001"
      # A .tran has many points; an .op has one.
      check parseInt(rows[1].split('\t')[9]) == 1
      check parseInt(rows[2].split('\t')[9]) > 1

    test "a failed run keeps its deck and log, and says so in the index":
      # This is the run whose artifacts are worth reading, so it must not be
      # the one that gets cleaned up.
      let dir = createTempDir("nimcir_keeptest_", "")
      defer: removeDir(dir)
      withEnv("NIMCIR_KEEP_RUNS", dir):
        expect(SpiceSimError):
          discard run(floatingNetlist(), ".op")

      check fileExists(dir / "run000.cir")
      check fileExists(dir / "run000.log")
      # The fragment picture and scene are written before ngspice runs, so a
      # failed run keeps them like its deck and log.
      check fileExists(dir / "run000.svg")
      check fileExists(dir / "run000.json")
      let rows = readFile(dir / "index.txt").strip.splitLines
      check rows.len == 2
      check rows[1].split('\t')[1] == "failed"

    test "an .ac run still parses with save-currents on":
      # The regression this file exists for.
      let dir = createTempDir("nimcir_keeptest_", "")
      defer: removeDir(dir)
      withEnv("NIMCIR_KEEP_RUNS", dir):
        withEnv("NIMCIR_SAVE_CURRENTS", "1"):
          let ac = run(dividerNetlist(), ".ac dec 10 100 100k")
          check ac.dataKind == sdComplex
          check ac.mag("v(vout)").len > 0
          let tr = run(dividerNetlist(), ".tran 10u 1m")
          check tr.dataKind == sdReal

      check ".save" notin readFile(dir / "run000.cir")   # the .ac
      check ".save all @" in readFile(dir / "run001.cir") # the .tran
      # And the device current really is in the archived .tran rawfile.
      check "@r1[i]" in readFile(dir / "run001.raw").toLowerAscii

    test "archiving does not move a measured number":
      delEnv("NIMCIR_KEEP_RUNS")
      delEnv("NIMCIR_SAVE_CURRENTS")
      let plain = run(dividerNetlist(), ".op")["v(vout)"][0]

      let dir = createTempDir("nimcir_keeptest_", "")
      defer: removeDir(dir)
      withEnv("NIMCIR_KEEP_RUNS", dir):
        withEnv("NIMCIR_SAVE_CURRENTS", "1"):
          check run(dividerNetlist(), ".op")["v(vout)"][0] == plain
