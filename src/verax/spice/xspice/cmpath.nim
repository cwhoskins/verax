## Making a `.cm` path safe to write into a SPICE deck (stdlib only, so
## `spice/ngspice` can use it without the build driver).

import std/[hashes, os, strutils]

proc deckSafeCmPath*(cm: string): string =
  ## A path to `cm` that survives a deck: ngspice lowercases every line,
  ## including `pre_codemodel`'s argument, so any uppercase in the path
  ## breaks loading (quoting doesn't help). Common with temp dirs and home
  ## directories. Returns `cm` if already lowercase, else a lowercase
  ## symlink to it.
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
