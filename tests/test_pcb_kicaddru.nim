## `.kicad_dru` writer. The rendering checks always run; the acceptance gate
## needs `kicad-cli` (skipped without it): a fixture board + project + the
## emitted rules, `kicad-cli pcb drc`, and a deliberately violating track
## that must be reported -- proving the file is both parsed and enforced.

import std/[unittest, os, osproc, strutils, json, math]

import verax/pcb/formats/kicaddru

const board = """
(kicad_pcb
	(version 20241229)
	(generator "verax")
	(generator_version "0.1")
	(general (thickness 1.6))
	(paper "A4")
	(layers
		(0 "F.Cu" signal)
		(2 "B.Cu" signal)
		(25 "Edge.Cuts" user)
	)
	(setup (pad_to_mask_clearance 0))
	(net 0 "")
	(net 1 "SIG")
	(net 2 "AGG")
	(gr_rect (start 0 0) (end 100 50) (stroke (width 0.1) (type default)) (fill no) (layer "Edge.Cuts"))
	(segment (start 10 25) (end 70 25) (width 0.2) (layer "F.Cu") (net 1))
	(segment (start 10 25.5) (end 72 25.5) (width 0.2) (layer "F.Cu") (net 2))
)
"""
  ## A 60 mm track on net SIG, and a 62 mm one on AGG beside it: 0.3 mm
  ## edge to edge, 2 mm longer.

suite "render":
  test "length and via count per net, comments, skipped empties":
    let s = renderDru([
      druRule("SIG max length", netCondition("SIG"), maxLength = 0.142,
              comment = "derived by verax\nnet SIG"),
      druRule("SIG vias", netCondition("SIG"), maxViaCount = 2),
      druRule("nothing", netCondition("X"))])
    check s.startsWith("(version 1)\n")
    check "# derived by verax\n# net SIG\n" in s
    check "(condition \"A.NetName == 'SIG'\")" in s
    check "(constraint length (max 142.000mm))" in s
    check "(constraint via_count (max 2))" in s
    check "nothing" notin s

  test "a clearance between two nets, both orders":
    let s = renderDru([druRule("SIG/AGG spacing", pairCondition("SIG", "AGG"),
                               minClearance = 0.45e-3)])
    check "(constraint clearance (min 0.450mm))" in s
    check "A.NetName == 'SIG' && B.NetName == 'AGG'" in s
    check "A.NetName == 'AGG' && B.NetName == 'SIG'" in s

  test "a quote in a net name is refused, not escaped wrongly":
    expect ValueError:
      discard netCondition("A'B")

suite "kicad-cli DRC gate":
  proc drc(maxLen: float, clearance = NaN, skew = NaN): seq[string] =
    let dir = getTempDir() / "verax_dru_gate"
    createDir(dir)
    writeFile(dir / "b.kicad_pcb", board)
    writeFile(dir / "b.kicad_pro", """{"board": {}, "meta": {"filename": "b.kicad_pro", "version": 1}}""")
    var rules = @[druRule("SIG max length", netCondition("SIG"), maxLength = maxLen)]
    if not clearance.isNaN:
      rules.add druRule("SIG/AGG spacing", pairCondition("SIG", "AGG"), minClearance = clearance)
    if not skew.isNaN:
      rules.add druRule("SIG/AGG skew", eitherCondition("SIG", "AGG"), maxSkew = skew)
    writeDru(rules, dir / "b.kicad_dru")
    let (output, code) = execCmdEx("kicad-cli pcb drc --format json -o " &
                                   quoteShell(dir / "out.json") & " " & quoteShell(dir / "b.kicad_pcb"))
    check code == 0
    if code != 0: echo output
    let j = parseJson(readFile(dir / "out.json"))
    for v in j{"violations"}.getElems: result.add v["type"].getStr

  test "a violating track is reported, a compliant rule is silent":
    if findExe("kicad-cli").len == 0:
      skip()
    else:
      let (ver, _) = execCmdEx("kicad-cli version")
      if not ver.strip.startsWith("10."):
        echo "  note: gate proven on KiCad 10.0.6, running on ", ver.strip
      check "length_out_of_range" in drc(0.050)
      check "length_out_of_range" notin drc(0.070)

  test "a crosstalk spacing is enforced between exactly those two nets":
    if findExe("kicad-cli").len == 0:
      skip()
    else:
      check "clearance" in drc(0.070, clearance = 0.5e-3)
      check "clearance" notin drc(0.070, clearance = 0.2e-3)

  test "a pair's length skew is enforced":
    if findExe("kicad-cli").len == 0:
      skip()
    else:
      check "skew_out_of_range" in drc(0.070, skew = 1e-3)
      check "skew_out_of_range" notin drc(0.070, skew = 3e-3)
