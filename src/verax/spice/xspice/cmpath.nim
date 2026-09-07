## Making a `.cm` path safe to write into a SPICE deck.
##
## Split out of `xspice/build.nim` so `verax/spice/ngspice` can reuse it
## without pulling in the build driver: this module depends on nothing but the
## standard library.

import std/[hashes, os, strutils]

proc deckSafeCmPath*(cm: string): string =
  ## Return a path to `cm` that survives being written into a SPICE deck.
  ##
  ## ngspice lowercases every deck line before parsing -- including the
  ## argument of `pre_codemodel` -- so a `.cm` whose absolute path contains an
  ## uppercase character can *never* be loaded from a deck: ngspice reports
  ## `No such file or directory` for the case-folded name. Quoting does not
  ## help; the quotes are taken literally and become part of the filename.
  ## Verified against ngspice-46.
  ##
  ## This bites more often than it sounds: `std/tempfiles.createTempDir`
  ## generates mixed-case names, and `/home/SomeUser/...` is ordinary.
  ##
  ## Returns `cm` unchanged when its absolute path is already all-lowercase,
  ## otherwise an all-lowercase symlink to it. The symlink's *target* may of
  ## course contain uppercase -- only the text in the deck matters.
  let abs = cm.absolutePath
  if abs == abs.toLowerAscii: return abs
  var base = getTempDir()
  if base != base.toLowerAscii: base = "/tmp"
  let dir = base / "verax_cm"
  createDir(dir)
  result = dir / (abs.extractFilename.toLowerAscii.changeFileExt("") &
                  "_" & $(hash(abs).uint) & ".cm")
  if not fileExists(result) and not symlinkExists(result):
    createSymlink(abs, result)
