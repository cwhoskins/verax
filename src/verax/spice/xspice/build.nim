## Compiles a Nim code-model source into a loadable ngspice `.cm`.
##
## **Needs a configured ngspice source tree** (`$NGSPICE_SRC`): MIF headers,
## `cmpp`, `dlmain.c`, `dstring.c`, and the generated `config.h`.
##
## Pipeline (mirrors ngspice's `icm` build):
##
## 1. compile with `-d:xspiceGenIfs` and run it to write `ifspec.ifs` (no
##    headers needed);
## 2. `cmpp -ifs` -> `ifspec.c`;
## 3. `cmpp -lst` -> the `cmextrn.h`/`cminfo.h`/`udn*.h` glue;
## 4. compile `ifspec.c`, `dlmain.c`, `dstring.c`;
## 5. compile the model with `--app:lib`, linking those.
##
## Two requirements:
##
## * **`dstring.c` must be linked** (`dlmain.c` needs `ds_init`/`ds_free`,
##   which ngspice doesn't export); otherwise `dlopen` fails.
## * **Configure flags must match the installed simulator**: `CIDER`/`KLU`
##   change `SPICEdev`'s layout, and a mismatch segfaults silently.
##   `checkAbi` catches what it can.
##
## Nothing links `libngspice`: `cm_*` calls go through `dlmain.c`'s
## `coreitf` table.

import std/[os, osproc, strutils, tempfiles]
import ./cmpath
export cmpath

type
  XspiceBuildError* = object of CatchableError

  Toolchain* = object
    ngspiceSrc*: string    ## unpacked ngspice source tree
    ngspiceBuild*: string  ## where `configure` wrote `config.h`; = src for in-tree
    cmpp*: string          ## the cmpp executable

const veraxSrcDir =
  currentSourcePath().parentDir.parentDir.parentDir.parentDir
    ## `<...>/src`, so `verax/spice/xspice/dsl` resolves from a repo or a
    ## nimble install.

proc fail(msg: string) {.noreturn.} =
  raise newException(XspiceBuildError, msg)

proc run(exe: string, args: seq[string], workDir = ""): string {.discardable.} =
  let cmd = quoteShellCommand(@[exe] & args)
  let (output, code) = execCmdEx(cmd, workingDir = workDir)
  if code != 0:
    fail("command failed (exit " & $code & "):\n  " & cmd &
         (if workDir.len > 0: "\n  in: " & workDir else: "") &
         "\n--- output ---\n" & output)
  output

proc buildCmpp(tc: Toolchain): string =
  ## Build `cmpp` from the tree. Release tarballs ship generated lexers and
  ## parsers, so only a C compiler is needed.
  let srcDir = tc.ngspiceSrc / "src" / "xspice" / "cmpp"
  var sources: seq[string]
  for f in walkFiles(srcDir / "*.c"): sources.add f
  if sources.len == 0:
    fail("no cmpp sources under " & srcDir)
  let outDir = getCacheDir() / "verax" / "xspice"
  createDir(outDir)
  result = outDir / "cmpp"
  var args = @["-O1", "-w",
               "-I" & tc.ngspiceSrc / "src" / "include",
               "-I" & tc.ngspiceBuild / "src" / "include",
               "-I" & srcDir]
  args.add sources
  args.add ["-o", result]
  run("cc", args)

proc findToolchain*(ngspiceSrc = "", ngspiceBuild = ""): Toolchain =
  ## Locate and validate the ngspice source tree and `cmpp`.
  result.ngspiceSrc = if ngspiceSrc.len > 0: ngspiceSrc else: getEnv("NGSPICE_SRC")
  if result.ngspiceSrc.len == 0:
    # Fall back to a tree in the cache directory, so a configured tree works
    # without exporting `$NGSPICE_SRC` (which still wins).
    let cache = getEnv("VERAX_CACHE", getCacheDir() / "verax")
    if dirExists(cache):
      var best = ""
      for kind, path in walkDir(cache):
        if kind != pcDir: continue
        if not path.lastPathPart.startsWith("ngspice"): continue
        if not fileExists(path / "src/include/ngspice/config.h"): continue
        if path > best: best = path      # newest version by name
      result.ngspiceSrc = best
  if result.ngspiceSrc.len == 0:
    fail("no ngspice source tree: set $NGSPICE_SRC (or pass ngspiceSrc), or " &
         "unpack a configured one under " &
         (getEnv("VERAX_CACHE", getCacheDir() / "verax")) & ". " &
         "A distro -devel package is not enough -- building a .cm needs " &
         "cmpp, dlmain.c and the MIF headers, which only the source ships.")
  result.ngspiceSrc = result.ngspiceSrc.absolutePath
  result.ngspiceBuild =
    if ngspiceBuild.len > 0: ngspiceBuild.absolutePath else: result.ngspiceSrc

  var missing: seq[string]
  for rel in ["src/include/ngspice/mifcmdat.h",
              "src/xspice/icm/dlmain.c",
              "src/misc/dstring.c"]:
    if not fileExists(result.ngspiceSrc / rel): missing.add rel
  if missing.len > 0:
    fail("$NGSPICE_SRC does not look like an ngspice source tree (" &
         result.ngspiceSrc & "); missing: " & missing.join(", "))
  if not fileExists(result.ngspiceBuild / "src/include/ngspice/config.h"):
    fail("ngspice tree at " & result.ngspiceBuild & " is not configured " &
         "(no src/include/ngspice/config.h). Run:\n" &
         "  ./configure --enable-xspice --enable-cider\n" &
         "in that tree first -- and see checkAbi about matching the flags of " &
         "the ngspice you intend to run.")

  let prebuilt = result.ngspiceSrc / "src" / "xspice" / "cmpp" / "cmpp"
  if fileExists(prebuilt): result.cmpp = prebuilt
  else:
    let onPath = findExe("cmpp")
    let cached = getCacheDir() / "verax" / "xspice" / "cmpp"
    if onPath.len > 0: result.cmpp = onPath
    elif fileExists(cached): result.cmpp = cached
    else: result.cmpp = buildCmpp(result)

