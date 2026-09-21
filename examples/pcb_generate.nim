## The acceptance gate for **from-scratch** `.kicad_pcb` synthesis --
## `nimble generate`, gated on `findExe("kicad-cli")` (`kicad-cli 10.0.3` is
## installed here). Mirrors `examples/pcb_editcheck.nim`'s reasoning for the
## same tool: only KiCad's own tooling proves a file KiCad-cli reads is
## real KiCad, and `kicad-cli pcb drc` exiting 0 on its own proves nothing
## (finding 2 -- it read the corrupt demo board's first 1% and reported "0
## unconnected items"), hence the token-count check below rather than the
## exit code alone.
##
## Per design: `assemble` a `Pcb` with real footprints resolved through
## `pcb/formats/kicadmod` off `/usr/share/kicad/footprints`, `writeBoard` it,
## `kicad-cli pcb upgrade` the emitted file and assert its own
## footprint/pad/net token counts equal what the in-memory `Pcb` actually
## holds (a parser that silently dropped a footprint node would upgrade
## clean and report a smaller count -- the same class of silent failure
## `pcb_editcheck.nim` guards against on the edit path), then
## `kicad-cli pcb drc` asserting exit 0.
##
## Run with:
##   nim c -d:release -r --path:./src examples/pcb_generate.nim

import std/[os, osproc, sets, strutils, tables]

import verax/netlist
import verax/netlist/annotations
import verax/pcb
import verax/pcb/assemble
import verax/pcb/formats/kicadmod  # registers the KiCad FootprintSource
import verax/pcb/formats/kicad

proc countTokens(path: string): tuple[fp, pad, net: int] =
  let text = readFile(path)
  proc count(tok: string): int =
    var i = 0
    while true:
      let p = text.find(tok, i)
      if p < 0: break
      inc result
      i = p + tok.len
  # Distinct net *names* referenced anywhere in the file, not a count of
  # `(net ...)` declaration lines -- `kicad-cli pcb upgrade` turned out to
  # rewrite a fresh board straight to the name-only `(net "name")` shape
  # (`kicad.nim`'s own documented KiCad->=`20251028` finding), dropping the
  # top-level `(net N "name")` declaration block entirely, so counting
  # declarations would measure a KiCad version choice rather than anything
  # this generator did. Scanning every `(net ...)` occurrence for a quoted
  # name and collecting the *set* is robust to either convention -- a
  # numbered declaration, a numbered pad reference, or a bare name-only
  # one all read the same way, and `(net 0 "")`'s empty name is naturally
  # excluded by the `name.len > 0` guard below.
  var names: HashSet[string]
  var i = 0
  while true:
    let p = text.find("(net ", i)
    if p < 0: break
    var j = p + 5
    while j < text.len and text[j] == ' ': inc j
    while j < text.len and text[j] in {'0' .. '9'}: inc j
    while j < text.len and text[j] == ' ': inc j
    if j < text.len and text[j] == '"':
      inc j
      let start = j
      while j < text.len and text[j] != '"': inc j
      let nm = text[start ..< j]
      if nm.len > 0: names.incl nm
    i = p + 5
  (count("(footprint "), count("(pad "), names.len)

proc runCli(args: seq[string]): tuple[output: string, exitCode: int] =
  execCmdEx(quoteShellCommand(@["kicad-cli"] & args))

# ---------------------------------------------------------------- fixture designs

proc dividerDesign(): Netlist =
  ## The same shape as `designs/pcb_demo.nim` -- rebuilt here rather than
  ## imported, since a design file's own `quit(verifyMain(d))` makes it a
  ## program, not an importable module.
  result = newNetlist("gen_divider")
  let vin = addNet(result, newNet("VIN"))
  let mid = addNet(result, newNet("MID"))
  let gnd = addNet(result, newNet("GND"))
  let r1 = addComponent(result, newComponent("R1", kind = "resistor"))
  discard connect(r1, "1", vin, ptPassive)
  discard connect(r1, "2", mid, ptPassive)
  setAnnotation(r1, "footprint", "Resistor_SMD:R_0402_1005Metric")
  let r2 = addComponent(result, newComponent("R2", kind = "resistor"))
  discard connect(r2, "1", mid, ptPassive)
  discard connect(r2, "2", gnd, ptPassive)
  setAnnotation(r2, "footprint", "Resistor_SMD:R_0402_1005Metric")

