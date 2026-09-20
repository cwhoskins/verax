## The structural proof for `verax/pcb/formats/sexp`: parse a real,
## KiCad-`Prettify()`'d file and reconstruct it byte for byte, then probe
## every pathological atom the corpus actually contains.
##
## `render(doc, fastPath = false)` is used throughout, never the default --
## `fastPath = true` just returns `doc.src` and would pass even if the
## recursive gap/child walk in `emitSiblings`/`emitNode` were wrong in every
## particular. Only `fastPath = false` recurses to every leaf and proves the
## reconstruction, which is the whole point of this file.

import std/[strutils, unittest]

import verax/pcb/formats/sexp

const FixturePath = "tests/fixtures/trim.kicad_pcb"

test "a real KiCad file round-trips byte-exact through fastPath = false":
  let d = parseSexpFile(FixturePath)
  let original = readFile(FixturePath)
  check render(d, fastPath = false) == original
  # Nothing about this fixture is corrupt, so the lexer should have found no
  # stray close-parens to note.
  check d.diagnostics.len == 0
  check d.roots.len == 1
  check d.head(d.roots[0]) == "kicad_pcb"

test "fastPath = true is the identity, and proves nothing on its own":
  let d = parseSexpFile(FixturePath)
  # This is the documented, deliberately-weak check: it would pass even if
  # emitSiblings/emitNode never worked, because it never calls them.
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
  # Everything else in the file is untouched.
  check output.len == d.src.len + ("(version 99999999)".len - "(version 20241229)".len)

test "a deleted node disappears with its leading gap, not a blank line":
  let d = parseSexpFile(FixturePath)
  let root = d.roots[0]
  # `(paper "A4")` sits between `(general ...)` and `(title_block ...)` in
  # this fixture -- delete it and check no blank/mis-indented line remains
  # where it was.
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
  # Every pathological atom below is a literal Nim string, not something
  # hunted for in a real file -- the fixture corpus is clean (no escapes, no
  # non-ASCII: see `sexp.nim`'s module doc), so this is the only way to
  # exercise the escape/quoting rules the corpus proves are *in use*
  # elsewhere (finding 6: `\\` x5965, `\n` x150, `\"` x76 across all 18
  # boards) without committing a multi-megabyte fixture just to catch one of
  # each.
  template roundtrip(src: string) =
    let d = parseSexp(src)
    check d.roots.len == 1
    check render(d, fastPath = false) == src

  # A Windows UNC path, doubled backslashes throughout.
  roundtrip("(model \"\\\\\\\\cern.ch\\\\dfs\\\\path\")")

  # An inch dimension with an embedded, escaped double-quote.
  roundtrip("(descr \"pin pitch 0.020\\\" (0.50mm)\")")

  # An embedded newline escape, not a real newline byte -- finding 6: "no
  # string spans a physical line".
  roundtrip("(descr \"line one\\nline two\")")

  # The empty net name, which must stay quoted rather than becoming a bare
  # (and therefore different-kind) atom.
  block:
    let d = parseSexp("(net 0 \"\")")
    let root = d.roots[0]
    let netNameNode = arg(d, root, 1)
    check d.kind(netNameNode) == skString
    check d.text(netNameNode) == ""
    check d.raw(netNameNode) == "\"\""

  # A bare (unquoted) key beside a quoted value in the same node.
  roundtrip("(property ki_fp_filters \"R_* C_*\")")

  # A hex bitmask atom -- must not be mistaken for anything but an opaque
  # token; `parseNumber` should refuse it rather than silently misparsing.
  block:
    let d = parseSexp("(layerselection 0x00000000_00000000_55555555_555555f5)")
    let root = d.roots[0]
    let valNode = arg(d, root, 0)
    check d.kind(valNode) == skAtom
    check d.raw(valNode) == "0x00000000_00000000_55555555_555555f5"
    var f: float
    check not parseNumber(d, valNode, f)

  # A UTF-8 multi-byte character inside a quoted string.
  roundtrip("(descr \"trademark ™ sign\")")

  # One list mixing an unquoted atom, two quoted strings and another atom --
  # exactly the shape of a `(layers)` row.
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
  # The shape of the corruption in RoyalBlue54L-Feather.kicad_pcb, distilled
  # to a few bytes: `(curved_edges no)filter_ratio 0.9)` where
  # `(curved_edges no)(filter_ratio 0.9)` was meant. The lexer must still
  # produce something that round-trips byte-exact and must not raise.
  let src = "(a (curved_edges no)filter_ratio 0.9))"
  let d = parseSexp(src)
  check render(d, fastPath = false) == src
  check d.diagnostics.len >= 1

test "an unclosed list at EOF is closed there, not raised on":
  # Unlike the excess-close case above, this one is **not** byte-exact --
  # there is no way to both "never raise" and reproduce a `)` that was never
  # written. It does not occur in the corpus (finding 2's file has 349 more
  # closes than opens, never the reverse), so nothing downstream depends on
  # byte-exactness here; the contract is only "does not raise, and produces
  # something with balanced parens".
  let src = "(a (b 1"
  let d = parseSexp(src)
  let output = render(d, fastPath = false)
  check output == "(a (b 1))"

test "children/kids/child/kidsNamed walk exactly the direct children":
  let d = parseSexp("(via (at 1 2) (size 0.5) (drill 0.3) (net 4))")
  let root = d.roots[0]
  let kidsSeq = d.children(root)
  # "via" itself is the head/first child, then four argument lists.
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
