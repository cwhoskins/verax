## Finds, fetches, builds MFEM and the C-ABI shim that verax loads at runtime.
## Mirrors `spice/xspice/build.nim`: an env var wins, a cache under
## `~/.cache/verax/` is the fallback, and an absent toolchain is an *empty
## answer* (the caller skips), never an exception.
##
## **Why a shim and not `importcpp`:** MFEM is C++. Binding it from Nim would
## force every program that imports `verax/fem/mfem` -- and the CLI -- to
## compile as C++ (`nim cpp`). The shim is a small `extern "C"` library built
## here with `g++`, so verax itself stays `nim c`.
##
## **Serial MFEM only** (no MPI/hypre/METIS) and **`MFEM_USE_EXCEPTIONS=ON`**:
## without it `mfem_error` calls `abort()`, and one bad mesh kills the verax
## process instead of reaching the shim's `catch`.
##
## In MFEM 4.10 `MFEM_USE_MPI`, `MFEM_USE_EXCEPTIONS` and `BUILD_SHARED_LIBS`
## all default `OFF`, so `buildMfem` passes every one explicitly rather than
## trusting a default that could move.

import std/[os, osproc, strutils]

const
  mfemVersion* = "4.10"
  mfemTag* = "v4.10"
  mfemCommit* = "d964264cdb9a13e94a201b6c236c7721e0c8765f"
    ## Recorded for provenance; the tarball is verified by `mfemSha256`.
  mfemUrl* = "https://codeload.github.com/mfem/mfem/tar.gz/refs/tags/v4.10"
    ## `codeload`, not `github.com/.../archive/...`: measured from the dev
    ## host, the `archive` URL timed out while `codeload` and
    ## `git ls-remote` answered.
  mfemSha256* = "d5aabe991b8b5569aa26e2b5d4b59ac617ee10ebac3d45fd6ff9c74b2c1a47dd"
  shimAbiVersion* = 1
    ## Must equal `vx_mfem_abi_version()` in `shim.cpp`; part of the shim's
    ## cache filename so a stale `.so` is never loaded against a newer binding.

const shimDir = currentSourcePath().parentDir
  ## Where `shim.cpp`/`shim.h` live, in a repo or a nimble install.

type
  MfemBuildError* = object of CatchableError

  MfemToolchain* = object
    found*: bool
      ## false: no usable MFEM install; every other field is empty.
    mfemDir*: string       ## install prefix (contains `share/mfem/config.mk`)
    version*: string       ## `MFEM_VERSION_STRING` from config.mk
    cxx*: string
    cxxFlags*, incFlags*, tplFlags*, extLibs*: string
    libDir*: string

proc fail(msg: string) {.noreturn.} =
  raise newException(MfemBuildError, msg)

proc cacheRoot*(): string =
  getEnv("VERAX_CACHE", getCacheDir() / "verax")

proc defaultInstallDir*(): string =
  cacheRoot() / ("mfem-" & mfemVersion) / "install"

proc run(exe: string, args: seq[string], workDir = ""): string {.discardable.} =
  let cmd = quoteShellCommand(@[exe] & args)
  let (output, code) = execCmdEx(cmd, workingDir = workDir)
  if code != 0:
    fail("command failed (exit " & $code & "):\n  " & cmd &
         (if workDir.len > 0: "\n  in: " & workDir else: "") &
         "\n--- output (tail) ---\n" &
         output.splitLines[max(0, output.splitLines.len - 40) .. ^1].join("\n"))
  output

proc parseConfigMk(text: string): seq[(string, string)] =
  ## `KEY = value` lines of an MFEM `config.mk`; `#` comments and anything
  ## else skipped. Flags are read from here rather than hard-coded so the
  ## shim is compiled with exactly what MFEM was.
  for line in text.splitLines:
    let t = line.strip
    if t.len == 0 or t[0] == '#': continue
    let eq = t.find('=')
    if eq <= 0: continue
    result.add (t[0 ..< eq].strip.strip(chars = {':', '?'}), t[eq + 1 .. ^1].strip)

proc expandVars(v: string, vars: seq[(string, string)]): string =
  ## Expand `$(NAME)` references. config.mk writes
  ## `MFEM_INCFLAGS = -I$(MFEM_INC_DIR) $(MFEM_TPLFLAGS)`, and those flags are
  ## handed to `g++` directly, not to `make`, so the references must be
  ## resolved here. Unknown names expand to empty (as make does); depth-capped
  ## so a self-referential file cannot loop.
  result = v
  for _ in 0 ..< 8:
    let a = result.find("$(")
    if a < 0: return
    let b = result.find(')', a)
    if b < 0: return
    let name = result[a + 2 ..< b]
    var val = ""
    for (k, x) in vars:
      if k == name: val = x
    result = result[0 ..< a] & val & result[b + 1 .. ^1]

proc findMfem*(mfemDir = ""): MfemToolchain =
  ## `mfemDir` wins, then `$MFEM_DIR`, then the cache install. A *set but
  ## wrong* `$MFEM_DIR` is an empty result, not a silent fall-through to the
  ## cache: someone who pointed at a tree and got a different one answering
  ## would be debugging the wrong library.
  let explicit = if mfemDir.len > 0: mfemDir else: getEnv("MFEM_DIR")
  let dir = if explicit.len > 0: explicit else: defaultInstallDir()
  let cfg = dir / "share" / "mfem" / "config.mk"
  if not fileExists(cfg): return
  result.mfemDir = dir.absolutePath
  let vars = parseConfigMk(readFile(cfg))
  for (k, raw) in vars:
    let v = expandVars(raw, vars)
    case k
    of "MFEM_VERSION_STRING": result.version = v
    of "MFEM_CXX": result.cxx = v
    of "MFEM_CXXFLAGS": result.cxxFlags = v
    of "MFEM_INCFLAGS": result.incFlags = v
    of "MFEM_TPLFLAGS": result.tplFlags = v
    of "MFEM_EXT_LIBS": result.extLibs = v
    of "MFEM_LIB_DIR": result.libDir = v
    else: discard
  if result.libDir.len == 0 or not dirExists(result.libDir):
    result.libDir = result.mfemDir / "lib"
  result.found = true

