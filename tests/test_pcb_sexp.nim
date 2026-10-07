## Round-trips a real KiCad file byte for byte through
## `verax/pcb/formats/sexp`, then probes pathological atoms.
##
## Always `render(doc, fastPath = false)`: the fast path returns `doc.src`
## and proves nothing about the recursive emitter.

import std/[strutils, unittest]

import verax/pcb/formats/sexp

const FixturePath = "tests/fixtures/trim.kicad_pcb"

test "a real KiCad file round-trips byte-exact through fastPath = false":
  let d = parseSexpFile(FixturePath)
  let original = readFile(FixturePath)
  check render(d, fastPath = false) == original
  # The fixture isn't corrupt: no stray close-parens.
  check d.diagnostics.len == 0
  check d.roots.len == 1
  check d.head(d.roots[0]) == "kicad_pcb"

test "fastPath = true is the identity, and proves nothing on its own":
  let d = parseSexpFile(FixturePath)
  # Deliberately weak: never calls the emitter.
  check render(d, fastPath = true) == d.src

test "a modified node renders its override, not its source bytes":
  let d = parseSexpFile(FixturePath)
  let root = d.roots[0]
  let versionNode = d.child(root, "version")
  check versionNode >= 0
  markDirty(d, versionNode, "(version 99999999)")
  let output = render(d, fastPath = false)
  check "(version 99999999)" in output
  check "(version 20241229)" notin output
  # Everything else is untouched.
  check output.len == d.src.len + ("(version 99999999)".len - "(version 20241229)".len)

test "a deleted node disappears with its leading gap, not a blank line":
  let d = parseSexpFile(FixturePath)
  let root = d.roots[0]
  # Delete `(paper "A4")` and check no blank or mis-indented line remains.
  let paperNode = d.child(root, "paper")
  check paperNode >= 0
  markDeleted(d, paperNode)
  let output = render(d, fastPath = false)
  check "(paper " notin output
  check "\n\n\t(title_block" notin output   # would be a doubled gap
  check "\n\t(title_block" in output        # the original gap, reused verbatim

test "an inserted sibling lands after its anchor at the right depth":
  let d = parseSexpFile(FixturePath)
  let root = d.roots[0]
  let paperNode = d.child(root, "paper")
  markInserted(d, paperNode, "(comment \"inserted\")")
  let output = render(d, fastPath = false)
  let paperIdx = output.find("(paper ")
  let insertedIdx = output.find("(comment \"inserted\")")
  check paperIdx >= 0 and insertedIdx > paperIdx
  check "\n\t(comment \"inserted\")" in output

test "markInsertedBefore anchors to the preceding sibling":
  let d = parseSexpFile(FixturePath)
  let root = d.roots[0]
  let titleBlockNode = d.child(root, "title_block")
  check titleBlockNode >= 0
  markInsertedBefore(d, titleBlockNode, "(comment \"before\")")
  let output = render(d, fastPath = false)
  let commentIdx = output.find("(comment \"before\")")
  let titleIdx = output.find("(title_block")
  check commentIdx >= 0 and commentIdx < titleIdx

test "raw() is byte-identical and text() is non-destructively decoded":
  # Literal atoms, since the clean fixture has no escapes or non-ASCII but
  # real boards use `\\`, `\n` and `\"`.
  template roundtrip(src: string) =
    let d = parseSexp(src)
    check d.roots.len == 1
    check render(d, fastPath = false) == src

  # A Windows UNC path, doubled backslashes throughout.
  roundtrip("(model \"\\\\\\\\cern.ch\\\\dfs\\\\path\")")

  # An inch dimension with an embedded, escaped double-quote.
  roundtrip("(descr \"pin pitch 0.020\\\" (0.50mm)\")")

  # An escaped newline, not a real one: strings never span lines.
  roundtrip("(descr \"line one\\nline two\")")

  # The empty net name stays quoted, not a bare atom.
  block:
    let d = parseSexp("(net 0 \"\")")
    let root = d.roots[0]
    let netNameNode = arg(d, root, 1)
    check d.kind(netNameNode) == skString
    check d.text(netNameNode) == ""
    check d.raw(netNameNode) == "\"\""

  # A bare key beside a quoted value.
  roundtrip("(property ki_fp_filters \"R_* C_*\")")

  # A hex bitmask is opaque; `parseNumber` refuses it.
  block:
    let d = parseSexp("(layerselection 0x00000000_00000000_55555555_555555f5)")
    let root = d.roots[0]
    let valNode = arg(d, root, 0)
    check d.kind(valNode) == skAtom
    check d.raw(valNode) == "0x00000000_00000000_55555555_555555f5"
    var f: float
    check not parseNumber(d, valNode, f)

  # A multi-byte UTF-8 character in a quoted string.
  roundtrip("(descr \"trademark ™ sign\")")

  # Mixed atoms and quoted strings, like a `(layers)` row.
  block:
    let d = parseSexp("(0 \"F.Cu\" signal \"top_cu\")")
    let root = d.roots[0]
    check render(d, fastPath = false) == "(0 \"F.Cu\" signal \"top_cu\")"
    check d.kind(arg(d, root, 0)) == skString
    check d.text(arg(d, root, 0)) == "F.Cu"
    check d.kind(arg(d, root, 1)) == skAtom
    check d.text(arg(d, root, 1)) == "signal"
    check d.kind(arg(d, root, 2)) == skString
    check d.text(arg(d, root, 2)) == "top_cu"

test "a stray close-paren with no matching open is absorbed, not raised on":
  # A stray close-paren: `(curved_edges no)filter_ratio 0.9)` for
  # `(curved_edges no)(filter_ratio 0.9)`. Must round-trip and not raise.
  let src = "(a (curved_edges no)filter_ratio 0.9))"
  let d = parseSexp(src)
  check render(d, fastPath = false) == src
  check d.diagnostics.len >= 1

test "an unclosed list at EOF is closed there, not raised on":
  # Missing closes can't round-trip byte-exact (the `)` was never written);
  # the contract is only no raise and balanced output.
  let src = "(a (b 1"
  let d = parseSexp(src)
  let output = render(d, fastPath = false)
  check output == "(a (b 1))"

test "children/kids/child/kidsNamed walk exactly the direct children":
  let d = parseSexp("(via (at 1 2) (size 0.5) (drill 0.3) (net 4))")
  let root = d.roots[0]
  let kidsSeq = d.children(root)
  # "via" is the head, then four argument lists.
  check kidsSeq.len == 5
  check d.child(root, "at") >= 0
  check d.child(root, "size") >= 0
  check d.child(root, "missing") == -1
  var netCount = 0
  for n in d.kidsNamed(root, "net"): inc netCount
  check netCount == 1

test "arg() indexes past the head token":
  let d = parseSexp("(at 101.6 50.8 90)")
  let root = d.roots[0]
  var x, y, r: float
  check parseNumber(d, arg(d, root, 0), x)
  check parseNumber(d, arg(d, root, 1), y)
  check parseNumber(d, arg(d, root, 2), r)
  check x == 101.6
  check y == 50.8
  check r == 90.0
  check arg(d, root, 3) == -1

test "lineOf reports 1-based line numbers":
  let d = parseSexp("(a\n\t(b 1)\n\t(c 2)\n)")
  let root = d.roots[0]
  let bNode = d.child(root, "b")
  let cNode = d.child(root, "c")
  check lineOf(d, bNode) == 2
  check lineOf(d, cNode) == 3