proc configFlags*(tc: Toolchain): seq[string] =
  ## The feature macros `config.h` defines that affect struct layout.
  let text = readFile(tc.ngspiceBuild / "src/include/ngspice/config.h")
  for line in text.splitLines:
    let t = line.strip
    for flag in ["CIDER", "KLU", "XSPICE"]:
      if t.startsWith("#define " & flag) and flag notin result:
        result.add flag

proc checkAbi*(tc: Toolchain, ngspiceExe = "ngspice"): seq[string] =
  ## Compare the tree against the installed simulator; warnings only (a
  ## silent pass doesn't prove ABI agreement).
  let flags = tc.configFlags
  if "XSPICE" notin flags:
    fail("the ngspice tree at " & tc.ngspiceBuild & " was configured without " &
         "XSPICE; re-run ./configure --enable-xspice")
  let exe = findExe(ngspiceExe)
  if exe.len == 0:
    return @["ngspice not found on PATH; cannot check ABI parity"]
  let banner = try: execCmdEx(quoteShellCommand(@[exe, "-v"])).output
               except CatchableError: ""
  if banner.len == 0:
    return @["could not read `ngspice -v`; cannot check ABI parity"]
  let runtimeKlu = "KLU" in banner
  if runtimeKlu != ("KLU" in flags):
    result.add "KLU mismatch: installed ngspice " &
      (if runtimeKlu: "has" else: "lacks") & " KLU but the source tree " &
      (if "KLU" in flags: "has" else: "lacks") & " it. The .cm will segfault."
  if "CIDER" notin flags:
    result.add "the source tree is configured WITHOUT CIDER. `ngspice -v` " &
      "does not report CIDER, so this cannot be verified -- but if the " &
      "installed ngspice has it, the .cm will segfault inside ngspice with " &
      "no error message. Configure with --enable-cider if unsure."

proc buildCodeModel*(modelSource, outPath: string,
                     tc = findToolchain(),
                     buildDir = "",
                     extraNimFlags: seq[string] = @[]): string {.discardable.} =
  ## Compile `modelSource` (with a `codeModel` block) into a `.cm` at
  ## `outPath`; returns `outPath`.
  if not fileExists(modelSource):
    fail("no such model source: " & modelSource)
  let src = modelSource.absolutePath
  let outCm = outPath.absolutePath
  let bd = (if buildDir.len > 0: buildDir.absolutePath
            else: createTempDir("verax_xspice_", ""))
  let modDir = bd / "model"
  createDir(modDir)
  createDir(outCm.parentDir)

  let inc = @["-I" & bd, "-I" & modDir,
              "-I" & tc.ngspiceSrc / "src" / "include",
              "-I" & tc.ngspiceBuild / "src" / "include"]

  # 1. interface-only pass -- no ngspice headers needed here.
  let genExe = bd / "genifs"
  run("nim", @["c", "-d:xspiceGenIfs", "--hints:off", "--mm:arc",
               "--path:" & veraxSrcDir, "--nimcache:" & bd / "nc-ifs",
               "-o:" & genExe, src])
  run(genExe, @[modDir])
  if not fileExists(modDir / "ifspec.ifs"):
    fail("the -d:xspiceGenIfs pass produced no ifspec.ifs; does " & src &
         " contain a `codeModel` block at top level?")

  # 2/3. cmpp, which reads fixed filenames from the working directory.
  run(tc.cmpp, @["-ifs"], workDir = modDir)
  writeFile(bd / "modpath.lst", "model\n")
  writeFile(bd / "udnpath.lst", "")
  run(tc.cmpp, @["-lst"], workDir = bd)

  # 4. the C halves.
  for (obj, csrc) in [("ifspec.o", modDir / "ifspec.c"),
                      ("dlmain.o", tc.ngspiceSrc / "src/xspice/icm/dlmain.c"),
                      ("dstring.o", tc.ngspiceSrc / "src/misc/dstring.c")]:
    run("cc", @["-c", "-fPIC", "-O2", "-w"] & inc & @["-o", bd / obj, csrc])

  # 5. the Nim half, linked against them. `-d:release`, not `-d:danger`
  # (bounds checks matter here). Panics off, so a Defect is catchable and
  # reported instead of killing the ngspice session.
  var nimArgs = @["c", "--app:lib", "--mm:arc", "-d:useMalloc", "--threads:off",
                  "-d:release", "--stackTrace:off", "--lineTrace:off",
                  "--hints:off",
                  "--path:" & veraxSrcDir,
                  "-d:ngspiceSrc=" & tc.ngspiceSrc,
                  "--nimcache:" & bd / "nc-cm",
                  "--passC:-fPIC",
                  "--passC:" & inc.join(" "),
                  "--passL:" & quoteShellCommand(
                    @[bd / "ifspec.o", bd / "dlmain.o", bd / "dstring.o"]) & " -lm",
                  "--out:" & outCm]
  nimArgs.add extraNimFlags
  nimArgs.add src
  run("nim", nimArgs)

  if not fileExists(outCm):
    fail("nim reported success but produced no " & outCm)
  outCm