# --- fetching and building MFEM ---------------------------------------------

proc fetchMfem*(): string =
  ## Download (if not cached) and verify the pinned tarball; returns its path.
  let dir = cacheRoot() / ("mfem-" & mfemVersion)
  createDir(dir)
  result = dir / ("mfem-" & mfemVersion & ".tar.gz")
  proc ok(p: string): bool =
    fileExists(p) and
      run("sha256sum", @[p]).splitWhitespace[0] == mfemSha256
  if ok(result): return
  # No stdlib sha256 and std/httpclient needs OpenSSL at runtime; curl and
  # sha256sum are on every host that has the compiler MFEM needs anyway.
  run("curl", @["-fL", "--retry", "3", "-o", result, mfemUrl])
  if not ok(result):
    removeFile(result)
    fail("sha256 of " & mfemUrl & " does not match the pin " & mfemSha256 &
         "; refusing to build unverified source.")

proc buildMfem*(jobs = 0): MfemToolchain =
  ## Fetch, verify, configure and build serial shared MFEM into the cache.
  let tarball = fetchMfem()
  let root = tarball.parentDir
  let src = root / ("mfem-" & mfemVersion)
  let bld = root / "build"
  let prefix = defaultInstallDir()
  if not dirExists(src):
    run("tar", @["xzf", tarball, "-C", root])
  run("cmake", @["-S", src, "-B", bld, "-DCMAKE_BUILD_TYPE=Release",
                 "-DMFEM_USE_MPI=OFF", "-DMFEM_USE_EXCEPTIONS=ON",
                 "-DBUILD_SHARED_LIBS=ON", "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
                 "-DCMAKE_INSTALL_PREFIX=" & prefix])
  let j = if jobs > 0: jobs else: max(1, countProcessors())
  run("cmake", @["--build", bld, "-j", $j])
  run("cmake", @["--install", bld])
  result = findMfem(prefix)
  if not result.found:
    fail("MFEM installed but " & prefix / "share/mfem/config.mk" & " is missing")

# --- the shim -----------------------------------------------------------------

proc shimSourceHash(): string =
  ## FNV-1a 64 over `shim.cpp` + `shim.h`: only a cache key, so no
  ## cryptographic hash is needed (and the stdlib's `sha1` is deprecated).
  var h = 0xcbf29ce484222325'u64
  for c in readFile(shimDir / "shim.cpp") & readFile(shimDir / "shim.h"):
    h = (h xor uint64(ord(c))) * 0x100000001b3'u64
  result = toHex(h, 16).toLowerAscii

proc shimPath*(tc: MfemToolchain): string =
  ## Where the shim for this MFEM and this `shim.cpp` lives (it may not exist
  ## yet). ABI, MFEM version and a source hash are all in the name so a stale
  ## `.so` can never be mistaken for the current one.
  cacheRoot() / "mfem" / ("libverax_mfem-" & $shimAbiVersion & "-" &
    (if tc.version.len > 0: tc.version.replace(" ", "") else: "unknown") & "-" & shimSourceHash()[0 ..< 10] & ".so")

proc buildShim*(tc: MfemToolchain): string =
  ## Compile `shim.cpp` into `shimPath(tc)` (skipped if already there) and
  ## return it. The shim is `rpath`ed to MFEM's `lib/`, so loading it needs no
  ## `LD_LIBRARY_PATH`.
  if not tc.found:
    fail("no MFEM install: set $MFEM_DIR to an install prefix, or run `nimble mfem`.")
  result = shimPath(tc)
  if fileExists(result): return
  createDir(result.parentDir)
  let cxx = if tc.cxx.len > 0 and findExe(tc.cxx.splitWhitespace[0]).len > 0:
              tc.cxx else: "g++"
  # Flags come from config.mk as one shell string each, so go through `sh -c`;
  # `-std=c++17` last so it wins over whatever MFEM was configured with.
  let cmd = cxx & " -shared -fPIC -O2 " & tc.cxxFlags & " -std=c++17 " &
    tc.incFlags & " -I" & quoteShell(shimDir) & " " &
    quoteShell(shimDir / "shim.cpp") & " -o " & quoteShell(result & ".tmp") &
    " -L" & quoteShell(tc.libDir) & " -Wl,-rpath," & quoteShell(tc.libDir) &
    " -lmfem " & tc.extLibs
  let (output, code) = execCmdEx(cmd)
  if code != 0:
    fail("shim build failed (exit " & $code & "):\n  " & cmd & "\n--- output ---\n" & output)
  moveFile(result & ".tmp", result)  # atomic: a half-written .so is never loaded

when isMainModule:
  # `nimble mfem`: build MFEM if no install is found, then the shim.
  var tc = findMfem()
  if not tc.found:
    if getEnv("MFEM_DIR").len > 0:
      fail("$MFEM_DIR=" & getEnv("MFEM_DIR") & " has no share/mfem/config.mk; " &
           "unset it to let `nimble mfem` build into the cache.")
    echo "building MFEM ", mfemVersion, " into ", defaultInstallDir()
    tc = buildMfem()
  echo "MFEM install: ", tc.mfemDir, " (", tc.version, ")"
  echo "shim: ", buildShim(tc)