proc headerAndResistorsDesign(): Netlist =
  ## Mixes a through-hole part with two SMD ones, so the count check covers
  ## both aperture families and a multi-pin footprint.
  result = newNetlist("gen_header")
  let a = addNet(result, newNet("A"))
  let b = addNet(result, newNet("B"))
  let gnd = addNet(result, newNet("GND"))
  let j1 = addComponent(result, newComponent("J1", kind = "connector"))
  discard connect(j1, "1", a, ptPassive)
  discard connect(j1, "2", gnd, ptPassive)
  setAnnotation(j1, "footprint",
    "Connector_PinHeader_2.54mm:PinHeader_1x02_P2.54mm_Vertical")
  let r1 = addComponent(result, newComponent("R1", kind = "resistor"))
  discard connect(r1, "1", a, ptPassive)
  discard connect(r1, "2", b, ptPassive)
  setAnnotation(r1, "footprint", "Resistor_SMD:R_0402_1005Metric")
  let r2 = addComponent(result, newComponent("R2", kind = "resistor"))
  discard connect(r2, "1", b, ptPassive)
  discard connect(r2, "2", gnd, ptPassive)
  setAnnotation(r2, "footprint", "Resistor_SMD:R_0402_1005Metric")

const designs = {
  "gen_divider": dividerDesign,
  "gen_header": headerAndResistorsDesign,
}

proc main() =
  if findExe("kicad-cli").len == 0:
    echo "pcb_generate: kicad-cli not on PATH, skipping"
    quit(0)
  if not dirExists("/usr/share/kicad/footprints"):
    echo "pcb_generate: /usr/share/kicad/footprints not present, skipping"
    quit(0)

  var failures = 0
  let tmpDir = getTempDir() / "verax_pcb_generate"
  createDir(tmpDir)

  for (name, build) in designs:
    echo name
    let nl = build()
    let (pcb, issues, _) = assemble(nl)
    for i in issues:
      echo "  [", i.severity, "] ", i.kind, ": ", i.message
    if pcb.placements.len != nl.components.len:
      echo "  FAIL: assembled ", pcb.placements.len, " placement(s) for ",
           nl.components.len, " component(s)"
      inc failures
      continue

    # What the in-memory board itself carries -- the reference the written
    # file's own token counts are checked against.
    var wantFp = pcb.placements.len
    var wantPad = 0
    for _, p in pcb.placements:
      # One `(pad ...)` node per distinct pad id, regardless of how many
      # copper layers it spans -- a through-hole pad's `*.Cu` wildcard
      # produces two `Copper` records in `p.lands[id]` (one per side) but
      # is still exactly one node in the file, so this counts keys, not
      # the total `Copper` records across them.
      wantPad += p.lands.len
    var wantNet = 0
    for name in pcb.netCopper.keys:
      if pcb.netCopper[name].len > 0: inc wantNet

    let outPath = tmpDir / (name & ".kicad_pcb")
    writePcb(pcb, outPath)

    let (upOut, upRc) = runCli(@["pcb", "upgrade", "--force", outPath])
    if upRc != 0:
      echo "  FAIL: kicad-cli pcb upgrade exited ", upRc, ": ", upOut.strip()
      inc failures
      continue
    let counts = countTokens(outPath)
    var ok = true
    if counts.fp != wantFp:
      echo "  FAIL: footprint count in-memory=", wantFp, " file=", counts.fp
      ok = false
    if counts.pad != wantPad:
      echo "  FAIL: pad count in-memory=", wantPad, " file=", counts.pad
      ok = false
    if counts.net != wantNet:
      echo "  FAIL: net count in-memory=", wantNet, " file=", counts.net
      ok = false

    let (drcOut, drcRc) = runCli(@["pcb", "drc", outPath])
    if drcRc != 0:
      echo "  FAIL: kicad-cli pcb drc exited ", drcRc, ": ", drcOut.strip()
      ok = false

    if ok:
      echo "  OK (fp=", counts.fp, " pad=", counts.pad, " net=", counts.net, ")"
    else:
      inc failures

  removeDir(tmpDir)
  echo ""
  echo "--- summary ---"
  echo "designs checked: ", designs.len
  echo "failures:        ", failures
  if failures > 0: quit(1)

main()
